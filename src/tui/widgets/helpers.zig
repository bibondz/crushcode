const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core_api");
const theme_mod = @import("theme");
const widget_types = @import("widget_types");

const vxfw = vaxis.vxfw;

// --- Message role helpers ---

pub fn messageRoleStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.assistant_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .bold = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .bold = true };
    }
    return .{ .fg = theme.dimmed, .bold = true };
}

pub fn messageBodyStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.header_fg };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .dim = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .dim = true };
    }
    return .{ .fg = theme.dimmed, .dim = true };
}

pub fn messageRoleLabel(theme: *const theme_mod.Theme, role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return theme.user_label;
    if (std.mem.eql(u8, role, "assistant")) return theme.assistant_label;
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return role;
}

// --- Tool call helpers ---

pub fn shouldRenderMessageContent(message: *const widget_types.Message) bool {
    return message.content.len > 0 or message.tool_calls == null;
}

pub fn toolCallStatusIcon(status: widget_types.ToolCallStatus) []const u8 {
    return switch (status) {
        .pending => "●",
        .success => "✓",
        .failed => "×",
    };
}

pub fn toolCallStatusStyle(theme: *const theme_mod.Theme, status: widget_types.ToolCallStatus) vaxis.Style {
    return switch (status) {
        .pending => .{ .fg = theme.tool_pending, .bold = true },
        .success => .{ .fg = theme.tool_success, .bold = true },
        .failed => .{ .fg = theme.tool_error, .bold = true },
    };
}

pub fn toolCallStatusForMessage(message: ?*const widget_types.Message) widget_types.ToolCallStatus {
    const result = message orelse return .pending;
    if (std.mem.eql(u8, result.role, "error")) return .failed;

    const trimmed = std.mem.trim(u8, result.content, " \t\r\n");
    if (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "error:")) {
        return .failed;
    }
    return .success;
}

pub fn toolCallOutputText(allocator: std.mem.Allocator, output: ?[]const u8, status: widget_types.ToolCallStatus) ![]const u8 {
    const text = output orelse {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    };
    if (text.len == 0) {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    }

    var builder = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    var remaining: usize = 0;
    while (lines.next()) |line| {
        if (line_count < 5) {
            if (line_count > 0) try builder.append(allocator, '\n');
            try builder.appendSlice(allocator, "  ");
            try builder.appendSlice(allocator, line);
        } else {
            remaining += 1;
        }
        line_count += 1;
    }
    if (remaining > 0) {
        if (builder.items.len > 0) try builder.append(allocator, '\n');
        try builder.writer(allocator).print("  and {d} more lines...", .{remaining});
    }
    return builder.toOwnedSlice(allocator);
}

// --- Tool call lookup helpers ---

pub fn findToolCallBefore(messages: []const widget_types.Message, before_index: usize, tool_call_id: []const u8) ?core.client.ToolCallInfo {
    var idx = before_index;
    while (idx > 0) {
        idx -= 1;
        if (messages[idx].tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.id, tool_call_id)) return tool_call;
            }
        }
    }
    return null;
}

pub fn findToolResultMessageAfter(messages: []const widget_types.Message, after_index: usize, tool_call_id: []const u8) ?*const widget_types.Message {
    var idx = after_index + 1;
    while (idx < messages.len) : (idx += 1) {
        const message = &messages[idx];
        if (message.tool_call_id) |message_tool_call_id| {
            if (std.mem.eql(u8, message_tool_call_id, tool_call_id)) return message;
        }
    }
    return null;
}

pub fn visibleMessageCount(messages: []const widget_types.Message) usize {
    var count: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
        count += 1;
    }
    return count;
}

// --- Diff/tool helpers ---

pub fn isDiffRenderableTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit");
}

pub fn extractToolDiffText(output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "```diff")) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "@@")) return trimmed;
    return null;
}

pub fn extractToolFilePath(arguments: []const u8) ?[]const u8 {
    inline for (.{ "path", "file_path" }) |key| {
        if (std.mem.indexOf(u8, arguments, std.fmt.comptimePrint("\"{s}\"", .{key}))) |key_index| {
            const colon = std.mem.indexOfPos(u8, arguments, key_index, ":") orelse return null;
            var start = colon + 1;
            while (start < arguments.len and std.ascii.isWhitespace(arguments[start])) : (start += 1) {}
            if (start >= arguments.len or arguments[start] != '"') return null;
            start += 1;
            const end = std.mem.indexOfScalarPos(u8, arguments, start, '"') orelse return null;
            return arguments[start..end];
        }
    }
    return null;
}

// --- Drawing helpers ---

pub fn drawBorder(surface: *vxfw.Surface, style: vaxis.Style) void {
    const width = surface.size.width;
    const height = surface.size.height;
    if (width == 0 or height == 0) return;

    const horizontal: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style };
    const vertical: vaxis.Cell = .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style };
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    surface.writeCell(0, height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(width - 1, height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });

    if (width > 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), 0, horizontal);
            surface.writeCell(@intCast(col), height - 1, horizontal);
        }
    }
    if (height > 2) {
        for (1..height - 1) |row| {
            surface.writeCell(0, @intCast(row), vertical);
            surface.writeCell(width - 1, @intCast(row), vertical);
        }
    }
}

pub fn repeated(allocator: std.mem.Allocator, token: []const u8, count: u16) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try buffer.ensureTotalCapacity(allocator, token.len * count);
    for (0..count) |_| {
        try buffer.appendSlice(allocator, token);
    }
    return buffer.toOwnedSlice(allocator);
}

/// Wraps a raw surface in a SurfaceWidget so it can be used as a vxfw.Widget child.
pub fn contentSurfaceWidget(allocator: std.mem.Allocator, surface: vxfw.Surface) !vxfw.Widget {
    const SurfaceWidget = struct {
        surface: vxfw.Surface,

        pub fn widget(self: *const @This()) vxfw.Widget {
            return .{
                .userdata = @constCast(self),
                .drawFn = @This().typeErasedDrawFn,
            };
        }

        fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            _ = ctx;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.surface;
        }
    };
    const widget_holder = try allocator.create(SurfaceWidget);
    widget_holder.* = .{ .surface = surface };
    return widget_holder.widget();
}
