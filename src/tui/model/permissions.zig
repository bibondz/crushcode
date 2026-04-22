// src/tui/model/permissions.zig
// Permission management extracted from chat_tui_app.zig

const std = @import("std");

const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

const widget_types = @import("widget_types");

const ToolPermission = widget_types.ToolPermission;
const PermissionDecision = widget_types.PermissionDecision;

const fallback = @import("fallback.zig");

pub fn freePendingPermission(self: *Model, pending: ToolPermission) void {
    self.allocator.free(pending.tool_name);
    self.allocator.free(pending.arguments);
    if (pending.preview_diff) |d| self.allocator.free(d);
}

pub fn resolvePendingPermission(self: *Model, decision: PermissionDecision) void {
    self.permission_mutex.lock();
    self.permission_decision = decision;
    self.permission_condition.signal();
    self.permission_mutex.unlock();
}

pub fn needsPermission(self: *const Model, tool_name: []const u8) bool {
    _ = self;
    if (std.mem.eql(u8, tool_name, "shell")) return true;
    if (std.mem.eql(u8, tool_name, "write_file")) return true;
    if (std.mem.eql(u8, tool_name, "edit")) return true;
    return false;
}

pub fn isAlwaysAllowed(self: *const Model, tool_name: []const u8) bool {
    for (self.always_allow_tools.items) |allowed_tool| {
        if (std.mem.eql(u8, allowed_tool, tool_name)) return true;
    }
    return false;
}

pub fn requestToolPermission(self: *Model, tool_name: []const u8, arguments: []const u8, preview_diff: ?[]const u8) !bool {
    if (self.permission_mode == .auto or !needsPermission(self, tool_name) or isAlwaysAllowed(self, tool_name)) {
        return true;
    }

    self.permission_mutex.lock();
    defer self.permission_mutex.unlock();
    self.permission_decision = null;

    self.lock.lock();
    if (self.pending_permission) |pending| freePendingPermission(self, pending);
    self.pending_permission = .{
        .tool_name = try self.allocator.dupe(u8, tool_name),
        .arguments = try self.allocator.dupe(u8, arguments),
        .preview_diff = if (preview_diff) |d| try self.allocator.dupe(u8, d) else null,
        .tool_tier = fallback.classifyToolTier(tool_name),
    };
    self.lock.unlock();

    while (self.permission_decision == null) {
        self.permission_condition.wait(&self.permission_mutex);
    }

    const decision = self.permission_decision.?;
    self.permission_decision = null;

    self.lock.lock();
    defer self.lock.unlock();
    if (decision == .always and !isAlwaysAllowed(self, tool_name)) {
        self.always_allow_tools.append(self.allocator, try self.allocator.dupe(u8, tool_name)) catch {};
    }
    if (self.pending_permission) |pending| {
        freePendingPermission(self, pending);
        self.pending_permission = null;
    }
    return decision != .no;
}
