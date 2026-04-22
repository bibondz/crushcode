// src/tui/model/session_mgmt.zig
// Session management functions extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const session_mod = @import("session");
const widget_types = @import("widget_types");

// Import sibling helpers
const helpers = @import("helpers.zig");
const history_mod = @import("history.zig");
const session_time_mod = @import("session_time.zig");
const token_tracking_mod = @import("token_tracking.zig");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const InterruptedSessionCandidate = widget_types.InterruptedSessionCandidate;

pub fn prepareStartupSessionState(self: *Model) !void {
    const interrupted = try findInterruptedSessionCandidate(self);
    errdefer if (interrupted) |candidate| {
        var session = candidate.session;
        session_mod.deinitSession(self.allocator, &session);
        self.allocator.free(candidate.path);
    };

    try beginNewSessionUnlocked(self);
    if (interrupted) |candidate| {
        self.resume_prompt_session = candidate.session;
        self.resume_prompt_path = candidate.path;
    }
}

pub fn beginNewSessionUnlocked(self: *Model) !void {
    const now = std.time.timestamp();
    var session = session_mod.Session{
        .id = try session_mod.generateSessionId(self.allocator),
        .created_at = now,
        .updated_at = now,
        .title = try self.allocator.dupe(u8, "New session"),
        .messages = try self.allocator.alloc(session_mod.Message, 0),
        .model = try self.allocator.dupe(u8, self.model_name),
        .provider = try self.allocator.dupe(u8, self.provider_name),
        .total_tokens = 0,
        .total_cost = 0,
        .turn_count = 0,
        .duration_seconds = 0,
    };
    errdefer session_mod.deinitSession(self.allocator, &session);

    const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
    errdefer self.allocator.free(path);

    try session_mod.saveSession(self.allocator, self.session_dir, &session);

    if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
    self.current_session = session;
    if (self.session_path.len > 0) self.allocator.free(self.session_path);
    self.session_path = path;
    self.session_start = std.time.nanoTimestamp();
}

pub fn findInterruptedSessionCandidate(self: *Model) !?InterruptedSessionCandidate {
    const sessions = try session_mod.listSessions(self.allocator, self.session_dir);
    defer self.allocator.free(sessions);

    const now = std.time.timestamp();
    for (sessions, 0..) |session, index| {
        if (session.updated_at + 300 >= now) continue;
        if (!session_mod.isInterrupted(&session)) continue;

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
        for (sessions, 0..) |*other, other_index| {
            if (other_index == index) continue;
            session_mod.deinitSession(self.allocator, other);
        }
        return .{ .session = session, .path = path };
    }

    for (sessions) |*session| session_mod.deinitSession(self.allocator, session);
    return null;
}

pub fn clearRecentFilesUnlocked(self: *Model) void {
    for (self.recent_files.items) |file| self.allocator.free(file);
    self.recent_files.clearRetainingCapacity();
}

pub fn clearSessionListOwned(self: *Model) void {
    if (self.session_list.len == 0) {
        self.session_list = &.{};
        self.session_list_selected = 0;
        self.show_session_list = false;
        return;
    }
    for (self.session_list) |*session| session_mod.deinitSession(self.allocator, session);
    self.allocator.free(self.session_list);
    self.session_list = &.{};
    self.session_list_selected = 0;
    self.show_session_list = false;
}

pub fn clearResumePromptOwned(self: *Model) void {
    if (self.resume_prompt_session) |*session| {
        session_mod.deinitSession(self.allocator, session);
        self.resume_prompt_session = null;
    }
    if (self.resume_prompt_path) |path| {
        self.allocator.free(path);
        self.resume_prompt_path = null;
    }
}

pub fn saveSessionSnapshotUnlocked(self: *Model) !void {
    const current = self.current_session orelse return;
    var snapshot = session_mod.Session{
        .id = try self.allocator.dupe(u8, current.id),
        .created_at = current.created_at,
        .updated_at = std.time.timestamp(),
        .title = try self.allocator.dupe(u8, current.title),
        .messages = try buildSessionMessagesUnlocked(self),
        .model = try self.allocator.dupe(u8, self.model_name),
        .provider = try self.allocator.dupe(u8, self.provider_name),
        .total_tokens = self.total_input_tokens + self.total_output_tokens,
        .total_cost = token_tracking_mod.estimatedCostUsd(self),
        .turn_count = self.request_count,
        .duration_seconds = @intCast(@min(session_time_mod.sessionElapsedSeconds(self), std.math.maxInt(u32))),
    };
    errdefer session_mod.deinitSession(self.allocator, &snapshot);

    try session_mod.saveSession(self.allocator, self.session_dir, &snapshot);
    if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
    self.current_session = snapshot;
}

pub fn buildSessionMessagesUnlocked(self: *Model) ![]session_mod.Message {
    const copied = try self.allocator.alloc(session_mod.Message, self.messages.items.len);
    errdefer self.allocator.free(copied);

    for (self.messages.items, 0..) |message, index| {
        copied[index] = .{
            .role = try self.allocator.dupe(u8, message.role),
            .content = try self.allocator.dupe(u8, message.content),
            .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
            .tool_calls = try helpers.cloneToolCallInfos(self.allocator, message.tool_calls),
        };
    }
    return copied;
}

pub fn openSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
    clearSessionListOwned(self);
    const loaded = try session_mod.listSessions(self.allocator, self.session_dir);
    if (loaded.len == 0) {
        self.allocator.free(loaded);
        self.session_list = &.{};
    } else {
        self.session_list = loaded;
    }
    self.show_session_list = true;
    self.session_list_selected = 0;
    // NOTE: No requestFocus — Model stays focused, keys forwarded manually
    ctx.redraw = true;
}

pub fn closeSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
    clearSessionListOwned(self);
    // NOTE: No requestFocus — Model stays focused, keys forwarded manually
    ctx.redraw = true;
}

pub fn moveSessionListSelection(self: *Model, delta: isize) void {
    if (self.session_list.len == 0) {
        self.session_list_selected = 0;
        return;
    }
    const current: isize = @intCast(self.session_list_selected);
    const max_index: isize = @intCast(self.session_list.len - 1);
    const next = std.math.clamp(current + delta, 0, max_index);
    self.session_list_selected = @intCast(next);
}

pub fn deleteSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
    const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
    defer self.allocator.free(path);

    const deleting_current = if (self.current_session) |session|
        std.mem.eql(u8, session.id, session_id)
    else
        false;

    try session_mod.deleteSession(self.allocator, path);
    if (deleting_current) {
        history_mod.clearMessagesUnlocked(self);
        history_mod.clearHistoryUnlocked(self);
        clearRecentFilesUnlocked(self);
        self.total_input_tokens = 0;
        self.total_output_tokens = 0;
        self.request_count = 0;
        self.assistant_stream_index = null;
        self.awaiting_first_token = false;
        try beginNewSessionUnlocked(self);
    }
}
