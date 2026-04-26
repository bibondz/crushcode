// src/tui/model/streaming.zig
// Streaming request management and tool execution extracted from chat_tui_app.zig

const std = @import("std");
const vaxis = @import("vaxis");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const core = @import("core_api");
const widget_types = @import("widget_types");
const widget_toast = @import("widget_toast");
const widget_diff_preview = @import("widget_diff_preview");
const widget_spinner = @import("widget_spinner");
const tool_executors = @import("chat_tool_executors");
const myers = @import("myers");
const array_list_compat = @import("array_list_compat");
const lifecycle_mod = @import("lifecycle_hooks");
const session_mod = @import("session");
const safety_checkpoint_mod = @import("safety_checkpoint");
const plan_mod = @import("plan_handler");
const feedback_mod = @import("feedback");
const token_tracking_mod = @import("token_tracking.zig");

// Import sibling modules
const history_mod = @import("history.zig");
const input_handling = @import("input_handling.zig");
const model_fallback = @import("fallback.zig");
const permissions_mod = @import("permissions.zig");
const helpers = @import("helpers.zig");
const status_mod = @import("status.zig");
const session_mgmt = @import("session_mgmt.zig");

// Threadlocal for stream callback
threadlocal var active_stream_model: ?*Model = null;

// ---------------------------------------------------------------------------
// Worker / thread lifecycle
// ---------------------------------------------------------------------------

pub fn reapWorkerIfDone(self: *Model) void {
    var thread_to_join: ?std.Thread = null;
    self.lock.lock();
    if (self.request_done and self.worker != null) {
        thread_to_join = self.worker;
        self.worker = null;
        self.request_done = false;
    }
    self.lock.unlock();

    if (thread_to_join) |thread| {
        thread.join();
    }
}

pub fn requestThreadMain(self: *Model) void {
    active_stream_model = self;
    defer active_stream_model = null;

    // Set checkpoint threadlocals for this request thread
    const session_id = if (self.current_session) |sess| sess.id else "";
    tool_executors.setCheckpointSessionId(session_id);
    if (session_id.len > 0) {
        if (session_mod.getSessionDb(self.allocator)) |db| {
            tool_executors.setSessionDbForCheckpoint(db);
            // The CheckpointManager is lightweight — create on stack
            var cp_mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
            tool_executors.setCheckpointManager(&cp_mgr);
        } else |_| {}
    }
    defer {
        tool_executors.setCheckpointManager(null);
        tool_executors.setSessionDbForCheckpoint(null);
        tool_executors.setCheckpointSessionId("");
    }

    runStreamingRequest(self) catch |err| {
        finishRequestWithCaughtError(self, err);
    };
}

// ---------------------------------------------------------------------------
// Streaming request pipeline
// ---------------------------------------------------------------------------

pub fn runStreamingRequest(self: *Model) !void {
    self.request_start_time = std.time.milliTimestamp();

    self.budget_mgr.checkAndResetPeriods();
    if (self.budget_mgr.isOverBudget()) {
        finishRequestWithErrorText(self, "Budget limit reached. Increase limits or start a new session.");
        return;
    }

    // Refresh context based on user's latest message (relevance-filtered)
    if (self.history.items.len > 0) {
        const last_msg = self.history.items[self.history.items.len - 1];
        if (std.mem.eql(u8, last_msg.role, "user")) {
            const user_content = last_msg.content orelse "";
            if (user_content.len > 0) {
                self.refreshContextForQuery(user_content);

                // Update the AI client with the refreshed system prompt
                if (self.client) |*client| {
                    if (self.effective_system_prompt) |prompt| {
                        client.setSystemPrompt(prompt);
                    }
                }
            }
        }
    }

    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var iteration: u32 = 0;

    while (iteration < self.max_iterations) : (iteration += 1) {
        total_input_tokens += helpers.estimateMessageTokens(self.history.items);

        // Execute pre_request lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .pre_request;
            hook_ctx.provider = self.provider_name;
            hook_ctx.model = self.model_name;
            hook_ctx.token_count = @intCast(helpers.estimateMessageTokens(self.history.items));
            self.lifecycle_hooks.execute(.pre_request, &hook_ctx) catch {};
        }

        var response = try sendChatStreamingWithFallback(self);
        defer helpers.freeChatResponse(self.allocator, &response);

        if (response.choices.len == 0) {
            // Execute on_error lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .on_error;
                hook_ctx.error_message = "No response received from provider";
                self.lifecycle_hooks.execute(.on_error, &hook_ctx) catch {};
            }
            finishRequestWithErrorText(self, "No response received from provider");
            return;
        }

        const content = response.choices[0].message.content orelse "";
        const tool_calls = response.choices[0].message.tool_calls;
        if (content.len == 0 and tool_calls == null) {
            // Execute on_error lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .on_error;
                hook_ctx.error_message = "No response received from provider";
                self.lifecycle_hooks.execute(.on_error, &hook_ctx) catch {};
            }
            finishRequestWithErrorText(self, "No response received from provider");
            return;
        }

        total_output_tokens += helpers.estimateResponseOutputTokens(content, tool_calls);
        try applyAssistantResponse(self, content, tool_calls);

        // Execute post_request lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .post_request;
            hook_ctx.token_count = @intCast(total_input_tokens + total_output_tokens);
            self.lifecycle_hooks.execute(.post_request, &hook_ctx) catch {};
        }

        if (tool_calls) |calls| {
            // Update spinner phrase for tool execution
            if (self.spinner) |*spinner| {
                if (calls.len == 1) {
                    const phrase = std.fmt.allocPrint(self.allocator, "Running {s}...", .{calls[0].name}) catch "Running tool...";
                    spinner.setContextPhrase(phrase);
                } else {
                    const phrase = std.fmt.allocPrint(self.allocator, "Running {d} tools...", .{calls.len}) catch "Running tools...";
                    spinner.setContextPhrase(phrase);
                }
            }
            try executeToolCalls(self, calls);
            if (iteration + 1 >= self.max_iterations) {
                finishRequestWithErrorText(self, "Stopped after reaching max tool iterations.");
                return;
            }
            try startNextAssistantPlaceholder(self);
            continue;
        }

        finishRequestSuccess(self, total_input_tokens, total_output_tokens);
        return;
    }

    finishRequestWithErrorText(self, "Stopped after reaching max tool iterations.");
}

// ---------------------------------------------------------------------------
// Fallback provider handling
// ---------------------------------------------------------------------------

pub fn activateFallbackProvider(self: *Model, index: usize) !void {
    const provider = self.fallback_providers.items[index];

    self.lock.lock();
    defer self.lock.unlock();
    try input_handling.replaceOwnedString(self, &self.provider_name, provider.provider_name);
    try input_handling.replaceOwnedString(self, &self.model_name, provider.model_name);
    try input_handling.replaceOwnedString(self, &self.api_key, provider.api_key);
    if (self.override_url) |current_override_url| self.allocator.free(current_override_url);
    self.override_url = if (provider.override_url) |override_url| try self.allocator.dupe(u8, override_url) else null;
    self.active_provider_index = index;
    try self.initializeClientFor(self.provider_name, self.model_name, self.api_key, self.override_url);
}

pub fn sendChatStreamingWithFallback(self: *Model) !core.ChatResponse {
    var index = self.active_provider_index;
    while (index < self.fallback_providers.items.len) : (index += 1) {
        try activateFallbackProvider(self, index);
        const response = self.client.?.sendChatStreaming(self.history.items, streamCallback) catch |err| {
            if (!helpers.isRetryableProviderError(err) or index + 1 >= self.fallback_providers.items.len) {
                return err;
            }
            const next_provider = self.fallback_providers.items[index + 1];
            const status_text = try std.fmt.allocPrint(self.allocator, "⚠ {s} failed, trying {s}/{s}...", .{
                self.fallback_providers.items[index].provider_name,
                next_provider.provider_name,
                next_provider.model_name,
            });
            defer self.allocator.free(status_text);
            try status_mod.setStatusMessage(self, status_text);
            try resetActiveAssistantPlaceholderForRetry(self);
            continue;
        };
        status_mod.clearStatusMessage(self);
        return response;
    }
    return error.NetworkError;
}

pub fn resetActiveAssistantPlaceholderForRetry(self: *Model) !void {
    self.lock.lock();
    defer self.lock.unlock();
    if (self.assistant_stream_index) |index| {
        try history_mod.replaceMessageUnlocked(self, index, "assistant", "Thinking...", null, null);
    }
    self.awaiting_first_token = true;
}

// ---------------------------------------------------------------------------
// Response application
// ---------------------------------------------------------------------------

pub fn applyAssistantResponse(self: *Model, content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (tool_calls) |_| {
        try history_mod.trackToolCallFilesUnlocked(self, tool_calls);
    }

    if (self.awaiting_first_token) {
        if (self.assistant_stream_index) |index| {
            try history_mod.replaceMessageUnlocked(self, index, "assistant", content, null, tool_calls);
        } else {
            try history_mod.addMessageWithToolsUnlocked(self, "assistant", content, null, tool_calls);
            self.assistant_stream_index = self.messages.items.len - 1;
        }
        self.awaiting_first_token = false;
    } else if (self.assistant_stream_index) |index| {
        try history_mod.replaceMessageUnlocked(self, index, "assistant", content, null, tool_calls);
    }

    try history_mod.appendHistoryMessageWithToolsUnlocked(self, "assistant", content, null, tool_calls);
    // Persist to cross-session memory
    self.memory.addMessage("assistant", content) catch {};
    self.memory.save() catch {};
    try session_mgmt.saveSessionSnapshotUnlocked(self);

    self.context_tokens = token_tracking_mod.estimateContextTokens(self);
    if (self.compactor.needsCompaction(self.context_tokens)) {
        self.performCompactionAuto() catch {};
    }
}

// ---------------------------------------------------------------------------
// Tool execution
// ---------------------------------------------------------------------------

pub fn executeToolCalls(self: *Model, tool_calls: []const core.client.ToolCallInfo) !void {
    // Plan mode: capture tool calls as plan steps instead of executing
    if (self.plan_mode.active) {
        if (self.plan_mode.current_plan == null) {
            _ = self.plan_mode.createPlan("Proposed changes") catch return;
        }
        if (self.plan_mode.current_plan) |*plan| {
            for (tool_calls) |tc| {
                const risk = plan_mod.assessRisk(tc.name, tc.arguments);
                const action = plan_mod.extractAction(self.allocator, tc.name, tc.arguments) catch "Unknown action";
                const target = plan_mod.extractTargetFile(tc.arguments);
                plan.addStep(action, target, risk, "", tc.name, tc.arguments) catch {};
                self.allocator.free(action);
            }
            const formatted = plan.format() catch return;
            defer self.allocator.free(formatted);
            self.lock.lock();
            try history_mod.addMessageUnlocked(self, "assistant", formatted);
            self.lock.unlock();
        }
        return;
    }

    // Delegation mode: batch multiple tool calls through sub-agent
    if (self.delegate_mode and tool_calls.len > 1) {
        var task_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer task_buf.deinit();
        const writer = task_buf.writer();
        writer.print("Execute {d} tool calls: ", .{tool_calls.len}) catch {};
        for (tool_calls, 0..) |tc, i| {
            if (i > 0) writer.print(", ", .{}) catch {};
            writer.print("{s}", .{tc.name}) catch {};
        }
        const task_desc = task_buf.items;

        if (self.delegator.canDelegate(0)) {
            var result = self.delegator.delegate(0, task_desc, .general) catch |err| {
                const err_msg = std.fmt.allocPrint(self.allocator, "error: delegation failed: {s}", .{@errorName(err)}) catch "error: delegation failed";
                self.lock.lock();
                try history_mod.addMessageUnlocked(self, "tool", err_msg);
                self.lock.unlock();
                return;
            };
            defer result.deinit(self.allocator);
            self.lock.lock();
            try history_mod.addMessageUnlocked(self, "assistant", result.output);
            self.lock.unlock();
            return;
        }
    }

    for (tool_calls) |tool_call| {
        // Execute pre_tool lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .pre_tool;
            hook_ctx.tool_name = tool_call.name;
            self.lifecycle_hooks.execute(.pre_tool, &hook_ctx) catch {};
        }

        // Compute diff preview for edit/write_file tools
        var preview_diff: ?[]const u8 = null;
        var diff_preview_activated = false;

        if (std.mem.eql(u8, tool_call.name, "edit") or std.mem.eql(u8, tool_call.name, "write_file")) {
            preview_diff = computeEditPreview(self, tool_call) catch null;

            // Try interactive diff preview for multi-hunk changes
            const file_path = helpers.extractToolFilePath(tool_call.arguments) orelse "";
            if (file_path.len > 0) {
                const original_content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 100 * 1024 * 1024) catch null;
                if (original_content) |orig| {
                    var new_content_opt: ?[]const u8 = null;
                    var new_content_owned = false;

                    if (std.mem.eql(u8, tool_call.name, "edit")) {
                        const parsed = std.json.parseFromSlice(
                            struct { file_path: ?[]const u8 = null, path: ?[]const u8 = null, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null },
                            self.allocator, tool_call.arguments, .{ .ignore_unknown_fields = true },
                        ) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            const old_s = p.value.old_string orelse "";
                            const new_s = p.value.new_string orelse "";
                            if (std.mem.indexOf(u8, orig, old_s)) |pos| {
                                const after = pos + old_s.len;
                                var buf = std.ArrayList(u8).empty;
                                defer if (!new_content_owned) buf.deinit(self.allocator);
                                buf.appendSlice(self.allocator, orig[0..pos]) catch {};
                                buf.appendSlice(self.allocator, new_s) catch {};
                                buf.appendSlice(self.allocator, orig[after..]) catch {};
                                new_content_opt = buf.toOwnedSlice(self.allocator) catch null;
                                new_content_owned = true;
                            }
                        }
                    } else {
                        const parsed = std.json.parseFromSlice(
                            struct { path: ?[]const u8 = null, file_path: ?[]const u8 = null, content: ?[]const u8 = null },
                            self.allocator, tool_call.arguments, .{ .ignore_unknown_fields = true },
                        ) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            new_content_opt = p.value.content;
                        }
                    }

                    if (new_content_opt) |new_cont| {
                        var diff_result = myers.MyersDiff.diff(self.allocator, orig, new_cont) catch null;
                        if (diff_result) |*dr| {
                            if (dr.hunks.len >= 2) {
                                // Multi-hunk: activate diff preview
                                const decisions = self.allocator.alloc(widget_diff_preview.HunkDecision, dr.hunks.len) catch null;
                                if (decisions) |decs| {
                                    @memset(decs, .pending);
                                    self.lock.lock();
                                    self.diff_preview_active = true;
                                    self.diff_preview_hunks = dr.hunks;
                                    self.diff_preview_current = 0;
                                    self.diff_preview_file_path = file_path;
                                    self.diff_preview_original = orig;
                                    self.diff_preview_new_content = new_cont;
                                    self.diff_preview_tool_call_id = tool_call.id;
                                    self.diff_preview_tool_name = tool_call.name;
                                    self.diff_preview_tool_arguments = tool_call.arguments;
                                    self.diff_preview_decisions = decs;
                                    self.lock.unlock();
                                    diff_preview_activated = true;
                                    if (preview_diff) |d| self.allocator.free(d);
                                    // Don't free orig — referenced by hunks
                                    // Don't free dr — hunks reference its data
                                }
                            }
                            if (!diff_preview_activated) dr.deinit();
                        }
                    }
                    if (!diff_preview_activated) {
                        self.allocator.free(orig);
                    }
                }
            }
        }

        if (diff_preview_activated) continue;

        const allowed = try permissions_mod.requestToolPermission(self, tool_call.name, tool_call.arguments, preview_diff);
        if (preview_diff) |d| self.allocator.free(d);
        const result_text = if (!allowed)
            try self.allocator.dupe(u8, "error: tool execution denied by user")
        else blk: {
            // Use HybridBridge for unified tool dispatch (builtin + MCP)
            const parsed_tool_call = core.ParsedToolCall{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
            if (self.hybrid_bridge) |hb| {
                if (hb.executeTool(parsed_tool_call)) |result|
                    break :blk result
                else |_|
                    break :blk try std.fmt.allocPrint(self.allocator, "error: unsupported tool '{s}'", .{tool_call.name});
            }
            break :blk try self.allocator.dupe(u8, "error: tool dispatch unavailable");
        };
        defer self.allocator.free(result_text);

        // Execute post_tool lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .post_tool;
            hook_ctx.tool_name = tool_call.name;
            self.lifecycle_hooks.execute(.post_tool, &hook_ctx) catch {};
        }

        // Record tool call for auto-skill pattern detection (non-fatal)
        if (self.auto_gen) |*ag| {
            const is_success = !std.mem.startsWith(u8, result_text, "error:");
            const args_trimmed = if (tool_call.arguments.len > 80) tool_call.arguments[0..80] else tool_call.arguments;
            ag.recordToolCall(tool_call.name, args_trimmed, is_success) catch {};
            _ = ag.analyzePatterns() catch {};
        }

        // Record tool outcome for feedback learning (non-fatal)
        if (self.feedback) |*fb| {
            const fb_success = !std.mem.startsWith(u8, result_text, "error:");
            const fb_outcome: feedback_mod.TaskOutcome = if (fb_success) .success else .failure;
            const fb_err: []const u8 = if (fb_success) "" else result_text;
            var fb_tools = [_][]const u8{tool_call.name};
            fb.record("tool_execution", &fb_tools, fb_outcome, 0.8, fb_err) catch {};
        }

        // Update LSP diagnostics after file edits (non-fatal)
        if (std.mem.eql(u8, tool_call.name, "write_file") or std.mem.eql(u8, tool_call.name, "edit")) {
            // Extract file path from tool arguments
            const file_path = helpers.extractToolFilePath(tool_call.arguments);
            if (file_path) |fp| {
                self.lsp_manager.onFileOpened(fp);
            }
        }

        self.lock.lock();
        errdefer self.lock.unlock();
        try history_mod.addMessageWithToolsUnlocked(self, "tool", result_text, tool_call.id, null);
        try history_mod.appendHistoryMessageWithToolsUnlocked(self, "tool", result_text, tool_call.id, null);
        try session_mgmt.saveSessionSnapshotUnlocked(self);
        self.lock.unlock();
    }
}

// ---------------------------------------------------------------------------
// Diff preview
// ---------------------------------------------------------------------------

/// Compute a unified diff preview for edit/write_file tool calls without applying them.
pub fn computeEditPreview(self: *Model, tool_call: core.client.ToolCallInfo) !?[]const u8 {
    if (std.mem.eql(u8, tool_call.name, "edit")) {
        const parsed = std.json.parseFromSlice(
            struct { file_path: ?[]const u8 = null, path: ?[]const u8 = null, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null },
            self.allocator,
            tool_call.arguments,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();
        const fp = parsed.value.file_path orelse parsed.value.path orelse return null;
        const old_s = parsed.value.old_string orelse return null;
        const new_s = parsed.value.new_string orelse "";
        return try tool_executors.previewEditDiff(self.allocator, fp, old_s, new_s);
    }

    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        const parsed = std.json.parseFromSlice(
            struct { path: ?[]const u8 = null, file_path: ?[]const u8 = null, content: ?[]const u8 = null },
            self.allocator,
            tool_call.arguments,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();
        const fp = parsed.value.path orelse parsed.value.file_path orelse return null;
        const content = parsed.value.content orelse return null;
        return try tool_executors.previewWriteDiff(self.allocator, fp, content);
    }

    return null;
}

/// Handle key input during diff preview mode. Returns true if key was consumed.
pub fn handleDiffPreviewKey(self: *Model, key: vaxis.Key) bool {
    if (!self.diff_preview_active) return false;
    if (self.diff_preview_decisions.len == 0) return false;

    const current = self.diff_preview_current;

    if (key.matches('y', .{})) {
        if (current < self.diff_preview_decisions.len) {
            self.diff_preview_decisions[current] = .applied;
            if (current + 1 < self.diff_preview_decisions.len) {
                self.diff_preview_current = current + 1;
            } else {
                finishDiffPreview(self);
            }
        }
        return true;
    }
    if (key.matches('n', .{})) {
        if (current < self.diff_preview_decisions.len) {
            self.diff_preview_decisions[current] = .rejected;
            if (current + 1 < self.diff_preview_decisions.len) {
                self.diff_preview_current = current + 1;
            } else {
                finishDiffPreview(self);
            }
        }
        return true;
    }
    if (key.matches('a', .{})) {
        for (self.diff_preview_decisions[current..]) |*d| {
            d.* = .applied;
        }
        finishDiffPreview(self);
        return true;
    }
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
        for (self.diff_preview_decisions[current..]) |*d| {
            d.* = .rejected;
        }
        finishDiffPreview(self);
        return true;
    }
    if (key.matches('j', .{})) {
        if (current + 1 < self.diff_preview_decisions.len) {
            self.diff_preview_current = current + 1;
        }
        return true;
    }
    if (key.matches('k', .{})) {
        if (current > 0) {
            self.diff_preview_current = current - 1;
        }
        return true;
    }

    return true; // Consume all keys while diff preview is active
}

/// Finish diff preview: compute resulting text with selected hunks applied
pub fn finishDiffPreview(self: *Model) void {
    self.diff_preview_active = false;

    // Apply selected hunks: build output by walking through original lines
    // and substituting hunk content for applied hunks
    var result_buf = std.ArrayList(u8).empty;
    defer result_buf.deinit(self.allocator);

    var orig_lines = std.ArrayList([]const u8).empty;
    defer orig_lines.deinit(self.allocator);
    if (self.diff_preview_original.len > 0) {
        var iter = std.mem.splitScalar(u8, self.diff_preview_original, '\n');
        while (iter.next()) |line| {
            orig_lines.append(self.allocator, line) catch {};
        }
        // Remove trailing empty element from trailing newline
        if (self.diff_preview_original[self.diff_preview_original.len - 1] == '\n') {
            if (orig_lines.items.len > 0 and orig_lines.items[orig_lines.items.len - 1].len == 0) {
                orig_lines.items.len -= 1;
            }
        }
    }

    var cur_line: usize = 0;
    var hunk_idx: usize = 0;
    while (hunk_idx < self.diff_preview_hunks.len) : (hunk_idx += 1) {
        const hunk = self.diff_preview_hunks[hunk_idx];
        const decision = if (hunk_idx < self.diff_preview_decisions.len) self.diff_preview_decisions[hunk_idx] else .rejected;

        // Copy unchanged lines before this hunk (old_start is 1-based)
        const hunk_start_0: usize = if (hunk.old_start > 0) hunk.old_start - 1 else 0;
        while (cur_line < hunk_start_0 and cur_line < orig_lines.items.len) : (cur_line += 1) {
            result_buf.appendSlice(self.allocator, orig_lines.items[cur_line]) catch {};
            result_buf.append(self.allocator, '\n') catch {};
        }

        if (decision == .applied) {
            // Apply hunk: use new content from hunk lines
            for (hunk.lines) |line| {
                if (line.kind == .insert) {
                    result_buf.appendSlice(self.allocator, line.content) catch {};
                    result_buf.append(self.allocator, '\n') catch {};
                } else if (line.kind == .equal) {
                    result_buf.appendSlice(self.allocator, line.content) catch {};
                    result_buf.append(self.allocator, '\n') catch {};
                }
                // Skip .delete lines
            }
        } else {
            // Reject hunk: keep original lines
            var count: usize = 0;
            while (count < hunk.old_count and cur_line < orig_lines.items.len) : ({
                count += 1;
                cur_line += 1;
            }) {
                result_buf.appendSlice(self.allocator, orig_lines.items[cur_line]) catch {};
                result_buf.append(self.allocator, '\n') catch {};
            }
        }
        cur_line = hunk_start_0 + hunk.old_count;
    }

    // Copy remaining unchanged lines after last hunk
    while (cur_line < orig_lines.items.len) : (cur_line += 1) {
        result_buf.appendSlice(self.allocator, orig_lines.items[cur_line]) catch {};
        result_buf.append(self.allocator, '\n') catch {};
    }

    const result_text = result_buf.toOwnedSlice(self.allocator) catch "error: failed to apply hunks";
    defer if (!std.mem.startsWith(u8, result_text, "error:")) self.allocator.free(result_text);

    // Write the result to file
    if (self.diff_preview_file_path.len > 0 and !std.mem.startsWith(u8, result_text, "error:")) {
        if (std.fs.cwd().createFile(self.diff_preview_file_path, .{})) |file| {
            file.writeAll(result_text) catch {};
            file.close();
        } else |_| {}
    }

    // Count applied hunks
    var applied_count: usize = 0;
    for (self.diff_preview_decisions) |d| {
        if (d == .applied) applied_count += 1;
    }

    const tool_result = if (applied_count > 0)
        std.fmt.allocPrint(self.allocator, "Applied {d} of {d} hunks to {s}", .{
            applied_count, self.diff_preview_decisions.len, self.diff_preview_file_path,
        }) catch "Applied selected hunks"
    else
        self.allocator.dupe(u8, "error: all hunks rejected by user") catch "error: rejected";

    self.lock.lock();
    history_mod.addMessageWithToolsUnlocked(self, "tool", tool_result, self.diff_preview_tool_call_id, null) catch {};
    history_mod.appendHistoryMessageWithToolsUnlocked(self, "tool", tool_result, self.diff_preview_tool_call_id, null) catch {};
    session_mgmt.saveSessionSnapshotUnlocked(self) catch {};
    self.lock.unlock();
    self.allocator.free(tool_result);

    // Clean up diff preview state
    self.allocator.free(self.diff_preview_original);
    self.allocator.free(self.diff_preview_decisions);
    self.diff_preview_hunks = &.{};
    self.diff_preview_decisions = &.{};
}

// ---------------------------------------------------------------------------
// Request completion
// ---------------------------------------------------------------------------

pub fn startNextAssistantPlaceholder(self: *Model) !void {
    self.lock.lock();
    defer self.lock.unlock();
    try history_mod.addMessageUnlocked(self, "assistant", "Thinking...");
    self.assistant_stream_index = self.messages.items.len - 1;
    self.awaiting_first_token = true;
    var spinner = widget_spinner.AnimatedSpinner.init(self.current_theme);
    spinner.setContextPhrase("Thinking...");
    self.spinner = spinner;
    try session_mgmt.saveSessionSnapshotUnlocked(self);
}

pub fn finishRequestSuccess(self: *Model, input_tokens: u64, output_tokens: u64) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.total_input_tokens += input_tokens;
    self.total_output_tokens += output_tokens;
    self.request_count += 1;
    
    // Record per-turn token usage for sparkline
    const turn_total: u32 = @intCast(@min(input_tokens + output_tokens, std.math.maxInt(u32)));
    self.turn_token_history.append(turn_total) catch {};
    
    const cost = self.pricing_table.estimateCostSimple(self.provider_name, helpers.resolvedPricingModel(self), @intCast(@min(input_tokens, std.math.maxInt(u32))), @intCast(@min(output_tokens, std.math.maxInt(u32))));
    self.budget_mgr.recordCost(cost);
    if (self.budget_mgr.shouldAlert()) {
        const status = self.budget_mgr.checkBudget();
        const severity: widget_toast.Severity = if (status.isOverBudget()) .err else .warning;
        const message = if (status.isOverBudget())
            std.fmt.allocPrint(self.allocator, "Budget exceeded: ${d:.2}", .{self.budget_mgr.session_spent}) catch "Budget exceeded"
        else
            std.fmt.allocPrint(self.allocator, "Budget alert: ${d:.2} ({d:.0}% used)", .{ self.budget_mgr.session_spent, status.percent_used * 100.0 }) catch "Budget alert";
        self.toast_stack.push(message, severity) catch {};
    }
    self.request_active = false;
    self.request_done = true;
    self.spinner = null;
    // Keep typewriter alive so animation can finish naturally
    session_mgmt.saveSessionSnapshotUnlocked(self) catch {};

    // Auto-compact when context exceeds 70% of model window
    if (self.compactor.needsCompaction(self.context_tokens)) {
        self.performCompactionAuto() catch |err| {
            std.log.warn("Auto-compaction failed: {}", .{err});
        };
    }
}

pub fn finishRequestWithCaughtError(self: *Model, err: anyerror) void {
    switch (err) {
        error.AuthenticationError => finishRequestWithErrorText(self, "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"),
        error.NetworkError => finishRequestWithErrorText(self, "Network error while contacting provider. Check your connection and try again."),
        error.TimeoutError => finishRequestWithErrorText(self, "Request timed out. Please try again."),
        error.ServerError => finishRequestWithErrorText(self, "Provider returned an error. Please try again in a moment."),
        error.InvalidResponse => finishRequestWithErrorText(self, "Provider returned an invalid response."),
        error.ConfigurationError => finishRequestWithErrorText(self, "Chat client is not configured correctly. Run crushcode setup or edit ~/.crushcode/config.toml"),
        else => {
            const text = std.fmt.allocPrint(self.allocator, "Request failed: {s}", .{@errorName(err)}) catch return;
            defer self.allocator.free(text);
            finishRequestWithErrorText(self, text);
        },
    }
}

pub fn finishRequestWithErrorText(self: *Model, text: []const u8) void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.awaiting_first_token) {
        if (self.assistant_stream_index) |index| {
            history_mod.replaceMessageUnlocked(self, index, "error", text, null, null) catch {
                history_mod.addMessageUnlocked(self, "error", text) catch {};
            };
        } else {
            history_mod.addMessageUnlocked(self, "error", text) catch {};
        }
        self.awaiting_first_token = false;
    } else {
        history_mod.addMessageUnlocked(self, "error", text) catch {};
    }

    self.request_active = false;
    self.request_done = true;
    self.spinner = null;
    // Reveal typewriter immediately on error so the error text is fully visible
    if (self.typewriter) |*tw| {
        tw.revealAll();
    }
    session_mgmt.saveSessionSnapshotUnlocked(self) catch {};
}

// ---------------------------------------------------------------------------
// Stream token handling
// ---------------------------------------------------------------------------

pub fn handleStreamToken(self: *Model, token: []const u8, done: bool) void {
    _ = done;
    if (token.len == 0) {
        return;
    }

    if (self.awaiting_first_token) {
        const ttft = std.time.milliTimestamp() - self.request_start_time;
        std.debug.print("[PERF] TTFT: {d}ms\n", .{ttft});
    }

    // Feed token to spinner for animation + stalled detection
    if (self.spinner) |*spinner| {
        spinner.feedToken();
        // Update context phrase when streaming starts
        if (self.awaiting_first_token) {
            spinner.setContextPhrase("Writing...");
        }
    }

    self.lock.lock();
    defer self.lock.unlock();

    const index = self.assistant_stream_index orelse return;
    if (self.awaiting_first_token) {
        history_mod.replaceMessageUnlocked(self, index, "assistant", token, null, null) catch {};
        self.awaiting_first_token = false;
    } else {
        history_mod.appendToMessageUnlocked(self, index, token) catch {};
    }

    // Feed updated text to typewriter for progressive reveal
    if (self.typewriter) |*tw| {
        const msg = &self.messages.items[index];
        tw.updateText(msg.content);
    }
}

// ---------------------------------------------------------------------------
// Stream callback (file-level, uses active_stream_model threadlocal)
// ---------------------------------------------------------------------------

fn streamCallback(token: []const u8, done: bool) void {
    const model = active_stream_model orelse return;
    handleStreamToken(model, token, done);
}
