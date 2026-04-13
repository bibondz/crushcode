const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A single entry in the session history
pub const SessionEntry = struct {
    role: Role,
    content: []const u8,
    timestamp: i64,
    token_count: ?u32,

    pub const Role = enum { user, assistant, system, tool };

    pub fn deinit(self: *SessionEntry, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// Summary of a session for compact display
pub const SessionSummary = struct {
    allocator: Allocator,
    total_entries: u32,
    user_messages: u32,
    assistant_messages: u32,
    tool_calls: u32,
    total_tokens: u64,
    duration_seconds: u64,
    first_timestamp: i64,
    last_timestamp: i64,
    /// Truncated summary of key exchanges
    key_exchanges: []SessionEntry,

    pub fn deinit(self: *SessionSummary) void {
        for (self.key_exchanges) |*e| {
            e.deinit(self.allocator);
        }
        self.allocator.free(self.key_exchanges);
    }
};

/// Diff between two sessions
pub const SessionDiff = struct {
    added_entries: u32,
    removed_entries: u32,
    token_delta: i64,
    duration_delta_seconds: i64,
};

/// Session summarizer that tracks conversation history and produces compact summaries.
/// Reference: OpenCode session summarization (F11)
pub const SessionSummarizer = struct {
    allocator: Allocator,
    entries: array_list_compat.ArrayList(SessionEntry),
    max_entries: u32,

    pub fn init(allocator: Allocator, max_entries: u32) SessionSummarizer {
        return SessionSummarizer{
            .allocator = allocator,
            .entries = array_list_compat.ArrayList(SessionEntry).init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *SessionSummarizer) void {
        for (self.entries.items) |*e| {
            e.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Add an entry to the session
    pub fn addEntry(self: *SessionSummarizer, role: SessionEntry.Role, content: []const u8, token_count: ?u32) !void {
        const entry = SessionEntry{
            .role = role,
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
            .token_count = token_count,
        };
        try self.entries.append(entry);
    }

    /// Get all entries
    pub fn getEntries(self: *const SessionSummarizer) []const SessionEntry {
        return self.entries.items;
    }

    /// Get the last N entries
    pub fn getRecentEntries(self: *const SessionSummarizer, n: usize) []const SessionEntry {
        if (n >= self.entries.items.len) return self.entries.items;
        return self.entries.items[self.entries.items.len - n ..];
    }

    /// Generate a compact summary of the session
    pub fn summarize(self: *SessionSummarizer) !SessionSummary {
        var user_count: u32 = 0;
        var assistant_count: u32 = 0;
        var tool_count: u32 = 0;
        var total_tokens: u64 = 0;

        for (self.entries.items) |entry| {
            switch (entry.role) {
                .user => user_count += 1,
                .assistant => assistant_count += 1,
                .tool => tool_count += 1,
                .system => {},
            }
            if (entry.token_count) |tc| {
                total_tokens += tc;
            }
        }

        const first_ts = if (self.entries.items.len > 0) self.entries.items[0].timestamp else 0;
        const last_ts = if (self.entries.items.len > 0) self.entries.items[self.entries.items.len - 1].timestamp else 0;
        const duration = if (last_ts > first_ts) @as(u64, @intCast(last_ts - first_ts)) else 0;

        // Select key exchanges: first user, last user+assistant pair, and any tool calls
        var key = array_list_compat.ArrayList(SessionEntry).init(self.allocator);
        errdefer {
            for (key.items) |*e| e.deinit(self.allocator);
            key.deinit();
        }

        if (self.entries.items.len > 0) {
            // First entry
            try key.append(.{
                .role = self.entries.items[0].role,
                .content = try self.allocator.dupe(u8, truncate(self.entries.items[0].content, 200)),
                .timestamp = self.entries.items[0].timestamp,
                .token_count = self.entries.items[0].token_count,
            });
        }

        // Last entry (if different from first)
        if (self.entries.items.len > 1) {
            const last = self.entries.items[self.entries.items.len - 1];
            try key.append(.{
                .role = last.role,
                .content = try self.allocator.dupe(u8, truncate(last.content, 200)),
                .timestamp = last.timestamp,
                .token_count = last.token_count,
            });
        }

        return SessionSummary{
            .allocator = self.allocator,
            .total_entries = @intCast(self.entries.items.len),
            .user_messages = user_count,
            .assistant_messages = assistant_count,
            .tool_calls = tool_count,
            .total_tokens = total_tokens,
            .duration_seconds = duration,
            .first_timestamp = first_ts,
            .last_timestamp = last_ts,
            .key_exchanges = try key.toOwnedSlice(),
        };
    }

    /// Compute diff between two sets of entries
    pub fn diff(old_entries: []const SessionEntry, new_entries: []const SessionEntry) SessionDiff {
        const old_tokens = countTokens(old_entries);
        const new_tokens = countTokens(new_entries);

        const old_duration = if (old_entries.len > 1)
            @as(i64, @intCast(old_entries[old_entries.len - 1].timestamp - old_entries[0].timestamp))
        else
            @as(i64, 0);
        const new_duration = if (new_entries.len > 1)
            @as(i64, @intCast(new_entries[new_entries.len - 1].timestamp - new_entries[0].timestamp))
        else
            @as(i64, 0);

        const added = if (new_entries.len > old_entries.len)
            @as(u32, @intCast(new_entries.len - old_entries.len))
        else
            @as(u32, 0);
        const removed = if (old_entries.len > new_entries.len)
            @as(u32, @intCast(old_entries.len - new_entries.len))
        else
            @as(u32, 0);

        return SessionDiff{
            .added_entries = added,
            .removed_entries = removed,
            .token_delta = @as(i64, @intCast(new_tokens)) - @as(i64, @intCast(old_tokens)),
            .duration_delta_seconds = new_duration - old_duration,
        };
    }

    /// Export session as compact text for AI context
    pub fn toContextText(self: *SessionSummarizer, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        for (self.entries.items) |entry| {
            const role_str = switch (entry.role) {
                .user => "User",
                .assistant => "Assistant",
                .system => "System",
                .tool => "Tool",
            };
            const truncated = truncate(entry.content, 500);
            try writer.print("[{s}] {s}\n", .{ role_str, truncated });
        }

        return buf.toOwnedSlice();
    }

    fn truncate(text: []const u8, max_len: usize) []const u8 {
        if (text.len <= max_len) return text;
        return text[0..max_len];
    }

    fn countTokens(entries: []const SessionEntry) u64 {
        var total: u64 = 0;
        for (entries) |e| {
            if (e.token_count) |tc| total += tc;
        }
        return total;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "SessionSummarizer - add and count entries" {
    var ss = SessionSummarizer.init(testing.allocator, 100);
    defer ss.deinit();

    try ss.addEntry(.user, "Hello, help me with something", null);
    try ss.addEntry(.assistant, "Sure, I can help!", null);
    try ss.addEntry(.user, "Write a function", null);

    const entries = ss.getEntries();
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("Hello, help me with something", entries[0].content);
}

test "SessionSummarizer - summarize counts" {
    var ss = SessionSummarizer.init(testing.allocator, 100);
    defer ss.deinit();

    try ss.addEntry(.user, "Question 1", null);
    try ss.addEntry(.assistant, "Answer 1", @as(u32, 100));
    try ss.addEntry(.tool, "Tool result", @as(u32, 50));
    try ss.addEntry(.user, "Question 2", null);

    var summary = try ss.summarize();
    defer summary.deinit();

    try testing.expectEqual(@as(u32, 4), summary.total_entries);
    try testing.expectEqual(@as(u32, 2), summary.user_messages);
    try testing.expectEqual(@as(u32, 1), summary.assistant_messages);
    try testing.expectEqual(@as(u32, 1), summary.tool_calls);
    try testing.expectEqual(@as(u64, 150), summary.total_tokens);
}

test "SessionSummarizer - diff" {
    var old_ss = SessionSummarizer.init(testing.allocator, 100);
    defer old_ss.deinit();
    try old_ss.addEntry(.user, "Q1", @as(u32, 10));

    var new_ss = SessionSummarizer.init(testing.allocator, 100);
    defer new_ss.deinit();
    try new_ss.addEntry(.user, "Q1", @as(u32, 10));
    try new_ss.addEntry(.assistant, "A1", @as(u32, 50));
    try new_ss.addEntry(.user, "Q2", @as(u32, 20));

    const d = SessionSummarizer.diff(old_ss.getEntries(), new_ss.getEntries());
    try testing.expectEqual(@as(u32, 2), d.added_entries);
    try testing.expectEqual(@as(u32, 0), d.removed_entries);
    try testing.expectEqual(@as(i64, 60), d.token_delta);
}

test "SessionSummarizer - getRecentEntries" {
    var ss = SessionSummarizer.init(testing.allocator, 100);
    defer ss.deinit();

    try ss.addEntry(.user, "First", null);
    try ss.addEntry(.assistant, "Second", null);
    try ss.addEntry(.user, "Third", null);
    try ss.addEntry(.assistant, "Fourth", null);

    const recent = ss.getRecentEntries(2);
    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqualStrings("Third", recent[0].content);
    try testing.expectEqualStrings("Fourth", recent[1].content);
}

test "SessionSummarizer - toContextText" {
    var ss = SessionSummarizer.init(testing.allocator, 100);
    defer ss.deinit();

    try ss.addEntry(.user, "Hello", null);
    try ss.addEntry(.assistant, "World", null);

    const text = try ss.toContextText(testing.allocator);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "[User] Hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[Assistant] World") != null);
}
