// src/tui/model/notifications.zig
// Notification method extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const widget_toast = @import("widget_toast");
const hooks_mod = @import("hooks_registry");

pub fn showNotification(self: *Model, message: []const u8, severity: widget_toast.Severity) void {
    self.toast_stack.push(message, severity) catch {};

    // Fire Notification hook via hook registry
    if (self.hook_registry) |registry| {
        var ctx = hooks_mod.HookContext{
            .hook_type = .Notification,
            .result = message,
            .timestamp = std.time.milliTimestamp(),
        };
        const results = registry.executeHooks(&ctx) catch &.{};
        defer {
            for (results) |*r| r.deinit(self.allocator);
            if (results.len > 0) self.allocator.free(results);
        }
    }
}
