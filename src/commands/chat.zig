const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const client_mod = @import("client");
const core = @import("core_api");
const intent_gate_mod = @import("intent_gate");
const lifecycle_hooks_mod = @import("lifecycle_hooks");
const compaction_mod = @import("compaction");
const graph_mod = @import("graph");
const mcp_bridge_mod = @import("mcp_bridge");
const agent_loop_mod = @import("agent_loop");
const tools_mod = @import("tools");
const tool_loader = @import("tool_loader");

const Config = config_mod.Config;
const HookContext = lifecycle_hooks_mod.HookContext;
const IntentGate = intent_gate_mod.IntentGate;
const LifecycleHooks = lifecycle_hooks_mod.LifecycleHooks;
const ContextCompactor = compaction_mod.ContextCompactor;
const KnowledgeGraph = graph_mod.KnowledgeGraph;
const Bridge = mcp_bridge_mod.Bridge;
const AgentLoop = agent_loop_mod.AgentLoop;
const AIResponse = agent_loop_mod.AIResponse;
const LoopMessage = agent_loop_mod.LoopMessage;
const ToolExecutor = agent_loop_mod.ToolExecutor;
const ToolResult = agent_loop_mod.ToolResult;
const ToolRegistry = tools_mod.ToolRegistry;

fn preRequestHook(ctx: *HookContext) !void {
    std.debug.print("\x1b[2m[hook: {s} → {s}/{s}]\x1b[0m\n", .{
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
    });
}

fn postRequestHook(ctx: *HookContext) !void {
    std.debug.print("\x1b[2m[hook: {s} ← {s}/{s} | tokens: {d}]\x1b[0m\n", .{
        @tagName(ctx.phase),
        ctx.provider,
        ctx.model,
        ctx.token_count,
    });
}

fn registerCoreChatHooks(hooks: *LifecycleHooks) !void {
    try hooks.register("chat_pre_request", .core, .pre_request, preRequestHook, 10);
    try hooks.register("chat_post_request", .core, .post_request, postRequestHook, 20);
}

fn clampUsizeToU32(value: usize) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

fn clampU64ToU32(value: u64) u32 {
    if (value > std.math.maxInt(u32)) {
        return std.math.maxInt(u32);
    }
    return @as(u32, @intCast(value));
}

fn freeLastMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator) void {
    const removed = messages.pop().?;
    freeChatMessage(removed, allocator);
}

fn freeToolCallInfos(tool_calls: ?[]const ai_types.ToolCallInfo, allocator: std.mem.Allocator) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn freeChatMessage(message: core.ChatMessage, allocator: std.mem.Allocator) void {
    allocator.free(message.role);
    if (message.content) |content| {
        allocator.free(content);
    }
    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }
    freeToolCallInfos(message.tool_calls, allocator);
}

fn rollbackMessagesTo(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, target_len: usize) void {
    while (messages.items.len > target_len) {
        freeLastMessage(messages, allocator);
    }
}

fn duplicateToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const ai_types.ToolCallInfo) !?[]const ai_types.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(ai_types.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn appendResponseMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, message: core.ChatMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, message.role),
        .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
        .tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = try duplicateToolCallInfos(allocator, message.tool_calls),
    });
}

const ToolExecution = struct {
    display: []const u8,
    result: []const u8,
};

const InteractiveBridgeContext = struct {
    allocator: std.mem.Allocator,
    client: *core.AIClient,
    messages: *array_list_compat.ArrayList(core.ChatMessage),
    hooks: *LifecycleHooks,
    provider_name: []const u8,
    model_name: []const u8,
    turn_start_len: usize,
    synced_loop_messages: usize,
    turn_request_count: u32,
    turn_failed: bool,
    total_input_tokens: *u64,
    total_output_tokens: *u64,
    request_count: *u32,
    /// Per-request arena — reset after each AI response.
    /// Eliminates per-token/per-JSON-parse individual allocations.
    /// Tokens accumulate in the arena; whole arena freed on reset.
    request_arena: std.heap.ArenaAllocator,
};

const BuiltinToolDefinition = struct {
    name: []const u8,
    executor: ToolExecutor,
};

threadlocal var active_bridge_context: ?*InteractiveBridgeContext = null;

fn buildToolFailure(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall, err: anyerror) !ToolExecution {
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 {s} → error: {s}\n", .{ tool_call.name, @errorName(err) }),
        .result = try std.fmt.allocPrint(allocator, "Tool execution failed: {s}", .{@errorName(err)}),
    };
}

fn elapsedMillis(start_ms: i64) u64 {
    const end_ms = std.time.milliTimestamp();
    if (end_ms <= start_ms) {
        return 0;
    }
    return @as(u64, @intCast(end_ms - start_ms));
}

fn adaptToolExecution(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
    implementation: *const fn (std.mem.Allocator, core.ParsedToolCall) anyerror!ToolExecution,
) !ToolResult {
    const start_ms = std.time.milliTimestamp();
    const tool_call = core.ParsedToolCall{
        .id = call_id,
        .name = tool_name,
        .arguments = arguments,
    };

    var success = true;
    const execution = implementation(allocator, tool_call) catch |err| blk: {
        success = false;
        break :blk try buildToolFailure(allocator, tool_call, err);
    };
    defer allocator.free(execution.display);
    defer allocator.free(execution.result);

    std.debug.print("\n{s}", .{execution.display});

    var result = try ToolResult.init(allocator, call_id, execution.result, success);
    result.duration_ms = elapsedMillis(start_ms);
    return result;
}

fn readFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "read_file", arguments, executeReadFileTool);
}

fn shellExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "shell", arguments, executeShellTool);
}

fn writeFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "write_file", arguments, executeWriteFileTool);
}

fn globExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "glob", arguments, executeGlobTool);
}

fn grepExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "grep", arguments, executeGrepTool);
}

fn editExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "edit", arguments, executeEditTool);
}

const builtin_tool_bindings = [_]BuiltinToolDefinition{
    .{
        .name = "read_file",
        .executor = readFileExecutor,
    },
    .{
        .name = "shell",
        .executor = shellExecutor,
    },
    .{
        .name = "write_file",
        .executor = writeFileExecutor,
    },
    .{
        .name = "glob",
        .executor = globExecutor,
    },
    .{
        .name = "grep",
        .executor = grepExecutor,
    },
    .{
        .name = "edit",
        .executor = editExecutor,
    },
};

fn getExecutorForTool(name: []const u8) ?ToolExecutor {
    inline for (builtin_tool_bindings) |tool_binding| {
        if (std.mem.eql(u8, name, tool_binding.name)) {
            return tool_binding.executor;
        }
    }

    return null;
}

fn collectSupportedToolSchemas(allocator: std.mem.Allocator, tool_schemas: []const core.ToolSchema) ![]const core.ToolSchema {
    var supported = array_list_compat.ArrayList(core.ToolSchema).init(allocator);
    errdefer supported.deinit();

    for (tool_schemas) |schema| {
        if (getExecutorForTool(schema.name) != null) {
            try supported.append(schema);
        }
    }

    return supported.toOwnedSlice();
}

fn registerBuiltinAgentTools(agent_loop: *AgentLoop, tool_schemas: []const core.ToolSchema) !void {
    for (tool_schemas) |schema| {
        if (getExecutorForTool(schema.name)) |executor| {
            try agent_loop.registerTool(schema.name, executor);
        }
    }
}

fn appendLoopHistoryMessage(messages: *array_list_compat.ArrayList(core.ChatMessage), allocator: std.mem.Allocator, loop_message: LoopMessage) !void {
    try messages.append(.{
        .role = try allocator.dupe(u8, loop_message.role),
        .content = if (loop_message.content.len > 0) try allocator.dupe(u8, loop_message.content) else null,
        .tool_call_id = if (loop_message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
        .tool_calls = null,
    });
}

fn syncLoopMessagesToOuterHistory(ctx: *InteractiveBridgeContext, loop_messages: []const LoopMessage) !void {
    while (ctx.synced_loop_messages < loop_messages.len) : (ctx.synced_loop_messages += 1) {
        const loop_message = loop_messages[ctx.synced_loop_messages];
        if (std.mem.eql(u8, loop_message.role, "assistant")) {
            continue;
        }
        try appendLoopHistoryMessage(ctx.messages, ctx.allocator, loop_message);
    }
}

fn interactiveStreamCallback(token: []const u8, done: bool) void {
    _ = done;
    if (token.len == 0) {
        return;
    }

    const stdout = file_compat.File.stdout().writer();
    stdout.print("{s}", .{token}) catch {};
}

fn sendInteractiveLoopMessages(allocator: std.mem.Allocator, loop_messages: []const LoopMessage) anyerror!AIResponse {
    const ctx = active_bridge_context orelse return error.MissingBridgeContext;

    // Reset arena for this request — batch-frees all per-request memory
    // from the previous iteration (tokens, parsed JSON, tool call copies).
    _ = ctx.request_arena.reset(.retain_capacity);
    const arena = ctx.request_arena.allocator();

    try syncLoopMessagesToOuterHistory(ctx, loop_messages);

    const last_content_len = if (ctx.messages.items.len == 0)
        0
    else
        (ctx.messages.items[ctx.messages.items.len - 1].content orelse "").len;

    var pre_request_ctx = HookContext.init(arena);
    defer pre_request_ctx.deinit();
    pre_request_ctx.phase = .pre_request;
    pre_request_ctx.provider = ctx.provider_name;
    pre_request_ctx.model = ctx.model_name;
    pre_request_ctx.token_count = clampUsizeToU32(last_content_len);
    try ctx.hooks.execute(.pre_request, &pre_request_ctx);

    std.debug.print("\n\x1b[36mAssistant:\x1b[0m ", .{});

    // Use non-streaming for all providers - more reliable, avoids Zig stdlib HTTP bugs
    // TODO: Add --streaming flag for opt-in streaming when UX is desired
    var response: core.ChatResponse = undefined;
    response = ctx.client.sendChatWithHistory(ctx.messages.items) catch |err| {
        ctx.turn_failed = true;
        std.debug.print("\n\nError: {}\n", .{err});
        return err;
    };

    if (response.choices.len == 0) {
        ctx.turn_failed = true;
        std.debug.print("\n\nError: Empty response from AI\n", .{});
        return error.EmptyResponse;
    }

    ctx.turn_request_count += 1;
    ctx.request_count.* += 1;

    const choice = response.choices[0];
    const content = choice.message.content orelse "";
    const finish_reason_text = choice.finish_reason orelse "stop";

    if (response.usage) |usage| {
        ctx.total_input_tokens.* += usage.prompt_tokens;
        ctx.total_output_tokens.* += usage.completion_tokens;
        std.debug.print("\n\x1b[2m({d} tokens in / {d} out | session total: {d})\x1b[0m", .{
            usage.prompt_tokens,
            usage.completion_tokens,
            ctx.total_input_tokens.* + ctx.total_output_tokens.*,
        });
    }
    std.debug.print("\n", .{});

    var post_request_ctx = HookContext.init(arena);
    defer post_request_ctx.deinit();
    post_request_ctx.phase = .post_request;
    post_request_ctx.provider = ctx.provider_name;
    post_request_ctx.model = ctx.model_name;
    post_request_ctx.token_count = if (response.usage) |usage|
        clampU64ToU32(usage.total_tokens)
    else
        clampUsizeToU32(content.len);
    try ctx.hooks.execute(.post_request, &post_request_ctx);

    try appendResponseMessage(ctx.messages, allocator, choice.message);
    ctx.synced_loop_messages = loop_messages.len + 1;

    // Arena-allocated tool call parsing — no individual free() needed.
    // All memory reclaimed on next arena reset.
    const parsed_tool_calls = try ctx.client.extractToolCallsWithAllocator(&response, arena);

    if (std.mem.eql(u8, finish_reason_text, "tool_calls") and parsed_tool_calls.len == 0) {
        ctx.turn_failed = true;
        std.debug.print("\nError: Model requested tool calls but none were parsed\n", .{});
        return error.InvalidToolCallResponse;
    }

    var loop_tool_calls: []const AIResponse.ToolCallInfo = &.{};
    if (parsed_tool_calls.len > 0) {
        // Copy into arena — no individual free needed
        const copied = try arena.alloc(AIResponse.ToolCallInfo, parsed_tool_calls.len);
        for (parsed_tool_calls, 0..) |tool_call, i| {
            copied[i] = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .arguments = tool_call.arguments,
            };
        }
        loop_tool_calls = copied;
    }

    return .{
        .content = content,
        .finish_reason = AIResponse.FinishReason.fromString(finish_reason_text),
        .tool_calls = loop_tool_calls,
    };
}

fn executeReadFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ReadFileArgs = struct { path: []const u8 };

    var parsed = try std.json.parseFromSlice(ReadFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().openFile(parsed.value.path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, stat.size }),
        .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, stat.size, content }),
    };
}

fn executeShellTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ShellArgs = struct {
        command: []const u8,
        timeout: ?u32 = null,
    };

    var parsed = try std.json.parseFromSlice(ShellArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Use `timeout` utility if available and timeout is specified
    if (parsed.value.timeout) |secs| {
        if (secs > 0) {
            const cmd = try std.fmt.allocPrint(allocator, "timeout --signal=KILL {d} sh -c {s}", .{ secs, parsed.value.command });
            defer allocator.free(cmd);
            const argv: [3][]const u8 = .{ "sh", "-c", cmd };
            var child = std.process.Child.init(&argv, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            _ = try child.spawn();

            var stdout = std.ArrayListUnmanaged(u8){};
            var stderr = std.ArrayListUnmanaged(u8){};
            defer {
                stdout.deinit(allocator);
                stderr.deinit(allocator);
            }

            try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
            const term = try child.wait();
            const exit_code: u8 = switch (term) {
                .Exited => |code| @intCast(code),
                .Signal => |code| @intCast(code),
                else => 1,
            };
            const timed_out = if (exit_code == 124) true else false;
            return .{
                .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\", timeout={d}s) → exit {d}{s}\n", .{ parsed.value.command, secs, exit_code, if (timed_out) " (TIMEOUT)" else "" }),
                .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout.items, stderr.items }),
            };
        }
    }

    // No timeout: run directly
    const argv: [3][]const u8 = .{ "sh", "-c", parsed.value.command };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\") → exit {d}\n", .{ parsed.value.command, exit_code }),
        .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout.items, stderr.items }),
    };
}

fn executeWriteFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const WriteFileArgs = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(WriteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    try file.writeAll(parsed.value.content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 write_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, parsed.value.content.len }),
        .result = try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ parsed.value.content.len, parsed.value.path }),
    };
}

/// Glob tool: find files matching a pattern using shell `find` command
fn executeGlobTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GlobArgs = struct {
        pattern: []const u8,
        max_results: ?u32 = 50,
    };

    var parsed = try std.json.parseFromSlice(GlobArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const max = parsed.value.max_results orelse 50;

    // Use `find` to match glob patterns — portable and no external deps
    const find_cmd = try std.fmt.allocPrint(allocator, "find . -name '{s}' -type f 2>/dev/null | head -{d}", .{ parsed.value.pattern, max });
    defer allocator.free(find_cmd);

    const argv: [3][]const u8 = .{ "sh", "-c", find_cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    _ = try child.wait();

    // Count matching files
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, stdout.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 glob(\"{s}\") → {d} files\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} files matching '{s}':\n{s}", .{ count, parsed.value.pattern, stdout.items }),
    };
}

/// Grep tool: search file contents using shell `grep` command
fn executeGrepTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GrepArgs = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        include: ?[]const u8 = null,
        max_results: ?u32 = 50,
    };

    var parsed = try std.json.parseFromSlice(GrepArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const max = parsed.value.max_results orelse 50;
    const search_path = parsed.value.path orelse ".";

    var cmd_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer cmd_buf.deinit();
    const writer = cmd_buf.writer();

    try writer.print("grep -rn --binary-files=without-match '{s}' '{s}'", .{ parsed.value.pattern, search_path });
    if (parsed.value.include) |inc| {
        try writer.print(" --include='{s}'", .{inc});
    }
    try writer.print(" 2>/dev/null | head -{d}", .{max});

    const argv: [3][]const u8 = .{ "sh", "-c", cmd_buf.items };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    _ = try child.wait();

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, stdout.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 grep(\"{s}\") → {d} matches\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} matches for '{s}':\n{s}", .{ count, parsed.value.pattern, stdout.items }),
    };
}

/// Edit tool: find and replace text in a file
fn executeEditTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const EditArgs = struct {
        file_path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
    };

    var parsed = try std.json.parseFromSlice(EditArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Read the file
    const file = try std.fs.cwd().openFile(parsed.value.file_path, .{});
    defer file.close();
    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    // Find the old string
    const pos = std.mem.indexOf(u8, content, parsed.value.old_string) orelse {
        return error.OldStringNotFound;
    };

    // Check for multiple occurrences (ambiguous edit)
    const after_first = pos + parsed.value.old_string.len;
    if (std.mem.indexOf(u8, content[after_first..], parsed.value.old_string)) |_| {
        return error.MultipleMatches;
    }

    // Build new content
    var new_content = array_list_compat.ArrayList(u8).init(allocator);
    defer new_content.deinit();
    try new_content.appendSlice(content[0..pos]);
    try new_content.appendSlice(parsed.value.new_string);
    try new_content.appendSlice(content[after_first..]);

    // Write back
    const out_file = try std.fs.cwd().createFile(parsed.value.file_path, .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);

    const lines_before = countLines(content);
    const lines_after = countLines(new_content.items);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 edit(\"{s}\") → replaced {d} chars with {d} chars\n", .{ parsed.value.file_path, parsed.value.old_string.len, parsed.value.new_string.len }),
        .result = try std.fmt.allocPrint(allocator, "Edited {s}: replaced text at position {d}. File: {d} lines → {d} lines", .{ parsed.value.file_path, pos, lines_before, lines_after }),
    };
}

/// Count lines in text
fn countLines(text: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, text, "\n");
    while (lines.next()) |_| {
        count += 1;
    }
    return count;
}

fn executeBuiltinTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return executeReadFileTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "shell")) {
        return executeShellTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return executeWriteFileTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "glob")) {
        return executeGlobTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "grep")) {
        return executeGrepTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "edit")) {
        return executeEditTool(allocator, tool_call);
    }
    return error.UnsupportedTool;
}

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    const allocator = std.heap.page_allocator;

    // Check for interactive mode
    if (args.interactive) {
        try handleInteractiveChat(args, config, allocator);
        return;
    }

    // Single message mode (original behavior)
    if (args.remaining.len == 0) {
        std.debug.print("Crushcode - AI Coding Assistant\n", .{});
        std.debug.print("Usage: crushcode chat <message> [--provider <name>] [--model <name>] [--interactive]\n\n", .{});
        std.debug.print("Available Providers:\n", .{});
        std.debug.print("  openai - GPT models\n", .{});
        std.debug.print("  anthropic - Claude models\n", .{});
        std.debug.print("  gemini - Gemini models\n", .{});
        std.debug.print("  xai - Grok models\n", .{});
        std.debug.print("  mistral - Mistral models\n", .{});
        std.debug.print("  groq - Groq models\n", .{});
        std.debug.print("  deepseek - DeepSeek models\n", .{});
        std.debug.print("  together - Together AI\n", .{});
        std.debug.print("  azure - Azure OpenAI\n", .{});
        std.debug.print("  vertexai - Google Vertex AI\n", .{});
        std.debug.print("  bedrock - AWS Bedrock\n", .{});
        std.debug.print("  ollama - Local LLM\n", .{});
        std.debug.print("  lm-studio - LM Studio\n", .{});
        std.debug.print("  llama-cpp - llama.cpp\n", .{});
        std.debug.print("  openrouter - OpenRouter\n", .{});
        std.debug.print("  zai - Zhipu AI\n", .{});
        std.debug.print("  vercel-gateway - Vercel Gateway\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  crushcode chat \"Hello! Can you help me?\"\n", .{});
        std.debug.print("  crushcode chat --provider openai --model gpt-4o \"Hello\"\n", .{});
        std.debug.print("  crushcode chat --provider anthropic \"Help me code\"\n", .{});
        std.debug.print("  crushcode chat --interactive\n", .{});
        return;
    }

    const message = args.remaining[0];
    const provider_name = args.provider orelse config.default_provider;
    const model_name = args.model orelse config.default_model;

    // Initialize registry and get provider
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
        std.debug.print("Run 'crushcode list' to see available providers\n", .{});
        return error.ProviderNotFound;
    };

    // Get API key from config
    const api_key = config.getApiKey(provider_name) orelse "";

    if (api_key.len == 0) {
        std.debug.print("Warning: No API key found for provider '{s}'\n", .{provider_name});
        std.debug.print("Add your API key to ~/.crushcode/config.toml\n", .{});
        std.debug.print("Example: {s} = \"your-api-key\"\n\n", .{provider_name});

        if (!std.mem.eql(u8, provider_name, "ollama") and
            !std.mem.eql(u8, provider_name, "lm_studio") and
            !std.mem.eql(u8, provider_name, "llama_cpp"))
        {
            return error.MissingApiKey;
        }
    }

    // Initialize AI client
    var client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    // Set system prompt from config if available
    if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    std.debug.print("Sending request to {s} ({s})...\n", .{ provider_name, model_name });

    const response = client.sendChat(message) catch |err| {
        std.debug.print("\nError sending request: {}\n", .{err});
        return err;
    };

    // Safety check - ensure we have a valid response
    if (response.choices.len == 0) {
        std.debug.print("\nError: Empty response from AI\n", .{});
        return error.EmptyResponse;
    }

    // Simple content extraction with inline null check
    var content_slice: []const u8 = "";
    const choice = response.choices[0];
    if (choice.message.content) |c| {
        content_slice = c;
    }
    std.debug.print("\n{s}\n\n", .{content_slice});
    std.debug.print("---\n", .{});
    std.debug.print("Provider: {s}\n", .{provider_name});
    std.debug.print("Model: {s}\n", .{model_name});
    if (response.usage) |usage| {
        std.debug.print("Tokens used: {d} prompt + {d} completion = {d} total\n", .{
            usage.prompt_tokens,
            usage.completion_tokens,
            usage.total_tokens,
        });
        // Show extended usage info
        const ext = client.extractExtendedUsage(&response);
        std.debug.print("\x1b[2m({d} in / {d} out)\x1b[0m\n", .{ ext.input_tokens, ext.output_tokens });
    }
}

/// Interactive chat mode with streaming support and conversation history
fn handleInteractiveChat(args: args_mod.Args, config: *Config, allocator: std.mem.Allocator) !void {
    const provider_name = args.provider orelse config.default_provider;
    const model_name = args.model orelse config.default_model;

    // Initialize registry
    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerAllProviders();

    const provider = registry.getProvider(provider_name) orelse {
        std.debug.print("Error: Provider '{s}' not found\n", .{provider_name});
        return error.ProviderNotFound;
    };

    const api_key = config.getApiKey(provider_name) orelse "";

    if (api_key.len == 0 and !std.mem.eql(u8, provider_name, "ollama") and
        !std.mem.eql(u8, provider_name, "lm_studio") and
        !std.mem.eql(u8, provider_name, "llama_cpp"))
    {
        std.debug.print("Error: No API key for provider '{s}'. Add to ~/.crushcode/config.toml\n", .{provider_name});
        return error.MissingApiKey;
    }

    // Initialize client
    var client = try core.AIClient.init(allocator, provider, model_name, api_key);
    defer client.deinit();

    // Set system prompt from config if available
    if (config.getSystemPrompt()) |sys_prompt| {
        client.setSystemPrompt(sys_prompt);
    }

    // Define available tools for function calling (OpenAI schema format)
    const default_tool_schemas = try tool_loader.loadDefaultToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, default_tool_schemas);

    const user_tool_schemas = try tool_loader.loadUserToolSchemas(allocator);
    defer tool_loader.freeToolSchemas(allocator, user_tool_schemas);

    const merged_tool_schemas = try tool_loader.mergeToolSchemas(allocator, default_tool_schemas, user_tool_schemas);
    defer tool_loader.freeToolSchemas(allocator, merged_tool_schemas);

    const builtin_tool_schemas = try collectSupportedToolSchemas(allocator, merged_tool_schemas);
    defer allocator.free(builtin_tool_schemas);

    client.setTools(builtin_tool_schemas);

    // Initialize MCP bridge if MCP servers are configured
    var mcp_client = mcp_bridge_mod.MCPClient.init(allocator);
    var mcp_bridge: ?Bridge = if (config.mcp_servers.len > 0) Bridge.init(allocator, &mcp_client) catch null else null;
    var mcp_schemas: []const core.ToolSchema = &.{};
    defer tool_loader.freeToolSchemas(allocator, mcp_schemas);
    var combined_tool_schemas: ?[]const core.ToolSchema = null;
    defer if (combined_tool_schemas) |schemas| allocator.free(schemas);
    defer {
        if (mcp_bridge != null) {
            mcp_bridge.?.deinit();
        }
        mcp_client.deinit();
    }

    // Connect to MCP servers and discover tools
    if (mcp_bridge) |*bridge| {
        for (config.mcp_servers) |server_config| {
            const bridge_config = mcp_bridge_mod.MCPServerConfig{
                .transport = if (std.mem.eql(u8, server_config.transport orelse "stdio", "sse"))
                    mcp_bridge_mod.TransportType.sse
                else if (std.mem.eql(u8, server_config.transport orelse "stdio", "http"))
                    mcp_bridge_mod.TransportType.http
                else
                    mcp_bridge_mod.TransportType.stdio,
                .command = server_config.command,
                .url = server_config.url,
            };
            bridge.addServer(bridge_config) catch |err| {
                std.log.warn("Failed to add MCP server '{s}': {}", .{ server_config.name, err });
                continue;
            };
        }
        bridge.connectAll(&[_]mcp_bridge_mod.MCPServerConfig{});

        mcp_schemas = bridge.getToolSchemas(allocator) catch &[_]core.ToolSchema{};
        if (mcp_schemas.len > 0) {
            var all_tools = array_list_compat.ArrayList(core.ToolSchema).init(allocator);
            defer all_tools.deinit();

            for (builtin_tool_schemas) |ts| {
                try all_tools.append(ts);
            }
            for (mcp_schemas) |ts| {
                try all_tools.append(ts);
            }
            const combined = try all_tools.toOwnedSlice();
            combined_tool_schemas = combined;
            client.setTools(combined);
            std.log.info("Loaded {d} MCP tools from {d} servers", .{ mcp_schemas.len, bridge.getStats().servers });
        }
    }

    // Build codebase knowledge graph and inject into system prompt
    var kg = KnowledgeGraph.init(allocator);
    defer kg.deinit();

    const default_src_files = [_][]const u8{
        "src/main.zig",
        "src/ai/client.zig",
        "src/ai/registry.zig",
        "src/commands/handlers.zig",
        "src/commands/chat.zig",
        "src/config/config.zig",
        "src/cli/args.zig",
        "src/agent/loop.zig",
        "src/agent/compaction.zig",
        "src/graph/graph.zig",
        "src/graph/parser.zig",
        "src/streaming/session.zig",
        "src/plugin/interface.zig",
        "src/tools/registry.zig",
    };
    var indexed_count: u32 = 0;
    for (&default_src_files) |file_path| {
        kg.indexFile(file_path) catch continue;
        indexed_count += 1;
    }
    kg.detectCommunities() catch {};

    if (indexed_count > 0) {
        const graph_ctx = kg.toCompressedContext(allocator) catch null;
        if (graph_ctx) |ctx| {
            // Build enhanced system prompt with codebase context
            const base_prompt = config.getSystemPrompt() orelse "You are a helpful AI coding assistant with access to the user's codebase.";
            const enhanced = std.fmt.allocPrint(allocator,
                \\{s}
                \\
                \\## Codebase Context (Knowledge Graph)
                \\The following is an auto-generated compressed representation of the local codebase structure.
                \\Use this to understand the project architecture without needing to read every file.
                \\
                \\{s}
                \\
                \\## Available Tools
                \\You can call these tools during conversation:
                \\- read_file(path: string) — Read a file's contents
                \\- shell(command: string) — Execute a shell command
                \\- write_file(path: string, content: string) — Write content to a file
                \\- glob(pattern: string) — Find files matching a glob pattern
                \\- grep(pattern: string, path?: string) — Search file contents by regex
                \\- edit(file_path: string, old_string: string, new_string: string) — Replace text in a file
            , .{ base_prompt, ctx }) catch base_prompt;
            client.setSystemPrompt(enhanced);
            std.debug.print("\x1b[2m[graph: {d} files indexed, {d} symbols, {d:.1}x compression]\x1b[0m\n", .{
                indexed_count,
                kg.nodes.count(),
                kg.compressionRatio(),
            });
        }
    }

    var hooks = LifecycleHooks.init(allocator);
    defer hooks.deinit();
    try registerCoreChatHooks(&hooks);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.registerBuiltinTools();
    const available_tools = try tool_registry.getAvailableTools(allocator);
    defer allocator.free(available_tools);
    std.debug.assert(available_tools.len > 0);

    var agent_loop = AgentLoop.init(allocator);
    defer agent_loop.deinit();
    var loop_config = agent_loop_mod.LoopConfig.init();
    loop_config.show_intermediate = false;
    agent_loop.setConfig(loop_config);
    try registerBuiltinAgentTools(&agent_loop, builtin_tool_schemas);

    // Conversation history
    var messages = array_list_compat.ArrayList(core.ChatMessage).init(allocator);
    defer {
        for (messages.items) |msg| {
            freeChatMessage(msg, allocator);
        }
        messages.deinit();
    }

    // Session token tracking
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var request_count: u32 = 0;

    // Auto-compaction: compact context when approaching token limits
    // Default max context = 128k tokens, compact at 80% = ~102k tokens
    var compactor = ContextCompactor.init(allocator, 128_000);
    defer compactor.deinit();
    compactor.setRecentWindow(10); // Keep last 10 messages at full fidelity

    std.debug.print("=== Interactive Chat Mode (Streaming) ===\n", .{});
    std.debug.print("Provider: {s} | Model: {s}\n", .{ provider_name, model_name });
    std.debug.print("Type your message and press Enter. Press Ctrl+C to exit.\n", .{});
    std.debug.print("Commands: /usage | /clear | /hooks | /compact | /graph | /exit\n", .{});
    std.debug.print("--------------------------------------------\n\n", .{});

    const stdin = file_compat.File.stdin();
    const stdin_reader = stdin.reader();

    while (true) {
        // Print prompt
        std.debug.print("\n\x1b[32mYou:\x1b[0m ", .{});

        // Read line
        const line = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256 * 1024) catch {
            std.debug.print("\nError reading input\n", .{});
            break;
        };

        if (line == null) break;

        const user_message = line.?;
        defer allocator.free(user_message);

        if (user_message.len == 0) continue;

        // Handle built-in commands
        if (std.mem.eql(u8, user_message, "exit") or std.mem.eql(u8, user_message, "quit") or std.mem.eql(u8, user_message, "/exit")) {
            std.debug.print("Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, user_message, "/usage")) {
            std.debug.print("\n=== Session Usage ===\n", .{});
            std.debug.print("  Requests: {d}\n", .{request_count});
            std.debug.print("  Tokens: {d} in / {d} out\n", .{ total_input_tokens, total_output_tokens });
            continue;
        }

        if (std.mem.eql(u8, user_message, "/clear")) {
            for (messages.items) |msg| {
                freeChatMessage(msg, allocator);
            }
            messages.clearRetainingCapacity();
            total_input_tokens = 0;
            total_output_tokens = 0;
            request_count = 0;
            std.debug.print("History cleared.\n", .{});
            continue;
        }

        if (std.mem.eql(u8, user_message, "/hooks")) {
            hooks.printHooks();
            continue;
        }

        if (std.mem.eql(u8, user_message, "/compact")) {
            std.debug.print("\n=== Manual Compaction ===\n", .{});
            compactor.printStatus(total_input_tokens + total_output_tokens);

            if (messages.items.len > 12) {
                std.debug.print("  Compacting now...\n", .{});
                var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch continue;
                defer compact_msgs.deinit();
                for (messages.items) |msg| {
                    compact_msgs.appendAssumeCapacity(.{
                        .role = msg.role,
                        .content = msg.content orelse "",
                        .timestamp = null,
                    });
                }
                const result = compactor.compact(compact_msgs.items) catch |err| {
                    std.debug.print("  Compaction failed: {}\n", .{err});
                    continue;
                };
                if (result.messages_summarized > 0) {
                    for (messages.items) |msg| {
                        freeChatMessage(msg, allocator);
                    }
                    messages.clearRetainingCapacity();
                    const summary_content = std.fmt.allocPrint(allocator, "{s}", .{result.summary}) catch continue;
                    messages.append(.{
                        .role = allocator.dupe(u8, "system") catch continue,
                        .content = summary_content,
                        .tool_call_id = null,
                        .tool_calls = null,
                    }) catch continue;
                    for (result.messages) |compact_msg| {
                        messages.append(.{
                            .role = allocator.dupe(u8, compact_msg.role) catch continue,
                            .content = if (compact_msg.content.len > 0) allocator.dupe(u8, compact_msg.content) catch continue else null,
                            .tool_call_id = null,
                            .tool_calls = null,
                        }) catch continue;
                    }
                    allocator.free(result.summary);
                    std.debug.print("  Compacted {d} messages, saved ~{d} tokens.\n", .{
                        result.messages_summarized,
                        result.tokens_saved,
                    });
                }
            }
            continue;
        }

        if (std.mem.eql(u8, user_message, "/graph")) {
            std.debug.print("\n=== Knowledge Graph Status ===\n", .{});
            std.debug.print("  Files indexed: {d}\n", .{kg.file_count});
            std.debug.print("  Nodes: {d}\n", .{kg.nodes.count()});
            std.debug.print("  Edges: {d}\n", .{kg.edges.items.len});
            std.debug.print("  Communities: {d}\n", .{kg.communities.items.len});
            if (kg.compressionRatio() > 0) {
                std.debug.print("  Compression: {d:.1}x\n", .{kg.compressionRatio()});
            }
            std.debug.print("  [graph context already injected into system prompt]\n", .{});
            continue;
        }

        var intent_arena = std.heap.ArenaAllocator.init(allocator);
        defer intent_arena.deinit();

        var intent_gate = IntentGate.init(intent_arena.allocator());
        defer intent_gate.deinit();

        const intent = intent_gate.classify(user_message);
        std.debug.print("\x1b[2m[intent: {s} ({d:.2})]\x1b[0m\n", .{
            IntentGate.intentLabel(intent.intent_type),
            intent.confidence,
        });

        const turn_start_len = messages.items.len;

        var bridge_ctx = InteractiveBridgeContext{
            .allocator = allocator,
            .client = &client,
            .messages = &messages,
            .hooks = &hooks,
            .provider_name = provider_name,
            .model_name = model_name,
            .turn_start_len = turn_start_len,
            .synced_loop_messages = 0,
            .turn_request_count = 0,
            .turn_failed = false,
            .total_input_tokens = &total_input_tokens,
            .total_output_tokens = &total_output_tokens,
            .request_count = &request_count,
            .request_arena = std.heap.ArenaAllocator.init(allocator),
        };
        defer bridge_ctx.request_arena.deinit();

        active_bridge_context = &bridge_ctx;
        var loop_result = try agent_loop.run(sendInteractiveLoopMessages, user_message);
        active_bridge_context = null;
        defer loop_result.deinit();

        const hit_max_iterations = loop_result.steps.items.len > 0 and
            loop_result.total_iterations >= loop_config.max_iterations and
            loop_result.steps.items[loop_result.steps.items.len - 1].has_tool_calls;

        if (bridge_ctx.turn_failed) {
            rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

        if (hit_max_iterations) {
            std.debug.print("\nError: Agent loop hit max iterations ({d})\n", .{loop_config.max_iterations});
            rollbackMessagesTo(&messages, allocator, turn_start_len);
            continue;
        }

        // Auto-compact context when approaching token limits
        const session_tokens = total_input_tokens + total_output_tokens;
        if (compactor.needsCompaction(session_tokens) and messages.items.len > 12) {
            std.debug.print("\n\x1b[33m⚡ Context approaching limit ({d} tokens). Compacting...\x1b[0m\n", .{session_tokens});

            // Convert ChatMessages to CompactMessages for compaction
            var compact_msgs = array_list_compat.ArrayList(compaction_mod.CompactMessage).initCapacity(allocator, messages.items.len) catch continue;
            defer compact_msgs.deinit();
            for (messages.items) |msg| {
                compact_msgs.appendAssumeCapacity(.{
                    .role = msg.role,
                    .content = msg.content orelse "",
                    .timestamp = null,
                });
            }

            const result = compactor.compact(compact_msgs.items) catch |err| {
                std.debug.print("Compaction failed: {}\n", .{err});
                continue;
            };

            if (result.messages_summarized > 0) {
                // Free old messages
                for (messages.items) |msg| {
                    freeChatMessage(msg, allocator);
                }
                messages.clearRetainingCapacity();

                // Add summary as a system message
                const summary_content = std.fmt.allocPrint(allocator, "{s}", .{result.summary}) catch continue;

                messages.append(.{
                    .role = allocator.dupe(u8, "system") catch continue,
                    .content = summary_content,
                    .tool_call_id = null,
                    .tool_calls = null,
                }) catch continue;

                // Re-add preserved recent messages
                for (result.messages) |compact_msg| {
                    messages.append(.{
                        .role = allocator.dupe(u8, compact_msg.role) catch continue,
                        .content = if (compact_msg.content.len > 0) allocator.dupe(u8, compact_msg.content) catch continue else null,
                        .tool_call_id = null,
                        .tool_calls = null,
                    }) catch continue;
                }

                // Free the summary if it was allocated (compactor owns it, but we copied it)
                allocator.free(result.summary);

                std.debug.print("\x1b[33m  Compacted {d} messages. Saved ~{d} tokens.\x1b[0m\n", .{
                    result.messages_summarized,
                    result.tokens_saved,
                });
            }
        }
    }
}

pub const Args = struct {
    command: []const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    config_file: ?[]const u8,
    interactive: bool = false,
    remaining: [][]const u8,
};
