const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

/// Widget for displaying source code with line numbers and scroll support.
/// Uses vaxis Cell styling directly (not vxfw Element interface).
pub const CodeViewWidget = struct {
    allocator: std.mem.Allocator,
    /// Source code content (multi-line string)
    content: []const u8,
    /// Display file path in header
    file_path: []const u8,
    /// Current vertical scroll offset (0-based line index)
    scroll_offset: u32,
    /// Line to highlight (1-based, null = none)
    highlight_line: ?u32,
    /// Maximum rendering width in cells
    max_width: u16,
    /// Maximum rendering height in cells
    max_height: u16,

    /// Initialize a new CodeViewWidget.
    /// The content and file_path slices are duplicated.
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) !CodeViewWidget {
        return .{
            .allocator = allocator,
            .content = try allocator.dupe(u8, content),
            .file_path = try allocator.dupe(u8, file_path),
            .scroll_offset = 0,
            .highlight_line = null,
            .max_width = 80,
            .max_height = 24,
        };
    }

    /// Release all allocated memory.
    pub fn deinit(self: *CodeViewWidget) void {
        self.allocator.free(self.content);
        self.allocator.free(self.file_path);
    }

    /// Count total lines in the content.
    pub fn totalLines(self: *const CodeViewWidget) u32 {
        if (self.content.len == 0) return 1;
        var count: u32 = 1;
        for (self.content) |ch| {
            if (ch == '\n') count += 1;
        }
        // If content ends with '\n', don't count an extra empty line
        if (self.content[self.content.len - 1] == '\n') count -|= 1;
        return count;
    }

    /// Scroll up by the given number of lines.
    pub fn scrollUp(self: *CodeViewWidget, lines: u32) void {
        self.scroll_offset = self.scroll_offset -| lines;
    }

    /// Scroll down by the given number of lines, clamped to max.
    pub fn scrollDown(self: *CodeViewWidget, lines: u32) void {
        const max_offset = self.maxScrollOffset();
        self.scroll_offset = @min(self.scroll_offset + lines, max_offset);
    }

    /// Jump to a specific 1-based line number.
    pub fn goToLine(self: *CodeViewWidget, line: u32) void {
        if (line == 0) {
            self.scroll_offset = 0;
            return;
        }
        const total = self.totalLines();
        if (line > total) {
            self.scroll_offset = self.maxScrollOffset();
            return;
        }
        // Center the target line if possible
        const target = line - 1;
        const half_height = self.max_height / 2;
        if (target >= half_height) {
            self.scroll_offset = target - half_height;
        } else {
            self.scroll_offset = 0;
        }
        // Clamp to max
        const max_offset = self.maxScrollOffset();
        self.scroll_offset = @min(self.scroll_offset, max_offset);
    }

    /// Get the maximum scroll offset (total_lines - visible_height).
    fn maxScrollOffset(self: *const CodeViewWidget) u32 {
        const total = self.totalLines();
        return if (total > self.max_height) total - self.max_height else 0;
    }

    /// Render the code view into a vaxis Window using theme colors.
    pub fn render(self: *CodeViewWidget, win: vaxis.Window, theme: *const theme_mod.Theme) void {
        const width = win.width;
        const height = win.height;
        if (width == 0 or height == 0) return;

        // Reserve space: 1 line for header, rest for code
        const code_height: u16 = if (height > 1) @intCast(height - 1) else 0;
        if (code_height == 0) return;

        // Calculate line number column width
        const total = self.totalLines();
        const line_num_width: usize = numDigits(total);
        // gutter: "  " separator between line numbers and code
        const gutter_width = line_num_width + 2;
        const code_area_width = if (width > gutter_width) width - gutter_width else 0;

        // Draw header line: file path and line range
        const visible_start = self.scroll_offset + 1;
        const visible_end = @min(visible_start + code_height - 1, total);
        const header = std.fmt.bufPrint(
            &header_buf,
            " {s}  [{}-{}]",
            .{ self.file_path, visible_start, visible_end },
        ) catch " file";

        const header_style: vaxis.Style = .{
            .fg = theme.dimmed,
            .bold = true,
        };
        win.fill(.{ .style = .{ .bg = theme.code_bg } });

        var header_seg = [_]vaxis.Cell.Segment{.{
            .text = header,
            .style = header_style,
        }};
        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = width },
            .height = .{ .limit = 1 },
        });
        _ = header_win.print(header_seg[0..], .{ .wrap = .grapheme }) catch {};

        // Split content into lines
        var line_iter = std.mem.splitScalar(u8, self.content, '\n');
        var line_idx: u32 = 0;

        // Skip lines before scroll_offset
        while (line_idx < self.scroll_offset) : (line_idx += 1) {
            _ = line_iter.next();
        }

        // Draw visible lines
        var row: u16 = 0;
        while (row < code_height) : (row += 1) {
            const line_text = line_iter.next() orelse break;
            line_idx += 1;
            defer {}

            const is_highlighted = if (self.highlight_line) |hl| hl == line_idx + self.scroll_offset else false;

            const line_num = line_idx + self.scroll_offset;
            const line_style: vaxis.Style = if (is_highlighted)
                .{ .fg = theme.accent, .bg = theme.code_bg, .bold = true }
            else
                .{ .fg = theme.dimmed, .bg = theme.code_bg };

            // Print line number (right-aligned in line_num_width cells)
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "?";
            const padding = if (num_str.len < line_num_width) line_num_width - num_str.len else 0;

            const line_num_win = win.child(.{
                .x_off = 0,
                .y_off = 1 + @as(usize, @intCast(row)),
                .width = .{ .limit = gutter_width },
                .height = .{ .limit = 1 },
            });
            // Pad + number
            var padded: [32]u8 = undefined;
            var pad_idx: usize = 0;
            for (0..padding) |_| {
                if (pad_idx < padded.len) {
                    padded[pad_idx] = ' ';
                    pad_idx += 1;
                }
            }
            for (num_str) |ch| {
                if (pad_idx < padded.len) {
                    padded[pad_idx] = ch;
                    pad_idx += 1;
                }
            }
            const final_num = padded[0..pad_idx];
            var num_seg = [_]vaxis.Cell.Segment{.{
                .text = final_num,
                .style = line_style,
            }};
            _ = line_num_win.print(num_seg[0..], .{ .wrap = .grapheme }) catch {};

            // Print code text
            if (code_area_width > 0) {
                const code_win = win.child(.{
                    .x_off = gutter_width,
                    .y_off = 1 + @as(usize, @intCast(row)),
                    .width = .{ .limit = code_area_width },
                    .height = .{ .limit = 1 },
                });

                const code_style: vaxis.Style = if (is_highlighted)
                    .{ .fg = theme.md_code_fg, .bg = theme.code_bg, .bold = true }
                else
                    .{ .fg = theme.md_code_fg, .bg = theme.code_bg };

                var code_seg = [_]vaxis.Cell.Segment{.{
                    .text = line_text,
                    .style = code_style,
                }};
                _ = code_win.print(code_seg[0..], .{ .wrap = .grapheme }) catch {};
            }
        }
    }
};

var header_buf: [512]u8 = undefined;

/// Count the number of decimal digits needed to represent a positive integer.
fn numDigits(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var val = n;
    while (val > 0) : (count += 1) {
        val /= 10;
    }
    return count;
}

// --- Tests ---

test "CodeViewWidget - init and deinit" {
    const allocator = std.testing.allocator;
    var widget = try CodeViewWidget.init(allocator, "test.zig", "hello\nworld");
    defer widget.deinit();
    try std.testing.expectEqualStrings("test.zig", widget.file_path);
    try std.testing.expectEqualStrings("hello\nworld", widget.content);
    try std.testing.expectEqual(@as(u32, 0), widget.scroll_offset);
}

test "CodeViewWidget - totalLines counts correctly" {
    const allocator = std.testing.allocator;
    {
        var w = try CodeViewWidget.init(allocator, "a.zig", "line1\nline2\nline3");
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 3), w.totalLines());
    }
    {
        var w = try CodeViewWidget.init(allocator, "a.zig", "single");
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 1), w.totalLines());
    }
    {
        var w = try CodeViewWidget.init(allocator, "a.zig", "");
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 1), w.totalLines());
    }
    {
        var w = try CodeViewWidget.init(allocator, "a.zig", "a\nb\n");
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 2), w.totalLines());
    }
}

test "CodeViewWidget - scrollUp clamps to zero" {
    const allocator = std.testing.allocator;
    var w = try CodeViewWidget.init(allocator, "a.zig", "line1\nline2\nline3");
    defer w.deinit();
    w.max_height = 2;
    w.scroll_offset = 0;
    w.scrollUp(5);
    try std.testing.expectEqual(@as(u32, 0), w.scroll_offset);
}

test "CodeViewWidget - scrollDown clamps to max" {
    const allocator = std.testing.allocator;
    var w = try CodeViewWidget.init(allocator, "a.zig", "line1\nline2\nline3\nline4\nline5");
    defer w.deinit();
    w.max_height = 2;
    w.scrollDown(100);
    // max offset = 5 - 2 = 3
    try std.testing.expectEqual(@as(u32, 3), w.scroll_offset);
}

test "CodeViewWidget - goToLine centers the target" {
    const allocator = std.testing.allocator;
    var w = try CodeViewWidget.init(allocator, "a.zig", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
    defer w.deinit();
    w.max_height = 4;
    w.goToLine(7);
    // line 7 (0-based 6), half_height=2, offset = 6-2 = 4
    try std.testing.expectEqual(@as(u32, 4), w.scroll_offset);
}

test "CodeViewWidget - goToLine clamps for first lines" {
    const allocator = std.testing.allocator;
    var w = try CodeViewWidget.init(allocator, "a.zig", "a\nb\nc\nd\ne");
    defer w.deinit();
    w.max_height = 4;
    w.goToLine(1);
    try std.testing.expectEqual(@as(u32, 0), w.scroll_offset);
}

test "CodeViewWidget - goToLine handles out-of-bounds" {
    const allocator = std.testing.allocator;
    var w = try CodeViewWidget.init(allocator, "a.zig", "a\nb\nc");
    defer w.deinit();
    w.max_height = 2;
    w.goToLine(999);
    try std.testing.expectEqual(@as(u32, 1), w.scroll_offset);
}

test "CodeViewWidget - numDigits" {
    try std.testing.expectEqual(@as(usize, 1), numDigits(0));
    try std.testing.expectEqual(@as(usize, 1), numDigits(9));
    try std.testing.expectEqual(@as(usize, 2), numDigits(10));
    try std.testing.expectEqual(@as(usize, 3), numDigits(100));
    try std.testing.expectEqual(@as(usize, 5), numDigits(12345));
}
