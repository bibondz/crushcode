// src/tui/model/status.zig
// Status message management extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

pub fn setStatusMessage(self: *Model, text: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();
    try setStatusMessageUnlocked(self, text);
}

pub fn setStatusMessageUnlocked(self: *Model, text: []const u8) !void {
    if (self.status_message.len > 0) self.allocator.free(self.status_message);
    self.status_message = if (text.len == 0) "" else try self.allocator.dupe(u8, text);
}

pub fn clearStatusMessage(self: *Model) void {
    self.lock.lock();
    defer self.lock.unlock();
    if (self.status_message.len > 0) self.allocator.free(self.status_message);
    self.status_message = "";
}
