const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

const vxfw = vaxis.vxfw;

/// Predefined gradient presets for branding.
pub const Preset = enum {
    crushcode, // cyan → magenta → gold
    ocean, // deep blue → cyan → teal
    sunset, // orange → pink → purple
    forest, // green → lime → gold
    neon, // magenta → cyan → green

    /// Get the RGB stops for this preset.
    pub fn stops(self: Preset) [3][3]u8 {
        return switch (self) {
            .crushcode => .{ .{ 0x00, 0xDD, 0xDD }, .{ 0xDD, 0x44, 0xDD }, .{ 0xFF, 0xDD, 0x44 } },
            .ocean => .{ .{ 0x00, 0x44, 0xBB }, .{ 0x00, 0xBB, 0xDD }, .{ 0x00, 0x88, 0x88 } },
            .sunset => .{ .{ 0xFF, 0x88, 0x00 }, .{ 0xFF, 0x44, 0x88 }, .{ 0xAA, 0x22, 0xDD } },
            .forest => .{ .{ 0x22, 0xBB, 0x44 }, .{ 0x88, 0xDD, 0x22 }, .{ 0xDD, 0xBB, 0x22 } },
            .neon => .{ .{ 0xDD, 0x22, 0xDD }, .{ 0x22, 0xDD, 0xDD }, .{ 0x22, 0xDD, 0x44 } },
        };
    }
};

/// Linearly interpolate between two RGB colors.
/// t is in [0.0, 1.0].
pub fn lerpRgb(a: [3]u8, b: [3]u8, t: f32) [3]u8 {
    const tc = @max(0.0, @min(1.0, t));
    return .{
        @intFromFloat(@as(f32, @floatFromInt(a[0])) + (@as(f32, @floatFromInt(b[0])) - @as(f32, @floatFromInt(a[0]))) * tc),
        @intFromFloat(@as(f32, @floatFromInt(a[1])) + (@as(f32, @floatFromInt(b[1])) - @as(f32, @floatFromInt(a[1]))) * tc),
        @intFromFloat(@as(f32, @floatFromInt(a[2])) + (@as(f32, @floatFromInt(b[2])) - @as(f32, @floatFromInt(a[2]))) * tc),
    };
}

/// Compute the gradient color at position i out of total_len, using the given stops.
/// Stops are evenly spaced. For 3 stops: stop[0] at t=0, stop[1] at t=0.5, stop[2] at t=1.0.
pub fn gradientColor(stops_array: [3][3]u8, i: usize, total_len: usize) vaxis.Color {
    if (total_len <= 1) return .{ .rgb = stops_array[0] };
    const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(total_len - 1));

    // 3 stops evenly spaced: [0.0, 0.5, 1.0]
    const segment: usize = if (t < 0.5) 0 else 1;
    const local_t: f32 = if (t < 0.5) t * 2.0 else (t - 0.5) * 2.0;

    const rgb = lerpRgb(stops_array[segment], stops_array[segment + 1], local_t);
    return .{ .rgb = rgb };
}

/// GradientText — builds a RichText with per-character gradient coloring.
///
/// Usage:
///   const gt = GradientText.init("Crushcode", .crushcode, true);
///   const surface = try gt.draw(ctx);
pub const GradientText = struct {
    text: []const u8,
    stops: [3][3]u8,
    bold: bool,
    bg: vaxis.Color,

    pub fn init(text: []const u8, preset: Preset, is_bold: bool) @This() {
        return .{
            .text = text,
            .stops = preset.stops(),
            .bold = is_bold,
            .bg = .default,
        };
    }

    pub fn initWithBg(text: []const u8, preset: Preset, is_bold: bool, bg_color: vaxis.Color) @This() {
        return .{
            .text = text,
            .stops = preset.stops(),
            .bold = is_bold,
            .bg = bg_color,
        };
    }

    /// Build gradient segments. Each Unicode codepoint gets its own color.
    /// Returns a Surface.
    pub fn draw(self: *const @This(), ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        const width = max.width;

        if (self.text.len == 0) {
            const rich = vxfw.RichText{
                .text = &.{},
                .softwrap = false,
                .width_basis = .longest_line,
            };
            return rich.draw(ctx.withConstraints(
                .{ .width = width, .height = 1 },
                .{ .width = width, .height = 1 },
            ));
        }

        // Pass 1: count codepoints
        var num_codepoints: usize = 0;
        var i: usize = 0;
        while (i < self.text.len) : (num_codepoints += 1) {
            const byte = self.text[i];
            if (byte < 0x80) {
                i += 1;
            } else {
                i += 1;
                while (i < self.text.len and self.text[i] & 0xC0 == 0x80) {
                    i += 1;
                }
            }
        }

        // Pass 2: allocate and fill segments
        const segs = try ctx.arena.alloc(vaxis.Segment, num_codepoints);
        var char_idx: usize = 0;
        i = 0;
        while (i < self.text.len) : (char_idx += 1) {
            const start = i;
            const byte = self.text[i];
            if (byte < 0x80) {
                i += 1;
            } else {
                i += 1;
                while (i < self.text.len and self.text[i] & 0xC0 == 0x80) {
                    i += 1;
                }
            }
            const color = gradientColor(self.stops, char_idx, num_codepoints);
            segs[char_idx] = .{
                .text = self.text[start..i],
                .style = .{ .fg = color, .bg = self.bg, .bold = self.bold },
            };
        }

        const rich = vxfw.RichText{
            .text = segs,
            .softwrap = false,
            .width_basis = .longest_line,
        };

        return rich.draw(ctx.withConstraints(
            .{ .width = width, .height = 1 },
            .{ .width = width, .height = 1 },
        ));
    }
};
