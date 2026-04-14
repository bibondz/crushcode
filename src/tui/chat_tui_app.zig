const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core_api");
const registry_mod = @import("registry");
const markdown = @import("markdown");
const usage_pricing = @import("usage_pricing");

const vxfw = vaxis.vxfw;
const app_version = "0.2.2";

pub const Options = struct {
    provider_name: []const u8,
    model_name: []const u8,
    api_key: []const u8,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 4096,
    temperature: f32 = 0.7,
    override_url: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const core.client.ToolCallInfo = null,
};

threadlocal var active_stream_model: ?*Model = null;

const setup_provider_data = [_][]const u8{
    "openrouter",
    "openai",
    "anthropic",
    "groq",
    "together",
    "gemini",
    "xai",
    "mistral",
    "ollama",
    "zai",
};

const ToolCallStatus = enum {
    pending,
    success,
    failed,
};

const recent_files_max = 5;
const recent_files_display_max = 3;
const recent_file_tool_names = [_][]const u8{ "read_file", "write_file", "edit", "glob" };

const RoleLabelWidget = struct {
    label: []const u8,
    style: vaxis.Style,

    fn widget(self: *const RoleLabelWidget) vxfw.Widget {
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
                .{ .text = self.label, .style = self.style },
                .{ .text = ": ", .style = .{ .fg = .{ .index = 8 }, .dim = true } },
            },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return rich.draw(ctx);
    }
};

const MessageContentWidget = struct {
    message: *const Message,

    fn widget(self: *const MessageContentWidget) vxfw.Widget {
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
        const role_style = messageRoleStyle(self.message.role);
        const body_style = messageBodyStyle(self.message.role);
        const role_label: RoleLabelWidget = .{ .label = messageRoleLabel(self.message.role), .style = role_style };
        const content_surface = if (std.mem.eql(u8, self.message.role, "assistant")) blk: {
            const segments = try markdown.parseMarkdown(ctx.arena, self.message.content);
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
                .text = self.message.content,
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
                .{ .widget = try contentSurfaceWidget(ctx.arena, content_surface), .flex = 1 },
            },
        };
        return row.draw(ctx);
    }
};

const ToolCallWidget = struct {
    tool_call: core.client.ToolCallInfo,
    status: ToolCallStatus,
    output: ?[]const u8,

    fn widget(self: *const ToolCallWidget) vxfw.Widget {
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
        const max = ctx.max.size();
        const header = vxfw.RichText{
            .text = &.{
                .{ .text = toolCallStatusIcon(self.status), .style = toolCallStatusStyle(self.status) },
                .{ .text = " ", .style = .{} },
                .{ .text = self.tool_call.name, .style = .{ .fg = .{ .index = 15 }, .bold = true } },
                .{ .text = if (self.tool_call.arguments.len > 0) " " else "", .style = .{} },
                .{ .text = self.tool_call.arguments, .style = .{ .fg = .{ .index = 8 }, .dim = true } },
            },
            .softwrap = true,
            .width_basis = .parent,
        };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = max.width, .height = 0 },
            .{ .width = max.width, .height = max.height },
        ));

        const output_text = try toolCallOutputText(ctx.arena, self.output, self.status);
        if (output_text.len == 0) {
            return header_surface;
        }

        const output_widget = vxfw.Text{
            .text = output_text,
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
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

const MessageWidget = struct {
    model: *const Model,
    message_index: usize,

    fn widget(self: *const MessageWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MessageWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const MessageWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const message = &self.model.messages.items[self.message_index];
        const max = ctx.max.size();
        const border_width: u16 = if (std.mem.eql(u8, message.role, "user")) 2 else 0;
        const content_width = max.width -| border_width;

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        var current_row: u16 = 0;
        if (shouldRenderMessageContent(message)) {
            const content_widget: MessageContentWidget = .{ .message = message };
            const content_surface = try content_widget.draw(ctx.withConstraints(
                .{ .width = content_width, .height = 0 },
                .{ .width = content_width, .height = null },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = @intCast(border_width) },
                .surface = content_surface,
            });
            current_row += content_surface.size.height;
        }

        if (message.tool_calls) |tool_calls| {
            for (tool_calls, 0..) |tool_call, idx| {
                if (current_row > 0 or idx > 0) {
                    current_row += 1;
                }
                const tool_result = findToolResultMessageAfter(self.model.messages.items, self.message_index, tool_call.id);
                const tool_widget = ToolCallWidget{
                    .tool_call = tool_call,
                    .status = toolCallStatusForMessage(tool_result),
                    .output = if (tool_result) |result| result.content else null,
                };
                const tool_surface = try tool_widget.draw(ctx.withConstraints(
                    .{ .width = content_width, .height = 0 },
                    .{ .width = content_width, .height = null },
                ));
                try child_list.append(ctx.arena, .{
                    .origin = .{ .row = @intCast(current_row), .col = @intCast(border_width) },
                    .surface = tool_surface,
                });
                current_row += tool_surface.size.height;
            }
        }

        const height = @max(current_row, 1);
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max.width, .height = height });
        @memset(surface.buffer, .{ .style = .{} });

        if (border_width > 0) {
            const border_cell: vaxis.Cell = .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = .{ .index = 39 } },
            };
            for (0..height) |row| {
                surface.writeCell(0, @intCast(row), border_cell);
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

const MessageGapWidget = struct {
    fn widget(self: *const MessageGapWidget) vxfw.Widget {
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

const SeparatorWidget = struct {
    fn widget(self: *const SeparatorWidget) vxfw.Widget {
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
        _ = self;
        const width = ctx.max.width orelse ctx.min.width;
        const line_width: u16 = @max(@min(width, @as(u16, 40)), @as(u16, 2));
        const line = if (line_width <= 3)
            try repeated(ctx.arena, "─", line_width)
        else
            try std.fmt.allocPrint(ctx.arena, "╶{s}╴", .{try repeated(ctx.arena, "─", line_width - 2)});
        const text: vxfw.Text = .{
            .text = line,
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return text.draw(ctx.withConstraints(.{ .width = line_width, .height = 1 }, .{ .width = line_width, .height = 1 }));
    }
};

const HeaderWidget = struct {
    title: []const u8,

    fn widget(self: *const HeaderWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const HeaderWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const HeaderWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const title = vxfw.RichText{
            .text = &.{.{ .text = self.title, .style = .{ .fg = .{ .index = 15 }, .bold = true } }},
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const line = try repeated(ctx.arena, "─", width);
        const separator = vxfw.Text{
            .text = line,
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const separator_surface = try separator.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = title_surface };
        children[1] = .{ .origin = .{ .row = 1, .col = 0 }, .surface = separator_surface };

        return .{
            .size = .{ .width = width, .height = 2 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const SurfaceWidget = struct {
    surface: vxfw.Surface,

    fn widget(self: *const SurfaceWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = ctx;
        const self: *const SurfaceWidget = @ptrCast(@alignCast(ptr));
        return self.surface;
    }
};

const FilesWidget = struct {
    files: []const []const u8,

    fn widget(self: *const FilesWidget) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = typeErasedDrawFn };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const FilesWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const FilesWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const text_surface = try text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = text_surface };
        return .{ .size = surface.size, .widget = self.widget(), .buffer = surface.buffer, .children = children };
    }
};

const InputWidget = struct {
    prompt: []const u8,
    field: *vxfw.TextField,

    fn widget(self: *const InputWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const InputWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const InputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const prompt_text = vxfw.Text{
            .text = self.prompt,
            .style = .{ .fg = .{ .index = 39 }, .bold = true },
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

const Command = struct {
    name: []const u8,
    description: []const u8,
    shortcut: []const u8,
};

const palette_command_data = [_]Command{
    .{ .name = "/clear", .description = "Clear conversation history", .shortcut = "clr" },
    .{ .name = "/exit", .description = "Exit crushcode", .shortcut = "q" },
    .{ .name = "/model", .description = "Show current model", .shortcut = "m" },
    .{ .name = "/thinking", .description = "Toggle thinking mode", .shortcut = "t" },
    .{ .name = "/compact", .description = "Compact conversation context", .shortcut = "c" },
    .{ .name = "/help", .description = "Show available commands", .shortcut = "h" },
};

const CommandRowWidget = struct {
    command: Command,
    selected: bool,

    fn widget(self: *const CommandRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const CommandRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const CommandRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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
            .{ .fg = .{ .index = 39 }, .bold = true };
        const description_style: vaxis.Style = if (self.selected)
            .{ .dim = true, .reverse = true }
        else
            .{ .fg = .{ .index = 8 }, .dim = true };

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

const CommandPaletteWidget = struct {
    field: *vxfw.TextField,
    commands: []const Command,
    filter: []const u8,
    selected: usize,

    fn widget(self: *const CommandPaletteWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const CommandPaletteWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const CommandPaletteWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
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
        @memset(surface.buffer, .{ .style = .{ .bg = .{ .index = 0 } } });
        drawBorder(&surface, .{ .fg = .{ .index = 8 } });

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title_text = vxfw.Text{
            .text = "Commands (↑↓ navigate, Enter select, Esc close)",
            .style = .{ .fg = .{ .index = 15 }, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 2 }, .surface = title_surface });

        const input_widget = InputWidget{ .prompt = "Filter: ", .field = self.field };
        const input_surface = try input_widget.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 2, .col = 2 }, .surface = input_surface });

        if (filtered_count == 0) {
            const empty_text = vxfw.Text{
                .text = "No commands match.",
                .style = .{ .fg = .{ .index = 8 }, .dim = true },
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
                const row = CommandRowWidget{ .command = command, .selected = filtered_index == self.selected };
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

const SetupProviderRowWidget = struct {
    provider_name: []const u8,
    selected: bool,

    fn widget(self: *const SetupProviderRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SetupProviderRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SetupProviderRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const text = vxfw.RichText{
            .text = &.{
                .{ .text = if (self.selected) "› " else "  ", .style = if (self.selected) .{ .fg = .{ .index = 39 }, .bold = true } else .{ .fg = .{ .index = 8 }, .dim = true } },
                .{ .text = self.provider_name, .style = if (self.selected) .{ .fg = .{ .index = 15 }, .bold = true } else .{ .fg = .{ .index = 15 } } },
            },
            .softwrap = false,
            .width_basis = .parent,
        };
        return text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }
};

const SetupWizardWidget = struct {
    model: *const Model,

    fn widget(self: *const SetupWizardWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SetupWizardWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SetupWizardWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        const width = max.width;
        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        var row: u16 = 0;
        try appendSetupText(ctx, &child_list, &row, width, "Welcome to Crushcode!", .{ .fg = .{ .index = 15 }, .bold = true });
        row += 1;

        switch (self.model.setup_phase) {
            1 => {
                try appendSetupText(ctx, &child_list, &row, width, "Choose a provider:", .{ .fg = .{ .index = 15 }, .bold = true });
                try appendSetupText(ctx, &child_list, &row, width, "Use ↑↓ to choose, then press Enter.", .{ .fg = .{ .index = 8 }, .dim = true });
                row += 1;
                for (setup_provider_data, 0..) |provider_name, idx| {
                    const provider_row = SetupProviderRowWidget{ .provider_name = provider_name, .selected = idx == self.model.setup_provider_index };
                    const provider_surface = try provider_row.draw(ctx.withConstraints(
                        .{ .width = width, .height = 1 },
                        .{ .width = width, .height = 1 },
                    ));
                    try child_list.append(ctx.arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = provider_surface });
                    row += 1;
                }
            },
            2 => {
                const title = try std.fmt.allocPrint(ctx.arena, "Enter your API key for {s}:", .{self.model.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, title, .{ .fg = .{ .index = 15 }, .bold = true });
                if (setupProviderAllowsEmptyKey(self.model.provider_name)) {
                    try appendSetupText(ctx, &child_list, &row, width, "This provider can use a blank key. Press Enter to continue.", .{ .fg = .{ .index = 8 }, .dim = true });
                } else {
                    try appendSetupText(ctx, &child_list, &row, width, "Paste the key, then press Enter.", .{ .fg = .{ .index = 8 }, .dim = true });
                }
            },
            3 => {
                try appendSetupText(ctx, &child_list, &row, width, "Enter default model (or press Enter for default):", .{ .fg = .{ .index = 15 }, .bold = true });
                const provider_line = try std.fmt.allocPrint(ctx.arena, "Provider: {s}", .{self.model.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, provider_line, .{ .fg = .{ .index = 8 }, .dim = true });
                const default_line = try std.fmt.allocPrint(ctx.arena, "Default: {s}", .{setupDefaultModel(self.model.provider_name)});
                try appendSetupText(ctx, &child_list, &row, width, default_line, .{ .fg = .{ .index = 8 }, .dim = true });
            },
            4 => {
                try appendSetupText(ctx, &child_list, &row, width, "Setup complete! Press Enter to start chatting.", .{ .fg = .{ .index = 10 }, .bold = true });
                const provider_line = try std.fmt.allocPrint(ctx.arena, "Provider: {s}", .{self.model.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, provider_line, .{ .fg = .{ .index = 8 }, .dim = true });
                const model_line = try std.fmt.allocPrint(ctx.arena, "Model: {s}", .{self.model.model_name});
                try appendSetupText(ctx, &child_list, &row, width, model_line, .{ .fg = .{ .index = 8 }, .dim = true });
                const config_line = try std.fmt.allocPrint(ctx.arena, "Config: {s}", .{try setupConfigPath(ctx.arena)});
                try appendSetupText(ctx, &child_list, &row, width, config_line, .{ .fg = .{ .index = 8 }, .dim = true });
            },
            else => {},
        }

        if (self.model.setup_feedback.len > 0) {
            row += 1;
            try appendSetupText(
                ctx,
                &child_list,
                &row,
                width,
                self.model.setup_feedback,
                if (self.model.setup_feedback_is_error) .{ .fg = .{ .index = 1 }, .bold = true } else .{ .fg = .{ .index = 10 }, .dim = true },
            );
        }

        const height = @max(max.height, row);
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{} });

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

pub const Model = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    model_name: []const u8,
    api_key: []const u8,
    system_prompt: ?[]const u8,
    max_tokens: u32,
    temperature: f32,
    override_url: ?[]const u8,
    thinking: bool,
    app: *vxfw.App,
    registry: registry_mod.ProviderRegistry,
    client: ?core.AIClient,
    messages: std.ArrayList(Message),
    history: std.ArrayList(core.ChatMessage),
    input: vxfw.TextField,
    show_palette: bool,
    palette_input: vxfw.TextField,
    palette_commands: []const Command,
    palette_selected: usize,
    palette_filter: []const u8,
    scroll_view: vxfw.ScrollView,
    scroll_bars: vxfw.ScrollBars,
    recent_files: std.ArrayList([]const u8),
    lock: std.Thread.Mutex,
    worker: ?std.Thread,
    request_active: bool,
    request_done: bool,
    awaiting_first_token: bool,
    assistant_stream_index: ?usize,
    should_quit: bool,
    total_input_tokens: u64,
    total_output_tokens: u64,
    request_count: u32,
    session_start: i128,
    pricing_table: usage_pricing.PricingTable,
    setup_phase: u8,
    setup_provider_index: usize,
    setup_feedback: []const u8,
    setup_feedback_is_error: bool,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);

        const app = try allocator.create(vxfw.App);
        errdefer allocator.destroy(app);
        app.* = try vxfw.App.init(allocator);
        errdefer app.deinit();

        model.* = .{
            .allocator = allocator,
            .provider_name = try allocator.dupe(u8, options.provider_name),
            .model_name = try allocator.dupe(u8, options.model_name),
            .api_key = try allocator.dupe(u8, options.api_key),
            .system_prompt = if (options.system_prompt) |system_prompt| try allocator.dupe(u8, system_prompt) else null,
            .max_tokens = options.max_tokens,
            .temperature = options.temperature,
            .override_url = if (options.override_url) |override_url| try allocator.dupe(u8, override_url) else null,
            .thinking = false,
            .app = app,
            .registry = registry_mod.ProviderRegistry.init(allocator),
            .client = null,
            .messages = std.ArrayList(Message).empty,
            .history = std.ArrayList(core.ChatMessage).empty,
            .input = vxfw.TextField.init(allocator),
            .show_palette = false,
            .palette_input = vxfw.TextField.init(allocator),
            .palette_commands = &palette_command_data,
            .palette_selected = 0,
            .palette_filter = "",
            .scroll_view = .{
                .children = .{ .slice = &.{} },
                .draw_cursor = false,
                .wheel_scroll = 3,
            },
            .scroll_bars = undefined,
            .recent_files = try std.ArrayList([]const u8).initCapacity(allocator, 5),
            .lock = .{},
            .worker = null,
            .request_active = false,
            .request_done = false,
            .awaiting_first_token = false,
            .assistant_stream_index = null,
            .should_quit = false,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .request_count = 0,
            .session_start = std.time.nanoTimestamp(),
            .pricing_table = try usage_pricing.PricingTable.init(allocator),
            .setup_phase = if (options.api_key.len == 0) 1 else 0,
            .setup_provider_index = setupProviderIndex(options.provider_name),
            .setup_feedback = "",
            .setup_feedback_is_error = false,
        };
        errdefer model.destroy();

        model.messages = try std.ArrayList(Message).initCapacity(allocator, 8);
        model.history = try std.ArrayList(core.ChatMessage).initCapacity(allocator, 8);
        model.input.style = .{ .fg = .{ .index = 15 } };
        model.input.userdata = model;
        model.input.onSubmit = onSubmit;
        model.palette_input.style = .{ .fg = .{ .index = 15 } };
        model.palette_input.userdata = model;
        model.palette_input.onChange = onPaletteChange;
        model.palette_input.onSubmit = onPaletteSubmit;
        model.scroll_bars = .{
            .scroll_view = model.scroll_view,
            .draw_horizontal_scrollbar = false,
            .draw_vertical_scrollbar = true,
            .vertical_scrollbar_thumb = .{ .char = .{ .grapheme = "▐", .width = 1 }, .style = .{ .fg = .{ .index = 8 }, .dim = true } },
            .vertical_scrollbar_hover_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } },
            .vertical_scrollbar_drag_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = .{ .index = 39 } } },
        };

        try model.registry.registerAllProviders();
        if (model.setup_phase != 0) {
            const selected_provider = setup_provider_data[model.setup_provider_index];
            if (model.provider_name.len == 0) {
                model.allocator.free(model.provider_name);
                model.provider_name = try model.allocator.dupe(u8, selected_provider);
            }
        } else {
            try model.addMessageUnlocked("assistant", "TUI chat ready. Type a message and press Enter.");
            try model.initializeClient();
        }
        return model;
    }

    pub fn destroy(self: *Model) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
        if (self.client) |*client| {
            client.deinit();
        }
        self.input.deinit();
        self.palette_input.deinit();
        self.clearPaletteFilter();
        for (self.recent_files.items) |file| self.allocator.free(file);
        self.recent_files.deinit(self.allocator);
        for (self.messages.items) |message| {
            freeDisplayMessage(self.allocator, message);
        }
        self.messages.deinit(self.allocator);
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.deinit(self.allocator);
        self.registry.deinit();
        self.pricing_table.deinit();
        if (self.system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.override_url) |override_url| self.allocator.free(override_url);
        if (self.setup_feedback.len > 0) self.allocator.free(self.setup_feedback);
        self.allocator.free(self.provider_name);
        self.allocator.free(self.model_name);
        self.allocator.free(self.api_key);
        self.app.deinit();
        self.allocator.destroy(self.app);
        self.allocator.destroy(self);
    }

    pub fn run(self: *Model) !void {
        try self.app.run(self.widget(), .{ .framerate = 30 });
    }

    fn initializeClient(self: *Model) !void {
        if (self.provider_name.len == 0) {
            try self.addMessageUnlocked("error", "No provider configured. Set one in ~/.crushcode/config.toml or use a profile.");
            return;
        }

        const provider = self.registry.getProvider(self.provider_name) orelse {
            const text = try std.fmt.allocPrint(self.allocator, "Provider '{s}' is not registered. Run 'crushcode list --providers' to see available providers.", .{self.provider_name});
            defer self.allocator.free(text);
            try self.addMessageUnlocked("error", text);
            return;
        };

        if (self.api_key.len == 0 and !provider.config.is_local) {
            try self.addMessageUnlocked("error", "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml");
            return;
        }

        var client = try core.AIClient.init(self.allocator, provider, self.model_name, self.api_key);
        client.max_tokens = self.max_tokens;
        client.temperature = self.temperature;
        if (self.override_url) |override_url| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, override_url);
        }
        if (self.system_prompt) |system_prompt| {
            if (system_prompt.len > 0) {
                client.setSystemPrompt(system_prompt);
            }
        }
        self.client = client;
    }

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn handleEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        self.reapWorkerIfDone();

        switch (event) {
            .init => {
                try ctx.setTitle("Crushcode TUI Chat");
                try ctx.requestFocus(if (self.show_palette) self.palette_input.widget() else self.input.widget());
                ctx.redraw = true;
            },
            .focus_in => {
                try ctx.requestFocus(if (self.show_palette) self.palette_input.widget() else self.input.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    self.should_quit = true;
                    ctx.quit = true;
                    ctx.consumeEvent();
                    return;
                }

                if (key.matches('p', .{ .ctrl = true })) {
                    if (self.setup_phase != 0) {
                        ctx.consumeEvent();
                        return;
                    }
                    if (self.show_palette) {
                        try self.closePalette(ctx);
                    } else {
                        try self.openPalette(ctx);
                    }
                    ctx.consumeEvent();
                    return;
                }

                if (self.setup_phase == 1) {
                    if (key.matches(vaxis.Key.up, .{})) {
                        self.moveSetupProviderSelection(-1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        self.moveSetupProviderSelection(1);
                        ctx.consumeEvent();
                        return;
                    }
                }

                if (self.show_palette) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        try self.closePalette(ctx);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.up, .{})) {
                        self.movePaletteSelection(-1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        self.movePaletteSelection(1);
                        ctx.consumeEvent();
                        return;
                    }
                }
            },
            else => {},
        }

        ctx.redraw = true;
    }

    fn draw(self: *Model, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.reapWorkerIfDone();
        self.lock.lock();
        defer self.lock.unlock();

        const max = ctx.max.size();
        const header_height: u16 = 2;
        const files_height: u16 = if (self.recent_files.items.len > 0) 1 else 0;
        const status_height: u16 = 1;
        const input_height: u16 = 1;
        const body_height = max.height -| (header_height + files_height + status_height + input_height);

        const full_title = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | setup", .{app_version})
        else
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | {s}/{s} | thinking:{s} | ctx: {d}%", .{
                app_version,
                self.provider_name,
                self.model_name,
                if (self.thinking) "on" else "off",
                self.contextPercent(),
            });

        const header = HeaderWidget{ .title = full_title };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = max.width, .height = header_height },
            .{ .width = max.width, .height = header_height },
        ));

        const body_surface = blk: {
            if (self.setup_phase != 0) {
                const wizard = SetupWizardWidget{ .model = self };
                break :blk try wizard.draw(ctx.withConstraints(
                    .{ .width = max.width, .height = body_height },
                    .{ .width = max.width, .height = body_height },
                ));
            } else {
                var message_widgets = std.ArrayList(vxfw.Widget).empty;
                defer message_widgets.deinit(ctx.arena);
                try message_widgets.ensureTotalCapacity(ctx.arena, @max(self.messages.items.len * 3, 1));
                var visible_count: usize = 0;
                for (self.messages.items, 0..) |message, idx| {
                    if (message.tool_call_id != null and findToolCallBefore(self.messages.items, idx, message.tool_call_id.?) != null) {
                        continue;
                    }
                    const message_widget = MessageWidget{ .model = self, .message_index = idx };
                    try message_widgets.append(ctx.arena, message_widget.widget());
                    visible_count += 1;
                    if (visible_count < visibleMessageCount(self.messages.items)) {
                        const gap = MessageGapWidget{};
                        try message_widgets.append(ctx.arena, gap.widget());
                        const separator = SeparatorWidget{};
                        try message_widgets.append(ctx.arena, separator.widget());
                    }
                }

                self.scroll_view.children = .{ .slice = message_widgets.items };
                if (message_widgets.items.len > 0) {
                    self.scroll_view.item_count = @intCast(message_widgets.items.len);
                    self.scroll_view.cursor = @intCast(message_widgets.items.len - 1);
                    self.scroll_view.ensureScroll();
                } else {
                    self.scroll_view.item_count = 0;
                    self.scroll_view.cursor = 0;
                }
                self.scroll_bars.scroll_view = self.scroll_view;
                self.scroll_bars.estimated_content_height = estimateContentHeight(self);

                const surface = try self.scroll_bars.draw(ctx.withConstraints(
                    .{ .width = max.width, .height = body_height },
                    .{ .width = max.width, .height = body_height },
                ));
                self.scroll_view = self.scroll_bars.scroll_view;
                break :blk surface;
            }
        };

        const status_text = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Setup {d}/4 | {s}", .{
                @min(self.setup_phase, @as(u8, 4)),
                if (self.setup_phase == 1) "Choose a provider" else if (self.setup_phase == 2) "Enter your API key" else if (self.setup_phase == 3) "Choose a default model" else "Press Enter to continue",
            })
        else
            try std.fmt.allocPrint(ctx.arena, "Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s", .{
                self.total_input_tokens,
                self.total_output_tokens,
                self.estimatedCostUsd(),
                self.request_count,
                self.sessionMinutes(),
                self.sessionSecondsPart(),
            });
        const status_widget = vxfw.Text{
            .text = status_text,
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const status_surface = try status_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = status_height },
            .{ .width = max.width, .height = status_height },
        ));

        const input_widget = InputWidget{ .prompt = self.currentInputPrompt(), .field = &self.input };
        const input_surface = try input_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = input_height },
            .{ .width = max.width, .height = input_height },
        ));

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height), .col = 0 }, .surface = body_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + body_height + files_height), .col = 0 }, .surface = status_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + body_height + files_height + status_height), .col = 0 }, .surface = input_surface });

        if (self.show_palette) {
            const palette = CommandPaletteWidget{
                .field = &self.palette_input,
                .commands = self.palette_commands,
                .filter = self.palette_filter,
                .selected = self.palette_selected,
            };
            const palette_surface = try palette.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| palette_surface.size.height) / 2),
                    .col = @intCast((max.width -| palette_surface.size.width) / 2),
                },
                .surface = palette_surface,
            });
        }

        if (self.recent_files.items.len > 0) {
            const visible_files = recentFilesVisibleCount(self.recent_files.items);
            const files_widget = FilesWidget{ .files = self.recent_files.items[0..visible_files] };
            const files_surface = try files_widget.draw(ctx.withConstraints(
                .{ .width = max.width, .height = 1 },
                .{ .width = max.width, .height = 1 },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + body_height), .col = 0 }, .surface = files_surface });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_list.items.len);
        @memcpy(children, child_list.items);

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn handleSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        self.reapWorkerIfDone();

        if (self.setup_phase != 0) {
            try self.handleSetupSubmit(value, ctx);
            return;
        }

        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (std.mem.eql(u8, trimmed, "/exit")) {
            self.should_quit = true;
            ctx.quit = true;
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (self.request_active) {
            try self.addMessageUnlocked("error", "Still waiting for the current response. Please wait for it to finish.");
            ctx.redraw = true;
            return;
        }

        if (self.client == null) {
            const text = if (self.api_key.len == 0)
                "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"
            else
                "Chat client is not ready. Fix the configuration shown above and restart the TUI.";
            try self.addMessageUnlocked("error", text);
            ctx.redraw = true;
            return;
        }

        try self.addMessageUnlocked("user", trimmed);
        try self.appendHistoryMessageUnlocked("user", trimmed);
        try self.addMessageUnlocked("assistant", "Thinking...");
        self.assistant_stream_index = self.messages.items.len - 1;
        self.request_active = true;
        self.request_done = false;
        self.awaiting_first_token = true;

        self.resetInputField();
        self.worker = try std.Thread.spawn(.{}, requestThreadMain, .{self});
        ctx.redraw = true;
    }

    fn resetInputField(self: *Model) void {
        self.input.deinit();
        self.input = vxfw.TextField.init(self.allocator);
        self.input.style = .{ .fg = .{ .index = 15 } };
        self.input.userdata = self;
        self.input.onSubmit = onSubmit;
    }

    fn currentInputPrompt(self: *const Model) []const u8 {
        return switch (self.setup_phase) {
            1 => "Select: ",
            2 => "API key: ",
            3 => "Model: ",
            4 => "Continue: ",
            else => "❯ ",
        };
    }

    fn moveSetupProviderSelection(self: *Model, delta: isize) void {
        const current: isize = @intCast(self.setup_provider_index);
        const max_index: isize = @intCast(setup_provider_data.len - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.setup_provider_index = @intCast(next);
    }

    fn setSetupFeedback(self: *Model, text: []const u8, is_error: bool) !void {
        if (self.setup_feedback.len > 0) {
            self.allocator.free(self.setup_feedback);
        }
        self.setup_feedback = try self.allocator.dupe(u8, text);
        self.setup_feedback_is_error = is_error;
    }

    fn clearSetupFeedback(self: *Model) void {
        if (self.setup_feedback.len > 0) {
            self.allocator.free(self.setup_feedback);
        }
        self.setup_feedback = "";
        self.setup_feedback_is_error = false;
    }

    fn replaceOwnedString(self: *Model, slot: *[]const u8, value: []const u8) !void {
        const updated = try self.allocator.dupe(u8, value);
        self.allocator.free(slot.*);
        slot.* = updated;
    }

    fn handleSetupSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        switch (self.setup_phase) {
            1 => {
                try self.replaceOwnedString(&self.provider_name, setup_provider_data[self.setup_provider_index]);
                self.clearSetupFeedback();
                self.setup_phase = 2;
                self.resetInputField();
            },
            2 => {
                if (trimmed.len == 0 and !setupProviderAllowsEmptyKey(self.provider_name)) {
                    try self.setSetupFeedback("API key cannot be empty for this provider.", true);
                    ctx.redraw = true;
                    return;
                }
                try self.replaceOwnedString(&self.api_key, trimmed);
                self.clearSetupFeedback();
                self.setup_phase = 3;
                self.resetInputField();
            },
            3 => {
                const resolved_model = if (trimmed.len > 0) trimmed else setupDefaultModel(self.provider_name);
                try self.replaceOwnedString(&self.model_name, resolved_model);
                try self.saveSetupConfig();
                try self.initializeClient();
                self.clearSetupFeedback();
                self.setup_phase = 4;
                self.resetInputField();
            },
            4 => {
                self.clearSetupFeedback();
                self.setup_phase = 0;
                try self.addMessageUnlocked("assistant", "TUI chat ready. Type a message and press Enter.");
                self.resetInputField();
            },
            else => {},
        }
        try ctx.requestFocus(self.input.widget());
        ctx.redraw = true;
    }

    fn saveSetupConfig(self: *Model) !void {
        const config_path = try setupConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(config_dir);

        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        const escaped_model = self.model_name;
        const escaped_key = self.api_key;

        const content = try std.fmt.allocPrint(
            self.allocator,
            "default_provider = \"{s}\"\ndefault_model = \"{s}\"\n\n[api_keys]\n{s} = \"{s}\"\n",
            .{ self.provider_name, escaped_model, self.provider_name, escaped_key },
        );
        defer self.allocator.free(content);

        try file.writeAll(content);
    }

    fn resetPaletteInputField(self: *Model) void {
        self.palette_input.deinit();
        self.palette_input = vxfw.TextField.init(self.allocator);
        self.palette_input.style = .{ .fg = .{ .index = 15 } };
        self.palette_input.userdata = self;
        self.palette_input.onChange = onPaletteChange;
        self.palette_input.onSubmit = onPaletteSubmit;
    }

    fn clearPaletteFilter(self: *Model) void {
        if (self.palette_filter.len > 0) {
            self.allocator.free(self.palette_filter);
        }
        self.palette_filter = "";
        self.palette_selected = 0;
    }

    fn setPaletteFilter(self: *Model, value: []const u8) !void {
        if (self.palette_filter.len > 0) {
            self.allocator.free(self.palette_filter);
        }
        self.palette_filter = if (value.len == 0) "" else try self.allocator.dupe(u8, value);
        self.clampPaletteSelection();
    }

    fn openPalette(self: *Model, ctx: *vxfw.EventContext) !void {
        self.show_palette = true;
        self.clearPaletteFilter();
        self.resetPaletteInputField();
        try ctx.requestFocus(self.palette_input.widget());
        ctx.redraw = true;
    }

    fn closePalette(self: *Model, ctx: *vxfw.EventContext) !void {
        self.show_palette = false;
        self.clearPaletteFilter();
        self.resetPaletteInputField();
        try ctx.requestFocus(self.input.widget());
        ctx.redraw = true;
    }

    fn clampPaletteSelection(self: *Model) void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            self.palette_selected = 0;
            return;
        }
        if (self.palette_selected >= filtered_count) {
            self.palette_selected = filtered_count - 1;
        }
    }

    fn movePaletteSelection(self: *Model, delta: isize) void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            self.palette_selected = 0;
            return;
        }

        const current: isize = @intCast(self.palette_selected);
        const max_index: isize = @intCast(filtered_count - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.palette_selected = @intCast(next);
    }

    fn executePaletteSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            return;
        }

        const command = self.palette_commands[filtered_indices[self.palette_selected]];
        try self.closePalette(ctx);
        try self.executePaletteCommand(command.name, ctx);
    }

    fn executePaletteCommand(self: *Model, name: []const u8, ctx: *vxfw.EventContext) !void {
        if (std.mem.eql(u8, name, "/exit")) {
            self.should_quit = true;
            ctx.quit = true;
            ctx.redraw = true;
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (std.mem.eql(u8, name, "/clear")) {
            if (self.request_active) {
                try self.addMessageUnlocked("error", "Cannot clear the chat while a response is still streaming.");
            } else {
                self.clearMessagesUnlocked();
                self.clearHistoryUnlocked();
                self.assistant_stream_index = null;
                self.awaiting_first_token = false;
            }
        } else if (std.mem.eql(u8, name, "/thinking")) {
            self.thinking = !self.thinking;
            const text = if (self.thinking) "Thinking enabled." else "Thinking disabled.";
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/help")) {
            try self.addMessageUnlocked("assistant", "/clear — Clear conversation history\n/exit — Exit crushcode\n/model — Show current model\n/thinking — Toggle thinking mode\n/compact — Compact conversation context\n/help — Show available commands");
        } else if (std.mem.eql(u8, name, "/compact")) {
            try self.addMessageUnlocked("assistant", "/compact is not yet implemented.");
        } else if (std.mem.eql(u8, name, "/model")) {
            const text = try std.fmt.allocPrint(self.allocator, "Current model: {s}/{s}", .{ self.provider_name, self.model_name });
            defer self.allocator.free(text);
            try self.addMessageUnlocked("assistant", text);
        }

        ctx.redraw = true;
    }

    fn reapWorkerIfDone(self: *Model) void {
        var thread_to_join: ?std.Thread = null;
        self.lock.lock();
        if (self.request_done and self.worker != null) {
            thread_to_join = self.worker;
            self.worker = null;
            self.request_done = false;
        }
        self.lock.unlock();

        if (thread_to_join) |thread| {
            thread.join();
        }
    }

    fn addMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
        try self.addMessageWithToolsUnlocked(role, content, null, null);
    }

    fn addMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
            .tool_calls = try cloneToolCallInfos(self.allocator, tool_calls),
        });
    }

    fn clearMessagesUnlocked(self: *Model) void {
        for (self.messages.items) |message| {
            freeDisplayMessage(self.allocator, message);
        }
        self.messages.clearRetainingCapacity();
    }

    fn clearHistoryUnlocked(self: *Model) void {
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.clearRetainingCapacity();
    }

    fn appendHistoryMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
        try self.appendHistoryMessageWithToolsUnlocked(role, content, null, null);
    }

    fn appendHistoryMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        try self.history.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
            .tool_calls = try cloneToolCallInfos(self.allocator, tool_calls),
        });
    }

    fn replaceMessageUnlocked(self: *Model, index: usize, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        var message = &self.messages.items[index];
        self.allocator.free(message.role);
        self.allocator.free(message.content);
        if (message.tool_call_id) |value| self.allocator.free(value);
        freeToolCallInfos(self.allocator, message.tool_calls);
        message.role = try self.allocator.dupe(u8, role);
        message.content = try self.allocator.dupe(u8, content);
        message.tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
        message.tool_calls = try cloneToolCallInfos(self.allocator, tool_calls);
    }

    fn appendToMessageUnlocked(self: *Model, index: usize, suffix: []const u8) !void {
        var message = &self.messages.items[index];
        const updated = try self.allocator.alloc(u8, message.content.len + suffix.len);
        @memcpy(updated[0..message.content.len], message.content);
        @memcpy(updated[message.content.len..], suffix);
        self.allocator.free(message.content);
        message.content = updated;
    }

    fn trackToolCallFilesUnlocked(self: *Model, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        const calls = tool_calls orelse return;
        for (calls) |tool_call| {
            if (!isRecentFileTool(tool_call.name)) continue;
            if (extractToolFilePath(tool_call.arguments)) |path| {
                try self.addRecentFileUnlocked(path);
            }
        }
    }

    fn addRecentFileUnlocked(self: *Model, file_path: []const u8) !void {
        var found_index: ?usize = null;
        for (self.recent_files.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, file_path)) {
                found_index = idx;
                break;
            }
        }
        if (found_index) |idx| {
            self.allocator.free(self.recent_files.items[idx]);
            _ = self.recent_files.orderedRemove(idx);
        }
        const owned = try self.allocator.dupe(u8, file_path);
        try self.recent_files.append(self.allocator, owned);
        if (self.recent_files.items.len > recent_files_max) {
            self.allocator.free(self.recent_files.orderedRemove(0));
        }
    }

    fn requestThreadMain(self: *Model) void {
        active_stream_model = self;
        defer active_stream_model = null;
        self.runStreamingRequest() catch |err| {
            self.finishRequestWithCaughtError(err);
        };
    }

    fn runStreamingRequest(self: *Model) !void {
        const input_tokens = estimateMessageTokens(self.history.items);
        var response = try self.client.?.sendChatStreaming(self.history.items, streamCallback);
        defer freeChatResponse(self.allocator, &response);

        if (response.choices.len == 0) {
            self.finishRequestWithErrorText("No response received from provider");
            return;
        }

        const content = response.choices[0].message.content orelse "";
        const tool_calls = response.choices[0].message.tool_calls;
        if (content.len == 0 and tool_calls == null) {
            self.finishRequestWithErrorText("No response received from provider");
            return;
        }
        var output_tokens = estimateTextTokens(content);
        if (tool_calls) |calls| {
            for (calls) |tool_call| {
                output_tokens += estimateTextTokens(tool_call.name);
                output_tokens += estimateTextTokens(tool_call.arguments);
            }
            self.trackToolCallFilesUnlocked(tool_calls) catch {};
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
            }
            self.awaiting_first_token = false;
        } else if (self.assistant_stream_index) |index| {
            try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
        }

        try self.appendHistoryMessageWithToolsUnlocked("assistant", content, null, tool_calls);
        _ = response.usage;
        self.total_input_tokens += input_tokens;
        self.total_output_tokens += output_tokens;
        self.request_count += 1;
        self.request_active = false;
        self.request_done = true;
    }

    fn finishRequestWithCaughtError(self: *Model, err: anyerror) void {
        switch (err) {
            error.AuthenticationError => self.finishRequestWithErrorText("No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"),
            error.NetworkError => self.finishRequestWithErrorText("Network error while contacting provider. Check your connection and try again."),
            error.TimeoutError => self.finishRequestWithErrorText("Request timed out. Please try again."),
            error.ServerError => self.finishRequestWithErrorText("Provider returned an error. Please try again in a moment."),
            error.InvalidResponse => self.finishRequestWithErrorText("Provider returned an invalid response."),
            error.ConfigurationError => self.finishRequestWithErrorText("Chat client is not configured correctly. Run crushcode setup or edit ~/.crushcode/config.toml"),
            else => {
                const text = std.fmt.allocPrint(self.allocator, "Request failed: {s}", .{@errorName(err)}) catch return;
                defer self.allocator.free(text);
                self.finishRequestWithErrorText(text);
            },
        }
    }

    fn finishRequestWithErrorText(self: *Model, text: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                self.replaceMessageUnlocked(index, "error", text, null, null) catch {
                    self.addMessageUnlocked("error", text) catch {};
                };
            } else {
                self.addMessageUnlocked("error", text) catch {};
            }
            self.awaiting_first_token = false;
        } else {
            self.addMessageUnlocked("error", text) catch {};
        }

        self.request_active = false;
        self.request_done = true;
    }

    fn handleStreamToken(self: *Model, token: []const u8, done: bool) void {
        _ = done;
        if (token.len == 0) {
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.assistant_stream_index orelse return;
        if (self.awaiting_first_token) {
            self.replaceMessageUnlocked(index, "assistant", token, null, null) catch {};
            self.awaiting_first_token = false;
            return;
        }

        self.appendToMessageUnlocked(index, token) catch {};
    }

    fn estimatedCostUsd(self: *Model) f64 {
        const input_tokens: u32 = @intCast(@min(self.total_input_tokens, std.math.maxInt(u32)));
        const output_tokens: u32 = @intCast(@min(self.total_output_tokens, std.math.maxInt(u32)));
        return self.pricing_table.estimateCostSimple(self.provider_name, resolvedPricingModel(self), input_tokens, output_tokens);
    }

    fn contextPercent(self: *const Model) u8 {
        const total_tokens = self.total_input_tokens + self.total_output_tokens;
        const percent = @min((total_tokens * 100) / 128_000, 100);
        return @intCast(percent);
    }

    fn sessionElapsedSeconds(self: *const Model) u64 {
        const elapsed_ns = @max(std.time.nanoTimestamp() - self.session_start, 0);
        return @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
    }

    fn sessionMinutes(self: *const Model) u64 {
        return @divFloor(self.sessionElapsedSeconds(), 60);
    }

    fn sessionSecondsPart(self: *const Model) u64 {
        return @mod(self.sessionElapsedSeconds(), 60);
    }
};

fn onSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.handleSubmit(value, ctx);
}

fn onPaletteChange(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.setPaletteFilter(value);
    ctx.redraw = true;
}

fn onPaletteSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    _ = value;
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.executePaletteSelection(ctx);
}

fn streamCallback(token: []const u8, done: bool) void {
    const model = active_stream_model orelse return;
    model.handleStreamToken(token, done);
}

fn setupProviderIndex(provider_name: []const u8) usize {
    for (setup_provider_data, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate, provider_name)) return idx;
    }
    return 0;
}

fn setupProviderAllowsEmptyKey(provider_name: []const u8) bool {
    return std.mem.eql(u8, provider_name, "ollama");
}

fn setupDefaultModel(provider_name: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_name, "openrouter")) return "anthropic/claude-sonnet-4";
    if (std.mem.eql(u8, provider_name, "openai")) return "gpt-4o";
    if (std.mem.eql(u8, provider_name, "anthropic")) return "claude-3-5-sonnet-20241022";
    if (std.mem.eql(u8, provider_name, "groq")) return "llama-3.3-70b-versatile";
    if (std.mem.eql(u8, provider_name, "together")) return "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo";
    if (std.mem.eql(u8, provider_name, "gemini")) return "gemini-2.0-flash-exp";
    if (std.mem.eql(u8, provider_name, "xai")) return "grok-beta";
    if (std.mem.eql(u8, provider_name, "mistral")) return "mistral-large-latest";
    if (std.mem.eql(u8, provider_name, "ollama")) return "gemma4:31b-cloud";
    if (std.mem.eql(u8, provider_name, "zai")) return "glm-4.5-air";
    return "default";
}

fn setupConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/root";
    return std.fmt.allocPrint(allocator, "{s}/.crushcode/config.toml", .{home});
}

fn appendSetupText(
    ctx: vxfw.DrawContext,
    child_list: *std.ArrayList(vxfw.SubSurface),
    row: *u16,
    width: u16,
    text: []const u8,
    style: vaxis.Style,
) std.mem.Allocator.Error!void {
    const widget = vxfw.Text{
        .text = text,
        .style = style,
        .softwrap = true,
        .width_basis = .parent,
    };
    const surface = try widget.draw(ctx.withConstraints(
        .{ .width = width, .height = 0 },
        .{ .width = width, .height = null },
    ));
    try child_list.append(ctx.arena, .{ .origin = .{ .row = row.*, .col = 0 }, .surface = surface });
    row.* += surface.size.height;
}

fn shouldRenderMessageContent(message: *const Message) bool {
    return message.content.len > 0 or message.tool_calls == null;
}

fn toolCallStatusIcon(status: ToolCallStatus) []const u8 {
    return switch (status) {
        .pending => "●",
        .success => "✓",
        .failed => "×",
    };
}

fn toolCallStatusStyle(status: ToolCallStatus) vaxis.Style {
    return switch (status) {
        .pending => .{ .fg = .{ .index = 11 }, .bold = true },
        .success => .{ .fg = .{ .index = 10 }, .bold = true },
        .failed => .{ .fg = .{ .index = 1 }, .bold = true },
    };
}

fn toolCallStatusForMessage(message: ?*const Message) ToolCallStatus {
    const result = message orelse return .pending;
    if (std.mem.eql(u8, result.role, "error")) return .failed;

    const trimmed = std.mem.trim(u8, result.content, " \t\r\n");
    if (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "error:")) {
        return .failed;
    }
    return .success;
}

fn toolCallOutputText(allocator: std.mem.Allocator, output: ?[]const u8, status: ToolCallStatus) ![]const u8 {
    const text = output orelse {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    };
    if (text.len == 0) {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    }

    var builder = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    var remaining: usize = 0;
    while (lines.next()) |line| {
        if (line_count < 5) {
            if (line_count > 0) try builder.append(allocator, '\n');
            try builder.appendSlice(allocator, "  ");
            try builder.appendSlice(allocator, line);
        } else {
            remaining += 1;
        }
        line_count += 1;
    }
    if (remaining > 0) {
        if (builder.items.len > 0) try builder.append(allocator, '\n');
        try builder.writer(allocator).print("  and {d} more lines...", .{remaining});
    }
    return builder.toOwnedSlice(allocator);
}

fn findToolCallBefore(messages: []const Message, before_index: usize, tool_call_id: []const u8) ?core.client.ToolCallInfo {
    var idx = before_index;
    while (idx > 0) {
        idx -= 1;
        if (messages[idx].tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.id, tool_call_id)) return tool_call;
            }
        }
    }
    return null;
}

fn findToolResultMessageAfter(messages: []const Message, after_index: usize, tool_call_id: []const u8) ?*const Message {
    var idx = after_index + 1;
    while (idx < messages.len) : (idx += 1) {
        const message = &messages[idx];
        if (message.tool_call_id) |message_tool_call_id| {
            if (std.mem.eql(u8, message_tool_call_id, tool_call_id)) return message;
        }
    }
    return null;
}

fn visibleMessageCount(messages: []const Message) usize {
    var count: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
        count += 1;
    }
    return count;
}

fn messageRoleStyle(role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = .{ .index = 39 }, .bold = true };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = .{ .index = 1 }, .bold = true };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = .{ .index = 10 }, .bold = true };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = .{ .index = 11 }, .bold = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = .{ .index = 14 }, .bold = true };
    }
    return .{ .fg = .{ .index = 8 }, .bold = true };
}

fn messageBodyStyle(role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = .{ .index = 15 } };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = .{ .index = 39 } };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = .{ .index = 1 } };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = .{ .index = 11 }, .dim = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = .{ .index = 14 }, .dim = true };
    }
    return .{ .fg = .{ .index = 8 }, .dim = true };
}

fn messageRoleLabel(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return "You";
    if (std.mem.eql(u8, role, "assistant")) return "Assistant";
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return role;
}

fn estimateContentHeight(model: *const Model) ?u32 {
    var total: u32 = 0;
    const messages = model.messages.items;
    const visible_count = visibleMessageCount(messages);
    var visible_index: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;

        if (shouldRenderMessageContent(&message)) {
            total += @intCast(1 + std.mem.count(u8, message.content, "\n"));
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += 1;
                if (tool_call.arguments.len > 0) total += @intCast(std.mem.count(u8, tool_call.arguments, "\n"));
                const result = findToolResultMessageAfter(messages, idx, tool_call.id);
                const output = result orelse null;
                const output_text = if (output) |message_result| message_result.content else if (toolCallStatusForMessage(result) == .pending) "running..." else "";
                if (output_text.len > 0) {
                    total += @intCast(@min(std.mem.count(u8, output_text, "\n") + 1, 6));
                }
            }
        }

        visible_index += 1;
        if (visible_index < visible_count) total += 2;
    }
    return total;
}

fn drawBorder(surface: *vxfw.Surface, style: vaxis.Style) void {
    const width = surface.size.width;
    const height = surface.size.height;
    if (width == 0 or height == 0) return;

    const horizontal: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style };
    const vertical: vaxis.Cell = .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style };
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    surface.writeCell(0, height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(width - 1, height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });

    if (width > 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), 0, horizontal);
            surface.writeCell(@intCast(col), height - 1, horizontal);
        }
    }
    if (height > 2) {
        for (1..height - 1) |row| {
            surface.writeCell(0, @intCast(row), vertical);
            surface.writeCell(width - 1, @intCast(row), vertical);
        }
    }
}

fn collectFilteredCommandIndices(commands: []const Command, filter: []const u8, out: []usize) usize {
    var count: usize = 0;
    for (commands, 0..) |command, idx| {
        if (commandMatchesFilter(command, filter)) {
            out[count] = idx;
            count += 1;
        }
    }
    return count;
}

fn commandMatchesFilter(command: Command, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return containsIgnoreCase(command.name, filter) or
        containsIgnoreCase(command.description, filter) or
        containsIgnoreCase(command.shortcut, filter);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
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

fn commandDescriptionGap(name_len: usize) u16 {
    const max_name_len = maxCommandNameLen(&palette_command_data);
    const gap = max_name_len - name_len + 4;
    return @intCast(@max(gap, 1));
}

fn maxCommandNameLen(commands: []const Command) usize {
    var max_len: usize = 0;
    for (commands) |command| {
        max_len = @max(max_len, command.name.len);
    }
    return max_len;
}

fn estimateTextTokens(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return @intCast(@divFloor(text.len + 3, 4));
}

fn estimateMessageTokens(messages: []const core.ChatMessage) u64 {
    var total: u64 = 0;
    for (messages) |message| {
        total += estimateTextTokens(message.role);
        if (message.content) |content| {
            total += estimateTextTokens(content);
        }
        if (message.tool_call_id) |tool_call_id| {
            total += estimateTextTokens(tool_call_id);
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += estimateTextTokens(tool_call.id);
                total += estimateTextTokens(tool_call.name);
                total += estimateTextTokens(tool_call.arguments);
            }
        }
    }
    return total;
}

fn repeated(allocator: std.mem.Allocator, token: []const u8, count: u16) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try buffer.ensureTotalCapacity(allocator, token.len * count);
    for (0..count) |_| {
        try buffer.appendSlice(allocator, token);
    }
    return buffer.toOwnedSlice(allocator);
}

fn recentFilesDisplay(files: []const []const u8) []const []const u8 {
    return files[0..@min(files.len, recent_files_display_max)];
}

fn isRecentFileTool(name: []const u8) bool {
    for (recent_file_tool_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn extractToolFilePath(arguments: []const u8) ?[]const u8 {
    inline for (.{ "path", "file_path" }) |key| {
        if (std.mem.indexOf(u8, arguments, std.fmt.comptimePrint("\"{s}\"", .{key}))) |key_index| {
            const colon = std.mem.indexOfPos(u8, arguments, key_index, ":") orelse return null;
            var start = colon + 1;
            while (start < arguments.len and std.ascii.isWhitespace(arguments[start])) : (start += 1) {}
            if (start >= arguments.len or arguments[start] != '"') return null;
            start += 1;
            const end = std.mem.indexOfScalarPos(u8, arguments, start, '"') orelse return null;
            return arguments[start..end];
        }
    }
    return null;
}

fn recentFilesVisibleCount(files: []const []const u8) usize {
    return @min(files.len, recent_files_display_max);
}

fn contentSurfaceWidget(allocator: std.mem.Allocator, surface: vxfw.Surface) !vxfw.Widget {
    const widget_holder = try allocator.create(SurfaceWidget);
    widget_holder.* = .{ .surface = surface };
    return widget_holder.widget();
}

fn resolvedPricingModel(model: *Model) []const u8 {
    if (model.pricing_table.getPrice(model.provider_name, model.model_name) != null) {
        return model.model_name;
    }
    return "default";
}

fn spinnerFrame() []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const tick = @divFloor(std.time.milliTimestamp(), 120);
    return frames[@as(usize, @intCast(@mod(tick, frames.len)))];
}

fn freeToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn cloneToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) !?[]const core.client.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(core.client.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn freeDisplayMessage(allocator: std.mem.Allocator, message: Message) void {
    allocator.free(message.role);
    allocator.free(message.content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

fn freeChatMessage(allocator: std.mem.Allocator, message: core.ChatMessage) void {
    allocator.free(message.role);
    if (message.content) |content| allocator.free(content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

fn freeChatResponse(allocator: std.mem.Allocator, response: *core.ChatResponse) void {
    allocator.free(response.id);
    allocator.free(response.object);
    allocator.free(response.model);
    for (response.choices) |choice| {
        freeChatMessage(allocator, choice.message);
        if (choice.finish_reason) |finish_reason| allocator.free(finish_reason);
    }
    allocator.free(response.choices);
    if (response.provider) |provider| allocator.free(provider);
    if (response.cost) |cost| allocator.free(cost);
    if (response.system_fingerprint) |system_fingerprint| allocator.free(system_fingerprint);
}

pub fn run(allocator: std.mem.Allocator, provider_name: []const u8, model_name: []const u8, api_key: []const u8) !void {
    try runWithOptions(allocator, .{
        .provider_name = provider_name,
        .model_name = model_name,
        .api_key = api_key,
    });
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var model = try Model.create(allocator, options);
    defer model.destroy();
    try model.run();
}
