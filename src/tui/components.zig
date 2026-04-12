const std = @import("std");
const array_list_compat = @import("array_list_compat");
const screen = @import("screen.zig");
const layout = @import("layout.zig");

const Cell = screen.Cell;
const Color = screen.Color;
const Style = screen.Style;
const Rect = layout.Rect;
const NamedColor = screen.NamedColor;

// ============================================================================
// Scrollback — ring buffer of styled lines with scroll offset
// ============================================================================

/// A single styled rune: one codepoint + visual attributes.
pub const Rune = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},

    pub fn eql(a: Rune, b: Rune) bool {
        if (a.char != b.char) return false;
        if (!screen.colorEql(a.fg, b.fg)) return false;
        if (!screen.colorEql(a.bg, b.bg)) return false;
        return @as(u8, @bitCast(a.style)) == @as(u8, @bitCast(b.style));
    }
};

/// A line of styled runes.
pub const Line = struct {
    runes: []Rune,

    pub fn init(allocator: std.mem.Allocator, width: usize) !Line {
        const runes = try allocator.alloc(Rune, width);
        @memset(runes, .{});
        return .{ .runes = runes };
    }

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        allocator.free(self.runes);
    }
};

/// Scrollback buffer — stores up to `max_lines` lines, each up to `line_width` runes.
/// Supports scrolling and renders into a Screen region.
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    /// Maximum rune width per line.
    line_width: usize,
    /// Ring buffer storage.
    lines: array_list_compat.ArrayList(Line),
    /// Maximum stored lines before old ones are recycled.
    max_lines: usize,
    /// Scroll offset from the bottom (0 = latest).
    scroll_offset: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, line_width: usize, max_lines: usize) !Self {
        return .{
            .allocator = allocator,
            .line_width = line_width,
            .lines = array_list_compat.ArrayList(Line).init(allocator),
            .max_lines = max_lines,
            .scroll_offset = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit();
    }

    /// Number of lines currently stored.
    pub fn count(self: *const Self) usize {
        return self.lines.items.len;
    }

    /// Append a new blank line. Returns the new line for writing.
    pub fn appendLine(self: *Self) !*Line {
        // Recycle oldest line if at capacity.
        if (self.lines.items.len >= self.max_lines) {
            const old = self.lines.orderedRemove(0);
            @memset(old.runes, .{});
            try self.lines.append(old);
            return &self.lines.items[self.lines.items.len - 1];
        }
        const line = try Line.init(self.allocator, self.line_width);
        try self.lines.append(line);
        return &self.lines.items[self.lines.items.len - 1];
    }

    /// Write UTF-8 text at (col, line_index) with the given style.
    /// `line_index` is 0-based from the first stored line.
    pub fn writeAt(self: *Self, line_index: usize, col: usize, text: []const u8, fg: Color, bg: Color, s: Style) void {
        if (line_index >= self.lines.items.len) return;
        const runes = self.lines.items[line_index].runes;
        var c: usize = col;
        const view = std.unicode.Utf8View.initUnchecked(text);
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (c >= runes.len) break;
            runes[c] = .{ .char = cp, .fg = fg, .bg = bg, .style = s };
            c += 1;
        }
    }

    /// Convenience: append a new line with text and return.
    pub fn pushLine(self: *Self, text: []const u8, fg: Color, bg: Color, s: Style) !void {
        const line = try self.appendLine();
        const runes = line.runes;
        var c: usize = 0;
        const view = std.unicode.Utf8View.initUnchecked(text);
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (c >= runes.len) break;
            runes[c] = .{ .char = cp, .fg = fg, .bg = bg, .style = s };
            c += 1;
        }
    }

    /// Scroll up (towards older lines) by `n` lines.
    pub fn scrollUp(self: *Self, n: usize) void {
        const max_offset = self.lines.items.len;
        self.scroll_offset = @min(self.scroll_offset + n, max_offset);
    }

    /// Scroll down (towards newer lines) by `n` lines.
    pub fn scrollDown(self: *Self, n: usize) void {
        self.scroll_offset -|= n;
    }

    /// Scroll to the very bottom (latest content).
    pub fn scrollToBottom(self: *Self) void {
        self.scroll_offset = 0;
    }

    /// Remove and return the last line (for replacing placeholder messages)
    pub fn popLastLine(self: *Self) ?Line {
        if (self.lines.items.len == 0) return null;
        return self.lines.pop();
    }

    /// Render the visible portion into the Screen at the given rect.
    /// Only the rows that fit within `rect.h` are rendered.
    pub fn render(self: *const Self, scr: *screen.Screen, rect: Rect) void {
        if (rect.isEmpty()) return;
        if (self.lines.items.len == 0) return;

        const total = self.lines.items.len;
        // Bottom line index (most recent).
        const bottom: usize = if (self.scroll_offset < total) total - 1 - self.scroll_offset else 0;
        // Top visible line.
        const visible_rows: usize = @min(@as(usize, rect.h), bottom + 1);
        const top: usize = bottom + 1 - visible_rows;

        var screen_row: u16 = rect.y;
        var li: usize = top;
        while (li <= bottom and screen_row < rect.y + rect.h) : ({
            li += 1;
            screen_row += 1;
        }) {
            const runes = self.lines.items[li].runes;
            for (runes, 0..) |rune, col| {
                if (col >= rect.w) break;
                scr.setCell(rect.x + @as(u16, @intCast(col)), screen_row, .{
                    .char = rune.char,
                    .fg = rune.fg,
                    .bg = rune.bg,
                    .style = rune.style,
                });
            }
        }
    }
};

// ============================================================================
// InputBox — single-line editable text field with cursor
// ============================================================================

pub const InputBox = struct {
    allocator: std.mem.Allocator,
    /// UTF-8 text buffer.
    text: array_list_compat.ArrayList(u8),
    /// Cursor position as byte offset into `text`.
    cursor: usize = 0,
    /// Horizontal scroll offset for long text.
    view_offset: usize = 0,
    /// Visual attributes for the text.
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},
    /// Placeholder text shown when empty.
    placeholder: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .text = array_list_compat.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.text.deinit();
    }

    /// Current text content.
    pub fn getText(self: *const Self) []const u8 {
        return self.text.items;
    }

    /// Is the input empty?
    pub fn isEmpty(self: *const Self) bool {
        return self.text.items.len == 0;
    }

    /// Insert a byte at the cursor position.
    pub fn insertByte(self: *Self, byte: u8) !void {
        try self.text.insert(byte, self.cursor);
        self.cursor += 1;
    }

    /// Insert a UTF-8 string at the cursor position.
    pub fn insert(self: *Self, bytes: []const u8) !void {
        for (bytes) |b| {
            try self.insertByte(b);
        }
    }

    /// Delete the character before the cursor (backspace).
    pub fn backspace(self: *Self) void {
        if (self.cursor == 0) return;
        // Find start of previous codepoint.
        var i: usize = self.cursor - 1;
        while (i > 0 and self.text.items[i] & 0xC0 == 0x80) : (i -= 1) {}
        const end = self.cursor;
        self.cursor = i;
        _ = self.text.orderedRemove(i);
        if (i + 1 < end) {
            // Multi-byte: remove remaining bytes
            var j: usize = i + 1;
            while (j < self.text.items.len and j < end - 1) {
                _ = self.text.orderedRemove(i + 1);
                j += 1;
            }
        }
    }

    /// Delete the character at the cursor (delete key).
    pub fn delete(self: *Self) void {
        if (self.cursor >= self.text.items.len) return;
        _ = self.text.orderedRemove(self.cursor);
        // Remove continuation bytes.
        while (self.cursor < self.text.items.len and self.text.items[self.cursor] & 0xC0 == 0x80) {
            _ = self.text.orderedRemove(self.cursor);
        }
    }

    /// Move cursor left by one codepoint.
    pub fn moveLeft(self: *Self) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and self.text.items[self.cursor] & 0xC0 == 0x80) {
            self.cursor -= 1;
        }
    }

    /// Move cursor right by one codepoint.
    pub fn moveRight(self: *Self) void {
        if (self.cursor >= self.text.items.len) return;
        self.cursor += 1;
        while (self.cursor < self.text.items.len and self.text.items[self.cursor] & 0xC0 == 0x80) {
            self.cursor += 1;
        }
    }

    /// Move cursor to start.
    pub fn moveHome(self: *Self) void {
        self.cursor = 0;
    }

    /// Move cursor to end.
    pub fn moveEnd(self: *Self) void {
        self.cursor = self.text.items.len;
    }

    /// Clear all text and reset cursor.
    pub fn clear(self: *Self) void {
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.view_offset = 0;
    }

    /// Render the input box into the Screen at the given rect.
    /// Shows exactly one line; view_offset auto-adjusts to keep cursor visible.
    pub fn render(self: *Self, scr: *screen.Screen, rect: Rect) void {
        if (rect.isEmpty()) return;

        const w: usize = rect.w;

        // Show placeholder if empty.
        if (self.text.items.len == 0 and self.placeholder.len > 0) {
            scr.printAt(rect.x, rect.y, self.placeholder, .{
                .fg = .{ .named = .bright_black },
                .bg = self.bg,
                .style = self.style,
            });
            // Cursor at start
            scr.setCell(rect.x, rect.y, .{
                .char = ' ',
                .bg = self.bg,
                .style = .{ .reverse = true },
            });
            return;
        }

        // Auto-scroll to keep cursor visible.
        const cursor_col = self.codepointCountBefore(self.cursor);
        if (cursor_col < self.view_offset) {
            self.view_offset = cursor_col;
        } else if (cursor_col >= self.view_offset + w) {
            self.view_offset = cursor_col - w + 1;
        }

        // Render visible slice.
        var col: usize = 0;
        var byte_idx: usize = 0;
        const text = self.text.items;
        var cp_idx: usize = 0;

        while (byte_idx < text.len and col < w) {
            // Skip codepoints before view_offset.
            if (cp_idx < self.view_offset) {
                // Advance past this codepoint.
                byte_idx += 1;
                while (byte_idx < text.len and text[byte_idx] & 0xC0 == 0x80) {
                    byte_idx += 1;
                }
                cp_idx += 1;
                continue;
            }

            const cp = self.decodeCodepoint(text, byte_idx);
            const is_cursor = (byte_idx == self.cursor);

            if (is_cursor) {
                scr.setCell(rect.x + @as(u16, @intCast(col)), rect.y, .{
                    .char = if (cp) |c| c else ' ',
                    .fg = self.fg,
                    .bg = .{ .named = .white },
                    .style = .{ .reverse = true },
                });
            } else {
                scr.setCell(rect.x + @as(u16, @intCast(col)), rect.y, .{
                    .char = cp orelse ' ',
                    .fg = self.fg,
                    .bg = self.bg,
                    .style = self.style,
                });
            }

            byte_idx += 1;
            while (byte_idx < text.len and text[byte_idx] & 0xC0 == 0x80) {
                byte_idx += 1;
            }
            cp_idx += 1;
            col += 1;
        }

        // Cursor at end of text (past last char).
        if (self.cursor >= text.len and col < w) {
            scr.setCell(rect.x + @as(u16, @intCast(col)), rect.y, .{
                .char = ' ',
                .bg = .{ .named = .white },
                .style = .{ .reverse = true },
            });
        }
    }

    /// Count codepoints before byte offset.
    fn codepointCountBefore(self: *const Self, byte_offset: usize) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < byte_offset and i < self.text.items.len) {
            count += 1;
            i += 1;
            while (i < self.text.items.len and self.text.items[i] & 0xC0 == 0x80) {
                i += 1;
            }
        }
        return count;
    }

    /// Decode a single codepoint starting at byte offset.
    fn decodeCodepoint(self: *const Self, text: []const u8, offset: usize) ?u21 {
        _ = self;
        if (offset >= text.len) return null;
        if (text[offset] & 0x80 == 0) return @as(u21, text[offset]);
        // Multi-byte: use std.unicode
        return std.unicode.utf8Decode(text[offset..]) catch null;
    }
};

// ============================================================================
// Spinner — animated indicator with rotating frames
// ============================================================================

pub const Spinner = struct {
    /// A simple dotted spinner.
    pub const dots = [_][]const u8{ ".", "o", "O", "o" };

    /// A classic braille spinner.
    pub const classic = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    /// An arrow rotation spinner.
    pub const arrows = [_][]const u8{ "|", "/", "-", "\\" };

    frames: []const []const u8,
    frame_index: usize = 0,
    fg: Color = .default,
    style: Style = .{},

    const Self = @This();

    pub fn init(frames: []const []const u8) Self {
        return .{ .frames = frames };
    }

    /// Advance to next frame.
    pub fn tick(self: *Self) void {
        self.frame_index = (self.frame_index + 1) % self.frames.len;
    }

    /// Get current frame text.
    pub fn currentText(self: *const Self) []const u8 {
        return self.frames[self.frame_index];
    }

    /// Render the spinner at a single cell position.
    pub fn render(self: *Self, scr: *screen.Screen, x: u16, y: u16) void {
        const text = self.currentText();
        const view = std.unicode.Utf8View.initUnchecked(text);
        var iter = view.iterator();
        var col: u16 = 0;
        while (iter.nextCodepoint()) |cp| {
            scr.setCell(x + col, y, .{
                .char = cp,
                .fg = self.fg,
                .style = self.style,
            });
            col += 1;
        }
    }

    /// Reset to first frame.
    pub fn reset(self: *Self) void {
        self.frame_index = 0;
    }
};

// ============================================================================
// ProgressBar — horizontal fill bar with optional label
// ============================================================================

pub const ProgressBar = struct {
    /// Fill ratio 0.0–1.0.
    ratio: f32 = 0.0,
    /// Character used for filled portion.
    fill_char: u21 = '█',
    /// Character used for empty portion.
    empty_char: u21 = '░',
    /// Optional label rendered before the bar.
    label: []const u8 = "",
    /// Label + bar separator.
    separator: []const u8 = " ",
    fg: Color = .{ .named = .green },
    bg: Color = .default,
    empty_fg: Color = .{ .named = .bright_black },
    style: Style = .{},

    const Self = @This();

    pub fn init(ratio: f32) Self {
        return .{ .ratio = @max(0.0, @min(1.0, ratio)) };
    }

    /// Render the progress bar into the Screen at the given rect (single row).
    pub fn render(self: *const Self, scr: *screen.Screen, rect: Rect) void {
        if (rect.isEmpty()) return;

        var col: u16 = 0;

        // Draw label if present.
        if (self.label.len > 0) {
            scr.printAt(rect.x + col, rect.y, self.label, .{
                .fg = .default,
                .bg = self.bg,
                .style = self.style,
            });
            const view = std.unicode.Utf8View.initUnchecked(self.label);
            var iter = view.iterator();
            while (iter.nextCodepoint()) |_| {
                col += 1;
                if (col >= rect.w) return;
            }
        }

        // Draw separator.
        if (self.separator.len > 0 and col < rect.w) {
            scr.printAt(rect.x + col, rect.y, self.separator, .{
                .fg = .default,
                .bg = self.bg,
            });
            const view = std.unicode.Utf8View.initUnchecked(self.separator);
            var iter = view.iterator();
            while (iter.nextCodepoint()) |_| {
                col += 1;
                if (col >= rect.w) return;
            }
        }

        // Draw bar.
        const bar_width: usize = @as(usize, rect.w) - col;
        if (bar_width == 0) return;
        const fill_count: usize = @intFromFloat(@as(f32, @floatFromInt(bar_width)) * self.ratio);

        for (0..bar_width) |i| {
            const is_filled = i < fill_count;
            scr.setCell(rect.x + col + @as(u16, @intCast(i)), rect.y, .{
                .char = if (is_filled) self.fill_char else self.empty_char,
                .fg = if (is_filled) self.fg else self.empty_fg,
                .bg = self.bg,
                .style = self.style,
            });
        }
    }
};

// ============================================================================
// Markdown — lightweight renderer (bold, italic, code, headers, lists → Runes)
// ============================================================================

/// Inline span style.
const MdStyle = enum { normal, bold, italic, code, bold_italic };

/// Render a markdown string into a Scrollback buffer.
/// Supports: **bold**, *italic*, `code`, # headers, - lists, > blockquotes.
pub fn renderMarkdown(sb: *Scrollback, md: []const u8) !void {
    var pos: usize = 0;
    while (pos < md.len) {
        // Find next newline.
        const eol = if (std.mem.indexOfScalar(u8, md[pos..], '\n')) |i| pos + i else md.len;
        const line = md[pos..eol];
        try renderMarkdownLine(sb, line);
        pos = eol + 1;
    }
}

fn renderMarkdownLine(sb: *Scrollback, line: []const u8) !void {
    if (line.len == 0) {
        try sb.pushLine("", .default, .default, .{});
        return;
    }

    // Detect block type.
    const rest = line;
    var skip_prefix: usize = 0;

    // Headers: # → h1, ## → h2, ### → h3
    if (rest.len >= 1 and rest[0] == '#') {
        var level: usize = 0;
        while (level < rest.len and level < 6 and rest[level] == '#') : (level += 1) {}
        skip_prefix = level + 1; // # + space
        if (skip_prefix > rest.len) skip_prefix = rest.len;
        const tline = try sb.appendLine();
        // Render prefix "# " or "## " etc.
        var col: usize = 0;
        for (0..level) |_| {
            if (col >= tline.runes.len) break;
            tline.runes[col] = .{ .char = '#', .fg = .{ .named = .bright_yellow }, .style = .{ .bold = true } };
            col += 1;
        }
        if (col < tline.runes.len) {
            tline.runes[col] = .{ .char = ' ', .fg = .default };
            col += 1;
        }
        try renderInlineRunes(tline.runes, col, rest[skip_prefix..]);
        return;
    }

    // Blockquote: >
    if (rest.len >= 2 and rest[0] == '>' and rest[1] == ' ') {
        skip_prefix = 2;
        const tline = try sb.appendLine();
        if (tline.runes.len > 0) {
            tline.runes[0] = .{ .char = '▎', .fg = .{ .named = .bright_blue } };
        }
        if (tline.runes.len > 1) {
            tline.runes[1] = .{ .char = ' ', .fg = .default };
        }
        try renderInlineRunes(tline.runes, 2, rest[skip_prefix..]);
        return;
    }

    // List: "- " or "* "
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*') and rest[1] == ' ') {
        skip_prefix = 2;
        const tline = try sb.appendLine();
        if (tline.runes.len > 0) {
            tline.runes[0] = .{ .char = '•', .fg = .{ .named = .cyan } };
        }
        if (tline.runes.len > 1) {
            tline.runes[1] = .{ .char = ' ', .fg = .default };
        }
        try renderInlineRunes(tline.runes, 2, rest[skip_prefix..]);
        return;
    }

    // Regular line with inline formatting.
    const tline = try sb.appendLine();
    try renderInlineRunes(tline.runes, 0, rest);
}

/// Render inline markdown (bold, italic, code) into pre-allocated runes.
fn renderInlineRunes(runes: []Rune, start_col: usize, text: []const u8) !void {
    var col: usize = start_col;
    var i: usize = 0;
    var current_style: MdStyle = .normal;

    while (i < text.len) {
        // Code span: `...`
        if (text[i] == '`') {
            const end = if (std.mem.indexOfScalar(u8, text[i + 1 ..], '`')) |e| i + 1 + e else null;
            if (end) |e| {
                // Render code content
                var ci: usize = i + 1;
                while (ci < e and col < runes.len) {
                    const cp_len = std.unicode.utf8ByteSequenceLength(text[ci]) catch 1;
                    const cp = std.unicode.utf8Decode(text[ci..@min(ci + cp_len, text.len)]) catch text[ci];
                    runes[col] = .{
                        .char = @as(u21, @intCast(cp)),
                        .fg = .{ .named = .bright_red },
                        .bg = .{ .named = .bright_black },
                        .style = .{},
                    };
                    col += 1;
                    ci += cp_len;
                }
                i = e + 1;
                continue;
            }
        }

        // Bold + italic: ***...***
        if (i + 2 < text.len and text[i] == '*' and text[i + 1] == '*' and text[i + 2] == '*') {
            current_style = if (current_style == .bold_italic) .normal else .bold_italic;
            i += 3;
            continue;
        }

        // Bold: **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            current_style = if (current_style == .bold) .normal else .bold;
            i += 2;
            continue;
        }

        // Italic: *...*
        if (text[i] == '*') {
            current_style = if (current_style == .italic) .normal else .italic;
            i += 1;
            continue;
        }

        // Regular character
        if (col >= runes.len) break;
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end_byte = @min(i + cp_len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end_byte]) catch @as(u21, text[i]);
        runes[col] = .{
            .char = @as(u21, @intCast(cp)),
            .fg = .default,
            .style = switch (current_style) {
                .normal => .{},
                .bold => .{ .bold = true },
                .italic => .{ .italic = true },
                .code => .{},
                .bold_italic => .{ .bold = true, .italic = true },
            },
        };
        col += 1;
        i = end_byte;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Rune eql" {
    const a = Rune{ .char = 'X', .fg = .{ .named = .red } };
    const b = Rune{ .char = 'X', .fg = .{ .named = .red } };
    try std.testing.expect(Rune.eql(a, b));
    const c = Rune{ .char = 'Y', .fg = .{ .named = .red } };
    try std.testing.expect(!Rune.eql(a, c));
}

test "Scrollback — push and count" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try sb.pushLine("Hello", .default, .default, .{});
    try sb.pushLine("World", .default, .default, .{});
    try std.testing.expectEqual(@as(usize, 2), sb.count());
}

test "Scrollback — push with style" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try sb.pushLine("Bold text", .{ .named = .green }, .default, .{ .bold = true });
    try std.testing.expectEqual(@as(usize, 1), sb.count());
    const line0 = sb.lines.items[0];
    try std.testing.expect(line0.runes[0].char == 'B');
    try std.testing.expect(line0.runes[0].fg == .named);
    try std.testing.expect(line0.runes[0].style.bold);
}

test "Scrollback — ring buffer recycling" {
    var sb = try Scrollback.init(std.testing.allocator, 10, 3);
    defer sb.deinit();

    try sb.pushLine("line1", .default, .default, .{});
    try sb.pushLine("line2", .default, .default, .{});
    try sb.pushLine("line3", .default, .default, .{});
    try sb.pushLine("line4", .default, .default, .{});

    // Should have max 3 lines; oldest (line1) recycled.
    try std.testing.expectEqual(@as(usize, 3), sb.count());
    // First line should now be line2
    try std.testing.expect(sb.lines.items[0].runes[0].char == 'l');
    try std.testing.expect(sb.lines.items[0].runes[1].char == 'i');
    try std.testing.expect(sb.lines.items[0].runes[2].char == 'n');
    try std.testing.expect(sb.lines.items[0].runes[3].char == 'e');
    try std.testing.expect(sb.lines.items[0].runes[4].char == '2');
}

test "Scrollback — render to screen" {
    var scr = try screen.Screen.init(std.testing.allocator, 20, 5);
    defer scr.deinit();
    var sb = try Scrollback.init(std.testing.allocator, 20, 100);
    defer sb.deinit();

    try sb.pushLine("Hello World", .{ .named = .cyan }, .default, .{});
    try sb.pushLine("Second line", .default, .default, .{});

    const rect = Rect{ .x = 0, .y = 0, .w = 20, .h = 5 };
    sb.render(&scr, rect);

    const cell = scr.getCell(0, 1).?;
    try std.testing.expect(cell.char == 'S');
}

test "Scrollback — scroll offset" {
    var sb = try Scrollback.init(std.testing.allocator, 20, 100);
    defer sb.deinit();

    try sb.pushLine("line1", .default, .default, .{});
    try sb.pushLine("line2", .default, .default, .{});
    try sb.pushLine("line3", .default, .default, .{});

    sb.scrollUp(1);
    try std.testing.expectEqual(@as(usize, 1), sb.scroll_offset);

    sb.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), sb.scroll_offset);
}

test "InputBox — insert and getText" {
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("Hello");
    try std.testing.expectEqualStrings("Hello", input.getText());
    try std.testing.expectEqual(@as(usize, 5), input.cursor);
}

test "InputBox — backspace" {
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("Ab");
    input.backspace();
    try std.testing.expectEqualStrings("A", input.getText());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
}

test "InputBox — delete" {
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("AB");
    input.moveHome();
    input.delete();
    try std.testing.expectEqualStrings("B", input.getText());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "InputBox — cursor movement" {
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("ABCDE");
    try std.testing.expectEqual(@as(usize, 5), input.cursor);

    input.moveLeft();
    try std.testing.expectEqual(@as(usize, 4), input.cursor);

    input.moveRight();
    try std.testing.expectEqual(@as(usize, 5), input.cursor);

    input.moveHome();
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    input.moveEnd();
    try std.testing.expectEqual(@as(usize, 5), input.cursor);
}

test "InputBox — clear" {
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("Hello");
    input.clear();
    try std.testing.expect(input.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "InputBox — render with text" {
    var scr = try screen.Screen.init(std.testing.allocator, 20, 3);
    defer scr.deinit();
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();

    try input.insert("Hi");
    const rect = Rect{ .x = 0, .y = 0, .w = 10, .h = 1 };
    input.render(&scr, rect);

    try std.testing.expect(scr.getCell(0, 0).?.char == 'H');
    try std.testing.expect(scr.getCell(1, 0).?.char == 'i');
}

test "InputBox — render with placeholder" {
    var scr = try screen.Screen.init(std.testing.allocator, 20, 3);
    defer scr.deinit();
    var input = InputBox.init(std.testing.allocator);
    defer input.deinit();
    input.placeholder = "Type here...";

    const rect = Rect{ .x = 0, .y = 0, .w = 14, .h = 1 };
    input.render(&scr, rect);

    try std.testing.expect(scr.getCell(0, 0).?.char == 'T');
    try std.testing.expect(scr.getCell(0, 0).?.fg == .named);
    try std.testing.expect(scr.getCell(0, 0).?.fg.named == .bright_black);
}

test "Spinner — tick cycles through frames" {
    const test_dots = [_][]const u8{ ".", "o", "O", "o" };
    var sp = Spinner.init(&test_dots);
    try std.testing.expectEqualStrings(".", sp.currentText());
    sp.tick();
    try std.testing.expectEqualStrings("o", sp.currentText());
    sp.tick();
    try std.testing.expectEqualStrings("O", sp.currentText());
    sp.tick();
    try std.testing.expectEqualStrings("o", sp.currentText());
    sp.tick(); // wraps around
    try std.testing.expectEqualStrings(".", sp.currentText());
}

test "Spinner — render to screen" {
    var scr = try screen.Screen.init(std.testing.allocator, 10, 3);
    defer scr.deinit();
    const test_arrows = [_][]const u8{ "|", "/", "-", "\\" };
    var sp = Spinner.init(&test_arrows);
    sp.fg = .{ .named = .cyan };

    sp.render(&scr, 5, 1);
    const cell = scr.getCell(5, 1).?;
    try std.testing.expect(cell.char == '|');
    try std.testing.expect(cell.fg == .named);
}

test "Spinner — reset" {
    const test_classic = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var sp = Spinner.init(&test_classic);
    for (0..5) |_| sp.tick();
    sp.reset();
    try std.testing.expectEqual(@as(usize, 0), sp.frame_index);
}

test "ProgressBar — render at 50%" {
    var scr = try screen.Screen.init(std.testing.allocator, 20, 3);
    defer scr.deinit();

    var pb = ProgressBar.init(0.5);
    const rect = Rect{ .x = 0, .y = 0, .w = 10, .h = 1 };
    pb.render(&scr, rect);

    // First 5 cells should be filled
    try std.testing.expect(scr.getCell(0, 0).?.char == '█');
    try std.testing.expect(scr.getCell(4, 0).?.char == '█');
    // Last 5 should be empty
    try std.testing.expect(scr.getCell(5, 0).?.char == '░');
    try std.testing.expect(scr.getCell(9, 0).?.char == '░');
}

test "ProgressBar — render with label" {
    var scr = try screen.Screen.init(std.testing.allocator, 20, 3);
    defer scr.deinit();

    var pb = ProgressBar.init(0.75);
    pb.label = "Loading";
    pb.separator = " ";
    const rect = Rect{ .x = 0, .y = 0, .w = 16, .h = 1 };
    pb.render(&scr, rect);

    // Label at start
    try std.testing.expect(scr.getCell(0, 0).?.char == 'L');
    try std.testing.expect(scr.getCell(6, 0).?.char == 'g');
    // Separator at position 7
    try std.testing.expect(scr.getCell(7, 0).?.char == ' ');
    // Bar starts at position 8
    try std.testing.expect(scr.getCell(8, 0).?.char == '█');
}

test "ProgressBar — clamp ratio to 0-1" {
    const pb = ProgressBar.init(2.0);
    try std.testing.expectEqual(@as(f32, 1.0), pb.ratio);
    const pb2 = ProgressBar.init(-0.5);
    try std.testing.expectEqual(@as(f32, 0.0), pb2.ratio);
}

test "Markdown — plain text" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "Hello world");
    try std.testing.expectEqual(@as(usize, 1), sb.count());
    try std.testing.expect(sb.lines.items[0].runes[0].char == 'H');
}

test "Markdown — header" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "# Title");
    try std.testing.expectEqual(@as(usize, 1), sb.count());
    // '#' prefix at col 0 with bright_yellow
    try std.testing.expect(sb.lines.items[0].runes[0].char == '#');
    try std.testing.expect(sb.lines.items[0].runes[0].fg == .named);
    try std.testing.expect(sb.lines.items[0].runes[0].fg.named == .bright_yellow);
    // 'T' at col 2 (after "# ")
    try std.testing.expect(sb.lines.items[0].runes[2].char == 'T');
}

test "Markdown — bold and italic" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "normal **bold** *italic*");
    const runes = sb.lines.items[0].runes;
    // "normal " (7 chars) + bold starts
    try std.testing.expect(runes[7].char == 'b');
    try std.testing.expect(runes[7].style.bold);
    try std.testing.expect(!runes[7].style.italic);
    // "bold" is 4 chars, then "**" ends bold → space
    try std.testing.expect(runes[11].char == ' ');
    try std.testing.expect(!runes[11].style.bold);
    // italic starts
    try std.testing.expect(runes[12].char == 'i');
    try std.testing.expect(runes[12].style.italic);
}

test "Markdown — code span" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "use `std.testing` here");
    const runes = sb.lines.items[0].runes;
    // "use " (4) then code starts
    try std.testing.expect(runes[4].char == 's');
    try std.testing.expect(runes[4].fg == .named);
    try std.testing.expect(runes[4].fg.named == .bright_red);
    try std.testing.expect(runes[4].bg == .named);
}

test "Markdown — list item" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "- Item one");
    const runes = sb.lines.items[0].runes;
    // Bullet at col 0
    try std.testing.expect(runes[0].char == '•');
    try std.testing.expect(runes[0].fg.named == .cyan);
    // Text at col 2
    try std.testing.expect(runes[2].char == 'I');
}

test "Markdown — blockquote" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "> Quote text");
    const runes = sb.lines.items[0].runes;
    // Quote bar at col 0
    try std.testing.expect(runes[0].char == '▎');
    try std.testing.expect(runes[0].fg.named == .bright_blue);
    // Text at col 2
    try std.testing.expect(runes[2].char == 'Q');
}

test "Markdown — multi-line" {
    var sb = try Scrollback.init(std.testing.allocator, 80, 100);
    defer sb.deinit();

    try renderMarkdown(&sb, "# Header\nParagraph\n- List item");
    try std.testing.expectEqual(@as(usize, 3), sb.count());
}
