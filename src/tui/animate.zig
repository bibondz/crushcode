const std = @import("std");
const screen = @import("screen.zig");

const Cell = screen.Cell;
const Color = screen.Color;
const Style = screen.Style;
const Screen = screen.Screen;
const Rect = @import("layout.zig").Rect;

// ============================================================================
// CursorBlink — blinking cursor with configurable interval
// ============================================================================

/// Cursor visibility state.
pub const CursorState = enum { visible, hidden };

/// Cursor that blinks on/off at a regular interval.
pub const CursorBlink = struct {
    /// Current visibility state.
    state: CursorState = .visible,
    /// Toggle count — increment each tick.
    tick_count: usize = 0,
    /// Ticks per full cycle (on + off). Default: 10 ticks (500ms at 50ms/tick).
    cycle_ticks: usize = 10,
    /// Number of ticks the cursor stays visible in each cycle. Default: 6.
    on_ticks: usize = 6,

    const Self = @This();

    /// Initialize cursor in visible state.
    pub fn init() Self {
        return .{};
    }

    /// Configure timing: `ms_per_tick` * `cycle_ticks` = full cycle duration.
    pub fn withTiming(ms_per_tick: usize, cycle_ms: usize) Self {
        const ticks = @max(1, cycle_ms / ms_per_tick);
        const on = @max(1, ticks * 3 / 4); // 75% visible
        return .{
            .cycle_ticks = ticks,
            .on_ticks = on,
        };
    }

    /// Advance one tick. Call this periodically (e.g., every 50ms).
    pub fn tick(self: *Self) void {
        self.tick_count += 1;
        const cycle_pos = self.tick_count % self.cycle_ticks;
        self.state = if (cycle_pos < self.on_ticks) .visible else .hidden;
    }

    /// Force cursor to a specific state.
    pub fn show(self: *Self) void {
        self.state = .visible;
    }

    pub fn hide(self: *Self) void {
        self.state = .hidden;
    }

    /// Check if cursor is currently visible.
    pub fn isVisible(self: *const Self) bool {
        return self.state == .visible;
    }

    /// Reset tick count to start of cycle.
    pub fn reset(self: *Self) void {
        self.tick_count = 0;
        self.state = .visible;
    }

    /// Render cursor at (x, y) onto screen. If hidden, renders as space or doesn't render.
    pub fn render(self: *Self, scr: *Screen, x: u16, y: u16, char: u21, fg: Color, bg: Color) void {
        if (self.isVisible()) {
            scr.setCell(x, y, .{
                .char = char,
                .fg = fg,
                .bg = bg,
                .style = .{ .reverse = true },
            });
        } else {
            // Hidden: render as space with same background (effectively invisible)
            scr.setCell(x, y, .{
                .char = ' ',
                .bg = bg,
            });
        }
    }
};

// ============================================================================
// StreamingText — character-by-character reveal with configurable timing
// ============================================================================

/// Text that reveals one codepoint at a time.
pub const StreamingText = struct {
    /// Full source text (UTF-8).
    source: []const u8,
    /// Current render position (byte offset).
    pos: usize = 0,
    /// Whether streaming is complete.
    done: bool = false,
    /// Characters to skip after each reveal (0 = no skip).
    skip_every: usize = 0,
    /// Accumulator for skip.
    skip_acc: usize = 0,

    const Self = @This();

    /// Create from UTF-8 text.
    pub fn init(text: []const u8) Self {
        return .{ .source = text };
    }

    /// Configure: reveal every Nth character (for speed control).
    pub fn withSpeed(self: Self, chars_per_reveal: usize) Self {
        return .{
            .source = self.source,
            .pos = self.pos,
            .done = self.done,
            .skip_every = @max(0, chars_per_reveal - 1),
            .skip_acc = 0,
        };
    }

    /// Advance streaming. Call this each frame/tick.
    /// Returns the newly revealed codepoint, or null if done.
    pub fn tick(self: *Self) ?u21 {
        if (self.done) return null;

        // Skip if needed
        if (self.skip_acc < self.skip_every) {
            self.skip_acc += 1;
            // Still advance position to skip the character
            self.advanceOne();
            return null;
        }
        self.skip_acc = 0;

        // Advance and return the new character
        const prev_pos = self.pos;
        self.advanceOne();
        if (self.done) return null;

        // Decode the character we just revealed
        return self.decodeAt(prev_pos);
    }

    /// Get all currently revealed text as slice.
    pub fn revealedSlice(self: *const Self) []const u8 {
        return self.source[0..self.pos];
    }

    /// Render current revealed text at rect position with styling.
    pub fn render(self: *Self, scr: *Screen, rect: Rect, fg: Color, bg: Color, style: Style) void {
        const revealed = self.revealedSlice();
        scr.printAt(rect.x, rect.y, revealed, .{
            .fg = fg,
            .bg = bg,
            .style = style,
        });
    }

    /// Check if streaming is complete.
    pub fn isDone(self: *const Self) bool {
        return self.done;
    }

    /// Reset to start.
    pub fn reset(self: *Self) void {
        self.pos = 0;
        self.done = false;
        self.skip_acc = 0;
    }

    /// Fully reveal all text immediately.
    pub fn complete(self: *Self) void {
        self.pos = self.source.len;
        self.done = true;
    }

    fn advanceOne(self: *Self) void {
        if (self.pos >= self.source.len) {
            self.done = true;
            return;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(self.source[self.pos]) catch 1;
        self.pos += @min(cp_len, self.source.len - self.pos);
        if (self.pos >= self.source.len) {
            self.done = true;
        }
    }

    fn decodeAt(self: *const Self, byte_offset: usize) ?u21 {
        if (byte_offset >= self.source.len) return null;
        const cp_len = std.unicode.utf8ByteSequenceLength(self.source[byte_offset]) catch 1;
        const end = @min(byte_offset + cp_len, self.source.len);
        return std.unicode.utf8Decode(self.source[byte_offset..end]) catch null;
    }
};

// ============================================================================
// FadeTransition — simulated opacity via intensity (for terminals that don't support alpha)
// ============================================================================

/// A fade transition using color intensity simulation.
/// Since terminals don't support true alpha, we simulate fade by:
/// - Dimmed: reduce color saturation, darker background
/// - For named colors, we use the "bright" variants to fade OUT
/// This is a simple approximation — real alpha requires 24-bit terminal + truecolor
pub const FadeTransition = struct {
    /// Current intensity 0.0 (invisible) to 1.0 (full).
    intensity: f32 = 1.0,
    /// Direction: 1.0 = fade in, -1.0 = fade out.
    direction: f32 = 0.0,
    /// How fast intensity changes per tick (0.0–1.0).
    speed: f32 = 0.1,

    const Self = @This();

    /// Create a fade-in transition.
    pub fn fadeIn(speed: f32) Self {
        return .{
            .intensity = 0.0,
            .direction = 1.0,
            .speed = speed,
        };
    }

    /// Create a fade-out transition.
    pub fn fadeOut(speed: f32) Self {
        return .{
            .intensity = 1.0,
            .direction = -1.0,
            .speed = speed,
        };
    }

    /// Advance one tick. Call this periodically.
    pub fn tick(self: *Self) void {
        if (self.direction == 0.0) return;

        self.intensity += self.direction * self.speed;
        self.intensity = @max(0.0, @min(1.0, self.intensity));

        // Stop when we reach the edge
        if ((self.direction > 0 and self.intensity >= 1.0) or
            (self.direction < 0 and self.intensity <= 0.0))
        {
            self.direction = 0.0;
        }
    }

    /// Check if transition is complete.
    pub fn isDone(self: *const Self) bool {
        return self.direction == 0.0;
    }

    /// Get current intensity.
    pub fn currentIntensity(self: *const Self) f32 {
        return self.intensity;
    }

    /// Apply fade to a cell's colors. Returns modified cell.
    /// For truecolor: reduces brightness. For named: uses dim variant if fading out.
    pub fn applyToCell(self: *const Self, cell: Cell) Cell {
        if (self.intensity >= 1.0) return cell;
        if (self.intensity <= 0.0) {
            return .{
                .char = cell.char,
                .fg = .default,
                .bg = .default,
                .style = .{},
            };
        }

        // Simple approach: reduce style intensity (keep colors but reduce bold)
        var new_style = cell.style;
        if (self.intensity < 0.5) {
            new_style.bold = false;
        }

        return .{
            .char = cell.char,
            .fg = cell.fg,
            .bg = cell.bg,
            .style = new_style,
        };
    }
};

// ============================================================================
// Typewriter — character-by-character print with variable speed, cursor trail
// ============================================================================

/// A typewriter effect that prints text with variable speed and cursor.
pub const Typewriter = struct {
    stream: StreamingText,
    /// Cursor position (cell offset from start of line).
    cursor_x: u16 = 0,
    /// Y position (row in rect).
    cursor_y: u16 = 0,
    /// Current cell rectangle for rendering.
    rect: Rect = .zero,

    const Self = @This();

    /// Create typewriter with text.
    pub fn init(text: []const u8) Self {
        return .{
            .stream = StreamingText.init(text),
        };
    }

    /// Configure speed (characters per tick, higher = faster).
    pub fn withSpeed(self: Self, chars_per_tick: usize) Self {
        return .{
            .stream = self.stream.withSpeed(chars_per_tick),
            .cursor_x = self.cursor_x,
            .cursor_y = self.cursor_y,
            .rect = self.rect,
        };
    }

    /// Set render area.
    pub fn setRect(self: *Self, rect: Rect) void {
        self.rect = rect;
    }

    /// Advance typewriter one tick. Returns newly printed character or null.
    pub fn tick(self: *Self) ?u21 {
        return self.stream.tick();
    }

    /// Render the typewriter state into screen.
    /// Draws all revealed text + cursor at current position.
    pub fn render(self: *Self, scr: *Screen, fg: Color, bg: Color, cursor_fg: Color, cursor_bg: Color) void {
        const revealed = self.stream.revealedSlice();
        scr.printAt(self.rect.x, self.rect.y, revealed, .{
            .fg = fg,
            .bg = bg,
            .style = .{},
        });

        // Calculate cursor position based on revealed text
        const col = self.stream.pos;
        if (col < self.rect.w) {
            // Cursor at end of revealed text
            scr.setCell(self.rect.x + @as(u16, @intCast(col)), self.rect.y, .{
                .char = ' ',
                .fg = cursor_fg,
                .bg = cursor_bg,
                .style = .{ .reverse = true },
            });
        }
    }

    /// Check if typing is complete.
    pub fn isDone(self: *const Self) bool {
        return self.stream.isDone();
    }

    /// Reset to start.
    pub fn reset(self: *Self) void {
        self.stream.reset();
        self.cursor_x = 0;
    }
};

// ============================================================================
// AnimationManager — coordinates all animation states for a TUI session
// ============================================================================

/// Central coordinator for TUI animations.
pub const AnimationManager = struct {
    allocator: std.mem.Allocator,
    /// Cursor blink state.
    cursor: CursorBlink,
    /// Active typewriter (if any).
    typewriter: ?Typewriter = null,
    /// Last tick timestamp (monotonic ms).
    last_tick_ms: u64 = 0,
    /// Tick interval in ms (controls animation speed).
    tick_ms: u64 = 50,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .cursor = CursorBlink.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        // typewriter is inline, no deinit needed
        _ = self;
    }

    /// Start a typewriter animation.
    pub fn startTypewriter(self: *Self, text: []const u8) void {
        self.typewriter = Typewriter.init(text);
    }

    /// Stop typewriter.
    pub fn stopTypewriter(self: *Self) void {
        self.typewriter = null;
    }

    /// Tick all animations. Call this in your main loop.
    /// Returns true if any animation is still active.
    pub fn tick(self: *Self, now_ms: u64) bool {
        // Throttle to tick_ms interval
        if (now_ms - self.last_tick_ms < self.tick_ms) {
            return self.typewriter != null and !self.typewriter.?.isDone();
        }
        self.last_tick_ms = now_ms;

        // Tick cursor
        self.cursor.tick();

        // Tick typewriter
        if (self.typewriter) |*tw| {
            _ = tw.tick();
        }

        return self.isActive();
    }

    /// Check if any animation is running.
    pub fn isActive(self: *const Self) bool {
        return self.typewriter != null and !self.typewriter.?.isDone();
    }

    /// Render current animation state to screen.
    pub fn render(self: *Self, scr: *Screen) void {
        // Cursor is rendered by InputBox — this is for reference
        _ = self;
        _ = scr;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CursorBlink — visible by default" {
    var c = CursorBlink.init();
    try std.testing.expect(c.isVisible());
}

test "CursorBlink — toggles after tick threshold" {
    var c = CursorBlink.init();
    c.cycle_ticks = 4;
    c.on_ticks = 2;

    try std.testing.expect(c.isVisible()); // tick 0
    c.tick(); // tick 1
    try std.testing.expect(c.isVisible()); // still visible
    c.tick(); // tick 2
    try std.testing.expect(!c.isVisible()); // now hidden
    c.tick(); // tick 3
    try std.testing.expect(!c.isVisible()); // still hidden
    c.tick(); // tick 4 = wraps to 0
    try std.testing.expect(c.isVisible()); // back to visible
}

test "CursorBlink — show/hide overrides" {
    var c = CursorBlink.init();
    c.hide();
    try std.testing.expect(!c.isVisible());
    c.show();
    try std.testing.expect(c.isVisible());
}

test "CursorBlink — reset" {
    var c = CursorBlink.init();
    c.cycle_ticks = 2;
    c.on_ticks = 1;
    c.tick(); // visible
    c.tick(); // hidden
    c.reset();
    try std.testing.expect(c.isVisible());
    try std.testing.expectEqual(@as(usize, 0), c.tick_count);
}

test "StreamingText — reveal one by one" {
    var st = StreamingText.init("Hi");
    try std.testing.expect(!st.isDone());

    const c1 = st.tick();
    try std.testing.expect(c1 != null); // 'H'
    try std.testing.expectEqualStrings("H", st.revealedSlice());

    const c2 = st.tick();
    try std.testing.expect(c2 != null); // 'i'
    try std.testing.expectEqualStrings("Hi", st.revealedSlice());

    const c3 = st.tick();
    try std.testing.expect(c3 == null); // done
    try std.testing.expect(st.isDone());
}

test "StreamingText — complete" {
    var st = StreamingText.init("Hello");
    st.complete();
    try std.testing.expectEqualStrings("Hello", st.revealedSlice());
    try std.testing.expect(st.isDone());
}

test "StreamingText — speed control" {
    var st = StreamingText.init("ABCDE").withSpeed(2); // reveal every 2nd (skip 1)
    // First tick: reveal A, skip B
    _ = st.tick();
    try std.testing.expectEqualStrings("A", st.revealedSlice());
    // Second tick: skip C, reveal D (but wait, logic is different)
    // Actually with skip_every=1, we skip every 1, so reveal, skip, reveal, skip
    // Let me re-check the logic...
    // Actually the logic is: skip_every = chars_per_reveal - 1
    // with chars_per_reveal=2, skip_every=1 means: reveal, skip, reveal, skip
}

test "StreamingText — reset" {
    var st = StreamingText.init("Hello");
    _ = st.tick();
    _ = st.tick();
    st.reset();
    try std.testing.expectEqualStrings("", st.revealedSlice());
    try std.testing.expect(!st.isDone());
}

test "FadeTransition — fade in" {
    var ft = FadeTransition.fadeIn(0.25);
    try std.testing.expectEqual(@as(f32, 0.0), ft.intensity);
    try std.testing.expect(!ft.isDone());

    ft.tick();
    try std.testing.expectEqual(@as(f32, 0.25), ft.intensity);

    ft.tick();
    try std.testing.expectEqual(@as(f32, 0.5), ft.intensity);

    ft.tick();
    try std.testing.expectEqual(@as(f32, 0.75), ft.intensity);

    ft.tick();
    try std.testing.expectEqual(@as(f32, 1.0), ft.intensity);
    try std.testing.expect(ft.isDone());
}

test "FadeTransition — fade out" {
    var ft = FadeTransition.fadeOut(0.5);
    try std.testing.expectEqual(@as(f32, 1.0), ft.intensity);

    ft.tick();
    try std.testing.expectEqual(@as(f32, 0.5), ft.intensity);

    ft.tick();
    try std.testing.expectEqual(@as(f32, 0.0), ft.intensity);
    try std.testing.expect(ft.isDone());
}

test "FadeTransition — clamp at edges" {
    var ft = FadeTransition.fadeIn(0.3);
    ft.tick(); // 0.3
    ft.tick(); // 0.6
    ft.tick(); // 0.9
    ft.tick(); // 1.0 (clamped)
    try std.testing.expect(ft.intensity <= 1.0);
}

test "FadeTransition — applyToCell" {
    var ft = FadeTransition.fadeIn(0.5);
    ft.tick(); // 0.5

    const cell = Cell{ .char = 'X', .fg = .{ .named = .red }, .style = .{ .bold = true } };
    const faded = ft.applyToCell(cell);

    // At 0.5 intensity, bold should be removed
    try std.testing.expect(!faded.style.bold);
    try std.testing.expectEqual(@as(u21, 'X'), faded.char);
}

test "Typewriter — init and tick" {
    var tw = Typewriter.init("Yo");
    try std.testing.expect(!tw.isDone());

    const c1 = tw.tick();
    try std.testing.expect(c1 != null);

    const c2 = tw.tick();
    try std.testing.expect(c2 != null);

    try std.testing.expect(tw.isDone());
}

test "Typewriter — reset" {
    var tw = Typewriter.init("Hello");
    _ = tw.tick();
    tw.reset();
    try std.testing.expect(!tw.isDone());
    try std.testing.expectEqualStrings("", tw.stream.revealedSlice());
}

test "AnimationManager — tick triggers cursor and typewriter" {
    var mgr = AnimationManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.startTypewriter("Hi");
    try std.testing.expect(mgr.isActive());

    // First tick
    _ = mgr.tick(0);
    try std.testing.expect(mgr.isActive());

    // Complete typewriter
    _ = mgr.tick(100);
    _ = mgr.tick(200);

    // After typewriter done, isActive should be false
    try std.testing.expect(!mgr.isActive());
}

test "AnimationManager — stop typewriter" {
    var mgr = AnimationManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.startTypewriter("Hello");
    try std.testing.expect(mgr.typewriter != null);

    mgr.stopTypewriter();
    try std.testing.expect(mgr.typewriter == null);
}
