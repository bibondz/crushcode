const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Scrollable text panel for displaying long content with scroll support.
/// Plain text output, no vaxis dependency.
pub const ScrollPanel = struct {
    allocator: std.mem.Allocator,
    /// Lines split from content
    lines: array_list_compat.ArrayList([]const u8),
    /// Current scroll offset (0-based line index of top visible line)
    scroll_offset: u32,
    /// Number of visible lines in the viewport
    visible_height: u16,

    /// Initialize an empty ScrollPanel.
    pub fn init(allocator: std.mem.Allocator) ScrollPanel {
        return .{
            .allocator = allocator,
            .lines = array_list_compat.ArrayList([]const u8).init(allocator),
            .scroll_offset = 0,
            .visible_height = 24,
        };
    }

    /// Release all allocated memory.
    pub fn deinit(self: *ScrollPanel) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }

    /// Set the panel content by splitting text into lines.
    /// Replaces any existing content.
    pub fn setContent(self: *ScrollPanel, text: []const u8) !void {
        // Clear existing lines
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.clearRetainingCapacity();
        self.scroll_offset = 0;

        if (text.len == 0) {
            try self.lines.append(try self.allocator.dupe(u8, ""));
            return;
        }

        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            const dup = try self.allocator.dupe(u8, line);
            try self.lines.append(dup);
        }
    }

    /// Render the visible window of lines as a single string.
    /// Each line is truncated to max_width characters.
    pub fn render(self: *ScrollPanel, max_width: u16, max_height: u16) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const total = self.totalLines();
        if (total == 0) return self.allocator.dupe(u8, "");

        const visible = @min(@as(u32, max_height), total -| self.scroll_offset);

        var i: u32 = 0;
        while (i < visible) : (i += 1) {
            const line_idx = self.scroll_offset + i;
            if (line_idx >= total) break;

            const line = self.lines.items[@intCast(line_idx)];
            const truncated = if (line.len > max_width) line[0..max_width] else line;

            if (i > 0) try buf.append('\n');
            try buf.appendSlice(truncated);
        }

        return buf.toOwnedSlice();
    }

    /// Scroll up by the given number of lines.
    pub fn scrollUp(self: *ScrollPanel, lines: u32) void {
        self.scroll_offset = self.scroll_offset -| lines;
    }

    /// Scroll down by the given number of lines, clamped to max.
    pub fn scrollDown(self: *ScrollPanel, lines: u32) void {
        const max_offset = self.maxScrollOffset();
        self.scroll_offset = @min(self.scroll_offset + lines, max_offset);
    }

    /// Scroll to the top of the content.
    pub fn scrollToTop(self: *ScrollPanel) void {
        self.scroll_offset = 0;
    }

    /// Scroll to the bottom of the content.
    pub fn scrollToBottom(self: *ScrollPanel) void {
        self.scroll_offset = self.maxScrollOffset();
    }

    /// Return the total number of lines.
    pub fn totalLines(self: *const ScrollPanel) u32 {
        return @intCast(self.lines.items.len);
    }

    /// Return scroll position as a percentage: 0.0 at top, 1.0 at bottom.
    pub fn scrollPercent(self: *const ScrollPanel) f64 {
        const total = self.totalLines();
        if (total == 0) return 0.0;
        const max_offset = if (total > self.visible_height) total - self.visible_height else 0;
        if (max_offset == 0) return 0.0;
        return @as(f64, @floatFromInt(self.scroll_offset)) / @as(f64, @floatFromInt(max_offset));
    }

    /// Calculate maximum scroll offset.
    fn maxScrollOffset(self: *const ScrollPanel) u32 {
        const total = self.totalLines();
        return if (total > self.visible_height) total - self.visible_height else 0;
    }
};

// --- Tests ---

test "ScrollPanel - init and deinit" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();
    try std.testing.expectEqual(@as(u32, 0), panel.totalLines());
    try std.testing.expectEqual(@as(u32, 0), panel.scroll_offset);
}

test "ScrollPanel - setContent splits lines" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("line1\nline2\nline3");
    try std.testing.expectEqual(@as(u32, 3), panel.totalLines());
    try std.testing.expectEqualStrings("line1", panel.lines.items[0]);
    try std.testing.expectEqualStrings("line2", panel.lines.items[1]);
    try std.testing.expectEqualStrings("line3", panel.lines.items[2]);
}

test "ScrollPanel - setContent handles empty string" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("");
    try std.testing.expectEqual(@as(u32, 1), panel.totalLines());
    try std.testing.expectEqualStrings("", panel.lines.items[0]);
}

test "ScrollPanel - setContent replaces previous content" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("first");
    try std.testing.expectEqual(@as(u32, 1), panel.totalLines());

    try panel.setContent("a\nb\nc");
    try std.testing.expectEqual(@as(u32, 3), panel.totalLines());
    try std.testing.expectEqual(@as(u32, 0), panel.scroll_offset);
}

test "ScrollPanel - scrollUp clamps to zero" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("a\nb\nc\nd\ne");
    panel.visible_height = 2;
    panel.scroll_offset = 1;
    panel.scrollUp(5);
    try std.testing.expectEqual(@as(u32, 0), panel.scroll_offset);
}

test "ScrollPanel - scrollDown clamps to max" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("a\nb\nc\nd\ne");
    panel.visible_height = 2;
    panel.scrollDown(100);
    // max_offset = 5 - 2 = 3
    try std.testing.expectEqual(@as(u32, 3), panel.scroll_offset);
}

test "ScrollPanel - scrollToTop and scrollToBottom" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("a\nb\nc\nd\ne");
    panel.visible_height = 2;
    panel.scrollDown(2);
    try std.testing.expectEqual(@as(u32, 2), panel.scroll_offset);

    panel.scrollToTop();
    try std.testing.expectEqual(@as(u32, 0), panel.scroll_offset);

    panel.scrollToBottom();
    try std.testing.expectEqual(@as(u32, 3), panel.scroll_offset);
}

test "ScrollPanel - scrollPercent" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("a\nb\nc\nd\ne");
    panel.visible_height = 2;

    // At top: 0.0
    try std.testing.expectEqual(@as(f64, 0.0), panel.scrollPercent());

    // At bottom: 1.0 (max_offset = 3, scroll_offset = 3)
    panel.scrollToBottom();
    try std.testing.expectEqual(@as(f64, 1.0), panel.scrollPercent());

    // Middle: scroll_offset = 1 → 1/3 ≈ 0.333
    panel.scroll_offset = 1;
    const pct = panel.scrollPercent();
    try std.testing.expect(pct > 0.3 and pct < 0.4);
}

test "ScrollPanel - scrollPercent with empty content" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try std.testing.expectEqual(@as(f64, 0.0), panel.scrollPercent());
}

test "ScrollPanel - scrollPercent when content fits viewport" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("a\nb");
    panel.visible_height = 10;
    try std.testing.expectEqual(@as(f64, 0.0), panel.scrollPercent());
}

test "ScrollPanel - render returns visible window" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("line1\nline2\nline3\nline4\nline5");
    panel.visible_height = 3;

    const output = try panel.render(80, 3);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("line1\nline2\nline3", output);
}

test "ScrollPanel - render with scroll offset" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("line1\nline2\nline3\nline4\nline5");
    panel.visible_height = 2;
    panel.scroll_offset = 2;

    const output = try panel.render(80, 2);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("line3\nline4", output);
}

test "ScrollPanel - render truncates long lines" {
    const allocator = std.testing.allocator;
    var panel = ScrollPanel.init(allocator);
    defer panel.deinit();

    try panel.setContent("abcdefghijklmnopqrstuvwxyz");
    const output = try panel.render(5, 1);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("abcde", output);
}
