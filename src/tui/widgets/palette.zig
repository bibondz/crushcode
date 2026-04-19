const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_types = @import("widget_types");
const widget_helpers = @import("widget_helpers");
const widget_input = @import("widget_input");
const session_mod = @import("session");

const vxfw = vaxis.vxfw;

const session_row_display_max = widget_types.session_row_display_max;

const repeated = widget_helpers.repeated;
const drawBorder = widget_helpers.drawBorder;

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    shortcut: []const u8,
};

pub const palette_command_data = [_]Command{
    .{ .name = "/clear", .description = "Clear conversation history", .shortcut = "clr" },
    .{ .name = "/sessions", .description = "Browse saved sessions", .shortcut = "ss" },
    .{ .name = "/ls", .description = "Alias for /sessions", .shortcut = "ls" },
    .{ .name = "/exit", .description = "Exit crushcode", .shortcut = "q" },
    .{ .name = "/model", .description = "Show current model", .shortcut = "m" },
    .{ .name = "/thinking", .description = "Toggle thinking mode", .shortcut = "t" },
    .{ .name = "/compact", .description = "Compact conversation context", .shortcut = "c" },
    .{ .name = "/theme dark", .description = "Switch to dark theme", .shortcut = "td" },
    .{ .name = "/theme light", .description = "Switch to light theme", .shortcut = "tl" },
    .{ .name = "/theme mono", .description = "Switch to monochrome theme", .shortcut = "tm" },
    .{ .name = "/workers", .description = "List active workers", .shortcut = "w" },
    .{ .name = "/kill", .description = "Kill a worker: /kill <id>", .shortcut = "k" },
    .{ .name = "/help", .description = "Show available commands", .shortcut = "h" },
    .{ .name = "/plan on", .description = "Enable plan mode (propose before executing)", .shortcut = "p" },
};

pub const CommandRowWidget = struct {
    command: Command,
    selected: bool,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const CommandRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const CommandRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const CommandRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
        const name_gap = try repeated(ctx.arena, " ", commandDescriptionGap(self.command.name.len));

        const base_style: vaxis.Style = if (self.selected)
            .{ .reverse = true }
        else
            .{};
        @memset(surface.buffer, .{ .style = base_style });

        const name_style: vaxis.Style = if (self.selected)
            .{ .bold = true, .reverse = true }
        else
            .{ .fg = self.theme.accent, .bold = true };
        const description_style: vaxis.Style = if (self.selected)
            .{ .dim = true, .reverse = true }
        else
            .{ .fg = self.theme.dimmed, .dim = true };

        const content = vxfw.RichText{
            .text = &.{
                .{ .text = "  ", .style = name_style },
                .{ .text = self.command.name, .style = name_style },
                .{ .text = name_gap, .style = description_style },
                .{ .text = self.command.description, .style = description_style },
            },
            .softwrap = false,
            .width_basis = .parent,
        };
        const content_surface = try content.draw(ctx.withConstraints(
            .{ .width = 0, .height = 1 },
            .{ .width = width, .height = 1 },
        ));

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = content_surface };

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};

pub const SessionListRowWidget = struct {
    session: *const session_mod.Session,
    selected: bool,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const SessionListRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SessionListRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const SessionListRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
        const base_style: vaxis.Style = if (self.selected) .{ .reverse = true } else .{};
        @memset(surface.buffer, .{ .style = base_style });

        const date_text = try formatSessionTimestamp(ctx.arena, self.session.updated_at);
        const line = try std.fmt.allocPrint(ctx.arena, "  {s} | {s} | {s} | {d} turns | {d} tokens", .{
            self.session.id,
            self.session.title,
            date_text,
            self.session.turn_count,
            self.session.total_tokens,
        });
        const line_widget = vxfw.Text{
            .text = line,
            .style = if (self.selected)
                .{ .reverse = true, .bold = true }
            else
                .{ .fg = self.theme.header_fg },
            .softwrap = false,
            .width_basis = .parent,
        };
        const line_surface = try line_widget.draw(ctx.withConstraints(
            .{ .width = width, .height = 1 },
            .{ .width = width, .height = 1 },
        ));

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = line_surface };
        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};

pub const SessionListWidget = struct {
    sessions: []const session_mod.Session,
    selected: usize,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const SessionListWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SessionListWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const SessionListWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        var width: u16 = @min(max.width -| 4, @as(u16, 96));
        if (width < 40) width = @min(max.width, @as(u16, 40));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var list_height: u16 = @intCast(if (self.sessions.len == 0) 1 else @min(self.sessions.len, session_row_display_max));
        if (list_height == 0) list_height = 1;
        const height = 4 + list_height;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.theme.code_bg } });
        drawBorder(&surface, .{ .fg = self.theme.border });

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title_text = vxfw.Text{
            .text = "Saved sessions (↑↓ navigate, Enter resume, Esc close)",
            .style = .{ .fg = self.theme.header_fg, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface });

        if (self.sessions.len == 0) {
            const empty_text = vxfw.Text{
                .text = "No saved sessions",
                .style = .{ .fg = self.theme.dimmed, .dim = true },
                .softwrap = false,
                .width_basis = .parent,
            };
            const empty_surface = try empty_text.draw(ctx.withConstraints(
                .{ .width = inner_width, .height = 1 },
                .{ .width = inner_width, .height = 1 },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 3, .col = 2 }, .surface = empty_surface });
        } else {
            const visible_start = if (self.selected >= list_height) self.selected - list_height + 1 else 0;
            const visible_end = @min(visible_start + list_height, self.sessions.len);
            for (visible_start..visible_end, 0..) |session_index, row_index| {
                const row = SessionListRowWidget{ .session = &self.sessions[session_index], .selected = session_index == self.selected, .theme = self.theme };
                const row_surface = try row.draw(ctx.withConstraints(
                    .{ .width = inner_width, .height = 1 },
                    .{ .width = inner_width, .height = 1 },
                ));
                try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(3 + row_index), .col = 2 }, .surface = row_surface });
            }
        }

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

pub const ResumePromptWidget = struct {
    session: *const session_mod.Session,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const ResumePromptWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ResumePromptWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const ResumePromptWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        var width: u16 = @min(max.width -| 4, @as(u16, 72));
        if (width < 36) width = @min(max.width, @as(u16, 36));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        const date_text = try formatSessionTimestamp(ctx.arena, self.session.updated_at);
        const info_line = try std.fmt.allocPrint(ctx.arena, "{s} | {s} | {s}", .{ self.session.id, self.session.title, date_text });

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title = vxfw.Text{
            .text = "Resume interrupted session? [y/n]",
            .style = .{ .fg = self.theme.header_fg, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface });

        const info = vxfw.Text{
            .text = info_line,
            .style = .{ .fg = self.theme.dimmed, .dim = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const info_surface = try info.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = 9999 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 3, .col = 2 }, .surface = info_surface });

        const footer = vxfw.Text{
            .text = "y = resume, n = discard",
            .style = .{ .fg = self.theme.tool_success, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const footer_row: u16 = @intCast(4 + info_surface.size.height);
        const footer_surface = try footer.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = footer_row, .col = 2 }, .surface = footer_surface });

        const height: u16 = footer_row + 2;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.theme.code_bg } });
        drawBorder(&surface, .{ .fg = self.theme.tool_pending });

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

pub const CommandPaletteWidget = struct {
    field: *vxfw.TextField,
    commands: []const Command,
    filter: []const u8,
    selected: usize,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const CommandPaletteWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const CommandPaletteWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const CommandPaletteWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        var width: u16 = @min(max.width -| 4, @as(u16, 72));
        if (width < 28) width = @min(max.width, @as(u16, 28));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.commands, self.filter, filtered_indices[0..]);
        var list_height: u16 = @intCast(if (filtered_count == 0) 1 else @min(filtered_count, @as(usize, max.height -| 4)));
        if (list_height == 0) list_height = 1;
        const height = 4 + list_height;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.theme.code_bg } });
        drawBorder(&surface, .{ .fg = self.theme.border });

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title_text = vxfw.Text{
            .text = "Commands (↑↓ navigate, Enter select, Esc close)",
            .style = .{ .fg = self.theme.header_fg, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface });

        const input_widget = widget_input.InputWidget{ .prompt = "Filter: ", .field = self.field, .theme = self.theme };
        const input_surface = try input_widget.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 2, .col = 2 }, .surface = input_surface });

        if (filtered_count == 0) {
            const empty_text = vxfw.Text{
                .text = "No commands match.",
                .style = .{ .fg = self.theme.dimmed, .dim = true },
                .softwrap = false,
                .width_basis = .parent,
            };
            const empty_surface = try empty_text.draw(ctx.withConstraints(
                .{ .width = inner_width, .height = 1 },
                .{ .width = inner_width, .height = 1 },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 3, .col = 2 }, .surface = empty_surface });
        } else {
            const visible_start = if (self.selected >= list_height) self.selected - list_height + 1 else 0;
            const visible_end = @min(visible_start + list_height, filtered_count);
            for (visible_start..visible_end, 0..) |filtered_index, row_index| {
                const command = self.commands[filtered_indices[filtered_index]];
                const row = CommandRowWidget{ .command = command, .selected = filtered_index == self.selected, .theme = self.theme };
                const row_surface = try row.draw(ctx.withConstraints(
                    .{ .width = inner_width, .height = 1 },
                    .{ .width = inner_width, .height = 1 },
                ));
                try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(3 + row_index), .col = 2 }, .surface = row_surface });
            }
        }

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

// --- Helper functions ---

pub fn formatSessionTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const seconds: u64 = @intCast(@max(timestamp, 0));
    const day_seconds: u64 = 24 * 60 * 60;
    const days = @divFloor(seconds, day_seconds);
    const remainder = @mod(seconds, day_seconds);
    const hours = @divFloor(remainder, 60 * 60);
    const minutes = @divFloor(@mod(remainder, 60 * 60), 60);
    return std.fmt.allocPrint(allocator, "day {d} {d:0>2}:{d:0>2}", .{ days, hours, minutes });
}

pub fn collectFilteredCommandIndices(commands: []const Command, filter: []const u8, out: []usize) usize {
    var count: usize = 0;
    for (commands, 0..) |command, idx| {
        if (commandMatchesFilter(command, filter)) {
            out[count] = idx;
            count += 1;
        }
    }
    return count;
}

pub fn commandMatchesFilter(command: Command, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return containsIgnoreCase(command.name, filter) or
        containsIgnoreCase(command.description, filter) or
        containsIgnoreCase(command.shortcut, filter);
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |start| {
        var matched = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn commandDescriptionGap(name_len: usize) u16 {
    const max_name_len = maxCommandNameLen(&palette_command_data);
    const gap = max_name_len - name_len + 4;
    return @intCast(@max(gap, 1));
}

pub fn maxCommandNameLen(commands: []const Command) usize {
    var max_len: usize = 0;
    for (commands) |command| {
        max_len = @max(max_len, command.name.len);
    }
    return max_len;
}
