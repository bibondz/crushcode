const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const env_mod = @import("env");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "err",
        };
    }
};

pub const LogEntry = struct {
    timestamp: i64, // epoch ms
    level: LogLevel,
    message: []const u8,
    session_id: ?[]const u8 = null,
    source: ?[]const u8 = null, // module/function
    field_key: ?[]const u8 = null, // optional extra field
    field_val: ?[]const u8 = null,
};

pub const StructuredLogger = struct {
    allocator: std.mem.Allocator,
    log_dir: []const u8,
    current_file: ?std.fs.File = null,
    current_date: []const u8 = "", // "YYYY-MM-DD"
    current_size: usize = 0,
    max_file_size: usize = 10 * 1024 * 1024, // 10MB
    max_files: u32 = 5, // keep last 5 log files
    enabled: bool = true,
    rotation_counter: u32 = 0,

    const Self = @This();

    /// Initialize the structured logger.
    /// Creates log directory if it doesn't exist and opens today's log file.
    pub fn init(allocator: std.mem.Allocator) !Self {
        const log_dir = env_mod.getLogDir(allocator) catch |err| {
            if (err == error.HomeNotFound) {
                return Self{
                    .allocator = allocator,
                    .log_dir = "",
                    .enabled = false,
                };
            }
            return err;
        };
        errdefer allocator.free(log_dir);

        env_mod.ensureDir(log_dir) catch {
            // Can't create log dir — disable logging
            allocator.free(log_dir);
            return Self{
                .allocator = allocator,
                .log_dir = "",
                .enabled = false,
            };
        };

        var self = Self{
            .allocator = allocator,
            .log_dir = log_dir,
            .enabled = true,
        };

        self.openCurrentFile() catch {
            // Can't open log file — disable logging
            allocator.free(log_dir);
            return Self{
                .allocator = allocator,
                .log_dir = "",
                .enabled = false,
            };
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.current_file) |f| {
            f.close();
            self.current_file = null;
        }
        if (self.current_date.len > 0) {
            self.allocator.free(self.current_date);
        }
        if (self.log_dir.len > 0) {
            self.allocator.free(self.log_dir);
        }
    }

    /// Log a formatted message at the given level.
    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;

        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);

        const entry = LogEntry{
            .timestamp = std.time.milliTimestamp(),
            .level = level,
            .message = message,
        };
        self.logEntry(entry);
    }

    /// Log a pre-built LogEntry.
    pub fn logEntry(self: *Self, entry: LogEntry) void {
        if (!self.enabled) return;

        // Check if we need to rotate files (date change or size)
        self.maybeRotate() catch return;

        // Build JSONL line manually
        const line = self.buildJsonlLine(entry) catch return;
        defer self.allocator.free(line);

        if (self.current_file) |f| {
            f.writeAll(line) catch return;
            f.writeAll("\n") catch return;
            self.current_size += line.len + 1;
        }
    }

    /// Flush is a no-op since writeAll writes immediately.
    pub fn flush(self: *Self) void {
        _ = self;
    }

    // --- Internal helpers ---

    fn buildJsonlLine(self: *Self, entry: LogEntry) ![]const u8 {
        // Escape the message for JSON (handle backslash and double-quote)
        const escaped_msg = try self.escapeJsonString(entry.message);
        defer self.allocator.free(escaped_msg);

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const w = buf.writer();
        try w.print("{{\"ts\":{d},\"level\":\"{s}\",\"msg\":\"{s}\"", .{ entry.timestamp, entry.level.asString(), escaped_msg });

        if (entry.session_id) |sid| {
            const escaped = try self.escapeJsonString(sid);
            defer self.allocator.free(escaped);
            try w.print(",\"session\":\"{s}\"", .{escaped});
        }
        if (entry.source) |src| {
            const escaped = try self.escapeJsonString(src);
            defer self.allocator.free(escaped);
            try w.print(",\"source\":\"{s}\"", .{escaped});
        }
        if (entry.field_key) |key| {
            const escaped_key = try self.escapeJsonString(key);
            defer self.allocator.free(escaped_key);
            if (entry.field_val) |val| {
                const escaped_val = try self.escapeJsonString(val);
                defer self.allocator.free(escaped_val);
                try w.print(",\"{s}\":\"{s}\"", .{ escaped_key, escaped_val });
            }
        }

        try w.writeAll("}");

        return buf.toOwnedSlice();
    }

    fn escapeJsonString(self: *Self, input: []const u8) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        for (input) |ch| {
            switch (ch) {
                '"' => {
                    try buf.appendSlice("\\\"");
                },
                '\\' => {
                    try buf.appendSlice("\\\\");
                },
                '\n' => {
                    try buf.appendSlice("\\n");
                },
                '\r' => {
                    try buf.appendSlice("\\r");
                },
                '\t' => {
                    try buf.appendSlice("\\t");
                },
                else => {
                    if (ch < 0x20) {
                        // Control character — skip
                        continue;
                    }
                    try buf.append(ch);
                },
            }
        }

        return buf.toOwnedSlice();
    }

    fn openCurrentFile(self: *Self) !void {
        const date_str = try self.getDateString();
        errdefer self.allocator.free(date_str);

        const filename = try std.fmt.allocPrint(self.allocator, "crushcode-{s}.jsonl", .{date_str});
        defer self.allocator.free(filename);

        const filepath = try std.fs.path.join(self.allocator, &.{ self.log_dir, filename });
        defer self.allocator.free(filepath);

        // Free old date if any
        if (self.current_date.len > 0) {
            self.allocator.free(self.current_date);
        }
        self.current_date = date_str;
        self.rotation_counter = 0;

        const file = std.fs.cwd().openFile(filepath, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) {
                // Create new file
                const new_file = std.fs.cwd().createFile(filepath, .{ .truncate = false }) catch |create_err| {
                    self.allocator.free(date_str);
                    self.current_date = "";
                    return create_err;
                };
                self.current_file = new_file;
                self.current_size = 0;
                return;
            }
            self.allocator.free(date_str);
            self.current_date = "";
            return err;
        };

        // Get existing file size
        file.seekFromEnd(0) catch {};
        const end_pos = file.getPos() catch 0;
        self.current_size = @intCast(end_pos);
        self.current_file = file;
    }

    fn maybeRotate(self: *Self) !void {
        const today = try self.getDateString();
        defer self.allocator.free(today);

        const date_changed = self.current_date.len > 0 and !std.mem.eql(u8, self.current_date, today);
        const size_exceeded = self.current_size >= self.max_file_size;

        if (date_changed or size_exceeded) {
            if (self.current_file) |f| {
                f.close();
                self.current_file = null;
            }

            if (date_changed) {
                // New day — open fresh file
                self.rotation_counter = 0;
                try self.openCurrentFile();
            } else {
                // Size exceeded — rotate with counter
                self.rotation_counter += 1;
                try self.openRotatedFile();
            }

            // Clean up old files
            self.cleanOldFiles() catch {};
        }
    }

    fn openRotatedFile(self: *Self) !void {
        const date_str = try self.allocator.dupe(u8, self.current_date);
        errdefer self.allocator.free(date_str);

        const filename = try std.fmt.allocPrint(self.allocator, "crushcode-{s}-{d}.jsonl", .{ date_str, self.rotation_counter });
        defer self.allocator.free(filename);
        self.allocator.free(date_str);

        const filepath = try std.fs.path.join(self.allocator, &.{ self.log_dir, filename });
        defer self.allocator.free(filepath);

        const file = std.fs.cwd().createFile(filepath, .{ .truncate = false }) catch |err| {
            return err;
        };
        self.current_size = 0;
        self.current_file = file;
    }

    fn cleanOldFiles(self: *Self) !void {
        var dir = std.fs.cwd().openDir(self.log_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var filenames = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (filenames.items) |name| self.allocator.free(name);
            filenames.deinit();
        }

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "crushcode-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const name_copy = try self.allocator.dupe(u8, entry.name);
            try filenames.append(name_copy);
        }

        // Sort by name (alphabetical — dates sort correctly)
        const items = filenames.items;
        std.sort.block([]const u8, items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        // Remove oldest files beyond max_files
        if (items.len > self.max_files) {
            const to_remove = items.len - self.max_files;
            var i: usize = 0;
            while (i < to_remove) : (i += 1) {
                dir.deleteFile(items[i]) catch {};
            }
        }
    }

    fn getDateString(self: *Self) ![]const u8 {
        const epoch_seconds = std.time.timestamp();
        // Convert epoch seconds to days since Unix epoch
        const days_since_epoch = @divTrunc(epoch_seconds, 86400);
        // Calculate year, month, day from days since epoch
        var remaining_days: i64 = days_since_epoch;

        // Estimate year
        var year: i64 = 1970;
        while (true) {
            const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }

        // Month lookup
        const month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: usize = 0;
        while (month < 12) {
            var dim: i64 = month_days[month];
            if (month == 1 and isLeapYear(year)) dim = 29;
            if (remaining_days < dim) break;
            remaining_days -= dim;
            month += 1;
        }

        const day: i64 = remaining_days + 1;

        return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month + 1, day });
    }
};

fn isLeapYear(year: i64) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}
