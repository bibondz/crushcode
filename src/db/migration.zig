/// JSON → SQLite session migration.
///
/// On first run with the SQLite backend, scans the existing JSON session
/// directory and imports all sessions into the database. Each session file
/// is read, parsed, and inserted via session_db.saveSession.
///
/// After successful import, JSON files are NOT deleted — user can keep them
/// as backup. A `.migrated` marker file is created to prevent re-import.
const std = @import("std");
const sqlite = @import("sqlite");
const session_db = @import("session_db");

const Allocator = std.mem.Allocator;

pub const MigrationResult = struct {
    total_found: u32,
    imported: u32,
    skipped: u32,
    failed: u32,
    already_migrated: bool,
};

/// Check if migration has already been done by looking for the marker file.
pub fn isMigrated(session_dir: []const u8) bool {
    const marker_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/.migrated", .{session_dir}) catch return false;
    defer std.heap.page_allocator.free(marker_path);
    const file = std.fs.cwd().openFile(marker_path, .{}) catch return false;
    file.close();
    return true;
}

/// Write the migration marker file.
fn writeMarker(session_dir: []const u8) !void {
    const marker_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.migrated", .{session_dir});
    defer std.heap.page_allocator.free(marker_path);
    const file = try std.fs.cwd().createFile(marker_path, .{});
    file.close();
}

/// Run the migration from JSON files to SQLite.
/// Returns a summary of what happened.
pub fn migrateFromJson(allocator: Allocator, session_dir: []const u8, db: *session_db.SessionDB) !MigrationResult {
    if (isMigrated(session_dir)) {
        return MigrationResult{
            .total_found = 0,
            .imported = 0,
            .skipped = 0,
            .failed = 0,
            .already_migrated = true,
        };
    }

    var result = MigrationResult{
        .total_found = 0,
        .imported = 0,
        .skipped = 0,
        .failed = 0,
        .already_migrated = false,
    };

    // Open the session directory
    var dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Only process .json files
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        result.total_found += 1;

        // Read and parse the JSON file
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ session_dir, entry.path }) catch continue;
        defer allocator.free(full_path);

        const content = std.fs.cwd().readFileAlloc(allocator, full_path, 16 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        // Parse as JSON session — use std.json directly
        var parsed = std.json.parseFromSlice(JsonSession, allocator, content, .{ .ignore_unknown_fields = true }) catch {
            result.failed += 1;
            continue;
        };
        defer parsed.deinit();

        const s = &parsed.value;

        // Convert to SessionRow
        const session_row = session_db.SessionRow{
            .id = s.id orelse continue,
            .title = s.title orelse "",
            .model = s.model orelse "",
            .provider = s.provider orelse "",
            .total_tokens = s.total_tokens orelse 0,
            .total_cost = s.total_cost orelse 0.0,
            .turn_count = s.turn_count orelse 0,
            .duration_seconds = s.duration_seconds orelse 0,
            .created_at = s.created_at orelse 0,
            .updated_at = s.updated_at orelse 0,
        };

        // Convert messages
        const json_msgs = s.messages orelse &[_]JsonMessage{};
        var msgs = try allocator.alloc(session_db.MessageRow, json_msgs.len);
        defer allocator.free(msgs); // session_db.saveSession copies strings

        for (json_msgs, 0..) |jm, i| {
            msgs[i] = .{
                .role = jm.role orelse "unknown",
                .content = jm.content,
                .tool_call_id = jm.tool_call_id,
                .tool_calls_json = null, // Not preserved in migration
            };
        }

        // Save to SQLite
        db.saveSession(&session_row, msgs) catch {
            result.failed += 1;
            continue;
        };
        result.imported += 1;
    }

    // Write marker file if any were imported or none were found
    if (result.imported > 0 or result.total_found == 0) {
        writeMarker(session_dir) catch {};
    }

    return result;
}

/// JSON-parseable session struct (all fields optional for robustness)
const JsonSession = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    total_tokens: ?u64 = null,
    total_cost: ?f64 = null,
    turn_count: ?u32 = null,
    duration_seconds: ?u32 = null,
    created_at: ?i64 = null,
    updated_at: ?i64 = null,
    messages: ?[]const JsonMessage = null,
};

const JsonMessage = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};
