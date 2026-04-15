const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_types = @import("widget_types");
const widget_helpers = @import("widget_helpers");

const vxfw = vaxis.vxfw;

pub const SidebarContext = struct {
    recent_files: []const []const u8,
    request_count: u32,
    total_input_tokens: u64,
    total_output_tokens: u64,
    estimated_cost_usd: f64,
    session_minutes: u32,
    session_seconds_part: u32,
    workers: []const widget_types.WorkerItem,
    theme_name: []const u8,
    current_theme: *const theme_mod.Theme,
};

pub const FilesWidget = struct {
    files: []const []const u8,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const FilesWidget) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = typeErasedDrawFn };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const FilesWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const FilesWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
        @memset(surface.buffer, .{ .style = .{} });

        if (self.files.len == 0) return surface;

        var buffer = std.ArrayList(u8).empty;
        try buffer.appendSlice(ctx.arena, "📄 Files: ");
        for (self.files, 0..) |file, idx| {
            if (idx > 0) try buffer.appendSlice(ctx.arena, ", ");
            try buffer.appendSlice(ctx.arena, file);
        }

        const text = vxfw.Text{
            .text = try buffer.toOwnedSlice(ctx.arena),
            .style = .{ .fg = self.theme.dimmed, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const text_surface = try text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = text_surface };
        return .{ .size = surface.size, .widget = self.widget(), .buffer = surface.buffer, .children = children };
    }
};

pub const SidebarWidget = struct {
    context: *const SidebarContext,
    width: u16,

    pub fn widget(self: *const SidebarWidget) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = typeErasedDrawFn };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SidebarWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const SidebarWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const height = ctx.max.height orelse 30;
        const width = self.width;
        const theme = self.context.current_theme;
        const w = width - 2;

        var child_idx: usize = 0;
        var children = try ctx.arena.alloc(vxfw.SubSurface, 20);
        var row: u16 = 1;

        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildSectionTitle(ctx, "Files", w, theme),
        };
        child_idx += 1;
        row += 1;

        const files = self.context.recent_files;
        for (files, 0..) |file, idx| {
            if (idx >= 5) break;
            const truncated = if (file.len > w) file[0..w] else file;
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 1 },
                .surface = try self.buildText(ctx, truncated, self.width - 2, .{ .fg = theme.dimmed }),
            };
            child_idx += 1;
            row += 1;
        }
        if (files.len > 5) {
            const txt = try std.fmt.allocPrint(ctx.arena, "+{d} more", .{files.len - 5});
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 1 },
                .surface = try self.buildText(ctx, txt, self.width - 2, .{ .fg = theme.dimmed }),
            };
            child_idx += 1;
            row += 1;
        }
        if (files.len == 0) {
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 1 },
                .surface = try self.buildText(ctx, "(none)", self.width - 2, .{ .fg = theme.dimmed }),
            };
            child_idx += 1;
            row += 1;
        }

        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildSectionTitle(ctx, "Session", w, theme),
        };
        child_idx += 1;
        row += 1;

        const turns_txt = try std.fmt.allocPrint(ctx.arena, "turns: {d}", .{self.context.request_count});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, turns_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const tokens_txt = try std.fmt.allocPrint(ctx.arena, "tokens: {d}", .{self.context.total_input_tokens + self.context.total_output_tokens});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, tokens_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const cost_txt = try std.fmt.allocPrint(ctx.arena, "cost: ${d:.4}", .{self.context.estimated_cost_usd});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, cost_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const time_txt = try std.fmt.allocPrint(ctx.arena, "{d}m{d}s", .{ self.context.session_minutes, self.context.session_seconds_part });
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, time_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildSectionTitle(ctx, "Workers", w, theme),
        };
        child_idx += 1;
        row += 1;

        if (self.context.workers.len == 0) {
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 1 },
                .surface = try self.buildText(ctx, "(none)", self.width - 2, .{ .fg = theme.dimmed }),
            };
            child_idx += 1;
            row += 1;
        } else {
            var idx: usize = 0;
            for (self.context.workers) |w_item| {
                if (idx >= 3) break;
                const status_ch: u8 = switch (w_item.status) {
                    .pending => 'P',
                    .running => 'R',
                    .done => 'D',
                    .@"error" => 'E',
                    .cancelled => 'C',
                };
                const status_style: vaxis.Style = switch (w_item.status) {
                    .pending => .{ .fg = theme.dimmed },
                    .running => .{ .fg = theme.accent },
                    .done => .{ .fg = .{ .index = 10 } },
                    .@"error" => .{ .fg = .{ .index = 1 } },
                    .cancelled => .{ .fg = theme.dimmed },
                };
                idx += 1;
                const id_txt = try std.fmt.allocPrint(ctx.arena, "#{d}", .{w_item.id});
                const combined_txt = try std.fmt.allocPrint(ctx.arena, "[{c}] {s}", .{ status_ch, id_txt });
                children[child_idx] = .{
                    .origin = .{ .row = row, .col = 1 },
                    .surface = try self.buildText(ctx, combined_txt, 8, status_style),
                };
                child_idx += 1;

                const task_truncated = if (w_item.task.len > w - 9) w_item.task[0..(w - 9)] else w_item.task;
                children[child_idx] = .{
                    .origin = .{ .row = row, .col = 9 },
                    .surface = try self.buildText(ctx, task_truncated, self.width - 10, .{ .fg = theme.dimmed }),
                };
                child_idx += 1;
                row += 1;
            }
            if (self.context.workers.len > 3) {
                const overflow_txt = try std.fmt.allocPrint(ctx.arena, "+{d} more", .{self.context.workers.len - 3});
                children[child_idx] = .{
                    .origin = .{ .row = row, .col = 1 },
                    .surface = try self.buildText(ctx, overflow_txt, self.width - 2, .{ .fg = theme.dimmed }),
                };
                child_idx += 1;
                row += 1;
            }
        }

        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildSectionTitle(ctx, "Theme", w, theme),
        };
        child_idx += 1;
        row += 1;

        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, self.context.theme_name, self.width - 2, .{ .fg = theme.accent }),
        };
        child_idx += 1;
        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, "/theme dark", self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, "/theme light", self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, "/theme mono", self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = theme.header_bg } });
        widget_helpers.drawBorder(&surface, .{ .fg = theme.border });

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children[0..child_idx],
        };
    }

    fn buildSectionTitle(_: *const SidebarWidget, ctx: vxfw.DrawContext, title: []const u8, width: u16, theme: *const theme_mod.Theme) std.mem.Allocator.Error!vxfw.Surface {
        var line = std.ArrayList(u8).empty;
        try line.appendSlice(ctx.arena, title);
        try line.appendSlice(ctx.arena, " ");
        const missing: u16 = if (line.items.len >= width) 0 else width - @as(u16, @intCast(line.items.len));
        var i: u16 = 0;
        while (i < missing) : (i += 1) {
            try line.append(ctx.arena, '-');
        }
        const text = vxfw.Text{
            .text = line.items,
            .style = .{ .fg = theme.dimmed, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        return text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }

    fn buildText(_: *const SidebarWidget, ctx: vxfw.DrawContext, text_content: []const u8, width: u16, style: vaxis.Style) std.mem.Allocator.Error!vxfw.Surface {
        const text = vxfw.Text{
            .text = text_content,
            .style = style,
            .softwrap = false,
            .width_basis = .parent,
        };
        return text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }
};
