const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

const vxfw = vaxis.vxfw;

pub const HeaderWidget = struct {
    title: []const u8,
    theme: *const theme_mod.Theme,
    context_pct: u8 = 0,
    file_count: u32 = 0,

    pub fn widget(self: *const HeaderWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const HeaderWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const HeaderWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const bg_style: vaxis.Style = .{ .fg = self.theme.header_fg, .bg = self.theme.header_bg };

        // Truncate title with ellipsis if it exceeds available width
        const display_title: []const u8 = if (self.title.len > width) blk: {
            const trunc_len = if (width > 1) width - 1 else 0;
            break :blk if (self.title.len > trunc_len) self.title[0..trunc_len] else self.title;
        } else self.title;
        const show_ellipsis = self.title.len > width;

        const title = vxfw.RichText{
            .text = &.{
                .{ .text = display_title, .style = .{ .fg = self.theme.header_fg, .bg = self.theme.header_bg, .bold = true } },
                .{ .text = if (show_ellipsis) "…" else "", .style = .{ .fg = self.theme.dimmed, .bg = self.theme.header_bg } },
            },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
        @memset(surface.buffer, .{ .style = bg_style });

        // Build context info string for right-aligned display
        var context_buf: [64]u8 = undefined;
        const context_text = std.fmt.bufPrint(&context_buf, "ctx:{d}% | {d} files", .{ self.context_pct, self.file_count }) catch &.{};
        const context_len = context_text.len;
        const context_col = if (context_len < width) width - context_len else 0;

        // Write context info characters directly into the surface buffer
        if (context_col < width and context_len > 0) {
            // Color-code context percentage: <50% dimmed, 50-70% yellow, >70% red
            const context_style: vaxis.Style = if (self.context_pct < 50)
                .{ .fg = self.theme.dimmed, .bg = self.theme.header_bg }
            else if (self.context_pct <= 70)
                .{ .fg = .{ .index = 11 }, .bg = self.theme.header_bg }
            else
                .{ .fg = .{ .index = 9 }, .bg = self.theme.header_bg };

            const end = @min(context_col + context_len, width);
            const copy_len = end - context_col;
            for (0..copy_len) |i| {
                const byte = context_text[i];
                const gp = switch (byte) {
                    0...127 => &[_]u8{byte},
                    else => &[_]u8{byte}, // ASCII-only context info is fine
                };
                surface.buffer[context_col + i].char = .{ .grapheme = gp, .width = 1 };
                surface.buffer[context_col + i].style = context_style;
            }
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = title_surface };

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};
