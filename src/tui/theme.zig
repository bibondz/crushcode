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
    role_user_icon: vaxis.Color,
    role_assistant_icon: vaxis.Color,
    role_error_icon: vaxis.Color,
    role_tool_icon: vaxis.Color,
    streaming_indicator: vaxis.Color,
    bubble_bg: vaxis.Color,
    bubble_border: vaxis.Color,
    // Markdown colors
    md_default_fg: vaxis.Color,
    md_header_fg: vaxis.Color,
    md_inline_code_fg: vaxis.Color,
    md_code_bg: vaxis.Color,
    md_code_fg: vaxis.Color,
    md_keyword_fg: vaxis.Color,
    md_string_fg: vaxis.Color,
    md_comment_fg: vaxis.Color,
    md_number_fg: vaxis.Color,
    md_blockquote_fg: vaxis.Color,
    md_link_fg: vaxis.Color,
    md_table_border_fg: vaxis.Color,
    md_task_done_fg: vaxis.Color,
    md_task_undone_fg: vaxis.Color,
    // Diff colors
    diff_file_header_fg: vaxis.Color,
    diff_hunk_header_fg: vaxis.Color,
    diff_removed_fg: vaxis.Color,
    diff_added_fg: vaxis.Color,
    diff_context_fg: vaxis.Color,
    // Setup colors
    setup_selected_fg: vaxis.Color,
    setup_text_fg: vaxis.Color,
    setup_dim_fg: vaxis.Color,
    setup_success_fg: vaxis.Color,
    setup_error_fg: vaxis.Color,
    // Spinner colors
    spinner_stalled_fg: vaxis.Color,
    spinner_g1: vaxis.Color,
    spinner_g2: vaxis.Color,
    spinner_g3: vaxis.Color,
    spinner_g4: vaxis.Color,
    spinner_g5: vaxis.Color,
    spinner_g6: vaxis.Color,
    spinner_g7: vaxis.Color,
    // Toast colors
    toast_msg_fg: vaxis.Color,
    toast_info_bg: vaxis.Color,
    toast_success_bg: vaxis.Color,
    toast_warning_bg: vaxis.Color,
    toast_error_bg: vaxis.Color,
    toast_warning_fg: vaxis.Color,
};

pub const themes = [_]Theme{
    Theme{
        .name = "dark",
        .user_fg = .{ .index = 14 },
        .user_label = "User",
        .assistant_fg = .{ .index = 10 },
        .assistant_label = "Assistant",
        .error_fg = .{ .index = 9 },
        .header_bg = .{ .index = 236 },
        .header_fg = .{ .index = 15 },
        .status_bg = .{ .index = 236 },
        .status_fg = .{ .index = 248 },
        .code_bg = .{ .index = 236 },
        .border = .{ .index = 240 },
        .dimmed = .{ .index = 243 },
        .accent = .{ .index = 14 },
        .tool_success = .{ .index = 10 },
        .tool_error = .{ .index = 9 },
        .tool_pending = .{ .index = 11 },
        .role_user_icon = .{ .index = 14 },
        .role_assistant_icon = .{ .index = 10 },
        .role_error_icon = .{ .index = 9 },
        .role_tool_icon = .{ .index = 11 },
        .streaming_indicator = .{ .index = 14 },
        .bubble_bg = .{ .index = 235 },
        .bubble_border = .{ .index = 242 },
        // Markdown colors
        .md_default_fg = .{ .index = 252 },
        .md_header_fg = .{ .index = 14 },
        .md_inline_code_fg = .{ .index = 11 },
        .md_code_bg = .{ .index = 236 },
        .md_code_fg = .{ .index = 252 },
        .md_keyword_fg = .{ .index = 13 },
        .md_string_fg = .{ .index = 10 },
        .md_comment_fg = .{ .index = 243 },
        .md_number_fg = .{ .index = 11 },
        .md_blockquote_fg = .{ .index = 243 },
        .md_link_fg = .{ .index = 14 },
        .md_table_border_fg = .{ .index = 240 },
        .md_task_done_fg = .{ .index = 10 },
        .md_task_undone_fg = .{ .index = 243 },
        // Diff colors
        .diff_file_header_fg = .{ .index = 14 },
        .diff_hunk_header_fg = .{ .index = 11 },
        .diff_removed_fg = .{ .index = 9 },
        .diff_added_fg = .{ .index = 10 },
        .diff_context_fg = .{ .index = 243 },
        // Setup colors
        .setup_selected_fg = .{ .index = 39 },
        .setup_text_fg = .{ .index = 15 },
        .setup_dim_fg = .{ .index = 8 },
        .setup_success_fg = .{ .index = 10 },
        .setup_error_fg = .{ .index = 1 },
        // Spinner colors
        .spinner_stalled_fg = .{ .index = 9 },
        .spinner_g1 = .{ .index = 12 },
        .spinner_g2 = .{ .index = 14 },
        .spinner_g3 = .{ .index = 13 },
        .spinner_g4 = .{ .index = 11 },
        .spinner_g5 = .{ .index = 10 },
        .spinner_g6 = .{ .index = 14 },
        .spinner_g7 = .{ .index = 12 },
        // Toast colors
        .toast_msg_fg = .{ .index = 15 },
        .toast_info_bg = .{ .rgb = .{ 0x1a, 0x2a, 0x3a } },
        .toast_success_bg = .{ .rgb = .{ 0x1a, 0x2e, 0x1a } },
        .toast_warning_bg = .{ .rgb = .{ 0x2e, 0x2a, 0x1a } },
        .toast_error_bg = .{ .rgb = .{ 0x2e, 0x1a, 0x1a } },
        .toast_warning_fg = .{ .rgb = .{ 0xFF, 0xAA, 0x00 } },
    },
    Theme{
        .name = "light",
        .user_label = "User",
        .user_fg = .{ .index = 6 },
        .assistant_fg = .{ .index = 2 },
        .assistant_label = "Assistant",
        .error_fg = .{ .index = 1 },
        .header_bg = .{ .index = 254 },
        .header_fg = .{ .index = 0 },
        .status_bg = .{ .index = 254 },
        .status_fg = .{ .index = 7 },
        .code_bg = .{ .index = 255 },
        .border = .{ .index = 7 },
        .dimmed = .{ .index = 243 },
        .accent = .{ .index = 6 },
        .tool_success = .{ .index = 2 },
        .tool_error = .{ .index = 1 },
        .tool_pending = .{ .index = 3 },
        .role_user_icon = .{ .index = 6 },
        .role_assistant_icon = .{ .index = 2 },
        .role_error_icon = .{ .index = 1 },
        .role_tool_icon = .{ .index = 3 },
        .streaming_indicator = .{ .index = 6 },
        .bubble_bg = .{ .index = 253 },
        .bubble_border = .{ .index = 249 },
        // Markdown colors
        .md_default_fg = .{ .index = 0 },
        .md_header_fg = .{ .index = 6 },
        .md_inline_code_fg = .{ .index = 3 },
        .md_code_bg = .{ .index = 255 },
        .md_code_fg = .{ .index = 0 },
        .md_keyword_fg = .{ .index = 5 },
        .md_string_fg = .{ .index = 2 },
        .md_comment_fg = .{ .index = 243 },
        .md_number_fg = .{ .index = 3 },
        .md_blockquote_fg = .{ .index = 243 },
        .md_link_fg = .{ .index = 6 },
        .md_table_border_fg = .{ .index = 7 },
        .md_task_done_fg = .{ .index = 2 },
        .md_task_undone_fg = .{ .index = 243 },
        // Diff colors
        .diff_file_header_fg = .{ .index = 6 },
        .diff_hunk_header_fg = .{ .index = 3 },
        .diff_removed_fg = .{ .index = 1 },
        .diff_added_fg = .{ .index = 2 },
        .diff_context_fg = .{ .index = 243 },
        // Setup colors
        .setup_selected_fg = .{ .index = 26 },
        .setup_text_fg = .{ .index = 0 },
        .setup_dim_fg = .{ .index = 243 },
        .setup_success_fg = .{ .index = 2 },
        .setup_error_fg = .{ .index = 1 },
        // Spinner colors
        .spinner_stalled_fg = .{ .index = 1 },
        .spinner_g1 = .{ .index = 6 },
        .spinner_g2 = .{ .index = 4 },
        .spinner_g3 = .{ .index = 5 },
        .spinner_g4 = .{ .index = 3 },
        .spinner_g5 = .{ .index = 2 },
        .spinner_g6 = .{ .index = 4 },
        .spinner_g7 = .{ .index = 6 },
        // Toast colors
        .toast_msg_fg = .{ .index = 0 },
        .toast_info_bg = .{ .rgb = .{ 0xd0, 0xe0, 0xf0 } },
        .toast_success_bg = .{ .rgb = .{ 0xd0, 0xf0, 0xd0 } },
        .toast_warning_bg = .{ .rgb = .{ 0xf0, 0xe8, 0xd0 } },
        .toast_error_bg = .{ .rgb = .{ 0xf0, 0xd0, 0xd0 } },
        .toast_warning_fg = .{ .rgb = .{ 0x99, 0x66, 0x00 } },
    },
    Theme{
        .name = "mono",
        .user_fg = .default,
        .user_label = "User",
        .assistant_fg = .default,
        .assistant_label = "Assistant",
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
        .role_user_icon = .default,
        .role_assistant_icon = .default,
        .role_error_icon = .default,
        .role_tool_icon = .default,
        .streaming_indicator = .default,
        .bubble_bg = .default,
        .bubble_border = .default,
        // Markdown colors
        .md_default_fg = .default,
        .md_header_fg = .default,
        .md_inline_code_fg = .default,
        .md_code_bg = .default,
        .md_code_fg = .default,
        .md_keyword_fg = .default,
        .md_string_fg = .default,
        .md_comment_fg = .default,
        .md_number_fg = .default,
        .md_blockquote_fg = .default,
        .md_link_fg = .default,
        .md_table_border_fg = .default,
        .md_task_done_fg = .default,
        .md_task_undone_fg = .default,
        // Diff colors
        .diff_file_header_fg = .default,
        .diff_hunk_header_fg = .default,
        .diff_removed_fg = .default,
        .diff_added_fg = .default,
        .diff_context_fg = .default,
        // Setup colors
        .setup_selected_fg = .default,
        .setup_text_fg = .default,
        .setup_dim_fg = .default,
        .setup_success_fg = .default,
        .setup_error_fg = .default,
        // Spinner colors
        .spinner_stalled_fg = .default,
        .spinner_g1 = .default,
        .spinner_g2 = .default,
        .spinner_g3 = .default,
        .spinner_g4 = .default,
        .spinner_g5 = .default,
        .spinner_g6 = .default,
        .spinner_g7 = .default,
        // Toast colors
        .toast_msg_fg = .default,
        .toast_info_bg = .default,
        .toast_success_bg = .default,
        .toast_warning_bg = .default,
        .toast_error_bg = .default,
        .toast_warning_fg = .default,
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

// --- Tests ---

test "Theme - getTheme returns dark by name" {
    const t = getTheme("dark").?;
    try std.testing.expectEqualStrings("dark", t.name);
}

test "Theme - getTheme returns light by name" {
    const t = getTheme("light").?;
    try std.testing.expectEqualStrings("light", t.name);
}

test "Theme - getTheme returns mono by name" {
    const t = getTheme("mono").?;
    try std.testing.expectEqualStrings("mono", t.name);
}

test "Theme - getTheme returns null for unknown" {
    try std.testing.expect(getTheme("solarized") == null);
    try std.testing.expect(getTheme("") == null);
}

test "Theme - defaultTheme is dark" {
    const dt = defaultTheme();
    try std.testing.expectEqualStrings("dark", dt.name);
}

test "Theme - themes array has 3 entries" {
    try std.testing.expectEqual(@as(usize, 3), themes.len);
}

test "Theme - all themes have unique names" {
    for (&themes, 0..) |*t, i| {
        for (&themes, 0..) |*u, j| {
            if (i != j) {
                try std.testing.expect(!std.mem.eql(u8, t.name, u.name));
            }
        }
    }
}

test "Theme - dark theme has distinct user and assistant colors" {
    const t = getTheme("dark").?;
    try std.testing.expect(!std.meta.eql(t.user_fg, t.assistant_fg));
}

test "Theme - light theme has distinct user and assistant colors" {
    const t = getTheme("light").?;
    try std.testing.expect(!std.meta.eql(t.user_fg, t.assistant_fg));
}

test "Theme - mono theme uses default colors" {
    const t = getTheme("mono").?;
    try std.testing.expect(std.meta.eql(t.user_fg, vaxis.Color.default));
    try std.testing.expect(std.meta.eql(t.assistant_fg, vaxis.Color.default));
    try std.testing.expect(std.meta.eql(t.error_fg, vaxis.Color.default));
}

test "Theme - all themes have non-empty labels" {
    for (&themes) |t| {
        try std.testing.expect(t.name.len > 0);
        try std.testing.expect(t.user_label.len > 0);
        try std.testing.expect(t.assistant_label.len > 0);
    }
}
