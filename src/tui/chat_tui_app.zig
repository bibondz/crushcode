const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core_api");
const config_mod = @import("config");
const fallback_mod = @import("fallback");
const graph_mod = @import("graph");
const registry_mod = @import("registry");
const session_mod = @import("session");
const diff = @import("diff");
const markdown = @import("markdown");
const theme_mod = @import("theme");
const usage_pricing = @import("usage_pricing");

const vxfw = vaxis.vxfw;
const app_version = "0.2.2";

pub const WorkerStatus = enum {
    pending,
    running,
    done,
    @"error",
    cancelled,
};

pub const WorkerItem = struct {
    id: u32,
    task: []const u8,
    status: WorkerStatus,
    result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

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
const tool_diff_max_lines: usize = 80;
const session_row_display_max: usize = 8;
const recent_file_tool_names = [_][]const u8{ "read_file", "write_file", "edit", "glob" };
const context_source_files = [_][]const u8{
    "build.zig",
    "src/main.zig",
    "src/cli/args.zig",
    "src/commands/chat.zig",
    "src/config/config.zig",
    "src/ai/client.zig",
    "src/ai/registry.zig",
    "src/tui/chat_tui_app.zig",
};

const builtin_tool_schemas = [_]core.ToolSchema{
    .{
        .name = "read_file",
        .description = "Read a file from disk",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "shell",
        .description = "Run a shell command",
        .parameters =
        \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Write full content to a file",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "glob",
        .description = "Find files matching a glob pattern",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Search file contents for text",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"include":{"type":"string"},"max_results":{"type":"integer"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "edit",
        .description = "Replace one exact string in a file",
        .parameters =
        \\{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["file_path","old_string","new_string"]}
        ,
    },
};

const PermissionMode = enum {
    default,
    auto,
    plan,
};

const PermissionDecision = enum {
    yes,
    no,
    always,
};

const ToolPermission = struct {
    tool_name: []const u8,
    arguments: []const u8,
};

const FallbackProvider = struct {
    provider_name: []const u8,
    api_key: []const u8,
    model_name: []const u8,
    override_url: ?[]const u8,
};

const InterruptedSessionCandidate = struct {
    session: session_mod.Session,
    path: []const u8,
};

const RoleLabelWidget = struct {
    label: []const u8,
    style: vaxis.Style,
    theme: *const theme_mod.Theme,

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
                .{ .text = ": ", .style = .{ .fg = self.theme.dimmed, .dim = true } },
            },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return rich.draw(ctx);
    }
};

const MessageContentWidget = struct {
    message: *const Message,
    theme: *const theme_mod.Theme,

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
        const role_style = messageRoleStyle(self.theme, self.message.role);
        const body_style = messageBodyStyle(self.theme, self.message.role);
        const role_label: RoleLabelWidget = .{ .label = messageRoleLabel(self.theme, self.message.role), .style = role_style, .theme = self.theme };
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
    theme: *const theme_mod.Theme,

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
                .{ .text = toolCallStatusIcon(self.status), .style = toolCallStatusStyle(self.theme, self.status) },
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

        const diff_text = if (isDiffRenderableTool(self.tool_call.name) and self.output != null)
            extractToolDiffText(self.output.?)
        else
            null;
        if (diff_text) |text| {
            const diff_widget = DiffWidget{
                .file_path = extractToolFilePath(self.tool_call.arguments) orelse self.tool_call.name,
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

        const output_text = try toolCallOutputText(ctx.arena, self.output, self.status);
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

const DiffWidget = struct {
    file_path: []const u8,
    diff_text: []const u8,
    theme: *const theme_mod.Theme,

    fn widget(self: *const DiffWidget) vxfw.Widget {
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
        const max = ctx.max.size();
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
            .{ .width = inner_width, .height = null },
        ));

        const diff_segments = try diff.parseDiff(ctx.arena, self.diff_text, tool_diff_max_lines);
        const diff_text_widget = vxfw.RichText{
            .text = diff_segments,
            .softwrap = true,
            .width_basis = .parent,
        };
        const diff_surface = try diff_text_widget.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = null },
        ));

        const height = 2 + title_surface.size.height + diff_surface.size.height;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.theme.header_bg } });
        drawBorder(&surface, .{ .fg = self.theme.accent, .dim = true });

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
            const theme = self.model.current_theme;
            const content_surface = try (MessageContentWidget{ .message = message, .theme = theme }).draw(ctx.withConstraints(
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
                    .theme = self.model.current_theme,
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
                .style = .{ .fg = self.model.current_theme.border },
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
    theme: *const theme_mod.Theme,

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
        const width = ctx.max.width orelse ctx.min.width;
        const line_width: u16 = @max(@min(width, @as(u16, 40)), @as(u16, 2));
        const line = if (line_width <= 3)
            try repeated(ctx.arena, "─", line_width)
        else
            try std.fmt.allocPrint(ctx.arena, "╶{s}╴", .{try repeated(ctx.arena, "─", line_width - 2)});
        const text: vxfw.Text = .{
            .text = line,
            .style = .{ .fg = self.theme.border, .dim = true },
            .softwrap = false,
            .width_basis = .longest_line,
        };
        return text.draw(ctx.withConstraints(.{ .width = line_width, .height = 1 }, .{ .width = line_width, .height = 1 }));
    }
};

const HeaderWidget = struct {
    title: []const u8,
    theme: *const theme_mod.Theme,

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
        const bg_style: vaxis.Style = .{ .fg = self.theme.header_fg, .bg = self.theme.header_bg };
        const title = vxfw.RichText{
            .text = &.{.{ .text = self.title, .style = .{ .fg = self.theme.header_fg, .bg = self.theme.header_bg, .bold = true } }},
            .softwrap = false,
            .width_basis = .parent,
        };
        const title_surface = try title.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));

        const line = try repeated(ctx.arena, "─", width);
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
    theme: *const theme_mod.Theme,

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

const SidebarWidget = struct {
    model: *const Model,
    width: u16,

    fn widget(self: *const SidebarWidget) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = typeErasedDrawFn };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SidebarWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SidebarWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const height = ctx.max.height orelse 30;
        const width = self.width;
        const theme = self.model.current_theme;
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

        const files = self.model.recent_files.items;
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

        const turns_txt = try std.fmt.allocPrint(ctx.arena, "turns: {d}", .{self.model.request_count});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, turns_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const tokens_txt = try std.fmt.allocPrint(ctx.arena, "tokens: {d}", .{self.model.total_input_tokens + self.model.total_output_tokens});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, tokens_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const cost_txt = try std.fmt.allocPrint(ctx.arena, "cost: ${d:.4}", .{self.model.estimatedCostUsd()});
        children[child_idx] = .{
            .origin = .{ .row = row, .col = 1 },
            .surface = try self.buildText(ctx, cost_txt, self.width - 2, .{ .fg = theme.dimmed }),
        };
        child_idx += 1;
        row += 1;

        const time_txt = try std.fmt.allocPrint(ctx.arena, "{d}m{d}s", .{ self.model.sessionMinutes(), self.model.sessionSecondsPart() });
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

        if (self.model.workers.items.len == 0) {
            children[child_idx] = .{
                .origin = .{ .row = row, .col = 1 },
                .surface = try self.buildText(ctx, "(none)", self.width - 2, .{ .fg = theme.dimmed }),
            };
            child_idx += 1;
            row += 1;
        } else {
            var idx: usize = 0;
            for (self.model.workers.items) |w_item| {
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
            if (self.model.workers.items.len > 3) {
                const overflow_txt = try std.fmt.allocPrint(ctx.arena, "+{d} more", .{self.model.workers.items.len - 3});
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
            .surface = try self.buildText(ctx, self.model.current_theme.name, self.width - 2, .{ .fg = theme.accent }),
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

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = theme.header_bg } });
        drawBorder(&surface, .{ .fg = theme.border });

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

const InputWidget = struct {
    prompt: []const u8,
    field: *vxfw.TextField,
    theme: *const theme_mod.Theme,

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

const Command = struct {
    name: []const u8,
    description: []const u8,
    shortcut: []const u8,
};

const palette_command_data = [_]Command{
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
};

const CommandRowWidget = struct {
    command: Command,
    selected: bool,
    theme: *const theme_mod.Theme,

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

const SessionListRowWidget = struct {
    session: *const session_mod.Session,
    selected: bool,
    theme: *const theme_mod.Theme,

    fn widget(self: *const SessionListRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SessionListRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SessionListRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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

const SessionListWidget = struct {
    sessions: []const session_mod.Session,
    selected: usize,
    theme: *const theme_mod.Theme,

    fn widget(self: *const SessionListWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SessionListWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const SessionListWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
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

const ResumePromptWidget = struct {
    session: *const session_mod.Session,
    theme: *const theme_mod.Theme,

    fn widget(self: *const ResumePromptWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ResumePromptWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const ResumePromptWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
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
            .{ .width = inner_width, .height = null },
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

const CommandPaletteWidget = struct {
    field: *vxfw.TextField,
    commands: []const Command,
    filter: []const u8,
    selected: usize,
    theme: *const theme_mod.Theme,

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

        const input_widget = InputWidget{ .prompt = "Filter: ", .field = self.field, .theme = self.theme };
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

const PermissionDialogWidget = struct {
    model: *const Model,

    fn widget(self: *const PermissionDialogWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const PermissionDialogWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const PermissionDialogWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const pending = self.model.pending_permission orelse {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        };

        const max = ctx.max.size();
        var width: u16 = @min(max.width -| 4, @as(u16, 84));
        if (width < 36) width = @min(max.width, @as(u16, 36));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        const title = vxfw.Text{
            .text = "Tool permission required",
            .style = .{ .fg = self.model.current_theme.header_fg, .bold = true },
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
            .style = .{ .fg = self.model.current_theme.tool_pending, .bold = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const tool_surface = try tool_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = null },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 3, .col = 2 }, .surface = tool_surface });

        const args_text = vxfw.Text{
            .text = pending.arguments,
            .style = .{ .fg = self.model.current_theme.dimmed, .dim = true },
            .softwrap = true,
            .width_basis = .parent,
        };
        const args_surface = try args_text.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{ .width = inner_width, .height = null },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(4 + tool_surface.size.height), .col = 2 }, .surface = args_surface });

        const footer_line = "[y] yes   [n] no   [a] always";
        const footer = vxfw.Text{
            .text = footer_line,
            .style = .{ .fg = self.model.current_theme.tool_success, .bold = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const footer_row: u16 = @intCast(5 + tool_surface.size.height + args_surface.size.height);
        const footer_surface = try footer.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = footer_row, .col = 2 }, .surface = footer_surface });

        const height: u16 = footer_row + 2;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = self.model.current_theme.code_bg } });
        drawBorder(&surface, .{ .fg = self.model.current_theme.tool_pending });

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
    effective_system_prompt: ?[]const u8,
    codebase_context: ?[]const u8,
    context_file_count: u32,
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
    fallback_chain: fallback_mod.FallbackChain,
    fallback_providers: std.ArrayList(FallbackProvider),
    active_provider_index: usize,
    max_iterations: u32,
    permission_mode: PermissionMode,
    pending_permission: ?ToolPermission,
    always_allow_tools: std.ArrayList([]const u8),
    permission_mutex: std.Thread.Mutex,
    permission_condition: std.Thread.Condition,
    permission_decision: ?PermissionDecision,
    status_message: []const u8,
    current_theme: *const theme_mod.Theme,
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
    session_dir: []const u8,
    current_session: ?session_mod.Session,
    session_path: []const u8,
    show_session_list: bool,
    session_list: []session_mod.Session,
    session_list_selected: usize,
    resume_prompt_session: ?session_mod.Session,
    resume_prompt_path: ?[]const u8,
    sidebar_visible: bool = false,
    workers: std.ArrayList(WorkerItem),
    next_worker_id: u32 = 0,

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
            .effective_system_prompt = null,
            .codebase_context = null,
            .context_file_count = 0,
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
            .fallback_chain = fallback_mod.FallbackChain.init(allocator),
            .fallback_providers = std.ArrayList(FallbackProvider).empty,
            .active_provider_index = 0,
            .max_iterations = 10,
            .permission_mode = .default,
            .pending_permission = null,
            .always_allow_tools = std.ArrayList([]const u8).empty,
            .permission_mutex = .{},
            .permission_condition = .{},
            .permission_decision = null,
            .status_message = "",
            .current_theme = theme_mod.defaultTheme(),
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
            .session_dir = try session_mod.defaultSessionDir(allocator),
            .current_session = null,
            .session_path = "",
            .show_session_list = false,
            .session_list = &.{},
            .session_list_selected = 0,
            .resume_prompt_session = null,
            .resume_prompt_path = null,
            .sidebar_visible = false,
            .workers = std.ArrayList(WorkerItem).empty,
        };
        errdefer model.destroy();

        model.messages = try std.ArrayList(Message).initCapacity(allocator, 8);
        model.history = try std.ArrayList(core.ChatMessage).initCapacity(allocator, 8);
        model.fallback_providers = try std.ArrayList(FallbackProvider).initCapacity(allocator, setup_provider_data.len);
        model.always_allow_tools = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        model.workers = try std.ArrayList(WorkerItem).initCapacity(allocator, 4);
        model.applyThemeStyles();
        model.input.userdata = model;
        model.input.onSubmit = onSubmit;
        model.palette_input.userdata = model;
        model.palette_input.onChange = onPaletteChange;
        model.palette_input.onSubmit = onPaletteSubmit;

        try model.registry.registerAllProviders();
        try model.buildCodebaseContext();
        try model.loadFallbackProviders();
        try std.fs.cwd().makePath(model.session_dir);
        try model.prepareStartupSessionState();
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
        self.resolvePendingPermission(.no);
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
        for (self.workers.items) |*w| {
            if (w.task.len > 0) self.allocator.free(w.task);
            if (w.result) |r| self.allocator.free(r);
            if (w.@"error") |e| self.allocator.free(e);
        }
        self.workers.deinit(self.allocator);
        if (self.client) |*client| {
            client.deinit();
        }
        self.input.deinit();
        self.palette_input.deinit();
        self.clearPaletteFilter();
        for (self.recent_files.items) |file| self.allocator.free(file);
        self.recent_files.deinit(self.allocator);
        self.fallback_chain.deinit();
        for (self.fallback_providers.items) |provider| self.freeFallbackProvider(provider);
        self.fallback_providers.deinit(self.allocator);
        if (self.pending_permission) |pending| self.freePendingPermission(pending);
        for (self.always_allow_tools.items) |tool_name| self.allocator.free(tool_name);
        self.always_allow_tools.deinit(self.allocator);
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
        if (self.effective_system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.codebase_context) |codebase_context| self.allocator.free(codebase_context);
        if (self.override_url) |override_url| self.allocator.free(override_url);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        if (self.setup_feedback.len > 0) self.allocator.free(self.setup_feedback);
        if (self.current_session) |*session| session_mod.deinitSession(self.allocator, session);
        self.clearSessionListOwned();
        if (self.resume_prompt_session) |*session| session_mod.deinitSession(self.allocator, session);
        if (self.resume_prompt_path) |path| self.allocator.free(path);
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.allocator.free(self.session_dir);
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

    fn prepareStartupSessionState(self: *Model) !void {
        const interrupted = try self.findInterruptedSessionCandidate();
        errdefer if (interrupted) |candidate| {
            var session = candidate.session;
            session_mod.deinitSession(self.allocator, &session);
            self.allocator.free(candidate.path);
        };

        try self.beginNewSessionUnlocked();
        if (interrupted) |candidate| {
            self.resume_prompt_session = candidate.session;
            self.resume_prompt_path = candidate.path;
        }
    }

    fn beginNewSessionUnlocked(self: *Model) !void {
        const now = std.time.timestamp();
        var session = session_mod.Session{
            .id = try session_mod.generateSessionId(self.allocator),
            .created_at = now,
            .updated_at = now,
            .title = try self.allocator.dupe(u8, "New session"),
            .messages = try self.allocator.alloc(session_mod.Message, 0),
            .model = try self.allocator.dupe(u8, self.model_name),
            .provider = try self.allocator.dupe(u8, self.provider_name),
            .total_tokens = 0,
            .total_cost = 0,
            .turn_count = 0,
            .duration_seconds = 0,
        };
        errdefer session_mod.deinitSession(self.allocator, &session);

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
        errdefer self.allocator.free(path);

        try session_mod.saveSession(self.allocator, self.session_dir, &session);

        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = session;
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.session_path = path;
        self.session_start = std.time.nanoTimestamp();
    }

    fn findInterruptedSessionCandidate(self: *Model) !?InterruptedSessionCandidate {
        const sessions = try session_mod.listSessions(self.allocator, self.session_dir);
        defer self.allocator.free(sessions);

        const now = std.time.timestamp();
        for (sessions, 0..) |session, index| {
            if (session.updated_at + 300 >= now) continue;
            if (!session_mod.isInterrupted(&session)) continue;

            const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
            for (sessions, 0..) |*other, other_index| {
                if (other_index == index) continue;
                session_mod.deinitSession(self.allocator, other);
            }
            return .{ .session = session, .path = path };
        }

        for (sessions) |*session| session_mod.deinitSession(self.allocator, session);
        return null;
    }

    fn clearRecentFilesUnlocked(self: *Model) void {
        for (self.recent_files.items) |file| self.allocator.free(file);
        self.recent_files.clearRetainingCapacity();
    }

    fn clearSessionListOwned(self: *Model) void {
        if (self.session_list.len == 0) {
            self.session_list = &.{};
            self.session_list_selected = 0;
            self.show_session_list = false;
            return;
        }
        for (self.session_list) |*session| session_mod.deinitSession(self.allocator, session);
        self.allocator.free(self.session_list);
        self.session_list = &.{};
        self.session_list_selected = 0;
        self.show_session_list = false;
    }

    fn clearResumePromptOwned(self: *Model) void {
        if (self.resume_prompt_session) |*session| {
            session_mod.deinitSession(self.allocator, session);
            self.resume_prompt_session = null;
        }
        if (self.resume_prompt_path) |path| {
            self.allocator.free(path);
            self.resume_prompt_path = null;
        }
    }

    fn saveSessionSnapshotUnlocked(self: *Model) !void {
        const current = self.current_session orelse return;
        var snapshot = session_mod.Session{
            .id = try self.allocator.dupe(u8, current.id),
            .created_at = current.created_at,
            .updated_at = std.time.timestamp(),
            .title = try self.allocator.dupe(u8, current.title),
            .messages = try self.buildSessionMessagesUnlocked(),
            .model = try self.allocator.dupe(u8, self.model_name),
            .provider = try self.allocator.dupe(u8, self.provider_name),
            .total_tokens = self.total_input_tokens + self.total_output_tokens,
            .total_cost = self.estimatedCostUsd(),
            .turn_count = self.request_count,
            .duration_seconds = @intCast(@min(self.sessionElapsedSeconds(), std.math.maxInt(u32))),
        };
        errdefer session_mod.deinitSession(self.allocator, &snapshot);

        try session_mod.saveSession(self.allocator, self.session_dir, &snapshot);
        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = snapshot;
    }

    fn buildSessionMessagesUnlocked(self: *Model) ![]session_mod.Message {
        const copied = try self.allocator.alloc(session_mod.Message, self.messages.items.len);
        errdefer self.allocator.free(copied);

        for (self.messages.items, 0..) |message, index| {
            copied[index] = .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = try self.allocator.dupe(u8, message.content),
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            };
        }
        return copied;
    }

    fn restoreSessionUnlocked(self: *Model, session: session_mod.Session, path: []const u8) !void {
        var owned_session = session;
        errdefer session_mod.deinitSession(self.allocator, &owned_session);

        self.clearMessagesUnlocked();
        self.clearHistoryUnlocked();
        self.clearRecentFilesUnlocked();
        self.assistant_stream_index = null;
        self.awaiting_first_token = false;
        self.request_active = false;
        self.request_done = false;

        for (owned_session.messages) |message| {
            try self.messages.append(self.allocator, .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = if (message.content) |content| try self.allocator.dupe(u8, content) else try self.allocator.dupe(u8, ""),
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            });
            try self.history.append(self.allocator, .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = if (message.content) |content| try self.allocator.dupe(u8, content) else null,
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            });
            if (message.tool_calls) |tool_calls| {
                try self.trackToolCallFilesUnlocked(tool_calls);
            }
        }

        try self.replaceOwnedString(&self.provider_name, owned_session.provider);
        try self.replaceOwnedString(&self.model_name, owned_session.model);
        self.resetFallbackProviders();
        try self.loadFallbackProviders();
        try self.refreshClientForSessionResumeUnlocked();

        self.total_input_tokens = owned_session.total_tokens;
        self.total_output_tokens = 0;
        self.request_count = owned_session.turn_count;
        self.session_start = std.time.nanoTimestamp() - (@as(i128, owned_session.duration_seconds) * std.time.ns_per_s);

        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = owned_session;
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.session_path = try self.allocator.dupe(u8, path);

        const status = try std.fmt.allocPrint(self.allocator, "Resumed session {s}", .{owned_session.id});
        defer self.allocator.free(status);
        try self.setStatusMessageUnlocked(status);
    }

    fn refreshClientForSessionResumeUnlocked(self: *Model) !void {
        var config = config_mod.Config.init(self.allocator);
        defer config.deinit();

        config.loadDefault() catch |err| switch (err) {
            error.ConfigNotFound, error.FileNotFound => {},
            else => return err,
        };

        if (config.getApiKey(self.provider_name)) |api_key| {
            try self.replaceOwnedString(&self.api_key, api_key);
        } else if (setupProviderAllowsEmptyKey(self.provider_name)) {
            try self.replaceOwnedString(&self.api_key, "");
        }

        if (self.override_url) |override_url| {
            self.allocator.free(override_url);
            self.override_url = null;
        }
        if (config.getProviderOverrideUrl(self.provider_name)) |override_url| {
            self.override_url = try self.allocator.dupe(u8, override_url);
        }

        if (self.client) |*existing_client| {
            existing_client.deinit();
            self.client = null;
        }

        const provider = self.registry.getProvider(self.provider_name) orelse {
            try self.setStatusMessageUnlocked("Resumed session provider is not registered.");
            return;
        };
        if (self.api_key.len == 0 and !provider.config.is_local) {
            try self.setStatusMessageUnlocked("Missing API key for resumed session provider.");
            return;
        }

        var client = try core.AIClient.init(self.allocator, provider, self.model_name, self.api_key);
        client.max_tokens = self.max_tokens;
        client.temperature = self.temperature;
        client.setTools(&builtin_tool_schemas);
        if (self.override_url) |value| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, value);
        }
        try self.refreshEffectiveSystemPrompt();
        if (self.effective_system_prompt) |system_prompt| {
            client.setSystemPrompt(system_prompt);
        }
        self.client = client;
    }

    fn openSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
        self.clearSessionListOwned();
        const loaded = try session_mod.listSessions(self.allocator, self.session_dir);
        if (loaded.len == 0) {
            self.allocator.free(loaded);
            self.session_list = &.{};
        } else {
            self.session_list = loaded;
        }
        self.show_session_list = true;
        self.session_list_selected = 0;
        try ctx.requestFocus(self.input.widget());
        ctx.redraw = true;
    }

    fn closeSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
        self.clearSessionListOwned();
        try ctx.requestFocus(self.input.widget());
        ctx.redraw = true;
    }

    fn moveSessionListSelection(self: *Model, delta: isize) void {
        if (self.session_list.len == 0) {
            self.session_list_selected = 0;
            return;
        }
        const current: isize = @intCast(self.session_list_selected);
        const max_index: isize = @intCast(self.session_list.len - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.session_list_selected = @intCast(next);
    }

    fn executeSessionSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.session_list.len == 0) {
            try self.closeSessionList(ctx);
            return;
        }

        const session_id = try self.allocator.dupe(u8, self.session_list[self.session_list_selected].id);
        defer self.allocator.free(session_id);
        try self.closeSessionList(ctx);
        try self.resumeSessionByIdUnlocked(session_id);
        ctx.redraw = true;
    }

    fn resumeSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
        if (self.request_active) {
            try self.addMessageUnlocked("error", "Cannot resume a session while a response is still streaming.");
            return;
        }

        try self.saveSessionSnapshotUnlocked();

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
        defer self.allocator.free(path);
        const loaded = try session_mod.loadSession(self.allocator, path);
        try self.restoreSessionUnlocked(loaded, path);
    }

    fn deleteSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
        defer self.allocator.free(path);

        const deleting_current = if (self.current_session) |session|
            std.mem.eql(u8, session.id, session_id)
        else
            false;

        try session_mod.deleteSession(self.allocator, path);
        if (deleting_current) {
            self.clearMessagesUnlocked();
            self.clearHistoryUnlocked();
            self.clearRecentFilesUnlocked();
            self.total_input_tokens = 0;
            self.total_output_tokens = 0;
            self.request_count = 0;
            self.assistant_stream_index = null;
            self.awaiting_first_token = false;
            try self.beginNewSessionUnlocked();
        }
    }

    fn handleResumePromptDecision(self: *Model, should_resume: bool) !void {
        if (!should_resume) {
            if (self.resume_prompt_path) |path| {
                session_mod.deleteSession(self.allocator, path) catch {};
            }
            self.clearResumePromptOwned();
            return;
        }

        const prompt_session = self.resume_prompt_session orelse return;
        const prompt_path = self.resume_prompt_path orelse return;

        if (self.session_path.len > 0) {
            session_mod.deleteSession(self.allocator, self.session_path) catch {};
            self.allocator.free(self.session_path);
            self.session_path = "";
        }
        if (self.current_session) |*existing| {
            session_mod.deinitSession(self.allocator, existing);
            self.current_session = null;
        }

        self.resume_prompt_session = null;
        self.resume_prompt_path = null;
        try self.restoreSessionUnlocked(prompt_session, prompt_path);
        self.allocator.free(prompt_path);
    }

    fn initializeClient(self: *Model) !void {
        return self.initializeClientFor(self.provider_name, self.model_name, self.api_key, self.override_url);
    }

    fn initializeClientFor(self: *Model, provider_name: []const u8, model_name: []const u8, api_key: []const u8, override_url: ?[]const u8) !void {
        if (provider_name.len == 0) {
            try self.addMessageUnlocked("error", "No provider configured. Set one in ~/.crushcode/config.toml or use a profile.");
            return;
        }

        const provider = self.registry.getProvider(provider_name) orelse {
            const text = try std.fmt.allocPrint(self.allocator, "Provider '{s}' is not registered. Run 'crushcode list --providers' to see available providers.", .{provider_name});
            defer self.allocator.free(text);
            try self.addMessageUnlocked("error", text);
            return;
        };

        if (api_key.len == 0 and !provider.config.is_local) {
            try self.addMessageUnlocked("error", "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml");
            return;
        }

        if (self.client) |*existing_client| {
            existing_client.deinit();
            self.client = null;
        }

        var client = try core.AIClient.init(self.allocator, provider, model_name, api_key);
        client.max_tokens = self.max_tokens;
        client.temperature = self.temperature;
        client.setTools(&builtin_tool_schemas);
        if (override_url) |value| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, value);
        }
        try self.refreshEffectiveSystemPrompt();
        if (self.effective_system_prompt) |system_prompt| {
            client.setSystemPrompt(system_prompt);
        }
        self.client = client;
    }

    fn buildCodebaseContext(self: *Model) !void {
        var kg = graph_mod.KnowledgeGraph.init(self.allocator);
        defer kg.deinit();

        var indexed_count: u32 = 0;
        for (context_source_files) |file_path| {
            kg.indexFile(file_path) catch continue;
            indexed_count += 1;
        }
        kg.detectCommunities() catch {};

        if (indexed_count == 0) return;
        self.codebase_context = try kg.toCompressedContext(self.allocator);
        self.context_file_count = indexed_count;
    }

    fn refreshEffectiveSystemPrompt(self: *Model) !void {
        if (self.effective_system_prompt) |existing| {
            self.allocator.free(existing);
            self.effective_system_prompt = null;
        }

        const base_prompt = if (self.system_prompt) |prompt|
            if (prompt.len > 0) prompt else "You are a helpful AI coding assistant with access to the user's codebase."
        else
            "You are a helpful AI coding assistant with access to the user's codebase.";

        if (self.codebase_context) |compressed_context| {
            self.effective_system_prompt = try std.fmt.allocPrint(
                self.allocator,
                \\{s}
                \\
                \\## Codebase Context
                \\{s}
                \\
                \\## Available Tools
                \\- read_file(path)
                \\- shell(command)
                \\- write_file(path, content)
                \\- glob(pattern)
                \\- grep(pattern)
                \\- edit(file_path, old_string, new_string)
            ,
                .{ base_prompt, compressed_context },
            );
            return;
        }

        self.effective_system_prompt = try self.allocator.dupe(u8, base_prompt);
    }

    fn loadFallbackProviders(self: *Model) !void {
        var config = config_mod.Config.init(self.allocator);
        defer config.deinit();

        config.loadDefault() catch |err| switch (err) {
            error.ConfigNotFound, error.FileNotFound => {},
            else => return err,
        };

        try self.appendFallbackProvider(self.provider_name, self.api_key, self.model_name, self.override_url);

        for (setup_provider_data) |provider_name| {
            if (std.mem.eql(u8, provider_name, self.provider_name)) continue;
            const provider = self.registry.getProvider(provider_name) orelse continue;
            const api_key = config.getApiKey(provider_name) orelse "";
            if (api_key.len == 0 and !provider.config.is_local) continue;
            const model_name = self.fallbackModelForProvider(provider_name);
            try self.appendFallbackProvider(provider_name, api_key, model_name, config.getProviderOverrideUrl(provider_name));
        }

        self.active_provider_index = self.findFallbackProviderIndex(self.provider_name) orelse 0;
    }

    fn resetFallbackProviders(self: *Model) void {
        self.fallback_chain.deinit();
        self.fallback_chain = fallback_mod.FallbackChain.init(self.allocator);
        for (self.fallback_providers.items) |provider| self.freeFallbackProvider(provider);
        self.fallback_providers.clearRetainingCapacity();
        self.active_provider_index = 0;
    }

    fn appendFallbackProvider(self: *Model, provider_name: []const u8, api_key: []const u8, model_name: []const u8, override_url: ?[]const u8) !void {
        if (self.findFallbackProviderIndex(provider_name) != null) return;

        try self.fallback_chain.addEntry(provider_name, model_name);
        try self.fallback_providers.append(self.allocator, .{
            .provider_name = try self.allocator.dupe(u8, provider_name),
            .api_key = try self.allocator.dupe(u8, api_key),
            .model_name = try self.allocator.dupe(u8, model_name),
            .override_url = if (override_url) |url| try self.allocator.dupe(u8, url) else null,
        });
    }

    fn fallbackModelForProvider(self: *const Model, provider_name: []const u8) []const u8 {
        if (std.mem.eql(u8, provider_name, self.provider_name)) return self.model_name;
        if (std.mem.indexOfScalar(u8, self.model_name, '/') == null) return self.model_name;
        return setupDefaultModel(provider_name);
    }

    fn findFallbackProviderIndex(self: *const Model, provider_name: []const u8) ?usize {
        for (self.fallback_providers.items, 0..) |provider, index| {
            if (std.mem.eql(u8, provider.provider_name, provider_name)) return index;
        }
        return null;
    }

    fn freeFallbackProvider(self: *Model, provider: FallbackProvider) void {
        self.allocator.free(provider.provider_name);
        self.allocator.free(provider.api_key);
        self.allocator.free(provider.model_name);
        if (provider.override_url) |override_url| self.allocator.free(override_url);
    }

    fn freePendingPermission(self: *Model, pending: ToolPermission) void {
        self.allocator.free(pending.tool_name);
        self.allocator.free(pending.arguments);
    }

    fn setStatusMessage(self: *Model, text: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.setStatusMessageUnlocked(text);
    }

    fn setStatusMessageUnlocked(self: *Model, text: []const u8) !void {
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.status_message = if (text.len == 0) "" else try self.allocator.dupe(u8, text);
    }

    fn clearStatusMessage(self: *Model) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.status_message = "";
    }

    fn applyThemeStyles(self: *Model) void {
        self.input.style = .{ .fg = self.current_theme.header_fg };
        self.palette_input.style = .{ .fg = self.current_theme.header_fg };
        self.scroll_bars = .{
            .scroll_view = self.scroll_view,
            .draw_horizontal_scrollbar = false,
            .draw_vertical_scrollbar = true,
            .vertical_scrollbar_thumb = .{ .char = .{ .grapheme = "▐", .width = 1 }, .style = .{ .fg = self.current_theme.dimmed, .dim = true } },
            .vertical_scrollbar_hover_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = self.current_theme.border } },
            .vertical_scrollbar_drag_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = self.current_theme.accent } },
        };
    }

    fn resolvePendingPermission(self: *Model, decision: PermissionDecision) void {
        self.permission_mutex.lock();
        self.permission_decision = decision;
        self.permission_condition.signal();
        self.permission_mutex.unlock();
    }

    fn needsPermission(self: *const Model, tool_name: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, tool_name, "shell")) return true;
        if (std.mem.eql(u8, tool_name, "write_file")) return true;
        if (std.mem.eql(u8, tool_name, "edit")) return true;
        return false;
    }

    fn isAlwaysAllowed(self: *const Model, tool_name: []const u8) bool {
        for (self.always_allow_tools.items) |allowed_tool| {
            if (std.mem.eql(u8, allowed_tool, tool_name)) return true;
        }
        return false;
    }

    fn requestToolPermission(self: *Model, tool_name: []const u8, arguments: []const u8) !bool {
        if (self.permission_mode == .auto or !self.needsPermission(tool_name) or self.isAlwaysAllowed(tool_name)) {
            return true;
        }

        self.permission_mutex.lock();
        defer self.permission_mutex.unlock();
        self.permission_decision = null;

        self.lock.lock();
        if (self.pending_permission) |pending| self.freePendingPermission(pending);
        self.pending_permission = .{
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .arguments = try self.allocator.dupe(u8, arguments),
        };
        self.lock.unlock();

        while (self.permission_decision == null) {
            self.permission_condition.wait(&self.permission_mutex);
        }

        const decision = self.permission_decision.?;
        self.permission_decision = null;

        self.lock.lock();
        defer self.lock.unlock();
        if (decision == .always and !self.isAlwaysAllowed(tool_name)) {
            self.always_allow_tools.append(self.allocator, try self.allocator.dupe(u8, tool_name)) catch {};
        }
        if (self.pending_permission) |pending| {
            self.freePendingPermission(pending);
            self.pending_permission = null;
        }
        return decision != .no;
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
                if (self.resume_prompt_session != null) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        try self.handleResumePromptDecision(true);
                    } else if (key.matches('n', .{}) or key.matches('N', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        try self.handleResumePromptDecision(false);
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (self.pending_permission != null) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        self.resolvePendingPermission(.yes);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('n', .{}) or key.matches('N', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        self.resolvePendingPermission(.no);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('a', .{}) or key.matches('A', .{})) {
                        self.resolvePendingPermission(.always);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    ctx.consumeEvent();
                    return;
                }

                if (self.show_session_list) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        try self.closeSessionList(ctx);
                    } else if (key.matches(vaxis.Key.up, .{})) {
                        self.moveSessionListSelection(-1);
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        self.moveSessionListSelection(1);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try self.executeSessionSelection(ctx);
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    self.resolvePendingPermission(.no);
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

                if (key.matches('b', .{ .ctrl = true })) {
                    self.sidebar_visible = !self.sidebar_visible;
                    ctx.consumeEvent();
                    ctx.redraw = true;
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
        const sidebar_width: u16 = 30;
        const main_width: u16 = if (self.sidebar_visible) max.width -| sidebar_width else max.width;
        const header_height: u16 = 2;
        const files_height: u16 = if (self.recent_files.items.len > 0) 1 else 0;
        const status_height: u16 = 1;
        const input_height: u16 = 1;
        const body_height = max.height -| (header_height + files_height + status_height + input_height);

        const full_title = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | setup", .{app_version})
        else
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | {s}/{s} | thinking:{s} | ctx: {d} files indexed | usage:{d}%", .{
                app_version,
                self.provider_name,
                self.model_name,
                if (self.thinking) "on" else "off",
                self.context_file_count,
                self.contextPercent(),
            });

        const header = HeaderWidget{ .title = full_title, .theme = self.current_theme };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = main_width, .height = header_height },
            .{ .width = main_width, .height = header_height },
        ));

        const body_surface = blk: {
            if (self.setup_phase != 0) {
                const wizard = SetupWizardWidget{ .model = self };
                break :blk try wizard.draw(ctx.withConstraints(
                    .{ .width = main_width, .height = body_height },
                    .{ .width = main_width, .height = body_height },
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
                        const separator = SeparatorWidget{ .theme = self.current_theme };
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
                    .{ .width = main_width, .height = body_height },
                    .{ .width = main_width, .height = body_height },
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
        else if (self.status_message.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s} | Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s", .{
                self.status_message,
                self.total_input_tokens,
                self.total_output_tokens,
                self.estimatedCostUsd(),
                self.request_count,
                self.sessionMinutes(),
                self.sessionSecondsPart(),
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
            .style = .{ .fg = self.current_theme.status_fg, .bg = self.current_theme.status_bg, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        const status_surface = try status_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = status_height },
            .{ .width = max.width, .height = status_height },
        ));

        const input_widget = InputWidget{ .prompt = self.currentInputPrompt(), .field = &self.input, .theme = self.current_theme };
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

        if (self.sidebar_visible) {
            const sidebar = SidebarWidget{ .model = self, .width = sidebar_width };
            const sidebar_height: u16 = header_height + body_height;
            const sidebar_surface = try sidebar.draw(ctx.withConstraints(
                .{ .width = sidebar_width, .height = sidebar_height },
                .{ .width = sidebar_width, .height = sidebar_height },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(main_width) }, .surface = sidebar_surface });
        }

        if (self.show_palette) {
            const palette = CommandPaletteWidget{
                .field = &self.palette_input,
                .commands = self.palette_commands,
                .filter = self.palette_filter,
                .selected = self.palette_selected,
                .theme = self.current_theme,
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

        if (self.pending_permission != null) {
            const permission_dialog = PermissionDialogWidget{ .model = self };
            const permission_surface = try permission_dialog.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| permission_surface.size.height) / 2),
                    .col = @intCast((max.width -| permission_surface.size.width) / 2),
                },
                .surface = permission_surface,
            });
        }

        if (self.show_session_list) {
            const session_list = SessionListWidget{
                .sessions = self.session_list,
                .selected = self.session_list_selected,
                .theme = self.current_theme,
            };
            const session_surface = try session_list.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| session_surface.size.height) / 2),
                    .col = @intCast((max.width -| session_surface.size.width) / 2),
                },
                .surface = session_surface,
            });
        }

        if (self.resume_prompt_session) |*prompt_session| {
            const prompt = ResumePromptWidget{ .session = prompt_session, .theme = self.current_theme };
            const prompt_surface = try prompt.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| prompt_surface.size.height) / 2),
                    .col = @intCast((max.width -| prompt_surface.size.width) / 2),
                },
                .surface = prompt_surface,
            });
        }

        if (self.recent_files.items.len > 0) {
            const visible_files = recentFilesVisibleCount(self.recent_files.items);
            const files_widget = FilesWidget{ .files = self.recent_files.items[0..visible_files], .theme = self.current_theme };
            const files_surface = try files_widget.draw(ctx.withConstraints(
                .{ .width = main_width, .height = 1 },
                .{ .width = main_width, .height = 1 },
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
            self.resolvePendingPermission(.no);
            self.should_quit = true;
            ctx.quit = true;
            return;
        }
        if (isSupportedSlashCommand(trimmed)) {
            try self.executePaletteCommand(trimmed, ctx);
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
        try self.saveSessionSnapshotUnlocked();

        self.resetInputField();
        self.worker = try std.Thread.spawn(.{}, requestThreadMain, .{self});
        ctx.redraw = true;
    }

    fn resetInputField(self: *Model) void {
        self.input.deinit();
        self.input = vxfw.TextField.init(self.allocator);
        self.input.style = .{ .fg = self.current_theme.header_fg };
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
                self.resetFallbackProviders();
                try self.loadFallbackProviders();
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
        self.palette_input.style = .{ .fg = self.current_theme.header_fg };
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

        if (try self.handleThemeCommandUnlocked(name)) {
            ctx.redraw = true;
            return;
        }

        if (std.mem.eql(u8, name, "/clear")) {
            if (self.request_active) {
                try self.addMessageUnlocked("error", "Cannot clear the chat while a response is still streaming.");
            } else {
                try self.saveSessionSnapshotUnlocked();
                self.clearMessagesUnlocked();
                self.clearHistoryUnlocked();
                self.clearRecentFilesUnlocked();
                self.total_input_tokens = 0;
                self.total_output_tokens = 0;
                self.request_count = 0;
                self.assistant_stream_index = null;
                self.awaiting_first_token = false;
                try self.beginNewSessionUnlocked();
            }
        } else if (std.mem.eql(u8, name, "/sessions") or std.mem.eql(u8, name, "/ls")) {
            try self.openSessionList(ctx);
            return;
        } else if (std.mem.startsWith(u8, name, "/resume")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try self.addMessageUnlocked("assistant", "Usage: /resume <id>");
            } else {
                try self.resumeSessionByIdUnlocked(session_id);
            }
        } else if (std.mem.startsWith(u8, name, "/delete")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try self.addMessageUnlocked("assistant", "Usage: /delete <id>");
            } else {
                try self.deleteSessionByIdUnlocked(session_id);
                const text = try std.fmt.allocPrint(self.allocator, "Deleted session {s}", .{session_id});
                defer self.allocator.free(text);
                try self.addMessageUnlocked("assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/thinking")) {
            self.thinking = !self.thinking;
            const text = if (self.thinking) "Thinking enabled." else "Thinking disabled.";
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/help")) {
            try self.addMessageUnlocked("assistant", "/clear — Clear conversation history\n/sessions — Browse saved sessions\n/ls — Alias for /sessions\n/resume <id> — Resume a saved session\n/delete <id> — Delete a saved session\n/exit — Exit crushcode\n/model — Show current model\n/thinking — Toggle thinking mode\n/compact — Compact conversation context\n/theme dark — Switch to dark theme\n/theme light — Switch to light theme\n/theme mono — Switch to monochrome theme\n/workers — List active workers\n/kill <id> — Cancel a worker\n/help — Show available commands");
        } else if (std.mem.eql(u8, name, "/compact")) {
            try self.addMessageUnlocked("assistant", "/compact is not yet implemented.");
        } else if (std.mem.eql(u8, name, "/model")) {
            const text = try std.fmt.allocPrint(self.allocator, "Current model: {s}/{s}", .{ self.provider_name, self.model_name });
            defer self.allocator.free(text);
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/workers")) {
            if (self.workers.items.len == 0) {
                try self.addMessageUnlocked("assistant", "No active workers.");
            } else {
                var buf: [1024]u8 = undefined;
                var offset: usize = 0;
                const head_result = std.fmt.bufPrint(&buf, "Active workers:\n", .{});
                if (head_result) |written| {
                    offset = written.len;
                } else |_| {}
                for (self.workers.items) |w| {
                    const status_str = switch (w.status) {
                        .pending => "pending",
                        .running => "running",
                        .done => "done",
                        .@"error" => "error",
                        .cancelled => "cancelled",
                    };
                    const result_preview = if (w.result) |r| if (r.len > 30) r[0..30] else r else "(none)";
                    const line_result = std.fmt.bufPrint(buf[offset..], "#{d} [{s}] {s} → {s}\n", .{ w.id, status_str, w.task, result_preview });
                    if (line_result) |written| {
                        offset += written.len;
                    } else |_| {}
                }
                const text = try self.allocator.dupe(u8, &buf);
                try self.addMessageUnlocked("assistant", text);
            }
        } else if (std.mem.startsWith(u8, name, "/kill ")) {
            const id_str = name[6..];
            const id = std.fmt.parseInt(u32, id_str, 10) catch {
                try self.addMessageUnlocked("assistant", "Invalid worker ID. Usage: /kill <id>");
                ctx.redraw = true;
                return;
            };
            var found = false;
            for (self.workers.items) |*w| {
                if (w.id == id) {
                    w.status = .cancelled;
                    const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} cancelled.", .{id});
                    try self.addMessageUnlocked("assistant", text);
                    found = true;
                    break;
                }
            }
            if (!found) {
                const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} not found.", .{id});
                try self.addMessageUnlocked("assistant", text);
            }
        }

        ctx.redraw = true;
    }

    fn handleThemeCommandUnlocked(self: *Model, name: []const u8) !bool {
        if (!std.mem.startsWith(u8, name, "/theme")) return false;

        const rest = std.mem.trim(u8, name[6..], " \t\r\n");
        if (rest.len == 0) {
            try self.addMessageUnlocked("system", "Available themes: dark, light, mono");
            return true;
        }

        if (theme_mod.getTheme(rest)) |theme| {
            self.current_theme = theme;
            self.applyThemeStyles();
            const text = try std.fmt.allocPrint(self.allocator, "Theme switched to {s}.", .{theme.name});
            defer self.allocator.free(text);
            try self.addMessageUnlocked("system", text);
            return true;
        }

        const text = try std.fmt.allocPrint(self.allocator, "Unknown theme: {s}", .{rest});
        defer self.allocator.free(text);
        try self.addMessageUnlocked("system", text);
        return true;
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
        var total_input_tokens: u64 = 0;
        var total_output_tokens: u64 = 0;
        var iteration: u32 = 0;

        while (iteration < self.max_iterations) : (iteration += 1) {
            total_input_tokens += estimateMessageTokens(self.history.items);

            var response = try self.sendChatStreamingWithFallback();
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

            total_output_tokens += estimateResponseOutputTokens(content, tool_calls);
            try self.applyAssistantResponse(content, tool_calls);

            if (tool_calls) |calls| {
                try self.executeToolCalls(calls);
                if (iteration + 1 >= self.max_iterations) {
                    self.finishRequestWithErrorText("Stopped after reaching max tool iterations.");
                    return;
                }
                try self.startNextAssistantPlaceholder();
                continue;
            }

            self.finishRequestSuccess(total_input_tokens, total_output_tokens);
            return;
        }

        self.finishRequestWithErrorText("Stopped after reaching max tool iterations.");
    }

    fn activateFallbackProvider(self: *Model, index: usize) !void {
        const provider = self.fallback_providers.items[index];

        self.lock.lock();
        defer self.lock.unlock();
        try self.replaceOwnedString(&self.provider_name, provider.provider_name);
        try self.replaceOwnedString(&self.model_name, provider.model_name);
        try self.replaceOwnedString(&self.api_key, provider.api_key);
        if (self.override_url) |current_override_url| self.allocator.free(current_override_url);
        self.override_url = if (provider.override_url) |override_url| try self.allocator.dupe(u8, override_url) else null;
        self.active_provider_index = index;
        try self.initializeClientFor(self.provider_name, self.model_name, self.api_key, self.override_url);
    }

    fn sendChatStreamingWithFallback(self: *Model) !core.ChatResponse {
        var index = self.active_provider_index;
        while (index < self.fallback_providers.items.len) : (index += 1) {
            try self.activateFallbackProvider(index);
            const response = self.client.?.sendChatStreaming(self.history.items, streamCallback) catch |err| {
                if (!isRetryableProviderError(err) or index + 1 >= self.fallback_providers.items.len) {
                    return err;
                }
                const next_provider = self.fallback_providers.items[index + 1];
                const status_text = try std.fmt.allocPrint(self.allocator, "⚠ {s} failed, trying {s}/{s}...", .{
                    self.fallback_providers.items[index].provider_name,
                    next_provider.provider_name,
                    next_provider.model_name,
                });
                defer self.allocator.free(status_text);
                try self.setStatusMessage(status_text);
                try self.resetActiveAssistantPlaceholderForRetry();
                continue;
            };
            self.clearStatusMessage();
            return response;
        }
        return error.NetworkError;
    }

    fn resetActiveAssistantPlaceholderForRetry(self: *Model) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.assistant_stream_index) |index| {
            try self.replaceMessageUnlocked(index, "assistant", "Thinking...", null, null);
        }
        self.awaiting_first_token = true;
    }

    fn applyAssistantResponse(self: *Model, content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (tool_calls) |_| {
            try self.trackToolCallFilesUnlocked(tool_calls);
        }

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
            } else {
                try self.addMessageWithToolsUnlocked("assistant", content, null, tool_calls);
                self.assistant_stream_index = self.messages.items.len - 1;
            }
            self.awaiting_first_token = false;
        } else if (self.assistant_stream_index) |index| {
            try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
        }

        try self.appendHistoryMessageWithToolsUnlocked("assistant", content, null, tool_calls);
        try self.saveSessionSnapshotUnlocked();
    }

    fn executeToolCalls(self: *Model, tool_calls: []const core.client.ToolCallInfo) !void {
        for (tool_calls) |tool_call| {
            const allowed = try self.requestToolPermission(tool_call.name, tool_call.arguments);
            const result_text = if (!allowed)
                try self.allocator.dupe(u8, "error: tool execution denied by user")
            else
                executeInlineTool(self.allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)});
            defer self.allocator.free(result_text);

            self.lock.lock();
            errdefer self.lock.unlock();
            try self.addMessageWithToolsUnlocked("tool", result_text, tool_call.id, null);
            try self.appendHistoryMessageWithToolsUnlocked("tool", result_text, tool_call.id, null);
            try self.saveSessionSnapshotUnlocked();
            self.lock.unlock();
        }
    }

    fn startNextAssistantPlaceholder(self: *Model) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.addMessageUnlocked("assistant", "Thinking...");
        self.assistant_stream_index = self.messages.items.len - 1;
        self.awaiting_first_token = true;
        try self.saveSessionSnapshotUnlocked();
    }

    fn finishRequestSuccess(self: *Model, input_tokens: u64, output_tokens: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.total_input_tokens += input_tokens;
        self.total_output_tokens += output_tokens;
        self.request_count += 1;
        self.request_active = false;
        self.request_done = true;
        self.saveSessionSnapshotUnlocked() catch {};
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
        self.saveSessionSnapshotUnlocked() catch {};
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

    fn estimatedCostUsd(self: *const Model) f64 {
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

fn toolCallStatusStyle(theme: *const theme_mod.Theme, status: ToolCallStatus) vaxis.Style {
    return switch (status) {
        .pending => .{ .fg = theme.tool_pending, .bold = true },
        .success => .{ .fg = theme.tool_success, .bold = true },
        .failed => .{ .fg = theme.tool_error, .bold = true },
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

fn messageRoleStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.assistant_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .bold = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .bold = true };
    }
    return .{ .fg = theme.dimmed, .bold = true };
}

fn messageBodyStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.header_fg };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .dim = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .dim = true };
    }
    return .{ .fg = theme.dimmed, .dim = true };
}

fn messageRoleLabel(theme: *const theme_mod.Theme, role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return theme.user_label;
    if (std.mem.eql(u8, role, "assistant")) return theme.assistant_label;
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return role;
}

fn isSupportedSlashCommand(value: []const u8) bool {
    return std.mem.eql(u8, value, "/clear") or
        std.mem.eql(u8, value, "/sessions") or
        std.mem.eql(u8, value, "/ls") or
        std.mem.eql(u8, value, "/model") or
        std.mem.eql(u8, value, "/thinking") or
        std.mem.eql(u8, value, "/compact") or
        std.mem.eql(u8, value, "/help") or
        std.mem.startsWith(u8, value, "/resume") or
        std.mem.startsWith(u8, value, "/delete") or
        std.mem.startsWith(u8, value, "/theme");
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
                if (isDiffRenderableTool(tool_call.name) and extractToolDiffText(output_text) != null) {
                    total += @as(u32, @intCast(@min(std.mem.count(u8, output_text, "\n") + 4, tool_diff_max_lines + 4)));
                } else if (output_text.len > 0) {
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

fn formatSessionTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const seconds: u64 = @intCast(@max(timestamp, 0));
    const day_seconds: u64 = 24 * 60 * 60;
    const days = @divFloor(seconds, day_seconds);
    const remainder = @mod(seconds, day_seconds);
    const hours = @divFloor(remainder, 60 * 60);
    const minutes = @divFloor(@mod(remainder, 60 * 60), 60);
    return std.fmt.allocPrint(allocator, "day {d} {d:0>2}:{d:0>2}", .{ days, hours, minutes });
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

fn isDiffRenderableTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit");
}

fn extractToolDiffText(output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "```diff")) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "@@")) return trimmed;
    return null;
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

fn resolvedPricingModel(model: *const Model) []const u8 {
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

fn estimateResponseOutputTokens(content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) u64 {
    var total = estimateTextTokens(content);
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            total += estimateTextTokens(tool_call.name);
            total += estimateTextTokens(tool_call.arguments);
        }
    }
    return total;
}

fn isRetryableProviderError(err: anyerror) bool {
    return switch (err) {
        error.NetworkError, error.TimeoutError, error.ServerError, error.RetryExhausted => true,
        else => false,
    };
}

fn executeInlineTool(allocator: std.mem.Allocator, tool_call: core.client.ToolCallInfo) ![]const u8 {
    if (std.mem.eql(u8, tool_call.name, "read_file")) return executeReadFileToolInline(allocator, tool_call.arguments);
    if (std.mem.eql(u8, tool_call.name, "shell")) return executeShellToolInline(allocator, tool_call.arguments);
    if (std.mem.eql(u8, tool_call.name, "write_file")) return executeWriteFileToolInline(allocator, tool_call.arguments);
    if (std.mem.eql(u8, tool_call.name, "glob")) return executeGlobToolInline(allocator, tool_call.arguments);
    if (std.mem.eql(u8, tool_call.name, "grep")) return executeGrepToolInline(allocator, tool_call.arguments);
    if (std.mem.eql(u8, tool_call.name, "edit")) return executeEditToolInline(allocator, tool_call.arguments);
    return std.fmt.allocPrint(allocator, "error: unsupported tool '{s}'", .{tool_call.name});
}

fn executeReadFileToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct { path: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const content = try std.fs.cwd().readFileAlloc(allocator, parsed.value.path, 1024 * 1024);
    defer allocator.free(content);
    return std.fmt.allocPrint(allocator, "=== {s} ===\n{s}", .{ parsed.value.path, content });
}

fn executeShellToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct { command: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", parsed.value.command },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .Exited => |code| code,
        .Signal => |signal| @as(i32, @intCast(signal)),
        else => 1,
    };
    return std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, result.stdout, result.stderr });
}

fn executeWriteFileToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct { path: []const u8, content: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    try file.writeAll(parsed.value.content);
    return std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ parsed.value.content.len, parsed.value.path });
}

fn executeGlobToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct { pattern: []const u8, max_results: ?usize = 50 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var buffer = std.ArrayList(u8).empty;
    var count: usize = 0;
    const max_results = parsed.value.max_results orelse 50;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!globMatch(parsed.value.pattern, entry.path)) continue;
        if (count > 0) try buffer.append(allocator, '\n');
        try buffer.appendSlice(allocator, entry.path);
        count += 1;
        if (count >= max_results) break;
    }
    return std.fmt.allocPrint(allocator, "Found {d} files matching '{s}':\n{s}", .{ count, parsed.value.pattern, buffer.items });
}

fn executeGrepToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        include: ?[]const u8 = null,
        max_results: ?usize = 50,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const search_path = parsed.value.path orelse ".";
    const max_results = parsed.value.max_results orelse 50;
    var matches = std.ArrayList(u8).empty;
    var match_count: usize = 0;

    const stat = std.fs.cwd().statFile(search_path) catch null;
    if (stat != null) {
        try appendGrepMatchesForFile(allocator, &matches, search_path, parsed.value.pattern, &match_count, max_results);
    } else {
        var dir = try std.fs.cwd().openDir(search_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (parsed.value.include) |include_pattern| {
                if (!globMatch(include_pattern, entry.path)) continue;
            }
            const full_path = if (std.mem.eql(u8, search_path, "."))
                try allocator.dupe(u8, entry.path)
            else
                try std.fs.path.join(allocator, &.{ search_path, entry.path });
            defer allocator.free(full_path);
            try appendGrepMatchesForFile(allocator, &matches, full_path, parsed.value.pattern, &match_count, max_results);
            if (match_count >= max_results) break;
        }
    }

    return std.fmt.allocPrint(allocator, "Found {d} matches for '{s}':\n{s}", .{ match_count, parsed.value.pattern, matches.items });
}

fn appendGrepMatchesForFile(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(u8),
    file_path: []const u8,
    pattern: []const u8,
    match_count: *usize,
    max_results: usize,
) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 512 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, pattern) == null) continue;
        if (matches.items.len > 0) try matches.append(allocator, '\n');
        try matches.writer(allocator).print("{s}:{d}: {s}", .{ file_path, line_no, line });
        match_count.* += 1;
        if (match_count.* >= max_results) return;
    }
}

fn executeEditToolInline(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    const Args = struct {
        file_path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const content = try std.fs.cwd().readFileAlloc(allocator, parsed.value.file_path, 1024 * 1024);
    defer allocator.free(content);

    const match_index = std.mem.indexOf(u8, content, parsed.value.old_string) orelse return error.OldStringNotFound;
    const after_match = match_index + parsed.value.old_string.len;
    if (std.mem.indexOf(u8, content[after_match..], parsed.value.old_string) != null) return error.MultipleMatches;

    var updated = std.ArrayList(u8).empty;
    try updated.appendSlice(allocator, content[0..match_index]);
    try updated.appendSlice(allocator, parsed.value.new_string);
    try updated.appendSlice(allocator, content[after_match..]);

    const file = try std.fs.cwd().createFile(parsed.value.file_path, .{});
    defer file.close();
    try file.writeAll(updated.items);

    return std.fmt.allocPrint(allocator, "edited {s}: {d} lines → {d} lines", .{
        parsed.value.file_path,
        countLines(content),
        countLines(updated.items),
    });
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;
    if (pattern[0] == '*') {
        if (globMatch(pattern[1..], value)) return true;
        if (value.len == 0) return false;
        return globMatch(pattern, value[1..]);
    }
    if (value.len == 0) return false;
    if (pattern[0] == '?') return globMatch(pattern[1..], value[1..]);
    if (pattern[0] != value[0]) return false;
    return globMatch(pattern[1..], value[1..]);
}

fn countLines(text: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |_| count += 1;
    return count;
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
