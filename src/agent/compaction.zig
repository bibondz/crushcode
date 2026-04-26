const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

pub const CompactionTier = enum {
    none,
    light,
    heavy,
    full,
};

/// Auto-Context Compaction — automatically compresses long conversation sessions
///
/// When context approaches the model's token limit, this system:
/// 1. Detects the approaching limit
/// 2. Preserves recent messages at full fidelity
/// 3. Summarizes older messages into a compact representation
/// 4. Maintains key decisions and context markers
/// 5. Preserves agent configuration metadata
///
/// Reference: OpenHarness auto-compaction for long session context
pub const ContextCompactor = struct {
    allocator: Allocator,
    max_tokens: u64,
    compact_threshold: f64,
    recent_window: u32,
    preserved_topics: array_list_compat.ArrayList([]const u8),
    previous_summary: []const u8 = "",
    agent_metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator, max_tokens: u64) ContextCompactor {
        return ContextCompactor{
            .allocator = allocator,
            .max_tokens = max_tokens,
            .compact_threshold = 0.8,
            .recent_window = 10,
            .preserved_topics = array_list_compat.ArrayList([]const u8).init(allocator),
            .previous_summary = "",
            .agent_metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn setThreshold(self: *ContextCompactor, threshold: f64) void {
        self.compact_threshold = @min(@max(threshold, 0.1), 0.99);
    }

    pub fn setRecentWindow(self: *ContextCompactor, window: u32) void {
        self.recent_window = window;
    }

    pub fn preserveTopic(self: *ContextCompactor, topic: []const u8) !void {
        try self.preserved_topics.append(try self.allocator.dupe(u8, topic));
    }

    /// Preserve agent configuration metadata during compaction
    pub fn preserveAgentMetadata(self: *ContextCompactor, key: []const u8, value: []const u8) !void {
        try self.agent_metadata.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
    }

    /// Set agent metadata from a source metadata hashmap
    pub fn setAgentMetadata(self: *ContextCompactor, source_metadata: *const std.StringHashMap([]const u8)) !void {
        var iter = source_metadata.iterator();
        while (iter.next()) |entry| {
            try self.preserveAgentMetadata(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn needsCompaction(self: *const ContextCompactor, current_tokens: u64) bool {
        const ratio = @as(f64, @floatFromInt(current_tokens)) / @as(f64, @floatFromInt(self.max_tokens));
        return ratio >= self.compact_threshold;
    }

    pub fn compactionTier(self: *const ContextCompactor, current_tokens: u64) CompactionTier {
        const ratio = @as(f64, @floatFromInt(current_tokens)) / @as(f64, @floatFromInt(self.max_tokens));
        if (ratio >= 0.95) return .full;
        if (ratio >= self.compact_threshold) return .heavy;
        if (ratio >= self.compact_threshold * 0.75) return .light;
        return .none;
    }

    pub fn estimateTokens(text: []const u8) u64 {
        return @intCast(std.math.divCeil(usize, text.len, 4) catch 1);
    }

    pub fn compact(
        self: *ContextCompactor,
        messages: []const CompactMessage,
    ) !CompactResult {
        return self.compactHeuristic(messages, "");
    }

    pub fn compactWithMetadata(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        metadata: ?*const std.StringHashMap([]const u8),
    ) !CompactResult {
        // Set agent metadata if provided
        if (metadata) |meta| {
            try self.setAgentMetadata(meta);
        }
        return self.compactHeuristic(messages, "");
    }

    pub fn compactWithSummary(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        previous_summary: []const u8,
    ) !CompactResult {
        return self.compactHeuristic(messages, previous_summary);
    }

    pub fn compactLight(
        self: *ContextCompactor,
        messages: []const CompactMessage,
    ) !CompactResult {
        const copied_messages = try self.allocator.alloc(CompactMessage, messages.len);
        var initialized: usize = 0;
        errdefer {
            for (copied_messages[0..initialized]) |msg| {
                self.allocator.free(msg.role);
                if (msg.content.len > 0) {
                    self.allocator.free(msg.content);
                }
            }
            self.allocator.free(copied_messages);
        }

        var total_tokens_before: u64 = 0;
        var total_tokens_after: u64 = 0;

        for (messages, 0..) |msg, i| {
            total_tokens_before += estimateTokens(msg.content);

            const content = if (msg.content.len > 500)
                try std.fmt.allocPrint(self.allocator, "{s}...", .{msg.content[0..@min(@as(usize, 200), msg.content.len)]})
            else if (msg.content.len > 0)
                try self.allocator.dupe(u8, msg.content)
            else
                "";

            copied_messages[i] = .{
                .role = try self.allocator.dupe(u8, msg.role),
                .content = content,
                .timestamp = msg.timestamp,
            };
            initialized += 1;

            total_tokens_after += estimateTokens(content);
        }

        // Copy agent metadata for the result
        var result_metadata = std.StringHashMap([]const u8).init(self.allocator);
        errdefer result_metadata.deinit();
        
        var meta_iter = self.agent_metadata.iterator();
        while (meta_iter.next()) |entry| {
            try result_metadata.put(try self.allocator.dupe(u8, entry.key_ptr.*), 
                                 try self.allocator.dupe(u8, entry.value_ptr.*));
        }
        
        return CompactResult{
            .messages = copied_messages,
            .tokens_saved = total_tokens_before -| total_tokens_after,
            .messages_summarized = 0,
            .summary = "",
            .agent_metadata = result_metadata,
            .allocator = self.allocator,
        };
    }

    /// Micro-compact: prune stale tool outputs older than the recent window.
    /// Lightweight operation — no summarization, just removes stale data.
    /// Does NOT touch user or assistant messages.
    /// Returns how many tokens were saved via the CompactResult.tokens_saved field.
    pub fn microCompact(
        self: *ContextCompactor,
        messages: []const CompactMessage,
    ) !CompactResult {
        const boundary = if (messages.len > self.recent_window)
            messages.len - self.recent_window
        else
            messages.len;

        const result_messages = try self.allocator.alloc(CompactMessage, messages.len);
        var initialized: usize = 0;
        errdefer {
            for (result_messages[0..initialized]) |msg| {
                self.allocator.free(msg.role);
                if (msg.content.len > 0) self.allocator.free(msg.content);
            }
            self.allocator.free(result_messages);
        }

        var total_tokens_before: u64 = 0;
        var total_tokens_after: u64 = 0;
        var pruned_count: u32 = 0;

        for (messages, 0..) |msg, i| {
            total_tokens_before += estimateTokens(msg.content);

            const is_stale_tool = i < boundary and std.mem.eql(u8, msg.role, "tool");

            if (is_stale_tool and msg.content.len > 0) {
                // Prune stale tool output — replace with compact placeholder
                const placeholder = "[tool output pruned]";
                result_messages[i] = .{
                    .role = try self.allocator.dupe(u8, msg.role),
                    .content = try self.allocator.dupe(u8, placeholder),
                    .timestamp = msg.timestamp,
                };
                pruned_count += 1;
            } else {
                // Keep message intact — user, assistant, and recent tool outputs
                result_messages[i] = .{
                    .role = try self.allocator.dupe(u8, msg.role),
                    .content = if (msg.content.len > 0) try self.allocator.dupe(u8, msg.content) else "",
                    .timestamp = msg.timestamp,
                };
            }
            initialized += 1;
            total_tokens_after += estimateTokens(result_messages[i].content);
        }

        // Copy agent metadata for the result
        var result_metadata = std.StringHashMap([]const u8).init(self.allocator);
        errdefer result_metadata.deinit();

        var meta_iter = self.agent_metadata.iterator();
        while (meta_iter.next()) |entry| {
            try result_metadata.put(
                try self.allocator.dupe(u8, entry.key_ptr.*),
                try self.allocator.dupe(u8, entry.value_ptr.*),
            );
        }

        return CompactResult{
            .messages = result_messages,
            .tokens_saved = total_tokens_before -| total_tokens_after,
            .messages_summarized = 0,
            .summary = "",
            .agent_metadata = result_metadata,
            .allocator = self.allocator,
        };
    }

    pub fn buildSummarizationPrompt(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        previous_summary: []const u8,
    ) ![]const u8 {
        var prompt = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer prompt.deinit();

        const split_point = if (messages.len > self.recent_window)
            messages.len - self.recent_window
        else
            messages.len;
        const history_messages = messages[0..split_point];

        const writer = prompt.writer();
        try writer.print(
            \\## Context Recovery
            \\
            \\A context limit was reached during a working session. Generate a compact version of the conversation below that preserves ALL information needed to continue working.
            \\
            \\This summary will be read by YOU (the AI assistant) in a future exchange to continue the session. Include EVERYTHING important — technical details, file paths, code, decisions, errors, and fixes. It is OK to make this longer than a normal summary since only you will read it.
            \\
            \\### Include these sections:
            \\1. **Goal** — What the user asked you to accomplish
            \\2. **Constraints** — User constraints, preferences, specifications
            \\3. **Discoveries** — Technical findings, decisions made, and why
            \\4. **Accomplished** — Completed work and anything in progress
            \\5. **Errors + Fixes** — Bugs found, resolutions, user-driven changes
            \\6. **Files** — All viewed/edited files with key code and change justifications
            \\7. **Pending** — Unresolved user requests
            \\8. **Next Step** — Active work at time of compaction
            \\
            \\Rules:
            \\- Preserve exact file paths, code snippets, error messages, and identifiers
            \\- Keep technical details verbatim — do not paraphrase code
            \\- Do not mention the compaction process itself
            \\
            \\
        , .{});

        if (previous_summary.len > 0) {
            try writer.print("Previous context summary:\n{s}\n\n", .{previous_summary});
        }

        try writer.print("Conversation history to summarize:\n", .{});
        for (history_messages, 0..) |msg, i| {
            try writer.print("[{d}] {s}:\n{s}\n\n", .{ i + 1, msg.role, msg.content });
        }

        return try prompt.toOwnedSlice();
    }

    pub fn setPreviousSummary(self: *ContextCompactor, summary: []const u8) !void {
        try self.storePreviousSummary(summary);
    }

    fn compactHeuristic(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        previous_summary: []const u8,
    ) !CompactResult {
        if (messages.len <= self.recent_window) {
            return CompactResult{
                .messages = messages,
                .tokens_saved = 0,
                .messages_summarized = 0,
                .summary = "",
                .agent_metadata = std.StringHashMap([]const u8).init(self.allocator),
            };
        }

        var total_tokens_before: u64 = 0;
        for (messages) |msg| {
            total_tokens_before += estimateTokens(msg.content);
        }

        const split_point = messages.len - self.recent_window;
        const old_messages = messages[0..split_point];
        const recent_messages = messages[split_point..];

        var summary_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer summary_buf.deinit();
        const writer = summary_buf.writer();

        if (previous_summary.len > 0) {
            try writer.print("[Rolling Summary — updated]\n", .{});
            try writer.print("\nPrevious context summary:\n{s}\n", .{previous_summary});
            try writer.print("\n[Additional Context — {d} messages compacted]\n", .{old_messages.len});
        } else {
            try writer.print("[Context Summary — {d} messages compacted]\n", .{old_messages.len});
        }

        var decisions = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (decisions.items) |decision| self.allocator.free(decision);
            decisions.deinit();
        }

        var topics_seen = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (topics_seen.items) |topic| self.allocator.free(topic);
            topics_seen.deinit();
        }

        for (old_messages) |msg| {
            if (self.containsAny(msg.content, &.{ "decided", "chose", "will use", "selected", "approved", "rejected" })) {
                const snippet = self.extractSnippet(msg.content, 200);
                try decisions.append(try self.allocator.dupe(u8, snippet));
            }

            for (self.preserved_topics.items) |topic| {
                if (std.mem.indexOf(u8, msg.content, topic) != null) {
                    const snippet = self.extractSnippet(msg.content, 300);
                    try topics_seen.append(try std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ topic, snippet }));
                }
            }
        }

        if (decisions.items.len > 0) {
            try writer.print("\nKey Decisions:\n", .{});
            for (decisions.items) |decision| {
                try writer.print("  - {s}\n", .{decision});
            }
        }

        if (topics_seen.items.len > 0) {
            try writer.print("\nPreserved Context:\n", .{});
            for (topics_seen.items) |topic| {
                try writer.print("  {s}\n", .{topic});
            }
        }

        var user_count: u32 = 0;
        var assistant_count: u32 = 0;
        for (old_messages) |msg| {
            if (std.mem.eql(u8, msg.role, "user")) user_count += 1;
            if (std.mem.eql(u8, msg.role, "assistant")) assistant_count += 1;
        }
        try writer.print("\nSession: {d} user msgs, {d} assistant msgs\n", .{ user_count, assistant_count });

        const summary = try summary_buf.toOwnedSlice();
        try self.storePreviousSummary(summary);

        const summary_tokens = estimateTokens(summary);
        var tokens_after: u64 = summary_tokens;
        for (recent_messages) |msg| {
            tokens_after += estimateTokens(msg.content);
        }

        // Copy agent metadata for the result
        var result_metadata = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var meta_iter = result_metadata.iterator();
            while (meta_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            result_metadata.deinit();
        }
        
        var meta_iter = self.agent_metadata.iterator();
        while (meta_iter.next()) |entry| {
            try result_metadata.put(try self.allocator.dupe(u8, entry.key_ptr.*), 
                                 try self.allocator.dupe(u8, entry.value_ptr.*));
        }
        
        return CompactResult{
            .messages = recent_messages,
            .tokens_saved = total_tokens_before -| tokens_after,
            .messages_summarized = @intCast(old_messages.len),
            .summary = summary,
            .agent_metadata = result_metadata,
            .allocator = self.allocator,
        };
    }

    fn containsAny(_: *ContextCompactor, text: []const u8, patterns: []const []const u8) bool {
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, text, pattern) != null) return true;
        }
        return false;
    }

    fn extractSnippet(_: *ContextCompactor, text: []const u8, max_len: usize) []const u8 {
        if (text.len <= max_len) return text;
        return text[0..max_len];
    }

    fn storePreviousSummary(self: *ContextCompactor, summary: []const u8) !void {
        const duped = try self.allocator.dupe(u8, summary);
        if (self.previous_summary.len > 0) {
            self.allocator.free(self.previous_summary);
        }
        self.previous_summary = duped;
    }

    /// Compact using LLM summarization instead of heuristic.
    /// Builds a summary prompt, sends it to an LLM via the provided function pointer,
    /// and uses the response as the context summary.
    /// Falls back to heuristic compaction on LLM failure.
    ///
    /// The `sendToLLM` function pointer allows decoupling from AIClient:
    ///   fn sendToLLM(allocator, prompt, model) anyerror!?[]const u8
    pub fn compactWithLLM(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        config: CompactionConfig,
        sendToLLM: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!?[]const u8,
    ) !CompactResult {
        const effective_window = if (config.recent_window > 0) config.recent_window else self.recent_window;

        // 1. If messages.len <= effective_window, return identity result (no compaction needed)
        if (messages.len <= effective_window) {
            return CompactResult{
                .messages = messages,
                .tokens_saved = 0,
                .messages_summarized = 0,
                .summary = "",
                .agent_metadata = std.StringHashMap([]const u8).init(self.allocator),
            };
        }

        // 2. Split messages: old = messages[0..split_point], recent = messages[split_point..]
        const split_point = messages.len - effective_window;
        const old_messages = messages[0..split_point];
        const recent_messages = messages[split_point..];

        // 3. Truncate tool outputs in old messages if preserve_tool_outputs == false
        var trunc_result: ?ToolTruncationResult = null;
        defer {
            if (trunc_result) |*tr| tr.deinit();
        }

        const summarization_messages: []const CompactMessage = blk: {
            if (!config.preserve_tool_outputs) {
                trunc_result = try self.truncateToolOutputs(old_messages, config.max_tool_output_chars);
                break :blk trunc_result.?.messages;
            } else {
                break :blk old_messages;
            }
        };

        // 4. Build summarization prompt using existing method
        const prompt = try self.buildSummarizationPrompt(summarization_messages, self.previous_summary);
        defer self.allocator.free(prompt);

        // 5. Call sendToLLM, fall back on null or error
        const llm_summary_opt = sendToLLM(self.allocator, prompt, config.llm_compaction_model) catch null;

        // 6. If LLM returns null or error: fall back to compactHeuristic
        if (llm_summary_opt) |llm_summary| {
            // 7. LLM succeeded — use response as summary
            try self.storePreviousSummary(llm_summary);

            // Calculate tokens saved
            var total_tokens_before: u64 = 0;
            for (messages) |msg| {
                total_tokens_before += estimateTokens(msg.content);
            }
            var tokens_after: u64 = estimateTokens(llm_summary);
            for (recent_messages) |msg| {
                tokens_after += estimateTokens(msg.content);
            }

            // 8. Copy agent metadata into result
            var result_metadata = std.StringHashMap([]const u8).init(self.allocator);
            var meta_iter = self.agent_metadata.iterator();
            while (meta_iter.next()) |entry| {
                try result_metadata.put(
                    try self.allocator.dupe(u8, entry.key_ptr.*),
                    try self.allocator.dupe(u8, entry.value_ptr.*),
                );
            }

            // 9. Return CompactResult
            return CompactResult{
                .messages = recent_messages,
                .tokens_saved = total_tokens_before -| tokens_after,
                .messages_summarized = @intCast(old_messages.len),
                .summary = llm_summary,
                .agent_metadata = result_metadata,
                .allocator = self.allocator,
            };
        }

        // Fallback to heuristic compaction
        return self.compactHeuristic(messages, self.previous_summary);
    }

    /// Truncate tool-role messages to max_chars, adding "... (truncated)" suffix.
    /// Non-tool messages are preserved unchanged.
    pub fn truncateToolOutputs(
        self: *ContextCompactor,
        messages: []const CompactMessage,
        max_chars: u32,
    ) !ToolTruncationResult {
        const result_messages = try self.allocator.alloc(CompactMessage, messages.len);
        var truncated_count: u32 = 0;
        var chars_saved: u64 = 0;
        var initialized: usize = 0;

        errdefer {
            for (result_messages[0..initialized]) |msg| {
                self.allocator.free(msg.role);
                if (msg.content.len > 0) self.allocator.free(msg.content);
            }
            self.allocator.free(result_messages);
        }

        const trunc_suffix = "... (truncated)";

        for (messages, 0..) |msg, i| {
            const role_copy = try self.allocator.dupe(u8, msg.role);

            if (std.mem.eql(u8, msg.role, "tool") and msg.content.len > max_chars) {
                // Truncate to max_chars and append suffix
                const truncated_content = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}",
                    .{ msg.content[0..@as(usize, @min(max_chars, msg.content.len))], trunc_suffix },
                );
                const saved = msg.content.len -| truncated_content.len;
                chars_saved += @intCast(saved);
                truncated_count += 1;

                result_messages[i] = .{
                    .role = role_copy,
                    .content = truncated_content,
                    .timestamp = msg.timestamp,
                };
            } else {
                const content_copy = if (msg.content.len > 0)
                    try self.allocator.dupe(u8, msg.content)
                else
                    "";

                result_messages[i] = .{
                    .role = role_copy,
                    .content = content_copy,
                    .timestamp = msg.timestamp,
                };
            }
            initialized += 1;
        }

        return ToolTruncationResult{
            .messages = result_messages,
            .truncated_count = truncated_count,
            .chars_saved = chars_saved,
            .allocator = self.allocator,
        };
    }

    pub fn printStatus(self: *ContextCompactor, current_tokens: u64) void {
        const stdout = file_compat.File.stdout().writer();
        const ratio = @as(f64, @floatFromInt(current_tokens)) / @as(f64, @floatFromInt(self.max_tokens)) * 100.0;

        stdout.print("\n=== Context Compaction Status ===\n", .{}) catch {};
        stdout.print("  Token usage: {d}/{d} ({d:.1}%)\n", .{ current_tokens, self.max_tokens, ratio }) catch {};
        stdout.print("  Threshold: {d:.0}%\n", .{self.compact_threshold * 100.0}) catch {};
        stdout.print("  Recent window: {d} messages\n", .{self.recent_window}) catch {};
        stdout.print("  Needs compaction: {s}\n", .{if (self.needsCompaction(current_tokens)) "YES" else "no"}) catch {};

        if (self.preserved_topics.items.len > 0) {
            stdout.print("  Preserved topics:\n", .{}) catch {};
            for (self.preserved_topics.items) |topic| {
                stdout.print("    - {s}\n", .{topic}) catch {};
            }
        }
    }

    pub fn deinit(self: *ContextCompactor) void {
        for (self.preserved_topics.items) |topic| {
            self.allocator.free(topic);
        }
        self.preserved_topics.deinit();
        if (self.previous_summary.len > 0) {
            self.allocator.free(self.previous_summary);
        }
    }
};

/// Configuration for context compaction behavior
pub const CompactionConfig = struct {
    max_tokens: u64 = 128000,
    compact_threshold: f64 = 0.8,
    recent_window: u32 = 10,
    preserve_tool_outputs: bool = false,
    max_summary_tokens: u32 = 512,
    max_tool_output_chars: u32 = 2000,
    llm_compaction_model: []const u8 = "haiku",
};

/// Result of truncating tool output messages
pub const ToolTruncationResult = struct {
    messages: []CompactMessage,
    truncated_count: u32,
    chars_saved: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolTruncationResult) void {
        for (self.messages) |msg| {
            self.allocator.free(msg.role);
            if (msg.content.len > 0) self.allocator.free(msg.content);
        }
        self.allocator.free(self.messages);
    }
};

pub const CompactMessage = struct {
    role: []const u8,
    content: []const u8,
    timestamp: ?i64,
};

pub const CompactResult = struct {
    messages: []const CompactMessage,
    tokens_saved: u64,
    messages_summarized: u32,
    summary: []const u8,
    agent_metadata: std.StringHashMap([]const u8),
    allocator: ?Allocator = null,

    pub fn deinit(self: *CompactResult) void {
        if (self.allocator) |alloc| {
            if (self.summary.len == 0 and self.messages_summarized == 0) {
                for (self.messages) |msg| {
                    alloc.free(msg.role);
                    if (msg.content.len > 0) {
                        alloc.free(msg.content);
                    }
                }
                if (self.messages.len > 0) {
                    alloc.free(self.messages);
                }
                return;
            }
            if (self.summary.len > 0) {
                alloc.free(self.summary);
            }
        }
    }
};

const testing = std.testing;

test "ContextCompactor - init default values" {
    var c = ContextCompactor.init(testing.allocator, 128000);
    defer c.deinit();
    try testing.expectEqual(@as(u64, 128000), c.max_tokens);
    try testing.expect(c.compact_threshold > 0.79 and c.compact_threshold < 0.81);
    try testing.expectEqual(@as(u32, 10), c.recent_window);
    try testing.expectEqual(@as(usize, 0), c.preserved_topics.items.len);
    try testing.expectEqualStrings("", c.previous_summary);
}

test "ContextCompactor - compactionTier thresholds" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    try testing.expectEqual(CompactionTier.none, c.compactionTier(50000));
    try testing.expectEqual(CompactionTier.light, c.compactionTier(60000));
    try testing.expectEqual(CompactionTier.heavy, c.compactionTier(80000));
    try testing.expectEqual(CompactionTier.full, c.compactionTier(95000));
}

test "ContextCompactor - setThreshold clamps values" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    c.setThreshold(0.5);
    try testing.expect(c.compact_threshold > 0.49 and c.compact_threshold < 0.51);

    c.setThreshold(0.0);
    try testing.expect(c.compact_threshold >= 0.1);

    c.setThreshold(2.0);
    try testing.expect(c.compact_threshold <= 0.99);
}

test "ContextCompactor - setRecentWindow" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(5);
    try testing.expectEqual(@as(u32, 5), c.recent_window);
}

test "ContextCompactor - preserveTopic" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    try c.preserveTopic("architecture");
    try c.preserveTopic("decisions");
    try testing.expectEqual(@as(usize, 2), c.preserved_topics.items.len);
    try testing.expectEqualStrings("architecture", c.preserved_topics.items[0]);
    try testing.expectEqualStrings("decisions", c.preserved_topics.items[1]);
}

test "ContextCompactor - needsCompaction below threshold" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setThreshold(0.8);
    try testing.expect(!c.needsCompaction(50000));
}

test "ContextCompactor - needsCompaction at threshold" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setThreshold(0.8);
    try testing.expect(c.needsCompaction(80000));
}

test "ContextCompactor - needsCompaction above threshold" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setThreshold(0.8);
    try testing.expect(c.needsCompaction(95000));
}

test "ContextCompactor - estimateTokens" {
    try testing.expectEqual(@as(u64, 25), ContextCompactor.estimateTokens("a" ** 100));
    try testing.expectEqual(@as(u64, 2), ContextCompactor.estimateTokens("hello"));
    try testing.expectEqual(@as(u64, 0), ContextCompactor.estimateTokens(""));
}

test "ContextCompactor - compact with messages under recent window" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(10);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "Hello", .timestamp = null },
        .{ .role = "assistant", .content = "Hi there", .timestamp = null },
        .{ .role = "user", .content = "How are you?", .timestamp = null },
    };

    const result = try c.compact(&messages);
    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
    try testing.expectEqual(@as(u32, 0), result.messages_summarized);
    try testing.expectEqual(@as(usize, 3), result.messages.len);
}

test "ContextCompactor - compact summarizes old messages" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "I decided to use React for the frontend and we need to plan the entire component architecture carefully", .timestamp = null },
        .{ .role = "assistant", .content = "Good choice. React is well-supported and has a large ecosystem of tools and libraries available for development.", .timestamp = null },
        .{ .role = "user", .content = "We chose PostgreSQL for the database because of its reliability and feature set for complex queries and data integrity", .timestamp = null },
        .{ .role = "assistant", .content = "PostgreSQL is excellent for this use case. It provides great performance for both read and write heavy workloads.", .timestamp = null },
        .{ .role = "user", .content = "What about the latest changes?", .timestamp = null },
        .{ .role = "assistant", .content = "Latest changes are deployed.", .timestamp = null },
    };

    var result = try c.compact(&messages);
    defer result.deinit();
    try testing.expectEqual(@as(u32, 4), result.messages_summarized);
    try testing.expectEqual(@as(usize, 2), result.messages.len);
    try testing.expectEqualStrings("user", result.messages[0].role);
    try testing.expectEqualStrings("assistant", result.messages[1].role);
    try testing.expect(result.summary.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.summary, "compacted") != null);
    try testing.expectEqualStrings(result.summary, c.previous_summary);
}

test "ContextCompactor - compact preserves decisions in summary" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "We decided to use JWT for authentication tokens in our new microservices architecture", .timestamp = null },
        .{ .role = "assistant", .content = "JWT auth is secure and scalable for distributed systems.", .timestamp = null },
        .{ .role = "user", .content = "I approved the microservices architecture with event-driven communication patterns", .timestamp = null },
        .{ .role = "assistant", .content = "Microservices will help with scaling individual components independently.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    var result = try c.compact(&messages);
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.summary, "decided") != null or std.mem.indexOf(u8, result.summary, "approved") != null);
}

test "ContextCompactor - compact with preserved topics" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);
    try c.preserveTopic("JWT");

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "Let's use JWT for auth tokens in our new system", .timestamp = null },
        .{ .role = "assistant", .content = "JWT is a good choice for stateless authentication and authorization.", .timestamp = null },
        .{ .role = "user", .content = "We also need a rate limiter for API protection", .timestamp = null },
        .{ .role = "assistant", .content = "Rate limiting is important for API protection and abuse prevention.", .timestamp = null },
        .{ .role = "user", .content = "Latest question", .timestamp = null },
        .{ .role = "assistant", .content = "Latest answer", .timestamp = null },
    };

    var result = try c.compact(&messages);
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.summary, "JWT") != null);
}

test "ContextCompactor - compactLight truncates long content" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const long_content = "a" ** 600;
    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = long_content, .timestamp = null },
        .{ .role = "assistant", .content = "short", .timestamp = null },
    };

    var result = try c.compactLight(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.messages.len);
    try testing.expect(result.tokens_saved > 0);
    try testing.expectEqual(@as(usize, 203), result.messages[0].content.len);
    try testing.expect(std.mem.endsWith(u8, result.messages[0].content, "..."));
    try testing.expectEqualStrings("short", result.messages[1].content);
}

test "ContextCompactor - compactWithSummary uses rolling summary marker" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "I decided to use Zig for this CLI implementation", .timestamp = null },
        .{ .role = "assistant", .content = "Zig fits the zero-dependency goal well.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    var result = try c.compactWithSummary(&messages, "Goal\n- I asked you to add context compression.");
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.summary, "[Rolling Summary — updated]") != null);
    try testing.expect(std.mem.indexOf(u8, result.summary, "Previous context summary") != null);
    try testing.expect(std.mem.indexOf(u8, result.summary, "context compression") != null);
    try testing.expectEqualStrings(result.summary, c.previous_summary);
}

test "ContextCompactor - buildSummarizationPrompt includes agent framing and previous summary" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(1);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "Please update src/agent/compaction.zig", .timestamp = null },
        .{ .role = "assistant", .content = "I inspected the current implementation.", .timestamp = null },
    };

    const prompt = try c.buildSummarizationPrompt(&messages, "Goal\n- I asked you to extend compaction.");
    defer testing.allocator.free(prompt);

    // Agent framing
    try testing.expect(std.mem.indexOf(u8, prompt, "Context Recovery") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "This summary will be read by YOU") != null);

    // Previous summary injection
    try testing.expect(std.mem.indexOf(u8, prompt, "Previous context summary:") != null);

    // Section headings
    try testing.expect(std.mem.indexOf(u8, prompt, "Goal") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Constraints") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Discoveries") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Accomplished") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Errors + Fixes") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Files") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Pending") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Next Step") != null);

    // Conversation history
    try testing.expect(std.mem.indexOf(u8, prompt, "Conversation history to summarize:") != null);
}

test "CompactMessage - struct field access" {
    const msg = CompactMessage{
        .role = "user",
        .content = "test message",
        .timestamp = @as(?i64, 1234567890),
    };
    try testing.expectEqualStrings("user", msg.role);
    try testing.expectEqualStrings("test message", msg.content);
    try testing.expect(msg.timestamp != null);
    try testing.expectEqual(@as(i64, 1234567890), msg.timestamp.?);
}

test "CompactResult - struct field access" {
    const msgs = [_]CompactMessage{
        .{ .role = "user", .content = "hi", .timestamp = null },
    };
    var result = CompactResult{
        .messages = &msgs,
        .tokens_saved = 500,
        .messages_summarized = 10,
        .summary = "Summary text",
        .agent_metadata = std.StringHashMap([]const u8).init(testing.allocator),
    };
    defer result.agent_metadata.deinit();
    try testing.expectEqual(@as(u64, 500), result.tokens_saved);
    try testing.expectEqual(@as(u32, 10), result.messages_summarized);
    try testing.expectEqualStrings("Summary text", result.summary);
    try testing.expectEqual(@as(usize, 1), result.messages.len);
}

// ========== Tests for new additions ==========

test "CompactionConfig - default values" {
    const config = CompactionConfig{};
    try testing.expectEqual(@as(u64, 128000), config.max_tokens);
    try testing.expect(config.compact_threshold > 0.79 and config.compact_threshold < 0.81);
    try testing.expectEqual(@as(u32, 10), config.recent_window);
    try testing.expect(!config.preserve_tool_outputs);
    try testing.expectEqual(@as(u32, 512), config.max_summary_tokens);
    try testing.expectEqual(@as(u32, 2000), config.max_tool_output_chars);
    try testing.expectEqualStrings("haiku", config.llm_compaction_model);
}

test "ToolTruncationResult - deinit frees allocations" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = "short", .timestamp = null },
    };

    var result = try c.truncateToolOutputs(&messages, 100);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.messages.len);
    try testing.expectEqual(@as(u32, 0), result.truncated_count);
    try testing.expectEqual(@as(u64, 0), result.chars_saved);
}

test "truncateToolOutputs - truncates tool messages exceeding max_chars" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const long_tool_output = "x" ** 5000;
    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = long_tool_output, .timestamp = null },
        .{ .role = "assistant", .content = "response", .timestamp = null },
        .{ .role = "tool", .content = "short tool output", .timestamp = null },
    };

    var result = try c.truncateToolOutputs(&messages, 100);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.messages.len);
    try testing.expectEqual(@as(u32, 1), result.truncated_count);
    try testing.expect(result.chars_saved > 0);
    try testing.expect(std.mem.endsWith(u8, result.messages[0].content, "... (truncated)"));
    try testing.expectEqualStrings("response", result.messages[1].content);
    try testing.expectEqualStrings("short tool output", result.messages[2].content);
}

test "truncateToolOutputs - preserves non-tool messages unchanged" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "a" ** 5000, .timestamp = null },
        .{ .role = "assistant", .content = "b" ** 5000, .timestamp = null },
    };

    var result = try c.truncateToolOutputs(&messages, 100);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.truncated_count);
    try testing.expectEqual(@as(u64, 0), result.chars_saved);
    try testing.expectEqualStrings("a" ** 5000, result.messages[0].content);
    try testing.expectEqualStrings("b" ** 5000, result.messages[1].content);
}

test "truncateToolOutputs - empty messages" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const messages = [_]CompactMessage{};
    var result = try c.truncateToolOutputs(&messages, 100);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.messages.len);
    try testing.expectEqual(@as(u32, 0), result.truncated_count);
}

fn mockSendToLLM(allocator: Allocator, prompt: []const u8, model: []const u8) anyerror!?[]const u8 {
    _ = prompt;
    _ = model;
    return try allocator.dupe(u8, "Goal\n- Build compaction system.\nAccomplished\n- Added truncateToolOutputs.");
}

test "compactWithLLM - successful LLM summarization" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "I decided to use Zig for this CLI implementation", .timestamp = null },
        .{ .role = "assistant", .content = "Zig fits the zero-dependency goal well.", .timestamp = null },
        .{ .role = "user", .content = "We also chose PostgreSQL for the database layer", .timestamp = null },
        .{ .role = "assistant", .content = "PostgreSQL is excellent for this use case.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    const config = CompactionConfig{};
    var result = try c.compactWithLLM(&messages, config, mockSendToLLM);
    defer result.deinit();

    try testing.expect(result.summary.len > 0);
    try testing.expectEqual(@as(u32, 4), result.messages_summarized);
    try testing.expectEqual(@as(usize, 2), result.messages.len);
    try testing.expectEqualStrings("user", result.messages[0].role);
    try testing.expect(result.tokens_saved > 0);
    try testing.expectEqualStrings(result.summary, c.previous_summary);
}

test "compactWithLLM - falls back to heuristic on LLM null" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "I decided to use React for the frontend", .timestamp = null },
        .{ .role = "assistant", .content = "React is well-supported.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    const config = CompactionConfig{};

    const nullLLM = struct {
        fn call(allocator: Allocator, prompt: []const u8, model: []const u8) anyerror!?[]const u8 {
            _ = allocator;
            _ = prompt;
            _ = model;
            return null;
        }
    }.call;

    var result = try c.compactWithLLM(&messages, config, nullLLM);
    defer result.deinit();

    // Should have fallen back to heuristic compaction
    try testing.expect(result.summary.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.summary, "compacted") != null);
}

test "compactWithLLM - falls back to heuristic on LLM error" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "I decided to use JWT for auth", .timestamp = null },
        .{ .role = "assistant", .content = "JWT auth is secure.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    const config = CompactionConfig{};

    const errorLLM = struct {
        fn call(allocator: Allocator, prompt: []const u8, model: []const u8) anyerror!?[]const u8 {
            _ = allocator;
            _ = prompt;
            _ = model;
            return error.NetworkError;
        }
    }.call;

    var result = try c.compactWithLLM(&messages, config, errorLLM);
    defer result.deinit();

    // Should have fallen back to heuristic compaction
    try testing.expect(result.summary.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.summary, "compacted") != null);
}

test "compactWithLLM - returns identity for small message count" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "Hello", .timestamp = null },
        .{ .role = "assistant", .content = "Hi there", .timestamp = null },
    };

    const config = CompactionConfig{};
    const result = try c.compactWithLLM(&messages, config, mockSendToLLM);

    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
    try testing.expectEqual(@as(u32, 0), result.messages_summarized);
    try testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "compactWithLLM - uses config recent_window over default" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(5);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "msg1", .timestamp = null },
        .{ .role = "assistant", .content = "msg2", .timestamp = null },
        .{ .role = "user", .content = "msg3", .timestamp = null },
        .{ .role = "assistant", .content = "msg4", .timestamp = null },
        .{ .role = "user", .content = "msg5", .timestamp = null },
        .{ .role = "assistant", .content = "msg6", .timestamp = null },
    };

    // Config overrides the default recent_window of 5 with 2
    const config = CompactionConfig{ .recent_window = 2 };
    var result = try c.compactWithLLM(&messages, config, mockSendToLLM);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 4), result.messages_summarized);
    try testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "compactWithLLM - truncates tool outputs when not preserving" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const long_tool = "x" ** 5000;
    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = long_tool, .timestamp = null },
        .{ .role = "assistant", .content = "Got it.", .timestamp = null },
        .{ .role = "user", .content = "Recent question", .timestamp = null },
        .{ .role = "assistant", .content = "Recent answer", .timestamp = null },
    };

    const config = CompactionConfig{ .preserve_tool_outputs = false, .max_tool_output_chars = 100 };
    var result = try c.compactWithLLM(&messages, config, mockSendToLLM);
    defer result.deinit();

    try testing.expect(result.summary.len > 0);
    try testing.expectEqual(@as(u32, 2), result.messages_summarized);
}

// ========== Tests for microCompact ==========

test "microCompact - prunes stale tool outputs older than recent window" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(2);

    const stale_tool_output = "x" ** 1000;
    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = stale_tool_output, .timestamp = null },
        .{ .role = "assistant", .content = "Got it.", .timestamp = null },
        .{ .role = "tool", .content = "recent tool output", .timestamp = null },
        .{ .role = "assistant", .content = "Done.", .timestamp = null },
    };

    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.messages.len);
    try testing.expect(result.tokens_saved > 0);
    // First tool message should be pruned (stale)
    try testing.expect(std.mem.indexOf(u8, result.messages[0].content, "[tool output pruned]") != null);
    // Recent tool message should be intact
    try testing.expectEqualStrings("recent tool output", result.messages[2].content);
    // User/assistant messages unchanged
    try testing.expectEqualStrings("Got it.", result.messages[1].content);
    try testing.expectEqualStrings("Done.", result.messages[3].content);
}

test "microCompact - does not touch user or assistant messages" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(1);

    const messages = [_]CompactMessage{
        .{ .role = "user", .content = "long user message that should not be touched at all " ** 50, .timestamp = null },
        .{ .role = "assistant", .content = "long assistant message that should not be touched " ** 50, .timestamp = null },
        .{ .role = "user", .content = "recent user msg", .timestamp = null },
    };

    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
    try testing.expectEqualStrings("user", result.messages[0].role);
    try testing.expectEqualStrings("assistant", result.messages[1].role);
}

test "microCompact - no pruning when all messages within recent window" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(10);

    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = "tool output 1", .timestamp = null },
        .{ .role = "tool", .content = "tool output 2", .timestamp = null },
    };

    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
    try testing.expectEqualStrings("tool output 1", result.messages[0].content);
    try testing.expectEqualStrings("tool output 2", result.messages[1].content);
}

test "microCompact - empty tool outputs are not pruned" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(1);

    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = "", .timestamp = null },
        .{ .role = "user", .content = "recent", .timestamp = null },
    };

    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
    try testing.expectEqualStrings("", result.messages[0].content);
}

test "microCompact - empty messages array" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();

    const messages = [_]CompactMessage{};
    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.messages.len);
    try testing.expectEqual(@as(u64, 0), result.tokens_saved);
}

test "microCompact - messages_summarized is zero (no messages removed)" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setRecentWindow(1);

    const messages = [_]CompactMessage{
        .{ .role = "tool", .content = "big stale tool output " ** 100, .timestamp = null },
        .{ .role = "user", .content = "recent", .timestamp = null },
    };

    var result = try c.microCompact(&messages);
    defer result.deinit();

    try testing.expect(result.tokens_saved > 0);
    try testing.expectEqual(@as(u32, 0), result.messages_summarized);
    try testing.expectEqual(@as(usize, 2), result.messages.len);
}
