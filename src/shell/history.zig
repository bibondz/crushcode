const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A single recorded shell command entry with metadata.
pub const HistoryEntry = struct {
    command: []const u8,
    exit_code: u8,
    cwd: []const u8,
    timestamp: i64,

    /// Free all allocated strings owned by this entry.
    pub fn deinit(self: *HistoryEntry, allocator: Allocator) void {
        allocator.free(self.command);
        allocator.free(self.cwd);
    }
};

/// Append-only JSONL shell command history.
///
/// Each command execution is recorded as a single JSON line in `history.jsonl`.
/// The file lives inside the user's config directory and is created on first write.
pub const ShellHistory = struct {
    allocator: Allocator,
    file_path: []const u8,

    const Self = @This();

    /// Initialize a shell history manager.
    ///
    /// `config_dir` is the base config directory. The history file will be
    /// located at `config_dir/history.jsonl`. The directory is created if it
    /// does not already exist. The returned `file_path` is owned by `Self`.
    pub fn init(allocator: Allocator, config_dir: []const u8) !ShellHistory {
        // Ensure the config directory exists
        std.fs.cwd().makePath(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path = try std.fs.path.join(allocator, &.{ config_dir, "history.jsonl" });

        return ShellHistory{
            .allocator = allocator,
            .file_path = path,
        };
    }

    /// Release the owned file path string.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.file_path);
    }

    /// Append a command execution record to the history file.
    ///
    /// The entry is written as a single JSON line in the format:
    /// `{"cmd":"...","exit":0,"cwd":"...","ts":123456}`
    ///
    /// The timestamp is captured automatically from `std.time.timestamp()`.
    pub fn add(self: *Self, command: []const u8, exit_code: u8, cwd: []const u8) !void {
        const ts = std.time.timestamp();

        // Build the JSON line manually
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"cmd\":\"{s}\",\"exit\":{d},\"cwd\":\"{s}\",\"ts\":{d}}}\n",
            .{ command, exit_code, cwd, ts },
        );
        defer self.allocator.free(line);

        // Open file for append (create if missing)
        const file = std.fs.cwd().openFile(self.file_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                break :blk try std.fs.cwd().createFile(self.file_path, .{});
            },
            else => |e| return e,
        };
        defer file.close();

        try file.seekFromEnd(0);
        try file.writeAll(line);
    }

    /// Read the last `limit` entries from the history file.
    ///
    /// Returns entries in chronological order (oldest first). If the file does
    /// not exist or is empty, returns an empty slice. Caller owns the returned
    /// slice and must free each entry then free the slice.
    pub fn recent(self: *Self, limit: usize) ![]HistoryEntry {
        const contents = self.readFileContents() catch |err| switch (err) {
            error.FileNotFound => return &[_]HistoryEntry{},
            else => return err,
        };
        defer self.allocator.free(contents);

        if (contents.len == 0) return &[_]HistoryEntry{};

        var lines = std.ArrayList([]const u8).init(self.allocator);
        defer lines.deinit();

        // Split by newlines
        var iter = std.mem.splitSequence(u8, contents, "\n");
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try lines.append(trimmed);
        }

        if (lines.items.len == 0) return &[_]HistoryEntry{};

        // Determine the slice of lines to parse (last N)
        const total = lines.items.len;
        const start = if (limit >= total) @as(usize, 0) else total - limit;

        // Use a dynamic list to handle malformed lines gracefully
        var entries = array_list_compat.ArrayList(HistoryEntry).init(self.allocator);

        for (lines.items[start..]) |line| {
            if (parseEntry(self.allocator, line)) |entry| {
                try entries.append(entry);
            } else |_| {
                // Skip malformed lines
                continue;
            }
        }

        return try entries.toOwnedSlice();
    }

    /// Search history for commands that start with `query`.
    ///
    /// Scans from most recent to oldest. Returns up to `limit` entries in
    /// reverse chronological order. Caller owns the returned slice and each
    /// entry within.
    pub fn search(self: *Self, query: []const u8, limit: usize) ![]HistoryEntry {
        const contents = self.readFileContents() catch |err| switch (err) {
            error.FileNotFound => return &[_]HistoryEntry{},
            else => return err,
        };
        defer self.allocator.free(contents);

        if (contents.len == 0) return &[_]HistoryEntry{};

        var lines = std.ArrayList([]const u8).init(self.allocator);
        defer lines.deinit();

        var iter = std.mem.splitSequence(u8, contents, "\n");
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try lines.append(trimmed);
        }

        var results = array_list_compat.ArrayList(HistoryEntry).init(self.allocator);

        // Scan from end to start (most recent first)
        var i: usize = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = lines.items[i];

            if (parseEntry(self.allocator, line)) |entry| {
                if (std.mem.startsWith(u8, entry.command, query)) {
                    try results.append(entry);
                    if (results.items.len >= limit) break;
                } else {
                    entry.deinit(self.allocator);
                }
            } else |_| {
                continue;
            }
        }

        return results.toOwnedSlice();
    }

    /// Return the full path to the history JSONL file.
    pub fn getFilePath(self: *const Self) []const u8 {
        return self.file_path;
    }

    // ── Internal helpers ──────────────────────────────────────────────

    /// Read the entire history file into a caller-owned buffer.
    fn readFileContents(self: *Self) ![]u8 {
        const file = try std.fs.cwd().openFile(self.file_path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return try self.allocator.dupe(u8, "");

        const buf = try self.allocator.alloc(u8, stat.size);
        const bytes_read = try file.readAll(buf);
        return buf[0..bytes_read];
    }

    /// Parse a single JSONL line into a HistoryEntry.
    fn parseEntry(allocator: Allocator, line: []const u8) !HistoryEntry {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        const obj = root.object;

        // Extract "cmd"
        const cmd_val = obj.get("cmd") orelse return error.InvalidFormat;
        if (cmd_val != .string) return error.InvalidFormat;
        const command = try allocator.dupe(u8, cmd_val.string);

        // Extract "exit"
        const exit_val = obj.get("exit") orelse return error.InvalidFormat;
        const exit_code: u8 = if (exit_val == .integer)
            @intCast(exit_val.integer)
        else
            return error.InvalidFormat;

        // Extract "cwd"
        const cwd_val = obj.get("cwd") orelse return error.InvalidFormat;
        if (cwd_val != .string) return error.InvalidFormat;
        const cwd = try allocator.dupe(u8, cwd_val.string);

        // Extract "ts"
        const ts_val = obj.get("ts") orelse return error.InvalidFormat;
        const timestamp: i64 = if (ts_val == .integer)
            ts_val.integer
        else
            return error.InvalidFormat;

        return HistoryEntry{
            .command = command,
            .exit_code = exit_code,
            .cwd = cwd,
            .timestamp = timestamp,
        };
    }
};
