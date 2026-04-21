//! Session database CRUD layer backed by SQLite.
//!
//! Provides all session/message operations, replacing the flat JSON file storage.
//! Each session is stored as a row in the `session` table with its messages
//! as rows in the `message` table (ordered by position).

const std = @import("std");
const sqlite = @import("sqlite");
const checkpoint_types = @import("safety_checkpoint");
const Allocator = std.mem.Allocator;

// Re-export Checkpoint type so callers can access it through session_db
pub const Checkpoint = checkpoint_types.Checkpoint;
pub const freeCheckpoints = checkpoint_types.freeCheckpoints;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

/// DDL for the session and message tables plus indexes.
/// Uses `++` concatenation to produce a single null-terminated `[:0]const u8`
/// that can be passed directly to `sqlite.Db.exec`.
pub const SCHEMA: [:0]const u8 =
    "CREATE TABLE IF NOT EXISTS session (" ++
    "id TEXT PRIMARY KEY, " ++
    "title TEXT NOT NULL DEFAULT '', " ++
    "model TEXT NOT NULL DEFAULT '', " ++
    "provider TEXT NOT NULL DEFAULT '', " ++
    "total_tokens INTEGER NOT NULL DEFAULT 0, " ++
    "total_cost REAL NOT NULL DEFAULT 0.0, " ++
    "turn_count INTEGER NOT NULL DEFAULT 0, " ++
    "duration_seconds INTEGER NOT NULL DEFAULT 0, " ++
    "created_at INTEGER NOT NULL, " ++
    "updated_at INTEGER NOT NULL" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS message (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE, " ++
    "position INTEGER NOT NULL, " ++
    "role TEXT NOT NULL, " ++
    "content TEXT, " ++
    "tool_call_id TEXT, " ++
    "tool_calls TEXT, " ++
    "created_at INTEGER NOT NULL" ++
    ");" ++
    "CREATE INDEX IF NOT EXISTS idx_message_session ON message(session_id, position);" ++
    "CREATE INDEX IF NOT EXISTS idx_session_updated ON session(updated_at DESC);" ++
    "CREATE TABLE IF NOT EXISTS checkpoints (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "session_id TEXT NOT NULL, " ++
    "file_path TEXT NOT NULL, " ++
    "timestamp INTEGER NOT NULL, " ++
    "operation TEXT NOT NULL, " ++
    "original_content TEXT NOT NULL, " ++
    "file_size INTEGER NOT NULL" ++
    ");" ++
    "CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON checkpoints(session_id, timestamp);";

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Mirrors the session row stored in SQLite.
pub const SessionRow = struct {
    id: []const u8,
    title: []const u8,
    model: []const u8,
    provider: []const u8,
    total_tokens: u64,
    total_cost: f64,
    turn_count: u32,
    duration_seconds: u32,
    created_at: i64,
    updated_at: i64,
};

/// Mirrors a single message row. `content`, `tool_call_id`, and
/// `tool_calls_json` are NULL-able columns.
pub const MessageRow = struct {
    role: []const u8,
    content: ?[]const u8,
    tool_call_id: ?[]const u8,
    tool_calls_json: ?[]const u8,
};

/// A loaded session together with all of its messages.
pub const SessionData = struct {
    session: SessionRow,
    messages: []const MessageRow,

    pub fn deinit(self: *SessionData, allocator: Allocator) void {
        allocator.free(self.session.id);
        allocator.free(self.session.title);
        allocator.free(self.session.model);
        allocator.free(self.session.provider);
        for (self.messages) |msg| {
            allocator.free(msg.role);
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tc| allocator.free(tc);
            if (msg.tool_calls_json) |tc| allocator.free(tc);
        }
        allocator.free(self.messages);
    }
};

// ---------------------------------------------------------------------------
// SessionDB
// ---------------------------------------------------------------------------

pub const SessionDB = struct {
    db: sqlite.Db,
    allocator: Allocator,

    /// Open (or create) the session database at the given path.
    /// Automatically runs schema migration via `CREATE TABLE IF NOT EXISTS`.
    pub fn init(allocator: Allocator, db_path: [:0]const u8) !SessionDB {
        var db = try sqlite.Db.open(db_path);
        errdefer db.close();
        try db.exec(SCHEMA);
        return SessionDB{ .db = db, .allocator = allocator };
    }

    pub fn deinit(self: *SessionDB) void {
        self.db.close();
    }

    // -----------------------------------------------------------------------
    // CRUD operations
    // -----------------------------------------------------------------------

    /// Insert or replace a session (upsert) together with its messages.
    /// Old messages for the session are deleted and re-inserted atomically.
    pub fn saveSession(self: *SessionDB, session: *const SessionRow, messages: []const MessageRow) !void {
        // Upsert session row
        var s_stmt = try sqlite.Stmt.prepare(&self.db,
            \\INSERT OR REPLACE INTO session (id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        );
        defer s_stmt.deinit();

        try s_stmt.bindText(1, session.id);
        try s_stmt.bindText(2, session.title);
        try s_stmt.bindText(3, session.model);
        try s_stmt.bindText(4, session.provider);
        try s_stmt.bindInt(5, @intCast(session.total_tokens));
        try s_stmt.bindDouble(6, session.total_cost);
        try s_stmt.bindInt(7, @intCast(session.turn_count));
        try s_stmt.bindInt(8, @intCast(session.duration_seconds));
        try s_stmt.bindInt(9, session.created_at);
        try s_stmt.bindInt(10, session.updated_at);
        _ = try s_stmt.step();

        // Delete old messages
        var del_stmt = try sqlite.Stmt.prepare(&self.db, "DELETE FROM message WHERE session_id = ?1");
        defer del_stmt.deinit();
        try del_stmt.bindText(1, session.id);
        _ = try del_stmt.step();

        // Re-insert messages
        for (messages, 0..) |msg, i| {
            var ins = try sqlite.Stmt.prepare(&self.db,
                \\INSERT INTO message (session_id, position, role, content, tool_call_id, tool_calls, created_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            );
            defer ins.deinit();
            try ins.bindText(1, session.id);
            try ins.bindInt(2, @intCast(i));
            try ins.bindText(3, msg.role);
            if (msg.content) |c| try ins.bindText(4, c) else try ins.bindNull(4);
            if (msg.tool_call_id) |tc| try ins.bindText(5, tc) else try ins.bindNull(5);
            if (msg.tool_calls_json) |tc| try ins.bindText(6, tc) else try ins.bindNull(6);
            try ins.bindInt(7, session.updated_at);
            _ = try ins.step();
        }
    }

    /// Load a session and all its messages by session ID.
    /// Returns `null` if the session does not exist.
    /// Caller owns the returned `SessionData` and must call `deinit`.
    pub fn loadSession(self: *SessionDB, allocator: Allocator, session_id: []const u8) !?SessionData {
        // Load session row
        var s_stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at
            \\FROM session WHERE id = ?1
        );
        defer s_stmt.deinit();
        try s_stmt.bindText(1, session_id);

        if (try s_stmt.step() != .row) return null;

        const session = SessionRow{
            .id = try allocator.dupe(u8, s_stmt.columnText(0)),
            .title = try allocator.dupe(u8, s_stmt.columnText(1)),
            .model = try allocator.dupe(u8, s_stmt.columnText(2)),
            .provider = try allocator.dupe(u8, s_stmt.columnText(3)),
            .total_tokens = @intCast(s_stmt.columnInt(4)),
            .total_cost = s_stmt.columnDouble(5),
            .turn_count = @intCast(s_stmt.columnInt(6)),
            .duration_seconds = @intCast(s_stmt.columnInt(7)),
            .created_at = s_stmt.columnInt(8),
            .updated_at = s_stmt.columnInt(9),
        };
        errdefer {
            allocator.free(session.id);
            allocator.free(session.title);
            allocator.free(session.model);
            allocator.free(session.provider);
        }

        // Load messages ordered by position
        var msg_list = std.ArrayList(MessageRow).empty;
        errdefer {
            for (msg_list.items) |msg| {
                allocator.free(msg.role);
                if (msg.content) |c| allocator.free(c);
                if (msg.tool_call_id) |tc| allocator.free(tc);
                if (msg.tool_calls_json) |tc| allocator.free(tc);
            }
            msg_list.deinit(allocator);
        }

        var m_stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT role, content, tool_call_id, tool_calls FROM message
            \\WHERE session_id = ?1 ORDER BY position ASC
        );
        defer m_stmt.deinit();
        try m_stmt.bindText(1, session_id);

        while (try m_stmt.step() == .row) {
            try msg_list.append(allocator, .{
                .role = try allocator.dupe(u8, m_stmt.columnText(0)),
                .content = if (!m_stmt.columnIsNull(1)) try allocator.dupe(u8, m_stmt.columnText(1)) else null,
                .tool_call_id = if (!m_stmt.columnIsNull(2)) try allocator.dupe(u8, m_stmt.columnText(2)) else null,
                .tool_calls_json = if (!m_stmt.columnIsNull(3)) try allocator.dupe(u8, m_stmt.columnText(3)) else null,
            });
        }

        return SessionData{
            .session = session,
            .messages = try msg_list.toOwnedSlice(allocator),
        };
    }

    /// List all sessions sorted by updated_at descending.
    /// Caller owns the returned slice and must free each session's string fields.
    pub fn listSessions(self: *SessionDB, allocator: Allocator) ![]SessionRow {
        // Count first
        var count_stmt = try sqlite.Stmt.prepare(&self.db, "SELECT COUNT(*) FROM session");
        defer count_stmt.deinit();
        _ = try count_stmt.step();
        const count: usize = @intCast(count_stmt.columnInt(0));

        if (count == 0) return try allocator.alloc(SessionRow, 0);

        const sessions = try allocator.alloc(SessionRow, count);
        errdefer {
            for (sessions) |*s| {
                allocator.free(s.id);
                allocator.free(s.title);
                allocator.free(s.model);
                allocator.free(s.provider);
            }
            allocator.free(sessions);
        }

        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at
            \\FROM session ORDER BY updated_at DESC
        );
        defer stmt.deinit();

        var idx: usize = 0;
        while (try stmt.step() == .row and idx < count) : (idx += 1) {
            sessions[idx] = .{
                .id = try allocator.dupe(u8, stmt.columnText(0)),
                .title = try allocator.dupe(u8, stmt.columnText(1)),
                .model = try allocator.dupe(u8, stmt.columnText(2)),
                .provider = try allocator.dupe(u8, stmt.columnText(3)),
                .total_tokens = @intCast(stmt.columnInt(4)),
                .total_cost = stmt.columnDouble(5),
                .turn_count = @intCast(stmt.columnInt(6)),
                .duration_seconds = @intCast(stmt.columnInt(7)),
                .created_at = stmt.columnInt(8),
                .updated_at = stmt.columnInt(9),
            };
        }
        return sessions;
    }

    /// Delete a session and its messages (CASCADE handles messages).
    pub fn deleteSession(self: *SessionDB, session_id: []const u8) !void {
        var stmt = try sqlite.Stmt.prepare(&self.db, "DELETE FROM session WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        _ = try stmt.step();
    }

    // -----------------------------------------------------------------------
    // JSON migration helper
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Tree queries (Phase 49)
    // -----------------------------------------------------------------------

    /// Get all child sessions of a given parent session.
    /// Uses the "Fork of <parent_id>" title convention from fork.zig.
    /// Caller owns the returned slice.
    pub fn getChildSessions(self: *SessionDB, allocator: Allocator, parent_id: []const u8) ![]SessionRow {
        const prefix = try std.fmt.allocPrint(allocator, "Fork of {s}%", .{parent_id});
        defer allocator.free(prefix);

        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at
            \\FROM session WHERE title LIKE ?1 ESCAPE '\' ORDER BY created_at ASC
        );
        defer stmt.deinit();

        // Build LIKE pattern: "Fork of <parent_id>%"
        const like_pattern = try std.fmt.allocPrint(allocator, "Fork of {s}%%", .{parent_id});
        defer allocator.free(like_pattern);
        try stmt.bindText(1, like_pattern);

        var results = std.ArrayList(SessionRow).empty;
        errdefer {
            for (results.items) |*r| {
                allocator.free(r.id);
                allocator.free(r.title);
                allocator.free(r.model);
                allocator.free(r.provider);
            }
            results.deinit(allocator);
        }

        while (try stmt.step() == .row) {
            try results.append(allocator, .{
                .id = try allocator.dupe(u8, stmt.columnText(0)),
                .title = try allocator.dupe(u8, stmt.columnText(1)),
                .model = try allocator.dupe(u8, stmt.columnText(2)),
                .provider = try allocator.dupe(u8, stmt.columnText(3)),
                .total_tokens = @intCast(stmt.columnInt(4)),
                .total_cost = stmt.columnDouble(5),
                .turn_count = @intCast(stmt.columnInt(6)),
                .duration_seconds = @intCast(stmt.columnInt(7)),
                .created_at = stmt.columnInt(8),
                .updated_at = stmt.columnInt(9),
            });
        }

        return try results.toOwnedSlice(allocator);
    }

    /// Get session metadata (id, title, provider, model, turn_count, total_cost, created_at)
    /// for a specific session. Returns null if not found.
    /// Caller owns the returned struct's string fields.
    pub fn getSessionMetadata(self: *SessionDB, allocator: Allocator, session_id: []const u8) !?SessionMetadata {
        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, title, provider, model, turn_count, total_cost, created_at
            \\FROM session WHERE id = ?1
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        if (try stmt.step() != .row) return null;

        return SessionMetadata{
            .id = try allocator.dupe(u8, stmt.columnText(0)),
            .title = try allocator.dupe(u8, stmt.columnText(1)),
            .provider = try allocator.dupe(u8, stmt.columnText(2)),
            .model = try allocator.dupe(u8, stmt.columnText(3)),
            .turn_count = @intCast(stmt.columnInt(4)),
            .total_cost = stmt.columnDouble(5),
            .created_at = stmt.columnInt(6),
        };
    }

    /// Session metadata for tree building (returned from getSessionMetadata).
    pub const SessionMetadata = struct {
        id: []const u8,
        title: []const u8,
        provider: []const u8,
        model: []const u8,
        turn_count: u32,
        total_cost: f64,
        created_at: i64,

        pub fn deinit(self: *const SessionMetadata, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.title);
            allocator.free(self.provider);
            allocator.free(self.model);
        }
    };

    /// Import a session row from the old JSON format into SQLite.
    /// Only inserts the session metadata — the caller (migration.zig) handles
    /// parsing and inserting individual messages via `saveSession`.
    pub fn importJsonSession(self: *SessionDB, session: *const SessionRow) !void {
        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\INSERT OR REPLACE INTO session (id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        );
        defer stmt.deinit();
        try stmt.bindText(1, session.id);
        try stmt.bindText(2, session.title);
        try stmt.bindText(3, session.model);
        try stmt.bindText(4, session.provider);
        try stmt.bindInt(5, @intCast(session.total_tokens));
        try stmt.bindDouble(6, session.total_cost);
        try stmt.bindInt(7, @intCast(session.turn_count));
        try stmt.bindInt(8, @intCast(session.duration_seconds));
        try stmt.bindInt(9, session.created_at);
        try stmt.bindInt(10, session.updated_at);
        _ = try stmt.step();
    }

    // -------------------------------------------------------------------
    // Checkpoint CRUD
    // -------------------------------------------------------------------

    /// Ensure the checkpoints table exists (idempotent).
    pub fn createCheckpointTable(self: *SessionDB) !void {
        try self.db.exec(
            "CREATE TABLE IF NOT EXISTS checkpoints (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
            "session_id TEXT NOT NULL, " ++
            "file_path TEXT NOT NULL, " ++
            "timestamp INTEGER NOT NULL, " ++
            "operation TEXT NOT NULL, " ++
            "original_content TEXT NOT NULL, " ++
            "file_size INTEGER NOT NULL" ++
            ");" ++
            "CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON checkpoints(session_id, timestamp);"
        );
    }

    /// Insert a checkpoint row. Returns the auto-generated id.
    pub fn insertCheckpoint(
        self: *SessionDB,
        session_id: []const u8,
        file_path: []const u8,
        timestamp: i64,
        operation: []const u8,
        original_content: []const u8,
        file_size: u64,
    ) !i64 {
        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\INSERT INTO checkpoints (session_id, file_path, timestamp, operation, original_content, file_size)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindText(2, file_path);
        try stmt.bindInt(3, timestamp);
        try stmt.bindText(4, operation);
        try stmt.bindText(5, original_content);
        try stmt.bindInt(6, @intCast(file_size));
        _ = try stmt.step();
        return self.db.lastInsertRowId();
    }

    /// Get all checkpoints for a session, ordered by timestamp descending.
    /// Caller owns the returned slice and must call `freeCheckpoints`.
    pub fn getCheckpoints(self: *SessionDB, allocator: Allocator, session_id: []const u8) ![]Checkpoint {
        // Count first
        var count_stmt = try sqlite.Stmt.prepare(&self.db,
            "SELECT COUNT(*) FROM checkpoints WHERE session_id = ?1"
        );
        defer count_stmt.deinit();
        try count_stmt.bindText(1, session_id);
        _ = try count_stmt.step();
        const count: usize = @intCast(count_stmt.columnInt(0));

        if (count == 0) return try allocator.alloc(Checkpoint, 0);

        const checkpoints = try allocator.alloc(Checkpoint, count);
        errdefer {
            for (checkpoints) |*cp| cp.deinit(allocator);
            allocator.free(checkpoints);
        }

        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, session_id, file_path, timestamp, operation, original_content, file_size
            \\FROM checkpoints WHERE session_id = ?1
            \\ORDER BY timestamp DESC
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        var idx: usize = 0;
        while (try stmt.step() == .row and idx < count) : (idx += 1) {
            checkpoints[idx] = .{
                .id = stmt.columnInt(0),
                .session_id = try allocator.dupe(u8, stmt.columnText(1)),
                .file_path = try allocator.dupe(u8, stmt.columnText(2)),
                .timestamp = stmt.columnInt(3),
                .operation = try allocator.dupe(u8, stmt.columnText(4)),
                .original_content = try allocator.dupe(u8, stmt.columnText(5)),
                .file_size = @intCast(stmt.columnInt(6)),
            };
        }
        return checkpoints;
    }

    /// Get a single checkpoint by id. Returns null if not found.
    pub fn getCheckpoint(self: *SessionDB, allocator: Allocator, id: i64) !?Checkpoint {
        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\SELECT id, session_id, file_path, timestamp, operation, original_content, file_size
            \\FROM checkpoints WHERE id = ?1
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);

        if (try stmt.step() != .row) return null;

        return .{
            .id = stmt.columnInt(0),
            .session_id = try allocator.dupe(u8, stmt.columnText(1)),
            .file_path = try allocator.dupe(u8, stmt.columnText(2)),
            .timestamp = stmt.columnInt(3),
            .operation = try allocator.dupe(u8, stmt.columnText(4)),
            .original_content = try allocator.dupe(u8, stmt.columnText(5)),
            .file_size = @intCast(stmt.columnInt(6)),
        };
    }

    /// Delete a single checkpoint by id.
    pub fn deleteCheckpoint(self: *SessionDB, id: i64) !void {
        var stmt = try sqlite.Stmt.prepare(&self.db, "DELETE FROM checkpoints WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        _ = try stmt.step();
    }

    /// Delete old checkpoints for a session, keeping only the newest `keep_count`.
    /// Returns the number of deleted rows.
    pub fn deleteOldCheckpoints(self: *SessionDB, session_id: []const u8, keep_count: u32) !u32 {
        var stmt = try sqlite.Stmt.prepare(&self.db,
            \\DELETE FROM checkpoints
            \\WHERE session_id = ?1 AND id NOT IN (
            \\  SELECT id FROM checkpoints
            \\  WHERE session_id = ?1
            \\  ORDER BY timestamp DESC
            \\  LIMIT ?2
            \\)
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt(2, @intCast(keep_count));
        _ = try stmt.step();
        return @intCast(self.db.changes());
    }
};

// ---------------------------------------------------------------------------
// Helpers for freeing session slices
// ---------------------------------------------------------------------------

/// Free a slice of SessionRow returned by `listSessions`.
pub fn freeSessionRows(allocator: Allocator, rows: []SessionRow) void {
    for (rows) |row| {
        allocator.free(row.id);
        allocator.free(row.title);
        allocator.free(row.model);
        allocator.free(row.provider);
    }
    allocator.free(rows);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init and deinit" {
    var sdb = try SessionDB.init(std.testing.allocator, ":memory:");
    defer sdb.deinit();
}

test "save and load session round-trip" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const session = SessionRow{
        .id = "test-session-1",
        .title = "Hello world",
        .model = "gpt-4",
        .provider = "openai",
        .total_tokens = 150,
        .total_cost = 0.003,
        .turn_count = 2,
        .duration_seconds = 30,
        .created_at = 1000,
        .updated_at = 2000,
    };

    const messages = [_]MessageRow{
        .{ .role = "user", .content = "Hello", .tool_call_id = null, .tool_calls_json = null },
        .{ .role = "assistant", .content = "Hi there!", .tool_call_id = null, .tool_calls_json = null },
        .{ .role = "assistant", .content = null, .tool_call_id = "tc-1", .tool_calls_json = "[{\"id\":\"tc-1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"/foo\\\"}\"]}]" },
    };

    try sdb.saveSession(&session, &messages);

    // Load and verify
    var data = (try sdb.loadSession(allocator, "test-session-1")).?;
    defer data.deinit(allocator);

    try std.testing.expectEqualStrings("test-session-1", data.session.id);
    try std.testing.expectEqualStrings("Hello world", data.session.title);
    try std.testing.expectEqualStrings("gpt-4", data.session.model);
    try std.testing.expectEqualStrings("openai", data.session.provider);
    try std.testing.expectEqual(@as(u64, 150), data.session.total_tokens);
    try std.testing.expectEqual(@as(f64, 0.003), data.session.total_cost);
    try std.testing.expectEqual(@as(u32, 2), data.session.turn_count);
    try std.testing.expectEqual(@as(u32, 30), data.session.duration_seconds);
    try std.testing.expectEqual(@as(i64, 1000), data.session.created_at);
    try std.testing.expectEqual(@as(i64, 2000), data.session.updated_at);

    try std.testing.expectEqual(@as(usize, 3), data.messages.len);
    try std.testing.expectEqualStrings("user", data.messages[0].role);
    try std.testing.expectEqualStrings("Hello", data.messages[0].content.?);
    try std.testing.expectEqualStrings("assistant", data.messages[1].role);
    try std.testing.expectEqualStrings("Hi there!", data.messages[1].content.?);
    try std.testing.expect(data.messages[2].content == null);
    try std.testing.expectEqualStrings("tc-1", data.messages[2].tool_call_id.?);
}

test "loadSession returns null for nonexistent session" {
    var sdb = try SessionDB.init(std.testing.allocator, ":memory:");
    defer sdb.deinit();

    const result = try sdb.loadSession(std.testing.allocator, "does-not-exist");
    try std.testing.expect(result == null);
}

test "listSessions returns sessions sorted by updated_at DESC" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    // Insert two sessions
    const s1 = SessionRow{
        .id = "sess-old",
        .title = "Old session",
        .model = "gpt-4",
        .provider = "openai",
        .total_tokens = 100,
        .total_cost = 0.001,
        .turn_count = 1,
        .duration_seconds = 10,
        .created_at = 100,
        .updated_at = 200,
    };
    const s2 = SessionRow{
        .id = "sess-new",
        .title = "New session",
        .model = "claude-3",
        .provider = "anthropic",
        .total_tokens = 200,
        .total_cost = 0.002,
        .turn_count = 2,
        .duration_seconds = 20,
        .created_at = 300,
        .updated_at = 400,
    };
    const empty = [_]MessageRow{};

    try sdb.saveSession(&s1, &empty);
    try sdb.saveSession(&s2, &empty);

    const sessions = try sdb.listSessions(allocator);
    defer freeSessionRows(allocator, sessions);

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    // Most recently updated first
    try std.testing.expectEqualStrings("sess-new", sessions[0].id);
    try std.testing.expectEqualStrings("sess-old", sessions[1].id);
}

test "listSessions returns empty slice when no sessions" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const sessions = try sdb.listSessions(allocator);
    defer allocator.free(sessions);

    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "deleteSession removes session and messages" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const session = SessionRow{
        .id = "to-delete",
        .title = "Delete me",
        .model = "gpt-4",
        .provider = "openai",
        .total_tokens = 50,
        .total_cost = 0.001,
        .turn_count = 1,
        .duration_seconds = 5,
        .created_at = 100,
        .updated_at = 200,
    };
    const messages = [_]MessageRow{
        .{ .role = "user", .content = "Hello", .tool_call_id = null, .tool_calls_json = null },
    };

    try sdb.saveSession(&session, &messages);

    // Verify it exists
    var data = (try sdb.loadSession(allocator, "to-delete")).?;
    data.deinit(allocator);

    // Delete
    try sdb.deleteSession("to-delete");

    // Verify it's gone
    const result = try sdb.loadSession(allocator, "to-delete");
    try std.testing.expect(result == null);
}

test "saveSession upserts existing session" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const session_v1 = SessionRow{
        .id = "upsert-test",
        .title = "Version 1",
        .model = "gpt-4",
        .provider = "openai",
        .total_tokens = 100,
        .total_cost = 0.001,
        .turn_count = 1,
        .duration_seconds = 10,
        .created_at = 100,
        .updated_at = 200,
    };
    const msgs_v1 = [_]MessageRow{
        .{ .role = "user", .content = "First", .tool_call_id = null, .tool_calls_json = null },
    };

    try sdb.saveSession(&session_v1, &msgs_v1);

    // Upsert with new data
    const session_v2 = SessionRow{
        .id = "upsert-test",
        .title = "Version 2",
        .model = "claude-3",
        .provider = "anthropic",
        .total_tokens = 300,
        .total_cost = 0.005,
        .turn_count = 3,
        .duration_seconds = 30,
        .created_at = 100,
        .updated_at = 500,
    };
    const msgs_v2 = [_]MessageRow{
        .{ .role = "user", .content = "First", .tool_call_id = null, .tool_calls_json = null },
        .{ .role = "assistant", .content = "Reply", .tool_call_id = null, .tool_calls_json = null },
    };

    try sdb.saveSession(&session_v2, &msgs_v2);

    var data = (try sdb.loadSession(allocator, "upsert-test")).?;
    defer data.deinit(allocator);

    try std.testing.expectEqualStrings("Version 2", data.session.title);
    try std.testing.expectEqualStrings("claude-3", data.session.model);
    try std.testing.expectEqual(@as(u64, 300), data.session.total_tokens);
    try std.testing.expectEqual(@as(usize, 2), data.messages.len);
}

test "importJsonSession inserts session row" {
    const allocator = std.testing.allocator;

    var sdb = try SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const session = SessionRow{
        .id = "json-import-1",
        .title = "Imported",
        .model = "gpt-4",
        .provider = "openai",
        .total_tokens = 50,
        .total_cost = 0.001,
        .turn_count = 1,
        .duration_seconds = 5,
        .created_at = 100,
        .updated_at = 200,
    };

    try sdb.importJsonSession(&session);

    // Verify it exists (messages will be empty since importJsonSession only inserts session row)
    var data = (try sdb.loadSession(allocator, "json-import-1")).?;
    defer data.deinit(allocator);

    try std.testing.expectEqualStrings("json-import-1", data.session.id);
    try std.testing.expectEqualStrings("Imported", data.session.title);
    try std.testing.expectEqual(@as(usize, 0), data.messages.len);
}
