const std = @import("std");
const vaxis = @import("vaxis");

pub const Theme = struct {
    name: []const u8,
    user_fg: vaxis.Color,
    user_label: []const u8,
    assistant_fg: vaxis.Color,
    assistant_label: []const u8,
    error_fg: vaxis.Color,
    header_bg: vaxis.Color,
    header_fg: vaxis.Color,
    status_bg: vaxis.Color,
    status_fg: vaxis.Color,
    code_bg: vaxis.Color,
    border: vaxis.Color,
    dimmed: vaxis.Color,
    accent: vaxis.Color,
    tool_success: vaxis.Color,
    tool_error: vaxis.Color,
    tool_pending: vaxis.Color,
};

pub const themes = [_]Theme{
    Theme{
        .name = "dark",
        .user_fg = .{ .index = 14 },
        .user_label = "You",
        .assistant_fg = .{ .index = 10 },
        .assistant_label = "✦",
        .error_fg = .{ .index = 9 },
        .header_bg = .{ .index = 236 },
        .header_fg = .{ .index = 15 },
        .status_bg = .{ .index = 236 },
        .status_fg = .{ .index = 8 },
        .code_bg = .{ .index = 236 },
        .border = .{ .index = 8 },
        .dimmed = .{ .index = 8 },
        .accent = .{ .index = 14 },
        .tool_success = .{ .index = 10 },
        .tool_error = .{ .index = 9 },
        .tool_pending = .{ .index = 11 },
    },
    Theme{
        .name = "light",
        .user_fg = .{ .index = 6 },
        .user_label = "You",
        .assistant_fg = .{ .index = 2 },
        .assistant_label = "✦",
        .error_fg = .{ .index = 1 },
        .header_bg = .{ .index = 254 },
        .header_fg = .{ .index = 0 },
        .status_bg = .{ .index = 254 },
        .status_fg = .{ .index = 7 },
        .code_bg = .{ .index = 255 },
        .border = .{ .index = 7 },
        .dimmed = .{ .index = 7 },
        .accent = .{ .index = 6 },
        .tool_success = .{ .index = 2 },
        .tool_error = .{ .index = 1 },
        .tool_pending = .{ .index = 3 },
    },
    Theme{
        .name = "mono",
        .user_fg = .default,
        .user_label = "You",
        .assistant_fg = .default,
        .assistant_label = "✦",
        .error_fg = .default,
        .header_bg = .default,
        .header_fg = .default,
        .status_bg = .default,
        .status_fg = .default,
        .code_bg = .default,
        .border = .default,
        .dimmed = .default,
        .accent = .default,
        .tool_success = .default,
        .tool_error = .default,
        .tool_pending = .default,
    },
};

pub fn getTheme(name: []const u8) ?*const Theme {
    for (&themes) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

pub fn defaultTheme() *const Theme {
    return &themes[0];
}
