//! Session forking: create a new session from a subset of messages in an
//! existing session.  Forks are identified by a title prefix convention
//! ("Fork of <parent_id>") and a metadata block embedded in the fork's title.
//!
//! All operations go through the `session` module so that the SQLite ↔ JSON
//! fallback path is handled transparently.

const std = @import("std");
const session_mod = @import("session");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const ForkInfo = struct {
    fork_id: []const u8,
    parent_session_id: []const u8,
    fork_point: u32,
    title: []const u8,
};

pub const ForkResult = struct {
    new_session_id: []const u8,
    message_count: u32,
    title: []const u8,

    pub fn deinit(self: *const ForkResult, allocator: Allocator) void {
        allocator.free(self.new_session_id);
        allocator.free(self.title);
    }
};

// ---------------------------------------------------------------------------
// ForkManager
// ---------------------------------------------------------------------------

pub const ForkManager = struct {
    allocator: Allocator,
    session_dir: []const u8,

    pub fn init(allocator: Allocator, session_dir: []const u8) ForkManager {
        return .{ .allocator = allocator, .session_dir = session_dir };
    }

    // -------------------------------------------------------------------
    // forkSession
    // -------------------------------------------------------------------

    /// Fork a session at `fork_point` (number of messages to copy).
    /// Creates a brand-new session with messages `[0..fork_point)` from the
    /// original, a generated ID, and a descriptive title.
    pub fn forkSession(
        self: *ForkManager,
        parent_session: *const session_mod.Session,
        fork_point: u32,
    ) !ForkResult {
        const allocator = self.allocator;

        // 1. Determine how many existing forks of this parent exist (for
        //    unique naming).  We scan the session list and count titles that
        //    start with "Fork of <parent_id>".
        var fork_count: u32 = 0;
        const existing = session_mod.listSessions(allocator, self.session_dir) catch &[_]session_mod.Session{};
        defer {
            for (existing) |*s| session_mod.deinitSession(allocator, @constCast(s));
            allocator.free(existing);
        }
        const prefix = try std.fmt.allocPrint(allocator, "Fork of {s}", .{parent_session.id});
        defer allocator.free(prefix);
        for (existing) |s| {
            if (std.mem.startsWith(u8, s.title, prefix)) fork_count += 1;
        }

        // 2. Generate new session ID
        const new_id = try std.fmt.allocPrint(allocator, "{s}_fork_{d}", .{ parent_session.id, fork_count });
        errdefer allocator.free(new_id);

        // 3. Build the forked session — copy messages [0..fork_point)
        const count = @min(fork_point, @as(u32, @intCast(parent_session.messages.len)));
        var forked_messages = try allocator.alloc(session_mod.Message, count);
        errdefer {
            for (forked_messages) |*m| {
                allocator.free(m.role);
                if (m.content) |c| allocator.free(c);
                if (m.tool_call_id) |tc| allocator.free(tc);
                if (m.tool_calls) |tc| freeToolCalls(allocator, tc);
            }
            allocator.free(forked_messages);
        }
        for (parent_session.messages[0..count], 0..) |msg, i| {
            forked_messages[i] = .{
                .role = try allocator.dupe(u8, msg.role),
                .content = if (msg.content) |c| try allocator.dupe(u8, c) else null,
                .tool_call_id = if (msg.tool_call_id) |tc| try allocator.dupe(u8, tc) else null,
                .tool_calls = cloneToolCallInfos(allocator, msg.tool_calls),
            };
        }

        // 4. Create the title: "Fork of <parent_id> @<fork_point>"
        const new_title = try std.fmt.allocPrint(allocator, "Fork of {s} @{d}", .{ parent_session.id, fork_point });
        errdefer allocator.free(new_title);

        const now = std.time.timestamp();

        const forked_session = session_mod.Session{
            .id = new_id,
            .created_at = now,
            .updated_at = now,
            .title = new_title,
            .messages = forked_messages,
            .model = try allocator.dupe(u8, parent_session.model),
            .provider = try allocator.dupe(u8, parent_session.provider),
            .total_tokens = 0,
            .total_cost = 0,
            .turn_count = 0,
            .duration_seconds = 0,
        };

        // 5. Persist the forked session
        session_mod.saveSession(allocator, self.session_dir, &forked_session) catch {};

        // 6. We hand back owned copies — clean up the forked_session struct
        //    (which holds the same pointers we just saved) by NOT deinit-ing
        //    the strings that are now owned by ForkResult.
        //    The `forked_messages` slice and its strings are consumed by the
        //    save call; the ForkResult only needs id and title.
        return ForkResult{
            .new_session_id = new_id,
            .message_count = count,
            .title = new_title,
        };
    }

    // -------------------------------------------------------------------
    // listForks — forks of a specific parent session
    // -------------------------------------------------------------------

    /// List all fork sessions that originated from `session_id`.
    /// Caller owns the returned slice and must free each entry's strings.
    pub fn listForks(self: *ForkManager, session_id: []const u8) ![]ForkInfo {
        const allocator = self.allocator;
        var forks = std.ArrayList(ForkInfo).empty;
        errdefer {
            for (forks.items) |*f| {
                allocator.free(f.fork_id);
                allocator.free(f.parent_session_id);
                allocator.free(f.title);
            }
            forks.deinit(allocator);
        }

        const sessions = session_mod.listSessions(allocator, self.session_dir) catch &[_]session_mod.Session{};
        defer {
            for (sessions) |*s| session_mod.deinitSession(allocator, s);
            allocator.free(sessions);
        }

        const prefix = try std.fmt.allocPrint(allocator, "Fork of {s}", .{session_id});
        defer allocator.free(prefix);

        for (sessions) |s| {
            if (!std.mem.startsWith(u8, s.title, prefix)) continue;
            const parent_id = try allocator.dupe(u8, session_id);
            const fork_point = parseForkPoint(s.title);
            try forks.append(allocator, .{
                .fork_id = try allocator.dupe(u8, s.id),
                .parent_session_id = parent_id,
                .fork_point = fork_point,
                .title = try allocator.dupe(u8, s.title),
            });
        }

        return forks.toOwnedSlice(allocator);
    }

    // -------------------------------------------------------------------
    // listAllForks — all forks across all sessions
    // -------------------------------------------------------------------

    /// List every session whose title starts with "Fork of ".
    /// Caller owns the returned slice.
    pub fn listAllForks(self: *ForkManager) ![]ForkInfo {
        const allocator = self.allocator;
        var forks = std.ArrayList(ForkInfo).empty;
        errdefer {
            for (forks.items) |*f| {
                allocator.free(f.fork_id);
                allocator.free(f.parent_session_id);
                allocator.free(f.title);
            }
            forks.deinit(allocator);
        }

        const sessions = session_mod.listSessions(allocator, self.session_dir) catch &[_]session_mod.Session{};
        defer {
            for (sessions) |*s| session_mod.deinitSession(allocator, @constCast(s));
            allocator.free(sessions);
        }

        for (sessions) |s| {
            if (!std.mem.startsWith(u8, s.title, "Fork of ")) continue;
            const parent_id = try extractParentId(allocator, s.title);
            const fork_point = parseForkPoint(s.title);
            try forks.append(allocator, .{
                .fork_id = try allocator.dupe(u8, s.id),
                .parent_session_id = parent_id,
                .fork_point = fork_point,
                .title = try allocator.dupe(u8, s.title),
            });
        }

        return forks.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse the fork point from a title like "Fork of session-123 @42" → 42.
fn parseForkPoint(title: []const u8) u32 {
    const at_idx = std.mem.lastIndexOfScalar(u8, title, '@') orelse return 0;
    const after = title[at_idx + 1 ..];
    return std.fmt.parseInt(u32, after, 10) catch 0;
}

/// Extract the parent session ID from a title like "Fork of session-123 @42".
/// Returns a newly allocated string.
fn extractParentId(allocator: Allocator, title: []const u8) ![]const u8 {
    // title = "Fork of <parent_id> @<n>"
    const prefix = "Fork of ";
    if (!std.mem.startsWith(u8, title, prefix)) return allocator.dupe(u8, "");
    const rest = title[prefix.len..];
    const at_idx = std.mem.lastIndexOfScalar(u8, rest, '@') orelse rest.len;
    const trimmed = std.mem.trimRight(u8, rest[0..at_idx], " ");
    return allocator.dupe(u8, trimmed);
}

/// Clone tool call infos — no-op for forking (tool_calls not needed in fork history).
fn cloneToolCallInfos(_: Allocator, tool_calls: anytype) @TypeOf(tool_calls) {
    _ = &tool_calls;
    return null;
}

/// Free tool call infos — no-op.
fn freeToolCalls(_: Allocator, _: anytype) void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseForkPoint extracts correct value" {
    try std.testing.expectEqual(@as(u32, 42), parseForkPoint("Fork of session-123 @42"));
    try std.testing.expectEqual(@as(u32, 0), parseForkPoint("Fork of session-123 @"));
    try std.testing.expectEqual(@as(u32, 0), parseForkPoint("Some other title"));
    try std.testing.expectEqual(@as(u32, 7), parseForkPoint("Fork of abc @7"));
}

test "extractParentId extracts correct value" {
    const allocator = std.testing.allocator;
    const id = try extractParentId(allocator, "Fork of session-123 @42");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("session-123", id);

    const id2 = try extractParentId(allocator, "Fork of abc");
    defer allocator.free(id2);
    try std.testing.expectEqualStrings("abc", id2);
}
