const std = @import("std");
const json = std.json;
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;
const PermissionAction = @import("permission_evaluate").PermissionAction;

/// A single permission audit log entry.
/// Records every permission decision made by the system.
pub const AuditEntry = struct {
    /// Unix epoch milliseconds when the decision was made
    timestamp: i64,
    /// Tool name (e.g., "bash", "file")
    tool_name: []const u8,
    /// Action being performed (e.g., "execute", "write")
    action: []const u8,
    /// Matched rule pattern, if any
    pattern: ?[]const u8 = null,
    /// Final decision (allow/deny/ask)
    decision: PermissionAction,
    /// Whether the permission was automatically approved
    auto_approved: bool,
    /// Session context identifier, if any
    session_id: ?[]const u8 = null,

    /// Serialize this entry to a JSON string.
    /// Caller owns the returned slice.
    pub fn toJson(self: AuditEntry, allocator: Allocator) ![]const u8 {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("ts", .{ .integer = self.timestamp });
        try obj.put("tool", .{ .string = self.tool_name });
        try obj.put("action", .{ .string = self.action });

        if (self.pattern) |pat| {
            try obj.put("pattern", .{ .string = pat });
        }

        try obj.put("decision", .{ .string = @tagName(self.decision) });
        try obj.put("auto", .{ .bool = self.auto_approved });

        if (self.session_id) |sid| {
            try obj.put("session", .{ .string = sid });
        }

        // Serialize to a JSON string for JSONL output
        // Build manually to avoid complex writer API
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.print("{{\"ts\":{d},\"tool\":\"{s}\",\"action\":\"{s}\",", .{ self.timestamp, self.tool_name, self.action });
        if (self.pattern) |pat| {
            try w.print("\"pattern\":\"{s}\",", .{pat});
        }
        try w.print("\"decision\":\"{s}\",\"auto\":{s}", .{ @tagName(self.decision), if (self.auto_approved) "true" else "false" });
        if (self.session_id) |sid| {
            try w.print(",\"session\":\"{s}\"", .{sid});
        }
        try w.writeByte('}');

        return try buf.toOwnedSlice();
    }

    /// Parse an AuditEntry from a JSON line.
    /// All string fields are duplicated into the provided allocator.
    pub fn fromJson(allocator: Allocator, line: []const u8) !AuditEntry {
        const parsed = try json.parseFromSlice(json.Value, allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        const obj = root.object;

        // Required fields
        const ts_val = obj.get("ts") orelse return error.MissingTimestamp;
        const timestamp: i64 = switch (ts_val) {
            .integer => |v| @intCast(v),
            else => return error.InvalidTimestamp,
        };

        const tool_val = obj.get("tool") orelse return error.MissingTool;
        if (tool_val != .string) return error.InvalidTool;
        const tool_name = tool_val.string;

        const action_val = obj.get("action") orelse return error.MissingAction;
        if (action_val != .string) return error.InvalidAction;
        const action = action_val.string;

        const decision_val = obj.get("decision") orelse return error.MissingDecision;
        if (decision_val != .string) return error.InvalidDecision;
        const decision = PermissionAction.fromString(decision_val.string) orelse return error.InvalidDecision;

        const auto_val = obj.get("auto") orelse return error.MissingAuto;
        if (auto_val != .bool) return error.InvalidAuto;
        const auto_approved = auto_val.bool;

        // Optional fields
        var pattern: ?[]const u8 = null;
        if (obj.get("pattern")) |pat_val| {
            if (pat_val == .string) {
                pattern = try allocator.dupe(u8, pat_val.string);
            }
        }

        var session_id: ?[]const u8 = null;
        if (obj.get("session")) |sid_val| {
            if (sid_val == .string) {
                session_id = try allocator.dupe(u8, sid_val.string);
            }
        }

        return AuditEntry{
            .timestamp = timestamp,
            .tool_name = try allocator.dupe(u8, tool_name),
            .action = try allocator.dupe(u8, action),
            .pattern = pattern,
            .decision = decision,
            .auto_approved = auto_approved,
            .session_id = session_id,
        };
    }

    /// Free all owned string allocations.
    pub fn deinit(self: *AuditEntry, allocator: Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.action);
        if (self.pattern) |pat| {
            allocator.free(pat);
        }
        if (self.session_id) |sid| {
            allocator.free(sid);
        }
    }
};

/// Append-only JSONL permission audit logger.
/// Writes one JSON object per line to a file at `config_dir/audit.jsonl`.
pub const PermissionAuditLogger = struct {
    allocator: Allocator,
    /// Full path to the audit.jsonl file
    file_path: []const u8,

    /// Initialize the audit logger.
    /// Creates the parent directory if it does not exist.
    /// `config_dir` should be the crushcode config directory (e.g., ~/.config/crushcode).
    pub fn init(allocator: Allocator, config_dir: []const u8) !PermissionAuditLogger {
        // Ensure the config directory exists
        std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{config_dir});

        return PermissionAuditLogger{
            .allocator = allocator,
            .file_path = file_path,
        };
    }

    /// Free the owned file path allocation.
    pub fn deinit(self: *PermissionAuditLogger) void {
        self.allocator.free(self.file_path);
    }

    /// Append a single audit entry as one JSONL line.
    pub fn log(self: *PermissionAuditLogger, entry: AuditEntry) !void {
        const json_line = try entry.toJson(self.allocator);
        defer self.allocator.free(json_line);

        const file = try std.fs.cwd().openFile(self.file_path, .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(json_line);
        try file.writeAll("\n");
    }

    /// Convenience method to log a permission decision with the current timestamp.
    pub fn logDecision(self: *PermissionAuditLogger, tool: []const u8, action: []const u8, decision: PermissionAction, auto_approved: bool) !void {
        const now_ms: i64 = @intCast(std.time.milliTimestamp());
        const entry = AuditEntry{
            .timestamp = now_ms,
            .tool_name = tool,
            .action = action,
            .decision = decision,
            .auto_approved = auto_approved,
        };
        try self.log(entry);
    }

    /// Read the last N entries from the audit log.
    /// Caller must free the returned slice and each entry via their respective deinit methods.
    pub fn recent(self: *PermissionAuditLogger, limit: usize) ![]AuditEntry {
        const file = std.fs.cwd().openFile(self.file_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                // No audit file yet — return empty slice
                return try self.allocator.alloc(AuditEntry, 0);
            },
            else => return err,
        };
        defer file.close();

        const max_size: usize = 64 * 1024 * 1024; // 64 MB safety limit
        const contents = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(contents);

        // Count lines to allocate the right-sized buffer
        var line_count: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                line_count += 1;
            }
        }

        // Collect all non-empty lines into a temporary list
        var all_lines = std.ArrayList([]const u8).init(self.allocator);
        defer all_lines.deinit();

        lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try all_lines.append(line);
            }
        }

        // Determine start index for the last N entries
        const start = if (all_lines.items.len > limit) all_lines.items.len - limit else 0;
        const count = all_lines.items.len - start;

        const entries = try self.allocator.alloc(AuditEntry, count);
        var parsed: usize = 0;
        errdefer {
            // Free any entries we already parsed before the error
            for (entries[0..parsed]) |*e| {
                e.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        for (all_lines.items[start..]) |line| {
            entries[parsed] = try AuditEntry.fromJson(self.allocator, line);
            parsed += 1;
        }

        return entries;
    }

    /// Return the full path to the audit file.
    pub fn getFilePath(self: *const PermissionAuditLogger) []const u8 {
        return self.file_path;
    }
};
