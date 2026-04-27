const file_compat = @import("file_compat");
const std = @import("std");
const core = @import("core_api");
const sqlite_mod = @import("sqlite");
const session_db_mod = @import("session_db");
const migration_mod = @import("db_migration");

/// Global SQLite session database. Initialized lazily on first use.
var g_session_db: ?session_db_mod.SessionDB = null;

/// Get or initialize the SQLite session database.
pub fn getSessionDb(allocator: std.mem.Allocator) !*session_db_mod.SessionDB {
    if (g_session_db != null) return &g_session_db.?;

    const session_dir = try defaultSessionDir(allocator);
    defer allocator.free(session_dir);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/sessions.db", .{session_dir});
    defer allocator.free(db_path);

    // Create null-terminated path
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db = try session_db_mod.SessionDB.init(allocator, db_path_z);

    // Run JSON → SQLite migration if needed
    const result = migration_mod.migrateFromJson(allocator, session_dir, &db) catch
        migration_mod.MigrationResult{ .total_found = 0, .imported = 0, .skipped = 0, .failed = 0, .already_migrated = true };
    _ = result;

    g_session_db = db;
    return &g_session_db.?;
}

/// Close the global database connection (call on shutdown).
pub fn closeSessionDb() void {
    if (g_session_db) |*db| {
        db.deinit();
        g_session_db = null;
    }
}

pub const Message = core.ChatMessage;

pub const Session = struct {
    id: []const u8,
    created_at: i64,
    updated_at: i64,
    title: []const u8,
    messages: []Message,
    model: []const u8,
    provider: []const u8,
    total_tokens: u64,
    total_cost: f64,
    turn_count: u32,
    duration_seconds: u32,
};

pub fn defaultSessionDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = file_compat.getEnv("HOME") orelse "/root";
    return std.fmt.allocPrint(allocator, "{s}/.crushcode/sessions", .{home});
}

pub fn saveSession(allocator: std.mem.Allocator, session_dir: []const u8, session: *const Session) !void {
    try std.fs.cwd().makePath(session_dir);

    const db = getSessionDb(allocator) catch {
        return saveSessionJson(allocator, session_dir, session);
    };

    const row = session_db_mod.SessionRow{
        .id = session.id,
        .title = session.title,
        .model = session.model,
        .provider = session.provider,
        .total_tokens = session.total_tokens,
        .total_cost = session.total_cost,
        .turn_count = session.turn_count,
        .duration_seconds = session.duration_seconds,
        .created_at = session.created_at,
        .updated_at = session.updated_at,
    };

    var msgs = try allocator.alloc(session_db_mod.MessageRow, session.messages.len);
    defer allocator.free(msgs);
    for (session.messages, 0..) |msg, i| {
        msgs[i] = .{
            .role = msg.role,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls_json = null,
        };
    }

    db.saveSession(&row, msgs) catch {
        return saveSessionJson(allocator, session_dir, session);
    };
}

fn saveSessionJson(allocator: std.mem.Allocator, session_dir: []const u8, session: *const Session) !void {
    var normalized = try normalizedSession(allocator, session);
    defer deinitSession(allocator, &normalized);

    const path = try sessionFilePath(allocator, session_dir, normalized.id);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    try std.json.Stringify.value(normalized, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

pub fn loadSession(allocator: std.mem.Allocator, path: []const u8) !Session {
    // Try SQLite first — extract session_id from path
    if (getSessionDb(allocator)) |db| {
        // Extract session ID from filename (e.g., "/path/session-123-abc.json" → "session-123-abc")
        const basename = std.fs.path.basename(path);
        const id = if (std.mem.endsWith(u8, basename, ".json"))
            basename[0..basename.len - 5]
        else
            basename;

        if (try db.loadSession(allocator, id)) |loaded| {
            var data = loaded;
            defer data.deinit(allocator);

            var messages = try allocator.alloc(Message, data.messages.len);
            errdefer {
                for (messages) |*m| {
                    allocator.free(m.role);
                    if (m.content) |c| allocator.free(c);
                    if (m.tool_call_id) |tc| allocator.free(tc);
                }
                allocator.free(messages);
            }
            for (data.messages, 0..) |mr, i| {
                messages[i] = .{
                    .role = try allocator.dupe(u8, mr.role),
                    .content = if (mr.content) |c| try allocator.dupe(u8, c) else null,
                    .tool_call_id = if (mr.tool_call_id) |tc| try allocator.dupe(u8, tc) else null,
                    .tool_calls = null,
                };
            }
            return .{
                .id = try allocator.dupe(u8, data.session.id),
                .created_at = data.session.created_at,
                .updated_at = data.session.updated_at,
                .title = try allocator.dupe(u8, data.session.title),
                .messages = messages,
                .model = try allocator.dupe(u8, data.session.model),
                .provider = try allocator.dupe(u8, data.session.provider),
                .total_tokens = data.session.total_tokens,
                .total_cost = data.session.total_cost,
                .turn_count = data.session.turn_count,
                .duration_seconds = data.session.duration_seconds,
            };
        }
    } else |_| {}

    // Fallback to JSON
    return loadSessionJson(allocator, path);
}

fn loadSessionJson(allocator: std.mem.Allocator, path: []const u8) !Session {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(Session, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return cloneSession(allocator, &parsed.value);
}

pub fn listSessions(allocator: std.mem.Allocator, session_dir: []const u8) ![]Session {
    const db = getSessionDb(allocator) catch {
        return listSessionsJson(allocator, session_dir);
    };
    const rows = db.listSessions(allocator) catch {
        return listSessionsJson(allocator, session_dir);
    };
    defer session_db_mod.freeSessionRows(allocator, rows);

    var sessions = try allocator.alloc(Session, rows.len);
    var init_count: usize = 0;
    errdefer {
        for (sessions[0..init_count]) |*s| deinitSession(allocator, s);
        allocator.free(sessions);
    }

    for (rows, 0..) |row, i| {
        sessions[i] = .{
            .id = try allocator.dupe(u8, row.id),
            .created_at = row.created_at,
            .updated_at = row.updated_at,
            .title = try allocator.dupe(u8, row.title),
            .messages = try allocator.alloc(Message, 0),
            .model = try allocator.dupe(u8, row.model),
            .provider = try allocator.dupe(u8, row.provider),
            .total_tokens = row.total_tokens,
            .total_cost = row.total_cost,
            .turn_count = row.turn_count,
            .duration_seconds = row.duration_seconds,
        };
        init_count = i + 1;
    }

    return sessions;
}

fn listSessionsJson(allocator: std.mem.Allocator, session_dir: []const u8) ![]Session {
    var dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Session, 0),
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var sessions = std.ArrayList(Session).empty;
    errdefer {
        for (sessions.items) |*session| deinitSession(allocator, session);
        sessions.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.path });
        defer allocator.free(full_path);

        const session = loadSessionJson(allocator, full_path) catch continue;
        try sessions.append(allocator, session);
    }

    sortSessionsByUpdatedAtDesc(sessions.items);
    return sessions.toOwnedSlice(allocator);
}

pub fn deleteSession(allocator: std.mem.Allocator, path: []const u8) !void {
    if (getSessionDb(allocator)) |db| {
        const basename = std.fs.path.basename(path);
        const id = if (std.mem.endsWith(u8, basename, ".json"))
            basename[0..basename.len - 5]
        else
            basename;
        db.deleteSession(id) catch {};
    } else |_| {}
    std.fs.cwd().deleteFile(path) catch {};
}

pub fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [3]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var suffix: [6]u8 = undefined;
    for (random_bytes, 0..) |byte, i| {
        const hex_pair = std.fmt.bytesToHex(&[_]u8{byte}, .lower);
        suffix[i * 2] = hex_pair[0];
        suffix[i * 2 + 1] = hex_pair[1];
    }

    return std.fmt.allocPrint(allocator, "session-{d}-{s}", .{ std.time.timestamp(), suffix[0..] });
}

pub fn sessionFilePath(allocator: std.mem.Allocator, session_dir: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, session_id });
}

pub fn cloneSession(allocator: std.mem.Allocator, session: *const Session) !Session {
    const messages = try cloneMessages(allocator, session.messages);
    errdefer freeMessages(allocator, messages);

    return .{
        .id = try allocator.dupe(u8, session.id),
        .created_at = session.created_at,
        .updated_at = session.updated_at,
        .title = try allocator.dupe(u8, session.title),
        .messages = messages,
        .model = try allocator.dupe(u8, session.model),
        .provider = try allocator.dupe(u8, session.provider),
        .total_tokens = session.total_tokens,
        .total_cost = session.total_cost,
        .turn_count = session.turn_count,
        .duration_seconds = session.duration_seconds,
    };
}

pub fn deinitSession(allocator: std.mem.Allocator, session: *Session) void {
    allocator.free(session.id);
    allocator.free(session.title);
    freeMessages(allocator, session.messages);
    allocator.free(session.model);
    allocator.free(session.provider);
    session.* = undefined;
}

pub fn isInterrupted(session: *const Session) bool {
    if (session.messages.len == 0) return false;
    const last = session.messages[session.messages.len - 1];
    const content = last.content orelse "";
    const trimmed = std.mem.trim(u8, content, " \t\r\n");

    if (std.mem.eql(u8, last.role, "user")) return true;
    if (std.mem.eql(u8, last.role, "assistant") and (trimmed.len == 0 or std.mem.eql(u8, trimmed, "Thinking..."))) {
        return true;
    }
    return false;
}

fn normalizedSession(allocator: std.mem.Allocator, session: *const Session) !Session {
    var cloned = try cloneSession(allocator, session);
    errdefer deinitSession(allocator, &cloned);

    allocator.free(cloned.title);
    cloned.title = try deriveTitle(allocator, cloned.messages);
    return cloned;
}

fn deriveTitle(allocator: std.mem.Allocator, messages: []const Message) ![]const u8 {
    for (messages) |message| {
        if (!std.mem.eql(u8, message.role, "user")) continue;
        const content = message.content orelse "";
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) continue;

        const normalized = try collapseWhitespace(allocator, trimmed);
        defer allocator.free(normalized);
        if (normalized.len <= 50) return allocator.dupe(u8, normalized);
        return std.fmt.allocPrint(allocator, "{s}...", .{normalized[0..50]});
    }
    return allocator.dupe(u8, "New session");
}

fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var previous_space = false;
    for (text) |char| {
        const is_space = std.ascii.isWhitespace(char);
        if (is_space) {
            if (output.items.len == 0 or previous_space) continue;
            try output.append(allocator, ' ');
        } else {
            try output.append(allocator, char);
        }
        previous_space = is_space;
    }

    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }
    return output.toOwnedSlice(allocator);
}

fn cloneMessages(allocator: std.mem.Allocator, messages: []const Message) ![]Message {
    const cloned = try allocator.alloc(Message, messages.len);
    errdefer allocator.free(cloned);

    for (messages, 0..) |message, index| {
        cloned[index] = .{
            .role = try allocator.dupe(u8, message.role),
            .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
            .tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null,
            .tool_calls = try cloneToolCallInfos(allocator, message.tool_calls),
        };
    }
    return cloned;
}

fn freeMessages(allocator: std.mem.Allocator, messages: []Message) void {
    for (messages) |message| {
        allocator.free(message.role);
        if (message.content) |content| allocator.free(content);
        if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        freeToolCallInfos(allocator, message.tool_calls);
    }
    allocator.free(messages);
}

fn cloneToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) !?[]const core.client.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(core.client.ToolCallInfo, source.len);
    errdefer allocator.free(copied);

    for (source, 0..) |tool_call, index| {
        copied[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn freeToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn sortSessionsByUpdatedAtDesc(sessions: []Session) void {
    if (sessions.len < 2) return;
    var i: usize = 1;
    while (i < sessions.len) : (i += 1) {
        var j = i;
        while (j > 0 and sessions[j].updated_at > sessions[j - 1].updated_at) : (j -= 1) {
            const tmp = sessions[j - 1];
            sessions[j - 1] = sessions[j];
            sessions[j] = tmp;
        }
    }
}
