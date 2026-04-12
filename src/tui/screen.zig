const std = @import("std");
const array_list_compat = @import("array_list_compat");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Standard 16 ANSI named colors.
pub const NamedColor = enum(u4) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
};

/// Terminal color representation supporting all common color models.
pub const Color = union(enum) {
    /// Terminal default (respects user theme)
    default,
    /// Standard 16-color ANSI palette
    named: NamedColor,
    /// 256-color palette index (0-255)
    indexed: u8,
    /// 24-bit true color
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Text style bitfield. Each flag maps to an SGR attribute.
pub const Style = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

/// A single terminal cell: character + visual attributes.
pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},

    /// Blank cell with default colors and no style.
    pub const empty: Cell = .{};

    /// True when every field is identical.
    pub fn eql(a: Cell, b: Cell) bool {
        if (a.char != b.char) return false;
        if (!colorEql(a.fg, b.fg)) return false;
        if (!colorEql(a.bg, b.bg)) return false;
        return @as(u8, @bitCast(a.style)) == @as(u8, @bitCast(b.style));
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn colorEql(a: Color, b: Color) bool {
    const ta = std.meta.activeTag(a);
    if (ta != std.meta.activeTag(b)) return false;
    return switch (a) {
        .default => true,
        .named => |n| n == b.named,
        .indexed => |i| i == b.indexed,
        .rgb => |c| c.r == b.rgb.r and c.g == b.rgb.g and c.b == b.rgb.b,
    };
}

/// Write foreground color escape sequence into buf.
fn writeFgColor(buf: *array_list_compat.ArrayList(u8), color: Color) !void {
    const w = buf.writer();
    switch (color) {
        .default => try w.print("\x1b[39m", .{}),
        .named => |n| {
            const v: u4 = @intFromEnum(n);
            if (v < 8) {
                try w.print("\x1b[{}m", .{30 + @as(u8, v)});
            } else {
                try w.print("\x1b[{}m", .{82 + @as(u8, v)});
            }
        },
        .indexed => |i| try w.print("\x1b[38;5;{}m", .{i}),
        .rgb => |c| try w.print("\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }),
    }
}

/// Write background color escape sequence into buf.
fn writeBgColor(buf: *array_list_compat.ArrayList(u8), color: Color) !void {
    const w = buf.writer();
    switch (color) {
        .default => try w.print("\x1b[49m", .{}),
        .named => |n| {
            const v: u4 = @intFromEnum(n);
            if (v < 8) {
                try w.print("\x1b[{}m", .{40 + @as(u8, v)});
            } else {
                try w.print("\x1b[{}m", .{92 + @as(u8, v)});
            }
        },
        .indexed => |i| try w.print("\x1b[48;5;{}m", .{i}),
        .rgb => |c| try w.print("\x1b[48;2;{};{};{}m", .{ c.r, c.g, c.b }),
    }
}

/// Emit minimal SGR sequences to transition from old → new style.
/// Toggles only the attributes that changed.
fn writeStyleDiff(buf: *array_list_compat.ArrayList(u8), old: Style, new: Style) !void {
    const w = buf.writer();
    if (old.bold != new.bold) {
        if (new.bold) try w.print("\x1b[1m", .{}) else try w.print("\x1b[22m", .{});
    }
    if (old.dim != new.dim) {
        if (new.dim) try w.print("\x1b[2m", .{}) else try w.print("\x1b[22m", .{});
    }
    if (old.italic != new.italic) {
        if (new.italic) try w.print("\x1b[3m", .{}) else try w.print("\x1b[23m", .{});
    }
    if (old.underline != new.underline) {
        if (new.underline) try w.print("\x1b[4m", .{}) else try w.print("\x1b[24m", .{});
    }
    if (old.blink != new.blink) {
        if (new.blink) try w.print("\x1b[5m", .{}) else try w.print("\x1b[25m", .{});
    }
    if (old.reverse != new.reverse) {
        if (new.reverse) try w.print("\x1b[7m", .{}) else try w.print("\x1b[27m", .{});
    }
    if (old.hidden != new.hidden) {
        if (new.hidden) try w.print("\x1b[8m", .{}) else try w.print("\x1b[28m", .{});
    }
    if (old.strikethrough != new.strikethrough) {
        if (new.strikethrough) try w.print("\x1b[9m", .{}) else try w.print("\x1b[29m", .{});
    }
}

// ---------------------------------------------------------------------------
// Screen — double-buffered cell grid with diff-based rendering
// ---------------------------------------------------------------------------

pub const Screen = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,

    /// What is currently on the terminal (last rendered frame).
    front: []Cell,
    /// What we are drawing (next frame).
    back: []Cell,

    /// Pre-allocated scratch buffer for building escape sequences.
    /// Avoids per-render heap allocation.
    render_buf: array_list_compat.ArrayList(u8),

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// Create a new screen with the given dimensions.
    /// Both buffers are filled with `Cell.empty`.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Screen {
        const size: usize = @as(usize, width) * height;
        const front = try allocator.alloc(Cell, size);
        const back = try allocator.alloc(Cell, size);
        @memset(front, Cell.empty);
        @memset(back, Cell.empty);

        // Rough estimate: ~8 bytes of escape data per cell worst case.
        const buf_cap = size * 8;
        const render_buf = try array_list_compat.ArrayList(u8).initCapacity(allocator, buf_cap);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .front = front,
            .back = back,
            .render_buf = render_buf,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.render_buf.deinit();
        self.* = undefined;
    }

    /// Resize the grid, preserving content in the overlapping region.
    pub fn resize(self: *Screen, new_width: u16, new_height: u16) !void {
        if (new_width == self.width and new_height == self.height) return;

        const new_size: usize = @as(usize, new_width) * new_height;
        const new_front = try self.allocator.alloc(Cell, new_size);
        const new_back = try self.allocator.alloc(Cell, new_size);

        @memset(new_front, Cell.empty);
        @memset(new_back, Cell.empty);

        const copy_rows = @min(self.height, new_height);
        const copy_cols = @min(self.width, new_width);
        for (0..copy_rows) |row| {
            const src = row * self.width;
            const dst = row * new_width;
            @memcpy(new_front[dst..][0..copy_cols], self.front[src..][0..copy_cols]);
            @memcpy(new_back[dst..][0..copy_cols], self.back[src..][0..copy_cols]);
        }

        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.front = new_front;
        self.back = new_back;
        self.width = new_width;
        self.height = new_height;

        try self.render_buf.ensureTotalCapacity(new_size * 8);
    }

    // ------------------------------------------------------------------
    // Drawing
    // ------------------------------------------------------------------

    /// Clear the back buffer to empty cells.
    pub fn clear(self: *Screen) void {
        @memset(self.back, Cell.empty);
    }

    /// Mark the front buffer as stale so the next render() will redraw
    /// everything. Useful after the terminal state is disrupted
    /// (e.g. a system message wrote to stdout).
    pub fn invalidate(self: *Screen) void {
        @memset(self.front, Cell.empty);
    }

    /// Set a single cell in the back buffer. Silently clipped to bounds.
    pub fn setCell(self: *Screen, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.back[@as(usize, y) * self.width + x] = cell;
    }

    /// Read a cell from the back buffer. Returns null if out of bounds.
    pub fn getCell(self: *const Screen, x: u16, y: u16) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.back[@as(usize, y) * self.width + x];
    }

    /// Write UTF-8 text starting at (x, y) with the given visual attributes.
    /// Each codepoint occupies exactly one cell (no wide-char handling yet).
    /// Silently clipped to screen bounds.
    pub fn printAt(self: *Screen, x: u16, y: u16, text: []const u8, opts: struct {
        fg: Color = .default,
        bg: Color = .default,
        style: Style = .{},
    }) void {
        if (y >= self.height) return;
        var cx: u16 = x;
        const view = std.unicode.Utf8View.initUnchecked(text);
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cx >= self.width) break;
            self.back[@as(usize, y) * self.width + cx] = .{
                .char = cp,
                .fg = opts.fg,
                .bg = opts.bg,
                .style = opts.style,
            };
            cx += 1;
        }
    }

    /// Fill a rectangular region with a cell.
    pub fn fillRect(self: *Screen, x: u16, y: u16, w: u16, h: u16, cell: Cell) void {
        var row: u16 = y;
        while (row < y + h) : (row += 1) {
            if (row >= self.height) break;
            var col: u16 = x;
            while (col < x + w) : (col += 1) {
                if (col >= self.width) break;
                self.back[@as(usize, row) * self.width + col] = cell;
            }
        }
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    /// Diff-render the back buffer to `writer`.
    ///
    /// Only cells that differ from the last rendered frame are emitted.
    /// Escape sequences are batched into an internal buffer and flushed
    /// in a single write call.
    ///
    /// After rendering, the front buffer is updated to match the back
    /// buffer so the next render only emits new changes.
    pub fn render(self: *Screen, writer: anytype) !void {
        self.render_buf.clearRetainingCapacity();

        var cur_style = Style{};
        var cur_fg: Color = .default;
        var cur_bg: Color = .default;
        // Terminal cursor position after the last byte we wrote.
        // Start at an impossible position to force an initial cursor move.
        var cur_x: u16 = std.math.maxInt(u16);
        var cur_y: u16 = std.math.maxInt(u16);

        for (0..self.height) |row| {
            for (0..self.width) |col| {
                const idx = row * self.width + col;
                if (Cell.eql(self.front[idx], self.back[idx])) continue;

                const cell = self.back[idx];

                // Move cursor if not adjacent to the last write position.
                const adjacent = col == cur_x and row == cur_y;
                if (!adjacent) {
                    try self.render_buf.writer().print("\x1b[{};{}H", .{ row + 1, col + 1 });
                }

                // Style — toggle only changed attributes.
                if (@as(u8, @bitCast(cell.style)) != @as(u8, @bitCast(cur_style))) {
                    try writeStyleDiff(&self.render_buf, cur_style, cell.style);
                    cur_style = cell.style;
                }

                // Foreground color.
                if (!colorEql(cell.fg, cur_fg)) {
                    try writeFgColor(&self.render_buf, cell.fg);
                    cur_fg = cell.fg;
                }

                // Background color.
                if (!colorEql(cell.bg, cur_bg)) {
                    try writeBgColor(&self.render_buf, cell.bg);
                    cur_bg = cell.bg;
                }

                // Character (UTF-8 encode).
                const ch = cell.char;
                if (ch < 0x80) {
                    try self.render_buf.append(@intCast(ch));
                } else {
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(ch, &utf8) catch continue;
                    try self.render_buf.appendSlice(utf8[0..len]);
                }

                cur_x = if (col < std.math.maxInt(u16)) @intCast(col + 1) else std.math.maxInt(u16);
                cur_y = @intCast(row);
            }
        }

        // Flush everything in one write.
        if (self.render_buf.items.len > 0) {
            try writer.writeAll(self.render_buf.items);
        }

        // Front ← back (copy, not swap, so back retains current state).
        @memcpy(self.front, self.back);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Cell.empty defaults" {
    const c = Cell.empty;
    try std.testing.expect(c.char == ' ');
    try std.testing.expect(c.fg == .default);
    try std.testing.expect(c.bg == .default);
    try std.testing.expect(@as(u8, @bitCast(c.style)) == 0);
}

test "Cell.eql — identical cells" {
    const a = Cell{ .char = 'X', .fg = .{ .named = .red }, .style = .{ .bold = true } };
    const b = Cell{ .char = 'X', .fg = .{ .named = .red }, .style = .{ .bold = true } };
    try std.testing.expect(Cell.eql(a, b));
}

test "Cell.eql — different char" {
    const a = Cell{ .char = 'X' };
    const b = Cell{ .char = 'Y' };
    try std.testing.expect(!Cell.eql(a, b));
}

test "Cell.eql — different fg color" {
    const a = Cell{ .char = 'A', .fg = .{ .named = .red } };
    const b = Cell{ .char = 'A', .fg = .{ .named = .green } };
    try std.testing.expect(!Cell.eql(a, b));
}

test "Cell.eql — different bg color" {
    const a = Cell{ .char = 'A', .bg = .{ .indexed = 17 } };
    const b = Cell{ .char = 'A', .bg = .{ .indexed = 18 } };
    try std.testing.expect(!Cell.eql(a, b));
}

test "Cell.eql — different style" {
    const a = Cell{ .char = 'A', .style = .{ .bold = true } };
    const b = Cell{ .char = 'A', .style = .{ .italic = true } };
    try std.testing.expect(!Cell.eql(a, b));
}

test "Color equality — default" {
    try std.testing.expect(colorEql(Color.default, Color.default));
    try std.testing.expect(!colorEql(Color.default, .{ .named = .white }));
}

test "Color equality — named" {
    try std.testing.expect(colorEql(
        Color{ .named = .bright_cyan },
        Color{ .named = .bright_cyan },
    ));
    try std.testing.expect(!colorEql(
        Color{ .named = .cyan },
        Color{ .named = .bright_cyan },
    ));
}

test "Color equality — indexed" {
    try std.testing.expect(colorEql(
        Color{ .indexed = 42 },
        Color{ .indexed = 42 },
    ));
    try std.testing.expect(!colorEql(
        Color{ .indexed = 42 },
        Color{ .indexed = 43 },
    ));
}

test "Color equality — rgb" {
    try std.testing.expect(colorEql(
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
    try std.testing.expect(!colorEql(
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        Color{ .rgb = .{ .r = 10, .g = 20, .b = 31 } },
    ));
}

test "Screen — init and dimensions" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();
    try std.testing.expectEqual(@as(u16, 10), screen.width);
    try std.testing.expectEqual(@as(u16, 5), screen.height);
    try std.testing.expectEqual(@as(usize, 50), screen.front.len);
    try std.testing.expectEqual(@as(usize, 50), screen.back.len);
}

test "Screen — setCell and getCell" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    const cell = Cell{ .char = 'A', .fg = .{ .named = .green } };
    screen.setCell(3, 2, cell);

    const got = screen.getCell(3, 2).?;
    try std.testing.expect(got.char == 'A');
    try std.testing.expect(got.fg == .named);
    try std.testing.expect(got.fg.named == .green);

    // Out-of-bounds returns null
    try std.testing.expect(screen.getCell(20, 20) == null);
}

test "Screen — printAt ASCII" {
    var screen = try Screen.init(std.testing.allocator, 20, 5);
    defer screen.deinit();

    screen.printAt(2, 1, "Hello", .{ .fg = .{ .named = .cyan } });

    try std.testing.expect(screen.getCell(2, 1).?.char == 'H');
    try std.testing.expect(screen.getCell(3, 1).?.char == 'e');
    try std.testing.expect(screen.getCell(6, 1).?.char == 'o');
    // Past the text should still be empty
    try std.testing.expect(screen.getCell(7, 1).?.char == ' ');
}

test "Screen — printAt clips to width" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    screen.printAt(3, 0, "ABCDEFGH", .{});
    // Only 'A','B' fit (positions 3,4). The rest is clipped.
    try std.testing.expect(screen.getCell(3, 0).?.char == 'A');
    try std.testing.expect(screen.getCell(4, 0).?.char == 'B');
    // Position 0 should still be empty
    try std.testing.expect(screen.getCell(0, 0).?.char == ' ');
}

test "Screen — fillRect" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    const fill = Cell{ .char = '#', .bg = .{ .named = .blue } };
    screen.fillRect(1, 1, 3, 2, fill);

    // Inside the rect
    try std.testing.expect(screen.getCell(1, 1).?.char == '#');
    try std.testing.expect(screen.getCell(2, 1).?.char == '#');
    try std.testing.expect(screen.getCell(3, 1).?.char == '#');
    try std.testing.expect(screen.getCell(1, 2).?.char == '#');
    try std.testing.expect(screen.getCell(3, 2).?.char == '#');

    // Outside the rect
    try std.testing.expect(screen.getCell(0, 0).?.char == ' ');
    try std.testing.expect(screen.getCell(4, 1).?.char == ' ');
}

test "Screen — render empty screen produces no output" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "Screen — render emits diff only on change" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    // Draw one cell
    screen.setCell(0, 0, .{ .char = 'X' });

    // First render should produce output
    try screen.render(output.writer());
    try std.testing.expect(output.items.len > 0);

    // Should contain cursor positioning
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[1;1H") != null);
    // Should contain the character
    try std.testing.expect(std.mem.indexOf(u8, output.items, "X") != null);

    // Second render with no changes → empty
    output.clearRetainingCapacity();
    try screen.render(output.writer());
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "Screen — render with named color" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{
        .char = 'R',
        .fg = .{ .named = .red },
    });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    // Red fg = \x1b[31m
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "R") != null);
}

test "Screen — render with bright named color" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{
        .char = 'B',
        .fg = .{ .named = .bright_green },
    });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    // bright_green = enum value 10, code = 82 + 10 = 92
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[92m") != null);
}

test "Screen — render with RGB color" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{
        .char = 'Z',
        .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
    });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[38;2;255;128;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Z") != null);
}

test "Screen — render with bold style" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{
        .char = '!',
        .style = .{ .bold = true },
    });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "!") != null);
}

test "Screen — render style transition" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    // First cell: bold
    screen.setCell(0, 0, .{ .char = 'A', .style = .{ .bold = true } });
    // Second cell: no style
    screen.setCell(1, 0, .{ .char = 'B' });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    // Should have bold on
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[1m") != null);
    // Should have bold off
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[22m") != null);
}

test "Screen — invalidate forces full redraw" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    // First render
    screen.setCell(0, 0, .{ .char = 'X' });
    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try screen.render(output.writer());
    try std.testing.expect(output.items.len > 0);

    // No changes → empty
    output.clearRetainingCapacity();
    try screen.render(output.writer());
    try std.testing.expectEqual(@as(usize, 0), output.items.len);

    // Invalidate → forces full redraw even though back buffer didn't change
    screen.invalidate();
    output.clearRetainingCapacity();
    try screen.render(output.writer());
    try std.testing.expect(output.items.len > 0);
}

test "Screen — resize preserves content" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    screen.setCell(0, 0, .{ .char = 'A' });
    screen.setCell(5, 2, .{ .char = 'B' });

    try screen.resize(20, 10);

    try std.testing.expectEqual(@as(u16, 20), screen.width);
    try std.testing.expectEqual(@as(u16, 10), screen.height);
    try std.testing.expect(screen.getCell(0, 0).?.char == 'A');
    try std.testing.expect(screen.getCell(5, 2).?.char == 'B');
    // New area should be empty
    try std.testing.expect(screen.getCell(15, 8).?.char == ' ');
}

test "Screen — resize shrinks and clips" {
    var screen = try Screen.init(std.testing.allocator, 20, 10);
    defer screen.deinit();

    screen.setCell(15, 8, .{ .char = 'Z' });

    try screen.resize(10, 5);

    try std.testing.expectEqual(@as(u16, 10), screen.width);
    try std.testing.expectEqual(@as(u16, 5), screen.height);
    // The cell at (15,8) is now out of bounds
    try std.testing.expect(screen.getCell(15, 8) == null);
}

test "Screen — resize no-op when dimensions match" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    screen.setCell(0, 0, .{ .char = 'K' });
    try screen.resize(10, 5);
    try std.testing.expect(screen.getCell(0, 0).?.char == 'K');
}

test "Screen — render with background color" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{
        .char = ' ',
        .bg = .{ .indexed = 220 },
    });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[48;5;220m") != null);
}

test "Screen — render multiple cells in same row" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{ .char = 'H' });
    screen.setCell(1, 0, .{ .char = 'i' });

    var output = array_list_compat.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try screen.render(output.writer());

    // Should position cursor once and write both characters contiguously
    const data = output.items;
    // Find "Hi" as a substring — means both chars were written adjacent
    try std.testing.expect(std.mem.indexOf(u8, data, "Hi") != null);
    // Should only have one cursor move (for position 1;1)
    const first_cursor = std.mem.indexOf(u8, data, "\x1b[").?;
    // No second cursor move (no \x1b[ between the two characters)
    try std.testing.expect(std.mem.indexOf(u8, data[first_cursor + 2 ..], "\x1b[") == null);
}

test "Screen — clear resets back buffer" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.setCell(0, 0, .{ .char = 'X' });
    screen.clear();

    try std.testing.expect(screen.getCell(0, 0).?.char == ' ');
}
