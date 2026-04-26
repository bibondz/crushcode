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

pub const PaletteCategory = enum {
    command,
    model,
    file,
    session,
};

pub const PaletteItem = struct {
    category: PaletteCategory,
    label: []const u8,
    description: []const u8,
    shortcut: []const u8,
    icon: []const u8,
    action: []const u8,
};

pub const palette_command_data = [_]PaletteItem{
    .{ .category = .command, .label = "/clear", .description = "Clear conversation history", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/clear" },
    .{ .category = .command, .label = "/sessions", .description = "Browse saved sessions", .shortcut = "Ctrl+S", .icon = "\xF0\x9F\x92\xA1", .action = "/sessions" },
    .{ .category = .command, .label = "/ls", .description = "Alias for /sessions", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/ls" },
    .{ .category = .command, .label = "/exit", .description = "Exit crushcode", .shortcut = "Ctrl+C", .icon = "\xF0\x9F\x92\xA1", .action = "/exit" },
    .{ .category = .command, .label = "/model", .description = "Show current model", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/model" },
    .{ .category = .command, .label = "/thinking", .description = "Toggle thinking mode", .shortcut = "Ctrl+T", .icon = "\xF0\x9F\x92\xA1", .action = "/thinking" },
    .{ .category = .command, .label = "/compact", .description = "Compact conversation context", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/compact" },
    .{ .category = .command, .label = "/theme dark", .description = "Switch to dark theme", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/theme dark" },
    .{ .category = .command, .label = "/theme light", .description = "Switch to light theme", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/theme light" },
    .{ .category = .command, .label = "/theme mono", .description = "Switch to monochrome theme", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/theme mono" },
    .{ .category = .command, .label = "/workers", .description = "List active workers", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/workers" },
    .{ .category = .command, .label = "/diag", .description = "Show LSP diagnostics", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/diag" },
    .{ .category = .command, .label = "/refs", .description = "Find LSP references for symbol", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/refs" },
    .{ .category = .command, .label = "/kill", .description = "Kill a worker: /kill <id>", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/kill" },
    .{ .category = .command, .label = "/help", .description = "Show available commands", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/help" },
    .{ .category = .command, .label = "/plan on", .description = "Enable plan mode (propose before executing)", .shortcut = "", .icon = "\xF0\x9F\x92\xA1", .action = "/plan on" },
    .{ .category = .command, .label = "/preview", .description = "Toggle file preview pane (Ctrl+\\)", .shortcut = "Ctrl+\\", .icon = "\xF0\x9F\x92\xA1", .action = "/preview" },
    .{ .category = .command, .label = "/refresh", .description = "Refresh sidebar project files (Ctrl+R)", .shortcut = "Ctrl+R", .icon = "\xF0\x9F\x92\xA1", .action = "/refresh" },
};

pub const CommandRowWidget = struct {
    item: PaletteItem,
    selected: bool,
    theme: *const theme_mod.Theme,
    filter: []const u8,

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
        const shortcut_style: vaxis.Style = if (self.selected)
            .{ .bold = true, .reverse = true }
        else
            .{ .fg = self.theme.accent, .bold = true };
        const match_style: vaxis.Style = if (self.selected)
            .{ .bold = true, .ul_style = .single, .reverse = true }
        else
            .{ .fg = self.theme.accent, .bold = true, .ul_style = .single };

        // Build segments: icon + space + highlighted label + gap + description [+ shortcut]
        var seg_list = std.ArrayList(vaxis.Segment).empty;
        defer seg_list.deinit(ctx.arena);

        // Icon + space
        try seg_list.append(ctx.arena, .{ .text = self.item.icon, .style = name_style });
        try seg_list.append(ctx.arena, .{ .text = " ", .style = name_style });

        // Label with match highlighting
        if (self.filter.len > 0) {
            var match_buf: [256]bool = undefined;
            computeMatchPositions(self.item.label, self.filter, match_buf[0..self.item.label.len]);

            // Group consecutive matched/unmatched chars into segments
            var i: usize = 0;
            while (i < self.item.label.len) {
                const is_matched = match_buf[i];
                var end = i + 1;
                while (end < self.item.label.len and match_buf[end] == is_matched) {
                    end += 1;
                }
                const seg_text = self.item.label[i..end];
                try seg_list.append(ctx.arena, .{
                    .text = seg_text,
                    .style = if (is_matched) match_style else name_style,
                });
                i = end;
            }
        } else {
            try seg_list.append(ctx.arena, .{ .text = self.item.label, .style = name_style });
        }

        // Gap between label and description
        const name_gap = try repeated(ctx.arena, " ", paletteItemDescriptionGap(self.item.label.len));
        try seg_list.append(ctx.arena, .{ .text = name_gap, .style = description_style });

        // Description
        try seg_list.append(ctx.arena, .{ .text = self.item.description, .style = description_style });

        // Shortcut (right-aligned) — only if there's room and shortcut is non-empty
        if (self.item.shortcut.len > 0) {
            const shortcut_pad = width -| self.item.shortcut.len -| 2;
            if (shortcut_pad > 20) {
                const pad_text = try repeated(ctx.arena, " ", @intCast(shortcut_pad));
                try seg_list.append(ctx.arena, .{ .text = pad_text, .style = description_style });
                try seg_list.append(ctx.arena, .{ .text = self.item.shortcut, .style = shortcut_style });
            }
        }

        const content = vxfw.RichText{
            .text = seg_list.items,
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

    /// Case-insensitive fuzzy match: mark which chars in label match the filter.
    /// out_buf must have at least label.len elements.
    fn computeMatchPositions(label: []const u8, filter: []const u8, out_buf: []bool) void {
        @memset(out_buf[0..label.len], false);
        if (filter.len == 0) return;

        var qi: usize = 0;
        for (label, 0..) |ch, ti| {
            if (qi >= filter.len) break;
            if (std.ascii.toLower(ch) == std.ascii.toLower(filter[qi])) {
                out_buf[ti] = true;
                qi += 1;
            }
        }
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
    items: []const PaletteItem,
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
        var width: u16 = @min(max.width -| 4, @as(u16, 120));
        if (width < @as(u16, 40)) width = @min(max.width, @as(u16, 40));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var filtered_indices: [max_palette_items]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.items, self.filter, filtered_indices[0..]);
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
                .text = "No items match.",
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
                const item = self.items[filtered_indices[filtered_index]];
                const row = CommandRowWidget{ .item = item, .selected = filtered_index == self.selected, .theme = self.theme, .filter = self.filter };
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

/// Maximum number of items the palette can hold (static buffer size).
/// 200 is enough for 18 commands + ~150 models + ~50 files.
pub const max_palette_items: usize = 200;

pub fn collectFilteredCommandIndices(items: []const PaletteItem, filter: []const u8, out: []usize) usize {
    if (filter.len == 0) {
        // No filter — return all in original order
        const count = @min(items.len, out.len);
        for (0..count) |idx| {
            out[idx] = idx;
        }
        return count;
    }
    // Score-based filtering with fuzzy matching
    var scored: [max_palette_items]struct { index: usize, score: i32 } = undefined;
    var count: usize = 0;
    for (items, 0..) |item, idx| {
        if (idx >= max_palette_items) break;
        const score = fuzzyCommandScore(item, filter);
        if (score > 0) {
            scored[count] = .{ .index = idx, .score = score };
            count += 1;
        }
    }
    // Sort by score descending (insertion sort — small N)
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const tmp = scored[i];
        var j: usize = i;
        while (j > 0 and scored[j - 1].score < tmp.score) : (j -= 1) {
            scored[j] = scored[j - 1];
        }
        scored[j] = tmp;
    }
    const result_count = @min(count, out.len);
    for (0..result_count) |k| {
        out[k] = scored[k].index;
    }
    return result_count;
}

/// Score a PaletteItem against a filter. Higher = better match. 0 = no match.
/// Scoring: prefix match on label (100), shortcut exact match (80),
/// fuzzy label match (50 + bonus for consecutive chars),
/// substring match on description (30).
pub fn fuzzyCommandScore(item: PaletteItem, filter: []const u8) i32 {
    if (filter.len == 0) return 1;
    var best: i32 = 0;

    // Prefix match on label (highest priority)
    if (std.mem.startsWith(u8, item.label, filter)) {
        best = @max(best, 100 + @as(i32, @intCast(filter.len)));
    }

    // Shortcut exact match
    if (std.mem.eql(u8, item.shortcut, filter)) {
        best = @max(best, 80);
    }

    // Shortcut prefix match
    if (std.mem.startsWith(u8, item.shortcut, filter)) {
        best = @max(best, 70);
    }

    // Fuzzy match on label — each matched char scores, consecutive chars get bonus
    const label_score = fuzzyCharScore(item.label, filter);
    if (label_score > 0) {
        best = @max(best, label_score);
    }

    // Substring match on description
    if (containsIgnoreCase(item.description, filter)) {
        best = @max(best, 30);
    }

    // Case-insensitive prefix on label
    if (item.label.len >= filter.len) {
        var prefix_match = true;
        for (filter, 0..) |c, i| {
            if (std.ascii.toLower(item.label[i]) != std.ascii.toLower(c)) {
                prefix_match = false;
                break;
            }
        }
        if (prefix_match) best = @max(best, 90);
    }

    return best;
}

/// Fuzzy character matching — each matched char = 10 points,
/// consecutive matched chars get +5 bonus each.
fn fuzzyCharScore(text: []const u8, query: []const u8) i32 {
    if (query.len == 0) return 0;
    if (query.len > text.len) return 0;

    var score: i32 = 0;
    var qi: usize = 0;
    var last_match: usize = 0;
    var first = true;

    for (text, 0..) |ch, ti| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            if (first) {
                score = 50;
                first = false;
            } else {
                score += 10;
                // Consecutive bonus
                if (ti == last_match + 1) {
                    score += 5;
                }
            }
            last_match = ti;
            qi += 1;
        }
    }

    // Only return score if ALL query chars matched
    if (qi < query.len) return 0;
    return score;
}

pub fn commandMatchesFilter(item: PaletteItem, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return containsIgnoreCase(item.label, filter) or
        containsIgnoreCase(item.description, filter) or
        containsIgnoreCase(item.shortcut, filter);
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

pub fn paletteItemDescriptionGap(label_len: usize) u16 {
    // For dynamic items the max label length varies widely,
    // so use a fixed minimum gap
    const min_gap: usize = 4;
    const max_label: usize = 30;
    if (label_len >= max_label) return @intCast(min_gap);
    const gap = max_label - label_len + min_gap;
    return @intCast(gap);
}
