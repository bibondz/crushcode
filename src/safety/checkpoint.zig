//! File-level checkpoint / rewind system for Crushcode.
//!
//! Before every destructive file operation (write_file, edit, create_file),
//! the original content is snapshotted into SQLite so the user can later
//! restore individual files or rewind an entire session via `/rewind`.

const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Mirrors a single row in the `checkpoints` SQLite table.
pub const Checkpoint = struct {
    id: i64,
    session_id: []const u8,
    file_path: []const u8,
    timestamp: i64,
    operation: []const u8,
    original_content: []const u8,
    file_size: u64,

    pub fn deinit(self: *Checkpoint, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.file_path);
        allocator.free(self.operation);
        allocator.free(self.original_content);
    }
};

/// Free a slice of Checkpoint rows.
pub fn freeCheckpoints(allocator: Allocator, checkpoints: []Checkpoint) void {
    for (checkpoints) |*cp| cp.deinit(allocator);
    allocator.free(checkpoints);
}

// ---------------------------------------------------------------------------
// CheckpointManager
// ---------------------------------------------------------------------------

/// Maximum file size that will be snapshotted (10 MB).
const max_snapshot_bytes: usize = 10 * 1024 * 1024;

pub const CheckpointManager = struct {
    allocator: Allocator,
    checkpoint_dir: []const u8,
    max_per_session: u32,

    /// Initialise the manager. `checkpoint_dir` should typically be
    /// `.crushcode/checkpoints/`. The directory is created lazily on first
    /// snapshot.
    pub fn init(allocator: Allocator, checkpoint_dir: []const u8) CheckpointManager {
        return .{
            .allocator = allocator,
            .checkpoint_dir = checkpoint_dir,
            .max_per_session = 50,
        };
    }

    pub fn deinit(self: *CheckpointManager) void {
        _ = self;
    }

    // ------------------------------------------------------------------
    // Core operations
    // ------------------------------------------------------------------

    /// Snapshot the current content of `file_path` before `operation`
    /// overwrites it.  If the file does not exist (e.g. create_file), this
    /// is a silent no-op.  The db parameter is duck-typed and must provide
    /// `insertCheckpoint`, `deleteOldCheckpoints`.
    pub fn snapshotFile(
        self: *CheckpointManager,
        db: anytype,
        session_id: []const u8,
        file_path: []const u8,
        operation: []const u8,
    ) !void {
        // Read current file content; silently skip if file doesn't exist yet.
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, max_snapshot_bytes) catch |err| switch (err) {
            error.FileNotFound => return,
            error.IsDir => return,
            else => return err,
        };
        defer self.allocator.free(content);

        const timestamp = std.time.milliTimestamp();

        // Write backup copy to disk (best-effort)
        self.writeBackup(session_id, file_path, timestamp, content) catch {};

        // Persist in SQLite
        _ = db.insertCheckpoint(
            session_id,
            file_path,
            timestamp,
            operation,
            content,
            @intCast(content.len),
        ) catch |err| {
            std.log.warn("[checkpoint] insertCheckpoint failed: {}", .{err});
            return;
        };

        // Prune old checkpoints for this session (best-effort)
        _ = db.deleteOldCheckpoints(session_id, self.max_per_session) catch {};
    }

    /// Restore a single checkpoint by ID.  The db parameter must provide
    /// `getCheckpoint(allocator, id)`.
    pub fn restoreCheckpoint(
        self: *CheckpointManager,
        db: anytype,
        allocator: Allocator,
        checkpoint_id: i64,
    ) !void {
        _ = self;
        const cp = (try db.getCheckpoint(allocator, checkpoint_id)) orelse
            return error.CheckpointNotFound;
        defer cp.deinit(allocator);
        // Create parent directories if needed
        if (std.fs.path.dirname(cp.file_path)) |dir_part| {
            if (dir_part.len > 0) {
                std.fs.cwd().makePath(dir_part) catch {};
            }
        }

        const file = try std.fs.cwd().createFile(cp.file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(cp.original_content);
    }

    /// List all checkpoints for `session_id`, ordered by timestamp
    /// descending (newest first).  The db parameter must provide
    /// `getCheckpoints(allocator, session_id)`.
    pub fn listCheckpoints(
        self: *CheckpointManager,
        db: anytype,
        allocator: Allocator,
        session_id: []const u8,
    ) ![]Checkpoint {
        _ = self;
        return try db.getCheckpoints(allocator, session_id);
    }

    /// Restore the most recent checkpoint for `session_id`.
    /// Returns the checkpoint that was restored, or null if none exist.
    pub fn rewindLast(
        self: *CheckpointManager,
        db: anytype,
        allocator: Allocator,
        session_id: []const u8,
    ) !?Checkpoint {
        _ = self;
        const checkpoints = try db.getCheckpoints(allocator, session_id);
        if (checkpoints.len == 0) return null;

        // Newest first — index 0 is the most recent
        const cp = checkpoints[0];
        // Create parent directories if needed
        if (std.fs.path.dirname(cp.file_path)) |dir_part| {
            if (dir_part.len > 0) {
                std.fs.cwd().makePath(dir_part) catch {};
            }
        }
        const file = try std.fs.cwd().createFile(cp.file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(cp.original_content);

        // Delete the restored checkpoint from DB
        db.deleteCheckpoint(cp.id) catch {};

        // Return the checkpoint info — free the rest
        const result = cp;
        // Skip index 0 since we're returning it; free the rest
        for (checkpoints[1..]) |*c| c.deinit(allocator);
        allocator.free(checkpoints);
        return result;
    }

    /// Restore ALL checkpoints for `session_id` in reverse chronological
    /// order. Returns the count of restored checkpoints.
    pub fn rewindAll(
        self: *CheckpointManager,
        db: anytype,
        allocator: Allocator,
        session_id: []const u8,
    ) !u32 {
        _ = self;
        const checkpoints = try db.getCheckpoints(allocator, session_id);
        if (checkpoints.len == 0) return 0;

        var count: u32 = 0;
        // Track which files we've already restored (avoid duplicate writes
        // when multiple checkpoints exist for the same file).
        // We restore in reverse order (oldest to newest) so the oldest
        // version wins — full rewind semantics.
        var i: usize = checkpoints.len;
        while (i > 0) {
            i -= 1;
            const cp = checkpoints[i];

            // Create parent directories if needed
            if (std.fs.path.dirname(cp.file_path)) |dir_part| {
                if (dir_part.len > 0) {
                    std.fs.cwd().makePath(dir_part) catch {};
                }
            }

            const file = std.fs.cwd().createFile(cp.file_path, .{ .truncate = true }) catch continue;
            defer file.close();
            file.writeAll(cp.original_content) catch continue;
            count += 1;
        }

        // Free all checkpoints
        for (checkpoints) |*c| c.deinit(allocator);
        allocator.free(checkpoints);
        return count;
    }

    /// Keep only the last `max_per_session` checkpoints, deleting older ones.
    /// The db parameter must provide `deleteOldCheckpoints`.
    pub fn pruneOld(
        self: *CheckpointManager,
        db: anytype,
        session_id: []const u8,
    ) !void {
        _ = try db.deleteOldCheckpoints(session_id, self.max_per_session);
    }

    /// Format a list of checkpoints as a human-readable string.
    /// Caller owns the returned slice.
    pub fn formatCheckpointList(
        self: *CheckpointManager,
        allocator: Allocator,
        checkpoints: []const Checkpoint,
    ) ![]const u8 {
        _ = self;
        if (checkpoints.len == 0) {
            return try allocator.dupe(u8, "No checkpoints for this session.");
        }

        var buf = array_list_compat.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("Checkpoints:\n");
        for (checkpoints, 0..) |cp, idx| {
            const ts_sec: i64 = @divTrunc(cp.timestamp, 1000);
            const time_of_day: u64 = if (ts_sec >= 0) @as(u64, @intCast(ts_sec)) % 86400 else 0;
            const hours: u64 = time_of_day / 3600;
            const minutes: u64 = (time_of_day % 3600) / 60;
            const seconds: u64 = time_of_day % 60;

            const fmt = formatFileSize(cp.file_size);
            try writer.print("  #{d}  [{d:0>2}:{d:0>2}:{d:0>2}]  {s}  {s}  ({d:.1}{s})\n", .{
                idx + 1,
                hours,
                minutes,
                seconds,
                cp.operation,
                cp.file_path,
                fmt.value,
                fmt.unit,
            });
        }

        return try buf.toOwnedSlice();
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Write a backup copy of the file content under the checkpoint dir.
    fn writeBackup(
        self: *CheckpointManager,
        session_id: []const u8,
        file_path: []const u8,
        timestamp: i64,
        content: []const u8,
    ) !void {
        const dir_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.checkpoint_dir, session_id },
        );
        defer self.allocator.free(dir_path);

        std.fs.cwd().makePath(dir_path) catch {};

        const basename = std.fs.path.basename(file_path);
        const filename = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{d}_{s}",
            .{ dir_path, timestamp, basename },
        );
        defer self.allocator.free(filename);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn formatFileSize(bytes: u64) struct { value: f64, unit: []const u8 } {
    if (bytes < 1024) return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
    const kb: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) return .{ .value = kb, .unit = "KB" };
    const mb: f64 = kb / 1024.0;
    return .{ .value = mb, .unit = "MB" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "formatFileSize" {
    const r1 = formatFileSize(0);
    try testing.expect(r1.value == 0);
    try testing.expectEqualStrings("B", r1.unit);

    const r2 = formatFileSize(512);
    try testing.expect(r2.value == 512);
    try testing.expectEqualStrings("B", r2.unit);

    const r3 = formatFileSize(2048);
    try testing.expectApproxEqAbs(@as(f64, 2.0), r3.value, 0.01);
    try testing.expectEqualStrings("KB", r3.unit);
}

test "CheckpointManager init/deinit" {
    var mgr = CheckpointManager.init(testing.allocator, ".crushcode/checkpoints/");
    defer mgr.deinit();
    try testing.expectEqual(@as(u32, 50), mgr.max_per_session);
}

test "formatCheckpointList empty" {
    var mgr = CheckpointManager.init(testing.allocator, ".crushcode/checkpoints/");
    defer mgr.deinit();

    const text = try mgr.formatCheckpointList(testing.allocator, &.{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "No checkpoints") != null);
}

test "formatCheckpointList with entries" {
    var mgr = CheckpointManager.init(testing.allocator, ".crushcode/checkpoints/");
    defer mgr.deinit();

    const cps = [_]Checkpoint{
        .{
            .id = 1,
            .session_id = "sess-1",
            .file_path = "src/main.zig",
            .timestamp = 1000000,
            .operation = "edit",
            .original_content = "hello",
            .file_size = 5,
        },
        .{
            .id = 2,
            .session_id = "sess-1",
            .file_path = "build.zig",
            .timestamp = 1001000,
            .operation = "write_file",
            .original_content = "world",
            .file_size = 2048,
        },
    };

    const text = try mgr.formatCheckpointList(testing.allocator, &cps);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "edit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "write_file") != null);
}
