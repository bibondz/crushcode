// src/tui/model/session_time.zig
// Session time tracking methods extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

pub fn sessionElapsedSeconds(self: *const Model) u64 {
    const elapsed_ns = @max(std.time.nanoTimestamp() - self.session_start, 0);
    return @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
}

pub fn sessionMinutes(self: *const Model) u64 {
    return @divFloor(sessionElapsedSeconds(self), 60);
}

pub fn sessionSecondsPart(self: *const Model) u64 {
    return @mod(sessionElapsedSeconds(self), 60);
}
