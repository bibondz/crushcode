const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_types = @import("widget_types");
const widget_helpers = @import("widget_helpers");
const diff_mod = @import("diff");

const vxfw = vaxis.vxfw;

const ToolPermission = widget_types.ToolPermission;

const drawBorder = widget_helpers.drawBorder;

pub const PermissionContext = struct {
    pending: ?ToolPermission,
    theme: *const theme_mod.Theme,
};

pub const PermissionDialogWidget = struct {
    context: *const PermissionContext,

    pub fn widget(self: *const PermissionDialogWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const PermissionDialogWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const PermissionDialogWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const pending = self.context.pending orelse {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        };

        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        var width: u16 = @min(max.width -| 4, @as(u16, 84));
        if (width < 36) width = @min(max.width, @as(u16, 36));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title = vxfw.Text{
            .text = "Tool permission required",
            .style = .{ .fg = self.context.theme.header_fg, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface });

        const tool_line = try std.fmt.allocPrint(ctx.arena, "Allow {s}?", .{pending.tool_name});
        const tool_text = vxfw.Text{
            .text = tool_line,
            .style = .{ .fg = self.context.theme.tool_pending, .bold = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const tool_surface = try tool_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = 9999 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 3, .col = 2 }, .surface = tool_surface });

        // Tier badge
        const tier_text = if (std.mem.eql(u8, pending.tool_tier, "READ"))
            "[READ — auto-allowed]"
        else if (std.mem.eql(u8, pending.tool_tier, "WRITE"))
            "[WRITE — requires approval]"
        else if (std.mem.eql(u8, pending.tool_tier, "DESTRUCTIVE"))
            "[DESTRUCTIVE — proceed with caution]"
        else
            "[unknown tier]";

        const tier_style: vaxis.Cell.Style = if (std.mem.eql(u8, pending.tool_tier, "READ"))
            .{ .fg = self.context.theme.tool_success }
        else if (std.mem.eql(u8, pending.tool_tier, "WRITE"))
            .{ .fg = self.context.theme.header_fg }
        else if (std.mem.eql(u8, pending.tool_tier, "DESTRUCTIVE"))
            .{ .fg = self.context.theme.error_fg, .bold = true }
        else
            .{ .fg = self.context.theme.dimmed };

        const tier_label = vxfw.Text{
            .text = tier_text,
            .style = tier_style,
            .softwrap = false,
            .width_basis = .parent,
        };
        const tier_row: u16 = @intCast(4 + tool_surface.size.height);
        const tier_surface = try tier_label.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = tier_row, .col = 2 }, .surface = tier_surface });

        const args_text = vxfw.Text{
            .text = pending.arguments,
            .style = .{ .fg = self.context.theme.dimmed, .dim = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const args_surface = try args_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = 9999 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(tier_row + 1 + tier_surface.size.height), .col = 2 }, .surface = args_surface });

        // Diff preview section (Phase 23)
        var current_row: u16 = @intCast(tier_row + 2 + tier_surface.size.height + args_surface.size.height);
        if (pending.preview_diff) |diff_text| {
            const diff_theme = diff_mod.diffThemeFromAppTheme(self.context.theme);
            const diff_segments = diff_mod.parseDiff(ctx.arena, diff_text, 20, diff_theme) catch &.{};
            if (diff_segments.len > 0) {
                const diff_rich = vxfw.RichText{
                    .text = diff_segments,
                    .softwrap = false,
                    .width_basis = .parent,
                };
                if (diff_rich.draw(ctx.withConstraints(
                    .{ .width = inner_width, .height = 1 },
                    .{ .width = inner_width, .height = 20 },
                ))) |surf| {
                    try child_list.append(ctx.arena, .{
                        .origin = .{ .row = @intCast(current_row), .col = 2 },
                        .surface = surf,
                    });
                    current_row += @intCast(surf.size.height + 1);
                } else |_| {
                    // If diff rendering fails, just skip it
                }
            }
        }

        const footer_line = "[y] Yes   [n] No   [a] Always   [Esc] Cancel";
        const footer = vxfw.Text{
            .text = footer_line,
            .style = .{ .fg = self.context.theme.tool_success, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const footer_row: u16 = current_row;
        const footer_surface = try footer.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = footer_row, .col = 2 }, .surface = footer_surface });

        const height: u16 = footer_row + 2;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.context.theme.code_bg } });
        drawBorder(&surface, .{ .fg = self.context.theme.tool_pending });

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_list.items.len);
        @memcpy(children, child_list.items);
        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};
