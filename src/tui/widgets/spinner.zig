const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_helpers = @import("widget_helpers");

const vxfw = vaxis.vxfw;

/// Braille animation frames for the spinner.
pub const braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// ASCII fallback frames for terminals without Unicode support.
pub const ascii_frames = [_][]const u8{ "-", "\\", "|", "/" };

/// Gradient colors cycled during normal (non-stalled) spinning.
/// NOTE: These are fallback defaults; frameColor() uses theme fields when available.
const gradient_defaults = [_]vaxis.Color{
    .{ .index = 12 }, // bright cyan
    .{ .index = 14 }, // bright blue
    .{ .index = 13 }, // bright magenta
    .{ .index = 11 }, // bright yellow
    .{ .index = 10 }, // bright green
    .{ .index = 14 }, // bright blue
    .{ .index = 12 }, // bright cyan
};

/// Stalled detection threshold in milliseconds.
const stall_threshold_ms: i64 = 5000;

/// AnimatedSpinner — renders a braille frame spinner with gradient color cycling,
/// stalled-stream detection, elapsed time, and optional token counter.
///
/// Usage:
///   1. Create: `var spinner = AnimatedSpinner.init(theme);`
///   2. Call `tick()` periodically (every ~100ms) to advance animation.
///   3. Call `feedToken()` when a streaming token arrives (resets stall timer).
///   4. Render via `SpinnerWidget{ .spinner = &spinner }` in vxfw tree.
///   5. Call `deinit()` when done (frees allocated strings).
pub const AnimatedSpinner = struct {
    theme: *const theme_mod.Theme,
    frame_idx: usize,
    start_ms: i64,
    last_token_ms: i64,
    stalled: bool,
    tick_count: usize,
    unicode: bool,

    /// Token counter (updated externally)
    token_count: u64,

    const Self = @This();

    /// Initialize spinner. Starts timing from now.
    pub fn init(theme: *const theme_mod.Theme) Self {
        const now = std.time.milliTimestamp();
        return .{
            .theme = theme,
            .frame_idx = 0,
            .start_ms = now,
            .last_token_ms = now,
            .stalled = false,
            .tick_count = 0,
            .token_count = 0,
            .unicode = true,
        };
    }

    /// Initialize spinner with explicit Unicode support flag.
    pub fn initWithUnicode(theme: *const theme_mod.Theme, unicode: bool) Self {
        var s = init(theme);
        s.unicode = unicode;
        return s;
    }

    /// Advance animation frame. Call every ~100ms.
    pub fn tick(self: *Self) void {
        const max_frames: usize = if (self.unicode) braille_frames.len else ascii_frames.len;
        self.frame_idx = (self.frame_idx + 1) % max_frames;
        self.tick_count += 1;

        // Check stalled: no token received for stall_threshold_ms
        const now = std.time.milliTimestamp();
        if (now - self.last_token_ms > stall_threshold_ms) {
            self.stalled = true;
        } else {
            self.stalled = false;
        }
    }

    /// Called when a streaming token arrives. Resets stall timer.
    pub fn feedToken(self: *Self) void {
        self.last_token_ms = std.time.milliTimestamp();
        self.token_count += 1;
        self.stalled = false;
    }

    /// Get elapsed time in seconds since init.
    pub fn elapsedSeconds(self: *const Self) f64 {
        const now = std.time.milliTimestamp();
        if (now <= self.start_ms) return 0.0;
        const delta_ms: f64 = @floatFromInt(now - self.start_ms);
        return delta_ms / 1000.0;
    }

    /// Get current spinner character.
    pub fn frame(self: *const Self) []const u8 {
        if (self.unicode) {
            return braille_frames[self.frame_idx % braille_frames.len];
        }
        return ascii_frames[self.frame_idx % ascii_frames.len];
    }

    /// Get the color for the current frame.
    pub fn frameColor(self: *const Self) vaxis.Color {
        if (self.stalled) {
            return self.theme.spinner_stalled_fg;
        }
        const theme_gradient = [_]vaxis.Color{
            self.theme.spinner_g1,
            self.theme.spinner_g2,
            self.theme.spinner_g3,
            self.theme.spinner_g4,
            self.theme.spinner_g5,
            self.theme.spinner_g6,
            self.theme.spinner_g7,
        };
        return theme_gradient[self.tick_count % theme_gradient.len];
    }

    /// Format elapsed time as "Xm Ys" or "Y.Zs".
    pub fn formatElapsed(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const elapsed = self.elapsedSeconds();
        if (elapsed >= 60.0) {
            const mins: u32 = @intFromFloat(@floor(elapsed / 60.0));
            const secs: u32 = @intFromFloat(@floor(@mod(elapsed, 60.0)));
            return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ mins, secs });
        }
        return std.fmt.allocPrint(allocator, "{d:.1}s", .{elapsed});
    }
};

/// SpinnerWidget — vxfw widget that renders an AnimatedSpinner.
///
/// Displays: `[spinner_frame] Thinking... [elapsed] [tokens]`
/// When stalled: red spinner + "Stalled" label
pub const SpinnerWidget = struct {
    spinner: *AnimatedSpinner,

    pub fn widget(self: *const SpinnerWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SpinnerWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SpinnerWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const s = self.spinner;
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const width = max.width;

        const frame_char = s.frame();
        const frame_color = s.frameColor();
        const status_text: []const u8 = if (s.stalled) "Stalled..." else "Thinking...";
        const elapsed_text = s.formatElapsed(ctx.arena) catch "0.0s";

        // Build segments array (max 7: frame, space, status, space, elapsed, space, tokens)
        const Segment = struct { text: []const u8, style: vaxis.Style };
        var segs: [7]Segment = undefined;
        var count: usize = 0;

        // Spinner frame with color
        segs[count] = .{ .text = frame_char, .style = .{ .fg = frame_color, .bold = true } };
        count += 1;
        segs[count] = .{ .text = " ", .style = .{} };
        count += 1;

        // Status text
        if (s.stalled) {
            segs[count] = .{ .text = status_text, .style = .{ .fg = .{ .index = 9 }, .bold = true } };
        } else {
            segs[count] = .{ .text = status_text, .style = .{ .fg = s.theme.assistant_fg } };
        }
        count += 1;

        // Elapsed time
        segs[count] = .{ .text = "  ", .style = .{} };
        count += 1;
        segs[count] = .{ .text = elapsed_text, .style = .{ .fg = s.theme.dimmed, .dim = true } };
        count += 1;

        // Token counter (only show if > 0)
        if (s.token_count > 0) {
            const token_text = std.fmt.allocPrint(ctx.arena, "  {} tokens", .{s.token_count}) catch "  ? tokens";
            segs[count] = .{ .text = token_text, .style = .{ .fg = s.theme.dimmed, .dim = true } };
            count += 1;
        }

        // Cast our Segment array to the anonymous struct type RichText expects
        // RichText.text is []const struct { text: []const u8, style: vaxis.Style }
        const TextSegment = @TypeOf(@as(vxfw.RichText, undefined).text);
        const ChildSeg = std.meta.Child(TextSegment);

        // Allocate on arena and cast each segment
        const arena_segs = try ctx.arena.alloc(ChildSeg, count);
        for (0..count) |i| {
            arena_segs[i] = .{ .text = segs[i].text, .style = segs[i].style };
        }

        const rich = vxfw.RichText{
            .text = arena_segs,
            .softwrap = false,
            .width_basis = .longest_line,
        };

        return rich.draw(ctx.withConstraints(
            .{ .width = width, .height = 1 },
            .{ .width = width, .height = 1 },
        ));
    }
};
