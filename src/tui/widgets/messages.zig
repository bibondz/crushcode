const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core_api");
const theme_mod = @import("theme");
const diff_mod = @import("diff");
const markdown_mod = @import("markdown");
const widget_types = @import("widget_types");
const widget_helpers = @import("widget_helpers");
const widget_typewriter = @import("typewriter");

const vxfw = vaxis.vxfw;

// --- RoleLabelWidget ---

pub const RoleLabelWidget = struct {
    label: []const u8,
    style: vaxis.Style,
    theme: *const theme_mod.Theme,
    icon: []const u8,
    icon_style: vaxis.Style,

    pub fn widget(self: *const RoleLabelWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const RoleLabelWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const RoleLabelWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const rich: vxfw.RichText = .{
            .text = &.{
                .{ .text = self.icon, .style = self.icon_style },
                .{ .text = " ", .style = .{} },
                .{ .text = self.label, .style = self.style },
                .{ .text = ": ", .style = .{ .fg = self.theme.dimmed, .dim = true } },
            },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return rich.draw(ctx);
    }
};

// --- MessageContentWidget ---

pub const MessageContentWidget = struct {
    message: *const widget_types.Message,
    theme: *const theme_mod.Theme,
    typewriter: ?*widget_typewriter.TypewriterState = null,
    awaiting_first_token: bool = false,

    pub fn widget(self: *const MessageContentWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MessageContentWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const MessageContentWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const role_style = widget_helpers.messageRoleStyle(self.theme, self.message.role);
        const body_style = widget_helpers.messageBodyStyle(self.theme, self.message.role);
        const role_label: RoleLabelWidget = .{
            .label = widget_helpers.messageRoleLabel(self.theme, self.message.role),
            .style = role_style,
            .theme = self.theme,
            .icon = widget_helpers.messageRoleIcon(self.message.role),
            .icon_style = widget_helpers.messageRoleIconStyle(self.theme, self.message.role),
        };

        // Determine display text: use typewriter revealed portion when active
        const tw = self.typewriter;
        const show_cursor = if (tw) |t| !t.complete else false;
        const display_text = if (tw) |t| blk: {
            if (!t.complete) {
                break :blk t.revealedText();
            }
            break :blk self.message.content;
        } else self.message.content;

        const content_surface = if (std.mem.eql(u8, self.message.role, "assistant")) blk: {
            if (show_cursor) {
                // Typewriter active: render streaming status + revealed markdown + blinking cursor
                const revealed = display_text;
                const is_thinking = self.awaiting_first_token or revealed.len == 0;
                const status_text: []const u8 = if (is_thinking) "Thinking..." else "Responding...";
                const cursor_visible_flag = if (tw) |t| t.cursor_visible else true;
                const md_theme = markdown_mod.markdownThemeFromAppTheme(self.theme);
                const md_segments = try markdown_mod.parseMarkdown(ctx.arena, revealed, md_theme);
                // Allocate: 1 indicator + md_segments + 1 cursor
                const segments = try ctx.arena.alloc(vaxis.Segment, md_segments.len + 2);
                // Streaming status indicator
                segments[0] = .{
                    .text = if (cursor_visible_flag)
                        try std.fmt.allocPrint(ctx.arena, "● {s}\n", .{status_text})
                    else
                        try std.fmt.allocPrint(ctx.arena, "  {s}\n", .{status_text}),
                    .style = .{ .fg = self.theme.streaming_indicator, .bold = true },
                };
                @memcpy(segments[1 .. 1 + md_segments.len], md_segments);
                // Append blinking cursor as last segment
                segments[1 + md_segments.len] = if (cursor_visible_flag)
                    .{ .text = "▌", .style = .{ .fg = self.theme.accent, .bold = true } }
                else
                    .{ .text = " ", .style = .{ .fg = self.theme.accent } };
                const content = vxfw.RichText{
                    .text = segments,
                    .softwrap = true,
                    .width_basis = .parent,
                };
                break :blk try content.draw(ctx.withConstraints(
                    .{ .width = 0, .height = 0 },
                    .{ .width = ctx.max.width, .height = ctx.max.height },
                ));
            }
            // Normal (non-streaming or complete) markdown rendering
            const md_theme = markdown_mod.markdownThemeFromAppTheme(self.theme);
            const segments = try markdown_mod.parseMarkdown(ctx.arena, display_text, md_theme);
            const content = vxfw.RichText{
                .text = segments,
                .softwrap = true,
                .width_basis = .parent,
            };
            break :blk try content.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = ctx.max.width, .height = ctx.max.height },
            ));
        } else blk: {
            const content = vxfw.Text{
                .text = display_text,
                .style = body_style,
                .softwrap = true,
                .width_basis = .parent,
            };
            break :blk try content.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = ctx.max.width, .height = ctx.max.height },
            ));
        };

        var row = vxfw.FlexRow{
            .children = &.{
                .{ .widget = role_label.widget(), .flex = 0 },
                .{ .widget = try widget_helpers.contentSurfaceWidget(ctx.arena, content_surface), .flex = 1 },
            },
        };
        return row.draw(ctx);
    }
};

// --- DiffWidget ---

pub const DiffWidget = struct {
    file_path: []const u8,
    diff_text: []const u8,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const DiffWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const DiffWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const DiffWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const width = max.width;
        const inner_width = width -| 4;

        const title_line = try std.fmt.allocPrint(ctx.arena, "Diff: {s}", .{self.file_path});
        const title = vxfw.Text{
            .text = title_line,
            .style = .{ .fg = self.theme.accent, .bold = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = 9999 },
        ));

        const diff_theme = diff_mod.diffThemeFromAppTheme(self.theme);
        const diff_segments = try diff_mod.parseDiff(ctx.arena, self.diff_text, widget_types.tool_diff_max_lines, diff_theme);
        const diff_text_widget = vxfw.RichText{
            .text = diff_segments,
            .softwrap = true,
            .width_basis = .parent,
        };
        const diff_surface = try diff_text_widget.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = 9999 },
        ));

        const height = 2 + title_surface.size.height + diff_surface.size.height;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.theme.header_bg } });
        widget_helpers.drawBorder(&surface, .{ .fg = self.theme.accent, .dim = true });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface };
        children[1] = .{ .origin = .{ .row = @intCast(1 + title_surface.size.height), .col = 2 }, .surface = diff_surface };

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};

// --- ToolCallWidget ---

pub const ToolCallWidget = struct {
    tool_call: core.client.ToolCallInfo,
    status: widget_types.ToolCallStatus,
    output: ?[]const u8,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const ToolCallWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ToolCallWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const ToolCallWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const header = vxfw.RichText{
            .text = &.{
                .{ .text = widget_helpers.toolCallStatusIcon(self.status), .style = widget_helpers.toolCallStatusStyle(self.theme, self.status) },
                .{ .text = " ", .style = .{} },
                .{ .text = self.tool_call.name, .style = .{ .fg = self.theme.header_fg, .bold = true } },
                .{ .text = if (self.tool_call.arguments.len > 0) " " else "", .style = .{} },
                .{ .text = self.tool_call.arguments, .style = .{ .fg = self.theme.dimmed, .dim = true } },
            },
            .softwrap = true,
            .width_basis = .parent,
        };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 0 },
            .{ .width = max.width, .height = max.height },
        ));

        const diff_text = if (widget_helpers.isDiffRenderableTool(self.tool_call.name) and self.output != null)
            widget_helpers.extractToolDiffText(self.output.?)
        else
            null;
        if (diff_text) |text| {
            const diff_widget = DiffWidget{
                .file_path = widget_helpers.extractToolFilePath(self.tool_call.arguments) orelse self.tool_call.name,
                .diff_text = text,
                .theme = self.theme,
            };
            const diff_surface = try diff_widget.draw(ctx.withConstraints(
                .{ .width = max.width, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));

            const height = header_surface.size.height + diff_surface.size.height;
            const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max.width, .height = height });
            @memset(surface.buffer, .{ .style = .{} });

            const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface };
            children[1] = .{ .origin = .{ .row = @intCast(header_surface.size.height), .col = 0 }, .surface = diff_surface };

            return .{
                .size = surface.size,
                .widget = self.widget(),
                .buffer = surface.buffer,
                .children = children,
            };
        }

        const output_text = try widget_helpers.toolCallOutputText(ctx.arena, self.output, self.status);
        if (output_text.len == 0) {
            return header_surface;
        }

        const output_widget = vxfw.Text{
            .text = output_text,
            .style = .{ .fg = self.theme.dimmed, .dim = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const output_surface = try output_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 0 },
            .{ .width = max.width, .height = max.height },
        ));

        const height = header_surface.size.height + output_surface.size.height;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max.width, .height = height });
        @memset(surface.buffer, .{ .style = .{} });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface };
        children[1] = .{ .origin = .{ .row = @intCast(header_surface.size.height), .col = 0 }, .surface = output_surface };

        return .{
            .size = surface.size,
            .widget = self.widget(),
            .buffer = surface.buffer,
            .children = children,
        };
    }
};

// --- MessageWidget ---
// Takes concrete data fields — NO *Model dependency.

pub const MessageWidget = struct {
    messages: []const widget_types.Message,
    message_index: usize,
    theme: *const theme_mod.Theme,
    typewriter: ?*widget_typewriter.TypewriterState = null,
    awaiting_first_token: bool = false,

    pub fn widget(self: *const MessageWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MessageWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const MessageWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const message = &self.messages[self.message_index];
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const is_user = std.mem.eql(u8, message.role, "user");
        const is_assistant = std.mem.eql(u8, message.role, "assistant");
        const is_tool = std.mem.eql(u8, message.role, "tool");
        const is_system = std.mem.eql(u8, message.role, "system");

        // Assistant messages get a rounded bubble border with 1-char inner padding.
        // Require at least 6 cols to fit: │ _ content _ │ (border + pad + 2 content + pad + border)
        const bubble_active = is_assistant and max.width >= 6;
        const left_col: u16 = if (is_user) 2 else if (bubble_active) 2 else if (is_tool or is_system) 1 else 0;
        const content_width: u16 = max.width -| if (bubble_active) 4 else left_col;
        const top_pad: u16 = 0; // No top padding — bubble top border is enough
        const bot_pad: u16 = if (bubble_active) 1 else 0;

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        var current_row: u16 = 0;
        if (widget_helpers.shouldRenderMessageContent(message)) {
            const content_surface = try (MessageContentWidget{ .message = message, .theme = self.theme, .typewriter = self.typewriter, .awaiting_first_token = self.awaiting_first_token }).draw(ctx.withConstraints(
                .{ .width = content_width, .height = 0 },
                .{ .width = content_width, .height = 9999 },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{ .row = top_pad, .col = left_col },
                .surface = content_surface,
            });
            current_row += content_surface.size.height;
        }

        if (message.tool_calls) |tool_calls| {
            for (tool_calls, 0..) |tool_call, idx| {
                if (current_row > 0 or idx > 0) {
                    current_row += 1;
                }
                const tool_result = widget_helpers.findToolResultMessageAfter(self.messages, self.message_index, tool_call.id);
                const tool_widget = ToolCallWidget{
                    .tool_call = tool_call,
                    .status = widget_helpers.toolCallStatusForMessage(tool_result),
                    .output = if (tool_result) |result| result.content else null,
                    .theme = self.theme,
                };
                const tool_surface = try tool_widget.draw(ctx.withConstraints(
                    .{ .width = content_width, .height = 0 },
                    .{ .width = content_width, .height = 9999 },
                ));
                try child_list.append(ctx.arena, .{
                    .origin = .{ .row = @intCast(current_row + top_pad), .col = left_col },
                    .surface = tool_surface,
                });
                current_row += tool_surface.size.height;
            }
        }

        const height = @max(current_row + top_pad + bot_pad, 1);
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max.width, .height = height });
        @memset(surface.buffer, .{ .style = .{} });

        if (is_user) {
            // User messages: keep existing ▌ left border
            const border_cell: vaxis.Cell = .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = self.theme.border },
            };
            for (0..height) |row| {
                surface.writeCell(0, @intCast(row), border_cell);
            }
        } else if (bubble_active) {
            // Assistant messages: rounded bubble with background tint
            const bg_style: vaxis.Style = .{ .bg = self.theme.bubble_bg };
            for (1..height -| 1) |row| {
                for (1..max.width -| 1) |col| {
                    surface.writeCell(@intCast(col), @intCast(row), .{ .style = bg_style });
                }
            }
            widget_helpers.drawRoundedBorder(&surface, .{ .fg = self.theme.bubble_border });
        } else if (is_tool) {
            // Draw thin left border for tool messages
            const tool_border_style: vaxis.Style = .{ .fg = self.theme.tool_pending };
            for (0..height) |row| {
                surface.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "▎", .width = 1 }, .style = tool_border_style });
            }
        } else if (is_system) {
            // Draw thin left border for system messages
            const sys_border_style: vaxis.Style = .{ .fg = self.theme.dimmed };
            for (0..height) |row| {
                surface.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = sys_border_style });
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

// --- MessageGapWidget ---

pub const MessageGapWidget = struct {
    pub fn widget(self: *const MessageGapWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MessageGapWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const MessageGapWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
        @memset(surface.buffer, .{ .style = .{} });
        return surface;
    }
};

// --- SeparatorWidget ---

pub const SeparatorWidget = struct {
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const SeparatorWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SeparatorWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SeparatorWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const line_width: u16 = @max(@min(width, @as(u16, 40)), @as(u16, 2));
        const line = if (line_width <= 3)
            try widget_helpers.repeated(ctx.arena, "─", line_width)
        else
            try std.fmt.allocPrint(ctx.arena, "╶{s}╴", .{try widget_helpers.repeated(ctx.arena, "─", line_width - 2)});
        const text: vxfw.Text = .{
            .text = line,
            .style = .{ .fg = self.theme.border, .dim = true },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return text.draw(ctx.withConstraints(.{ .width = line_width, .height = 1 }, .{ .width = line_width, .height = 1 }));
    }
};
