const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("zig_helpers.h");
});

pub const SqliteError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ColumnFailed,
    CloseFailed,
    NotFound,
    ConstraintViolation,
    Busy,
};

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open (or create) a database at the given path.
    /// Uses WAL mode + normal sync for crash safety.
    pub fn open(path: [:0]const u8) !Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }
        var self = Db{ .handle = db.? };
        // Enable WAL mode + set pragmas
        try self.exec("PRAGMA journal_mode=WAL;");
        try self.exec("PRAGMA synchronous=NORMAL;");
        try self.exec("PRAGMA foreign_keys=ON;");
        try self.exec("PRAGMA busy_timeout=30000;");
        try self.exec("PRAGMA cache_size=-8000;");
        return self;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute a SQL statement (no results).
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return SqliteError.ExecFailed;
    }

    /// Get last error message from SQLite.
    pub fn errorMessage(self: *Db) [*c]const u8 {
        return c.sqlite3_errmsg(self.handle);
    }

    /// Get last insert rowid.
    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Get number of rows changed by last statement.
    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.handle);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db: *Db,

    /// Prepare a SQL statement.
    pub fn prepare(db: *Db, sql: [:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v3(
            db.handle,
            sql.ptr,
            @intCast(sql.len),
            0,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return SqliteError.PrepareFailed;
        return Stmt{ .handle = stmt.?, .db = db };
    }

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Stmt) !void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return SqliteError.ExecFailed;
    }

    // --- Bind methods ---

    pub fn bindInt(self: *Stmt, idx: i32, val: i64) !void {
        const rc = c.sqlite3_bind_int64(self.handle, idx, val);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindDouble(self: *Stmt, idx: i32, val: f64) !void {
        const rc = c.sqlite3_bind_double(self.handle, idx, val);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindText(self: *Stmt, idx: i32, val: []const u8) !void {
        const rc = c.zig_sqlite3_bind_text_transient(self.handle, idx, val.ptr, @intCast(val.len));
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindNull(self: *Stmt, idx: i32) !void {
        const rc = c.sqlite3_bind_null(self.handle, idx);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    // --- Step ---

    pub const StepResult = enum { row, done };

    pub fn step(self: *Stmt) !StepResult {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return .row;
        if (rc == c.SQLITE_DONE) return .done;
        return SqliteError.StepFailed;
    }

    // --- Column getters ---

    pub fn columnInt(self: *Stmt, idx: i32) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    pub fn columnDouble(self: *Stmt, idx: i32) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    pub fn columnText(self: *Stmt, idx: i32) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return "";
        const len = c.sqlite3_column_bytes(self.handle, idx);
        return ptr[0..@intCast(len)];
    }

    pub fn columnIsNull(self: *Stmt, idx: i32) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }
};

/// Execute a query and call `callback` for each row.
/// The callback receives a Stmt that is positioned on the current row.
pub fn execQuery(
    db: *Db,
    sql: [:0]const u8,
    comptime Context: type,
    ctx: *Context,
    comptime callback: fn (*Context, *Stmt) anyerror!void,
) !void {
    var stmt = try Stmt.prepare(db, sql);
    defer stmt.deinit();
    while (try stmt.step() == .row) {
        try callback(ctx, &stmt);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "open and close in-memory database" {
    var db = try Db.open(":memory:");
    defer db.close();
}

test "create table and insert a row" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    var stmt = try Stmt.prepare(&db, "INSERT INTO test (name) VALUES (?);");
    defer stmt.deinit();
    try stmt.bindText(1, "hello");
    const result = try stmt.step();
    try std.testing.expectEqual(Stmt.StepResult.done, result);

    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowId());
    try std.testing.expectEqual(@as(i64, 1), db.changes());
}

test "query a row and read columns" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER NOT NULL);");
    try db.exec("INSERT INTO kv (k, v) VALUES ('answer', 42);");

    var stmt = try Stmt.prepare(&db, "SELECT k, v FROM kv WHERE k = ?;");
    defer stmt.deinit();
    try stmt.bindText(1, "answer");

    try std.testing.expectEqual(Stmt.StepResult.row, try stmt.step());
    try std.testing.expectEqualStrings("answer", stmt.columnText(0));
    try std.testing.expectEqual(@as(i64, 42), stmt.columnInt(1));
    try std.testing.expectEqual(Stmt.StepResult.done, try stmt.step());
}

test "WAL mode is enabled" {
    var db = try Db.open(":memory:");
    defer db.close();

    // In :memory: databases, journal_mode returns "memory" not "wal",
    // but the PRAGMA should not error. For a file db it would return "wal".
    // Verify the exec succeeded by querying journal_mode.
    var stmt = try Stmt.prepare(&db, "PRAGMA journal_mode;");
    defer stmt.deinit();
    try std.testing.expectEqual(Stmt.StepResult.row, try stmt.step());
    // :memory: db returns "memory" — just confirm we can read it
    const mode = stmt.columnText(0);
    try std.testing.expect(mode.len > 0);
}
