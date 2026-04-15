const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

const vxfw = vaxis.vxfw;

/// Minimum delay per character in milliseconds.
const min_char_delay_ms: i64 = 30;

/// Maximum delay per character in milliseconds.
const max_char_delay_ms: i64 = 80;

/// Blink interval for the cursor in milliseconds.
const cursor_blink_ms: i64 = 530;

/// TypewriterState — tracks per-character reveal state for streaming text.
///
/// Instead of revealing the entire text at once, this reveals characters
/// progressively with a typewriter effect, including a blinking cursor.
///
/// Usage:
///   1. Create: `var tw = TypewriterState.init(theme);`
///   2. Set text: `tw.setText("Hello world");`
///   3. Call `tick()` periodically (~50ms) to advance reveal.
///   4. Render via `TypewriterWidget{ .state = &tw }`.
///   5. Call `deinit()` when done.
pub const TypewriterState = struct {
    /// Full text to reveal.
    full_text: []const u8,
    /// Number of codepoints currently revealed.
    revealed: usize,
    /// Total codepoints in full_text.
    total_codepoints: usize,
    /// Timestamp of last reveal advancement.
    last_reveal_ms: i64,
    /// Current delay for next character (randomized within range).
    next_delay_ms: i64,
    /// Cursor blink toggle (true = visible).
    cursor_visible: bool,
    /// Timestamp of last cursor blink toggle.
    last_blink_ms: i64,
    /// Whether all text has been revealed.
    complete: bool,
    /// Theme for styling.
    theme: *const theme_mod.Theme,
    /// Random seed state for delay randomization.
    rng_state: u64,

    const Self = @This();

    /// Initialize typewriter state.
    pub fn init(theme: *const theme_mod.Theme) Self {
        const now = std.time.milliTimestamp();
        return .{
            .full_text = "",
            .revealed = 0,
            .total_codepoints = 0,
            .last_reveal_ms = now,
            .next_delay_ms = min_char_delay_ms,
            .cursor_visible = true,
            .last_blink_ms = now,
            .complete = true,
            .theme = theme,
            .rng_state = @intCast(std.time.nanoTimestamp()),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No allocations to free — full_text is borrowed reference
    }

    /// Set the text to reveal. Resets reveal progress.
    /// Note: text must outlive this struct (borrowed reference).
    pub fn setText(self: *Self, text: []const u8) void {
        self.full_text = text;
        self.revealed = 0;
        self.total_codepoints = countCodepoints(text);
        self.complete = (text.len == 0);
        self.last_reveal_ms = std.time.milliTimestamp();
        self.next_delay_ms = randomDelay(&self.rng_state);
    }

    /// Append more text to the existing buffer (for streaming).
    /// Revealed count stays the same — new text will be gradually revealed.
    pub fn appendText(self: *Self, text: []const u8) void {
        _ = text;
        // Note: Since full_text is a borrowed slice, streaming append
        // is handled by the caller updating the text and calling setText
        // or updateText. We re-count codepoints.
        self.total_codepoints = countCodepoints(self.full_text);
        self.complete = (self.revealed >= self.total_codepoints);
    }

    /// Update the full text without resetting reveal position.
    /// Used during streaming when the text grows.
    pub fn updateText(self: *Self, text: []const u8) void {
        self.full_text = text;
        self.total_codepoints = countCodepoints(text);
        self.complete = (self.revealed >= self.total_codepoints);
    }

    /// Advance reveal by one character if enough time has elapsed.
    /// Call periodically (~50ms intervals).
    pub fn tick(self: *Self) void {
        if (self.complete) return;

        const now = std.time.milliTimestamp();

        // Advance cursor blink
        if (now - self.last_blink_ms >= cursor_blink_ms) {
            self.cursor_visible = !self.cursor_visible;
            self.last_blink_ms = now;
        }

        // Advance reveal
        if (now - self.last_reveal_ms >= self.next_delay_ms) {
            self.revealed += 1;
            self.last_reveal_ms = now;
            self.next_delay_ms = randomDelay(&self.rng_state);

            if (self.revealed >= self.total_codepoints) {
                self.revealed = self.total_codepoints;
                self.complete = true;
            }
        }
    }

    /// Get the revealed portion of text as a byte slice.
    pub fn revealedText(self: *const Self) []const u8 {
        if (self.revealed == 0) return "";
        return sliceCodepoints(self.full_text, self.revealed);
    }

    /// Get the remaining unrevealed text.
    pub fn unrevealedText(self: *const Self) []const u8 {
        const revealed_slice = self.revealedText();
        if (revealed_slice.len >= self.full_text.len) return "";
        return self.full_text[revealed_slice.len..];
    }

    /// Immediately reveal all text (skip animation).
    pub fn revealAll(self: *Self) void {
        self.revealed = self.total_codepoints;
        self.complete = true;
    }
};

/// Count the number of Unicode codepoints in a UTF-8 string.
fn countCodepoints(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else {
            i += 1;
            while (i < text.len and text[i] & 0xC0 == 0x80) {
                i += 1;
            }
        }
    }
    return count;
}

/// Get a byte slice covering the first `n` codepoints.
fn sliceCodepoints(text: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < n) : (count += 1) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else {
            i += 1;
            while (i < text.len and text[i] & 0xC0 == 0x80) {
                i += 1;
            }
        }
    }
    return text[0..i];
}

/// Generate a random delay between min and max using xorshift64.
fn randomDelay(state: *u64) i64 {
    // xorshift64
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;

    const range = max_char_delay_ms - min_char_delay_ms;
    const offset: i64 = @intCast(@mod(x, @as(u64, @intCast(range))));
    return min_char_delay_ms + offset;
}

/// TypewriterWidget — vxfw widget that renders typewriter-revealed text.
///
/// Shows the revealed portion in normal text style, with a blinking
/// cursor character at the reveal boundary when not complete.
pub const TypewriterWidget = struct {
    state: *TypewriterState,

    pub fn widget(self: *const TypewriterWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const TypewriterWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const TypewriterWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const s = self.state;
        const max = ctx.max.size();
        const width = max.width;

        const revealed = s.revealedText();
        const show_cursor = !s.complete and s.cursor_visible;

        // Build segments: [revealed_text] [cursor?]
        const seg_count: usize = if (show_cursor) 2 else if (revealed.len > 0) 1 else 0;
        if (seg_count == 0) {
            return vxfw.Surface{
                .size = .{ .width = 0, .height = 0 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const segs = try ctx.arena.alloc(vaxis.Segment, seg_count);
        var idx: usize = 0;

        // Revealed text in assistant style
        if (revealed.len > 0) {
            segs[idx] = .{
                .text = revealed,
                .style = .{ .fg = s.theme.assistant_fg },
            };
            idx += 1;
        }

        // Blinking cursor block
        if (show_cursor) {
            segs[idx] = .{
                .text = "▌",
                .style = .{ .fg = s.theme.accent, .bold = true },
            };
        }

        const rich = vxfw.RichText{
            .text = segs,
            .softwrap = true,
            .width_basis = .longest_line,
        };

        return rich.draw(ctx.withConstraints(
            .{ .width = width, .height = 1 },
            .{ .width = width, .height = max.height },
        ));
    }
};
