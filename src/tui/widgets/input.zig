const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");

const vxfw = vaxis.vxfw;

pub const InputWidget = struct {
    prompt: []const u8,
    field: *vxfw.TextField,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const InputWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const InputWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const InputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const prompt_text = vxfw.Text{
            .text = self.prompt,
            .style = .{ .fg = self.theme.accent, .bold = true },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        const field_widget = self.field.widget();
        var row = vxfw.FlexRow{
            .children = &.{
                .{ .widget = prompt_text.widget(), .flex = 0 },
                .{ .widget = field_widget, .flex = 1 },
            },
        };
        return row.draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = ctx.max.width, .height = 1 }));
    }
};
