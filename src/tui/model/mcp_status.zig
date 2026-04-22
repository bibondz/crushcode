// src/tui/model/mcp_status.zig
// MCP server status method extracted from chat_tui_app.zig

const std = @import("std");

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies
const widget_sidebar = @import("widget_sidebar");

pub fn getMCPServerStatus(self: *const Model, allocator: std.mem.Allocator) []const widget_sidebar.MCPServerStatus {
    const bridge = self.mcp_bridge orelse return &.{};
    var statuses = std.ArrayList(widget_sidebar.MCPServerStatus).initCapacity(allocator, bridge.servers.items.len) catch return &.{};
    for (bridge.servers.items) |server| {
        statuses.append(allocator, .{
            .name = server.name,
            .connected = server.connected,
            .tool_count = @intCast(server.tools.len),
        }) catch break;
    }
    return statuses.toOwnedSlice(allocator) catch return &.{};
}
