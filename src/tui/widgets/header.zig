const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_helpers = @import("widget_helpers");

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
        const title = vxfw.RichText{
            .text = &.{.{ .text = self.title, .style = .{ .fg = self.theme.header_fg, .bg = self.theme.header_bg, .bold = true } }},
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const line = try widget_helpers.repeated(ctx.arena, "─", width);
        const separator = vxfw.Text{
            .text = line,
            .style = .{ .fg = self.theme.border, .bg = self.theme.header_bg, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const separator_surface = try separator.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 2 });
        @memset(surface.buffer, .{ .style = bg_style });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = title_surface };
        children[1] = .{ .origin = .{ .row = 1, .col = 0 }, .surface = separator_surface };

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};
