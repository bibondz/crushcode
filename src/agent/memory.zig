const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// A single conversation message
pub const Message = struct {
    role: []const u8,
    content: []const u8,
    timestamp: i64,
};

/// Conversation memory that persists across sessions
pub const Memory = struct {
    allocator: Allocator,
    messages: array_list_compat.ArrayList(Message),
    max_messages: usize,
    file_path: []const u8,

    pub fn init(allocator: Allocator, file_path: []const u8, max_messages: usize) Memory {
        return Memory{
            .allocator = allocator,
            .messages = array_list_compat.ArrayList(Message).init(allocator),
            .max_messages = max_messages,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *Memory) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
    }

    /// Add a message to memory
    pub fn addMessage(self: *Memory, role: []const u8, content: []const u8) !void {
        const msg = Message{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
        };

        try self.messages.append(msg);

        // Trim if over max
        while (self.messages.items.len > self.max_messages) {
            const old = self.messages.orderedRemove(0);
            self.allocator.free(old.role);
            self.allocator.free(old.content);
        }
    }

    /// Get recent messages for context window
    pub fn getRecent(self: *Memory, max_count: usize) []const Message {
        const start = if (max_count < self.messages.items.len) self.messages.items.len - max_count else 0;
        return self.messages.items[start..];
    }

    /// Get messages by role
    pub fn getByRole(self: *Memory, allocator: Allocator, role: []const u8) ![]const Message {
        var matching = array_list_compat.ArrayList(Message).init(allocator);
        errdefer matching.deinit();

        for (self.messages.items) |msg| {
            if (std.mem.eql(u8, msg.role, role)) {
                try matching.append(msg);
            }
        }

        return matching.toOwnedSlice();
    }

    /// Get total token estimate (rough: ~4 chars per token)
    pub fn estimateTokens(self: *Memory) usize {
        var total_chars: usize = 0;
        for (self.messages.items) |msg| {
            total_chars += msg.content.len;
        }
        return total_chars / 4;
    }

    /// Save memory to file
    pub fn save(self: *Memory) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(self.file_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const file = file_compat.wrap(try std.fs.cwd().createFile(self.file_path, .{ .truncate = true }));
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("[\n");
        for (self.messages.items, 0..) |msg, i| {
            try writer.print("  {{\"role\": \"{s}\", \"content\": \"{s}\", \"timestamp\": {}}}", .{ msg.role, msg.content, msg.timestamp });
            if (i < self.messages.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("]\n");
    }

    /// Load memory from file
    pub fn load(self: *Memory) !void {
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // No file = empty memory
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return;

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        const content = buffer[0..bytes_read];

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        for (parsed.value.array.items) |item| {
            const role = item.object.get("role").?.string;
            const content_str = item.object.get("content").?.string;
            // Don't use addMessage to avoid double-dupe — direct append
            try self.messages.append(Message{
                .role = try self.allocator.dupe(u8, role),
                .content = try self.allocator.dupe(u8, content_str),
                .timestamp = if (item.object.get("timestamp")) |ts| ts.integer else 0,
            });
        }
    }

    /// Clear all messages
    pub fn clear(self: *Memory) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.clearRetainingCapacity();
    }

    /// Get message count
    pub fn count(self: *Memory) usize {
        return self.messages.items.len;
    }

    /// Print memory summary
    pub fn printSummary(self: *Memory) void {
        std.log.info("Memory: {} messages, ~{} tokens", .{ self.count(), self.estimateTokens() });
        const recent = self.getRecent(5);
        if (recent.len > 0) {
            std.log.info("Recent:", .{});
            for (recent) |msg| {
                const preview_len = @min(msg.content.len, 80);
                std.log.info("  [{s}] {s}...", .{ msg.role, msg.content[0..preview_len] });
            }
        }
    }
};

// -- Tests --

test "Memory - add and retrieve" {
    const allocator = std.testing.allocator;
    var memory = Memory.init(allocator, "/tmp/crushcode_test_memory.json", 10);
    defer memory.deinit();

    try memory.addMessage("user", "Hello");
    try memory.addMessage("assistant", "Hi there!");
    try memory.addMessage("user", "How are you?");

    try std.testing.expectEqual(@as(usize, 3), memory.count());

    const recent = memory.getRecent(2);
    try std.testing.expectEqual(@as(usize, 2), recent.len);
    try std.testing.expect(std.mem.eql(u8, recent[0].role, "assistant"));
    try std.testing.expect(std.mem.eql(u8, recent[1].role, "user"));
}

test "Memory - max messages trim" {
    const allocator = std.testing.allocator;
    var memory = Memory.init(allocator, "/tmp/crushcode_test_memory_max.json", 3);
    defer memory.deinit();

    try memory.addMessage("user", "msg1");
    try memory.addMessage("user", "msg2");
    try memory.addMessage("user", "msg3");
    try memory.addMessage("user", "msg4");

    // Should be trimmed to 3
    try std.testing.expectEqual(@as(usize, 3), memory.count());
    // msg1 should be gone
    try std.testing.expect(std.mem.eql(u8, memory.messages.items[0].content, "msg2"));
}

test "Memory - save and load" {
    const allocator = std.testing.allocator;
    const path = "/tmp/crushcode_test_memory_persist.json";

    // Clean up
    std.fs.cwd().deleteFile(path) catch {};

    // Save
    {
        var mem1 = Memory.init(allocator, path, 100);
        defer mem1.deinit();

        try mem1.addMessage("user", "Persistent message");
        try mem1.addMessage("assistant", "Persistent response");
        try mem1.save();
    }

    // Load
    {
        var mem2 = Memory.init(allocator, path, 100);
        defer mem2.deinit();

        try mem2.load();
        try std.testing.expectEqual(@as(usize, 2), mem2.count());
        try std.testing.expect(std.mem.eql(u8, mem2.messages.items[0].content, "Persistent message"));
        try std.testing.expect(std.mem.eql(u8, mem2.messages.items[1].content, "Persistent response"));
    }

    std.fs.cwd().deleteFile(path) catch {};
}
