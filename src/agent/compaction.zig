const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

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
    preserved_topics: array_list_compat.ArrayList([]const u8), // Topics that must not be lost

    pub fn init(allocator: Allocator, max_tokens: u64) ContextCompactor {
        return ContextCompactor{
            .allocator = allocator,
            .max_tokens = max_tokens,
            .compact_threshold = 0.8,
            .recent_window = 10,
            .preserved_topics = array_list_compat.ArrayList([]const u8).init(allocator),
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
        var summary_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer summary_buf.deinit();
        const writer = summary_buf.writer();

        try writer.print("[Context Summary — {d} messages compacted]\n", .{old_messages.len});

        // Extract key information from old messages
        var decisions = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (decisions.items) |d| self.allocator.free(d);
            decisions.deinit();
        }

        var topics_seen = array_list_compat.ArrayList([]const u8).init(self.allocator);
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
            .allocator = self.allocator,
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
    allocator: ?Allocator = null,

    pub fn deinit(self: *CompactResult) void {
        if (self.allocator) |alloc| {
            if (self.summary.len > 0) {
                alloc.free(self.summary);
            }
        }
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "ContextCompactor - init default values" {
    var c = ContextCompactor.init(testing.allocator, 128000);
    defer c.deinit();
    try testing.expectEqual(@as(u64, 128000), c.max_tokens);
    try testing.expect(c.compact_threshold > 0.79 and c.compact_threshold < 0.81);
    try testing.expectEqual(@as(u32, 10), c.recent_window);
    try testing.expectEqual(@as(usize, 0), c.preserved_topics.items.len);
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
    // 50% usage → no compaction needed
    try testing.expect(!c.needsCompaction(50000));
}

test "ContextCompactor - needsCompaction at threshold" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setThreshold(0.8);
    // 80% usage → compaction needed
    try testing.expect(c.needsCompaction(80000));
}

test "ContextCompactor - needsCompaction above threshold" {
    var c = ContextCompactor.init(testing.allocator, 100000);
    defer c.deinit();
    c.setThreshold(0.8);
    // 95% usage → compaction needed
    try testing.expect(c.needsCompaction(95000));
}

test "ContextCompactor - estimateTokens" {
    // ~4 chars per token: divCeil(len, 4)
    try testing.expectEqual(@as(u64, 25), ContextCompactor.estimateTokens("a" ** 100));
    try testing.expectEqual(@as(u64, 2), ContextCompactor.estimateTokens("hello")); // divCeil(5, 4) = 2
    try testing.expectEqual(@as(u64, 0), ContextCompactor.estimateTokens("")); // divCeil(0, 4) = 0
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
    // 3 messages < 10 window → no compaction
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
    // 6 messages, window=2 → 4 summarized
    try testing.expectEqual(@as(u32, 4), result.messages_summarized);
    // Recent 2 messages preserved
    try testing.expectEqual(@as(usize, 2), result.messages.len);
    try testing.expectEqualStrings("user", result.messages[0].role);
    try testing.expectEqualStrings("assistant", result.messages[1].role);
    // Summary should contain decision keywords
    try testing.expect(result.summary.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.summary, "compacted") != null);
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
    // Summary should contain decision keywords
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
    // Preserved topic "JWT" should appear in summary
    try testing.expect(std.mem.indexOf(u8, result.summary, "JWT") != null);
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
    const result = CompactResult{
        .messages = &msgs,
        .tokens_saved = 500,
        .messages_summarized = 10,
        .summary = "Summary text",
    };
    try testing.expectEqual(@as(u64, 500), result.tokens_saved);
    try testing.expectEqual(@as(u32, 10), result.messages_summarized);
    try testing.expectEqualStrings("Summary text", result.summary);
    try testing.expectEqual(@as(usize, 1), result.messages.len);
}
