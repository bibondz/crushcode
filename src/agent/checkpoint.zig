const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// Checkpoint state for agent persistence
pub const Checkpoint = struct {
    allocator: Allocator,
    id: []const u8,
    timestamp: i64,
    messages: []const CheckpointMessage,
    tool_calls: u32,
    tokens_used: u32,
    metadata: std.StringHashMap([]const u8),

    pub const CheckpointMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    pub fn deinit(self: *Checkpoint) void {
        self.allocator.free(self.id);
        for (self.messages) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.allocator.free(self.messages);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Checkpoint manager for saving and restoring agent state
pub const CheckpointManager = struct {
    allocator: Allocator,
    checkpoint_dir: []const u8,

    pub fn init(allocator: Allocator, checkpoint_dir: []const u8) CheckpointManager {
        return CheckpointManager{
            .allocator = allocator,
            .checkpoint_dir = checkpoint_dir,
        };
    }

    /// Save a checkpoint to disk
    pub fn save(self: *CheckpointManager, checkpoint: *const Checkpoint) !void {
        // Ensure directory exists
        try std.fs.cwd().makePath(self.checkpoint_dir);

        // Build filename: checkpoint_<id>.json
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/checkpoint_{s}.json", .{ self.checkpoint_dir, checkpoint.id });
        defer self.allocator.free(filename);

        const file = file_compat.wrap(try std.fs.cwd().createFile(filename, .{ .truncate = true }));
        defer file.close();

        const writer = file.writer();

        // Write JSON manually (Zig stdlib has no JSON writer)
        try writer.writeAll("{\n");
        try writer.print("  \"id\": \"{s}\",\n", .{checkpoint.id});
        try writer.print("  \"timestamp\": {},\n", .{checkpoint.timestamp});
        try writer.print("  \"tool_calls\": {},\n", .{checkpoint.tool_calls});
        try writer.print("  \"tokens_used\": {},\n", .{checkpoint.tokens_used});

        // Write messages
        try writer.writeAll("  \"messages\": [\n");
        for (checkpoint.messages, 0..) |msg, i| {
            try writer.print("    {{\"role\": \"{s}\", \"content\": \"{s}\"}}", .{ msg.role, msg.content });
            if (i < checkpoint.messages.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }

    /// Load a checkpoint from disk
    pub fn load(self: *CheckpointManager, id: []const u8) !Checkpoint {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/checkpoint_{s}.json", .{ self.checkpoint_dir, id });
        defer self.allocator.free(filename);

        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value;

        var messages = array_list_compat.ArrayList(Checkpoint.CheckpointMessage).init(self.allocator);
        errdefer {
            for (messages.items) |msg| {
                self.allocator.free(msg.role);
                self.allocator.free(msg.content);
            }
            messages.deinit();
        }

        // Parse messages array
        if (root.object.get("messages")) |msgs_val| {
            for (msgs_val.array.items) |msg_val| {
                const role = msg_val.object.get("role").?.string;
                const content = msg_val.object.get("content").?.string;
                try messages.append(.{
                    .role = try self.allocator.dupe(u8, role),
                    .content = try self.allocator.dupe(u8, content),
                });
            }
        }

        return Checkpoint{
            .allocator = self.allocator,
            .id = try self.allocator.dupe(u8, root.object.get("id").?.string),
            .timestamp = root.object.get("timestamp").?.integer,
            .messages = try messages.toOwnedSlice(),
            .tool_calls = @intCast(root.object.get("tool_calls").?.integer),
            .tokens_used = @intCast(root.object.get("tokens_used").?.integer),
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
    }

    /// List available checkpoints
    pub fn list(self: *CheckpointManager) ![][]const u8 {
        var checkpoints = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (checkpoints.items) |cp| self.allocator.free(cp);
            checkpoints.deinit();
        }

        var dir = std.fs.cwd().openDir(self.checkpoint_dir, .{ .iterate = true }) catch return try checkpoints.toOwnedSlice();
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "checkpoint_")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            // Extract ID from filename
            const id_start = "checkpoint_".len;
            const id_end = entry.name.len - ".json".len;
            if (id_end > id_start) {
                const id = entry.name[id_start..id_end];
                try checkpoints.append(try self.allocator.dupe(u8, id));
            }
        }

        return checkpoints.toOwnedSlice();
    }

    /// Delete a checkpoint
    pub fn delete(self: *CheckpointManager, id: []const u8) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/checkpoint_{s}.json", .{ self.checkpoint_dir, id });
        defer self.allocator.free(filename);

        try std.fs.cwd().deleteFile(filename);
    }

    /// Create a new checkpoint from current state
    pub fn create(self: *CheckpointManager, messages: []const Checkpoint.CheckpointMessage, tool_calls: u32, tokens_used: u32) !Checkpoint {
        const timestamp = std.time.timestamp();

        // Generate ID from timestamp
        const id = try std.fmt.allocPrint(self.allocator, "{}", .{timestamp});

        var cp_messages = try self.allocator.alloc(Checkpoint.CheckpointMessage, messages.len);
        for (messages, 0..) |msg, i| {
            cp_messages[i] = .{
                .role = try self.allocator.dupe(u8, msg.role),
                .content = try self.allocator.dupe(u8, msg.content),
            };
        }

        return Checkpoint{
            .allocator = self.allocator,
            .id = id,
            .timestamp = timestamp,
            .messages = cp_messages,
            .tool_calls = tool_calls,
            .tokens_used = tokens_used,
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
    }
};

// -- Tests --

test "CheckpointManager - create and save" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/crushcode_test_checkpoints";

    // Clean up
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    var mgr = CheckpointManager.init(allocator, tmp_dir);
    const messages = [_]Checkpoint.CheckpointMessage{
        .{ .role = "user", .content = "Hello" },
        .{ .role = "assistant", .content = "Hi there!" },
    };

    var cp = try mgr.create(&messages, 3, 150);
    defer cp.deinit();

    try mgr.save(&cp);

    // Verify file exists
    const file_path = try std.fmt.allocPrint(allocator, "{s}/checkpoint_{s}.json", .{ tmp_dir, cp.id });
    defer allocator.free(file_path);
    const file = try std.fs.cwd().openFile(file_path, .{});
    file.close();

    // Clean up
    std.fs.cwd().deleteTree(tmp_dir) catch {};
}

test "CheckpointManager - save and load" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/crushcode_test_checkpoints2";

    std.fs.cwd().deleteTree(tmp_dir) catch {};

    var mgr = CheckpointManager.init(allocator, tmp_dir);
    const messages = [_]Checkpoint.CheckpointMessage{
        .{ .role = "user", .content = "Test message" },
        .{ .role = "assistant", .content = "Test response" },
    };

    var cp = try mgr.create(&messages, 1, 50);
    try mgr.save(&cp);
    const cp_id = try allocator.dupe(u8, cp.id);
    defer allocator.free(cp_id);
    cp.deinit();

    // Load back
    var loaded = try mgr.load(cp_id);
    defer loaded.deinit();

    try std.testing.expect(loaded.messages.len == 2);
    try std.testing.expect(std.mem.eql(u8, loaded.messages[0].role, "user"));
    try std.testing.expect(std.mem.eql(u8, loaded.messages[1].content, "Test response"));
    try std.testing.expect(loaded.tool_calls == 1);
    try std.testing.expect(loaded.tokens_used == 50);

    std.fs.cwd().deleteTree(tmp_dir) catch {};
}
