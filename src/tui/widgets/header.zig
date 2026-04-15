const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

const vxfw = vaxis.vxfw;

pub const HeaderWidget = struct {
    title: []const u8,
    theme: *const theme_mod.Theme,

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
