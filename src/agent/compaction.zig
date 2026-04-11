const std = @import("std");

const Allocator = std.mem.Allocator;

/// Auto-Context Compaction — automatically compresses long conversation sessions
///
/// When context approaches the model's token limit, this system:
/// 1. Detects the approaching limit
/// 2. Preserves recent messages at full fidelity
/// 3. Summarizes older messages into a compact representation
/// 4. Maintains key decisions and context markers
///
/// Reference: OpenHarness auto-compaction for long session context
pub const ContextCompactor = struct {
    allocator: Allocator,
    max_tokens: u64,
    compact_threshold: f64, // Compact when usage exceeds this ratio (0.0-1.0)
    recent_window: u32, // Number of recent messages to preserve unchanged
    preserved_topics: std.ArrayList([]const u8), // Topics that must not be lost

    pub fn init(allocator: Allocator, max_tokens: u64) ContextCompactor {
        return ContextCompactor{
            .allocator = allocator,
            .max_tokens = max_tokens,
            .compact_threshold = 0.8,
            .recent_window = 10,
            .preserved_topics = std.ArrayList([]const u8).init(allocator),
        };
    }

    /// Set the compaction threshold (0.0-1.0 of max_tokens)
    pub fn setThreshold(self: *ContextCompactor, threshold: f64) void {
        self.compact_threshold = @min(@max(threshold, 0.1), 0.99);
    }

    /// Set the number of recent messages to preserve
    pub fn setRecentWindow(self: *ContextCompactor, window: u32) void {
        self.recent_window = window;
    }

    /// Add a topic that must be preserved during compaction
    pub fn preserveTopic(self: *ContextCompactor, topic: []const u8) !void {
        try self.preserved_topics.append(try self.allocator.dupe(u8, topic));
    }

    /// Check if compaction is needed based on current token usage
    pub fn needsCompaction(self: *const ContextCompactor, current_tokens: u64) bool {
        const ratio = @as(f64, @floatFromInt(current_tokens)) / @as(f64, @floatFromInt(self.max_tokens));
        return ratio >= self.compact_threshold;
    }

    /// Estimate token count for a message (rough: ~4 chars per token)
    pub fn estimateTokens(text: []const u8) u64 {
        return @intCast(std.math.divCeil(usize, text.len, 4) catch 1);
    }

    /// Compact a list of messages
    /// Returns compacted messages with older ones summarized
    pub fn compact(
        self: *ContextCompactor,
        messages: []const CompactMessage,
    ) !CompactResult {
        if (messages.len <= self.recent_window) {
            return CompactResult{
                .messages = messages,
                .tokens_saved = 0,
                .messages_summarized = 0,
                .summary = "",
            };
        }

        var total_tokens_before: u64 = 0;
        for (messages) |msg| {
            total_tokens_before += estimateTokens(msg.content);
        }

        // Split into old (to summarize) and recent (to preserve)
        const split_point = messages.len - self.recent_window;
        const old_messages = messages[0..split_point];
        const recent_messages = messages[split_point..];

        // Build summary of old messages
        var summary_buf = std.ArrayList(u8).init(self.allocator);
        defer summary_buf.deinit();
        const writer = summary_buf.writer();

        try writer.print("[Context Summary — {d} messages compacted]\n", .{old_messages.len});

        // Extract key information from old messages
        var decisions = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (decisions.items) |d| self.allocator.free(d);
            decisions.deinit();
        }

        var topics_seen = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (topics_seen.items) |t| self.allocator.free(t);
            topics_seen.deinit();
        }

        for (old_messages) |msg| {
            // Detect decisions (messages containing "decided", "chose", "will use")
            if (self.containsAny(msg.content, &.{ "decided", "chose", "will use", "selected", "approved", "rejected" })) {
                const snippet = self.extractSnippet(msg.content, 200);
                try decisions.append(try self.allocator.dupe(u8, snippet));
            }

            // Check preserved topics
            for (self.preserved_topics.items) |topic| {
                if (std.mem.indexOf(u8, msg.content, topic) != null) {
                    const snippet = self.extractSnippet(msg.content, 300);
                    try topics_seen.append(try std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ topic, snippet }));
                }
            }
        }

        // Write summary sections
        if (decisions.items.len > 0) {
            try writer.print("\nKey Decisions:\n", .{});
            for (decisions.items) |d| {
                try writer.print("  - {s}\n", .{d});
            }
        }

        if (topics_seen.items.len > 0) {
            try writer.print("\nPreserved Context:\n", .{});
            for (topics_seen.items) |t| {
                try writer.print("  {s}\n", .{t});
            }
        }

        // Add role distribution
        var user_count: u32 = 0;
        var assistant_count: u32 = 0;
        for (old_messages) |msg| {
            if (std.mem.eql(u8, msg.role, "user")) user_count += 1;
            if (std.mem.eql(u8, msg.role, "assistant")) assistant_count += 1;
        }
        try writer.print("\nSession: {d} user msgs, {d} assistant msgs\n", .{ user_count, assistant_count });

        const summary = try summary_buf.toOwnedSlice();
        const summary_tokens = estimateTokens(summary);
        var tokens_after: u64 = summary_tokens;
        for (recent_messages) |msg| {
            tokens_after += estimateTokens(msg.content);
        }

        return CompactResult{
            .messages = recent_messages,
            .tokens_saved = total_tokens_before -| tokens_after,
            .messages_summarized = @intCast(old_messages.len),
            .summary = summary,
        };
    }

    /// Check if text contains any of the patterns
    fn containsAny(_: *ContextCompactor, text: []const u8, patterns: []const []const u8) bool {
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, text, pattern) != null) return true;
        }
        return false;
    }

    /// Extract a snippet from text (up to max_len chars)
    fn extractSnippet(_: *ContextCompactor, text: []const u8, max_len: usize) []const u8 {
        if (text.len <= max_len) return text;
        return text[0..max_len];
    }

    /// Print compaction status
    pub fn printStatus(self: *ContextCompactor, current_tokens: u64) void {
        const stdout = std.io.getStdOut().writer();
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
    }
};

/// A message in the compactable conversation
pub const CompactMessage = struct {
    role: []const u8,
    content: []const u8,
    timestamp: ?i64,
};

/// Result of a compaction operation
pub const CompactResult = struct {
    messages: []const CompactMessage,
    tokens_saved: u64,
    messages_summarized: u32,
    summary: []const u8,
};
