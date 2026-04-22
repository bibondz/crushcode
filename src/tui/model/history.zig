// src/tui/model/history.zig
// History and message management functions extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const core = @import("core_api");
const widget_types = @import("widget_types");

// Import sibling helpers
const helpers = @import("helpers.zig");

const recent_files_max = widget_types.recent_files_max;

pub fn addMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
    try addMessageWithToolsUnlocked(self, role, content, null, null);
}

pub fn addMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
    try self.messages.append(self.allocator, .{
        .role = try self.allocator.dupe(u8, role),
        .content = try self.allocator.dupe(u8, content),
        .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
        .tool_calls = try helpers.cloneToolCallInfos(self.allocator, tool_calls),
    });
}

pub fn clearMessagesUnlocked(self: *Model) void {
    for (self.messages.items) |message| {
        helpers.freeDisplayMessage(self.allocator, message);
    }
    self.messages.clearRetainingCapacity();
}

pub fn clearHistoryUnlocked(self: *Model) void {
    for (self.history.items) |message| {
        helpers.freeChatMessage(self.allocator, message);
    }
    self.history.clearRetainingCapacity();
}

pub fn appendHistoryMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
    try appendHistoryMessageWithToolsUnlocked(self, role, content, null, null);
}

pub fn appendHistoryMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
    try self.history.append(self.allocator, .{
        .role = try self.allocator.dupe(u8, role),
        .content = try self.allocator.dupe(u8, content),
        .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
        .tool_calls = try helpers.cloneToolCallInfos(self.allocator, tool_calls),
    });
}

pub fn replaceMessageUnlocked(self: *Model, index: usize, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
    var message = &self.messages.items[index];
    self.allocator.free(message.role);
    self.allocator.free(message.content);
    if (message.tool_call_id) |value| self.allocator.free(value);
    helpers.freeToolCallInfos(self.allocator, message.tool_calls);
    message.role = try self.allocator.dupe(u8, role);
    message.content = try self.allocator.dupe(u8, content);
    message.tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
    message.tool_calls = try helpers.cloneToolCallInfos(self.allocator, tool_calls);
}

pub fn appendToMessageUnlocked(self: *Model, index: usize, suffix: []const u8) !void {
    var message = &self.messages.items[index];
    const updated = try self.allocator.alloc(u8, message.content.len + suffix.len);
    @memcpy(updated[0..message.content.len], message.content);
    @memcpy(updated[message.content.len..], suffix);
    self.allocator.free(message.content);
    message.content = updated;
}

pub fn trackToolCallFilesUnlocked(self: *Model, tool_calls: ?[]const core.client.ToolCallInfo) !void {
    const calls = tool_calls orelse return;
    for (calls) |tool_call| {
        if (!helpers.isRecentFileTool(tool_call.name)) continue;
        if (helpers.extractToolFilePath(tool_call.arguments)) |path| {
            try addRecentFileUnlocked(self, path);
        }
    }
}

pub fn addRecentFileUnlocked(self: *Model, file_path: []const u8) !void {
    var found_index: ?usize = null;
    for (self.recent_files.items, 0..) |existing, idx| {
        if (std.mem.eql(u8, existing, file_path)) {
            found_index = idx;
            break;
        }
    }
    if (found_index) |idx| {
        self.allocator.free(self.recent_files.items[idx]);
        _ = self.recent_files.orderedRemove(idx);
    }
    const owned = try self.allocator.dupe(u8, file_path);
    try self.recent_files.append(self.allocator, owned);
    if (self.recent_files.items.len > recent_files_max) {
        self.allocator.free(self.recent_files.orderedRemove(0));
    }
}
