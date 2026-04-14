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
};

threadlocal var active_stream_model: ?*Model = null;

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

const MessageWidget = struct {
    message: *const Message,

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
        const max = ctx.max.size();
        const border_width: u16 = if (std.mem.eql(u8, self.message.role, "user")) 2 else 0;
        const content_width = max.width -| border_width;

        const content_widget: MessageContentWidget = .{ .message = self.message };
        const content_surface = try content_widget.draw(ctx.withConstraints(
            .{ .width = content_width, .height = 0 },
            .{ .width = content_width, .height = null },
        ));

        const height = @max(content_surface.size.height, 1);
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

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = 0, .col = @intCast(border_width) },
            .surface = content_surface,
        };

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

pub const Model = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    model_name: []const u8,
    api_key: []const u8,
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
        try model.addMessageUnlocked("assistant", "TUI chat ready. Type a message and press Enter.");
        try model.initializeClient(options);
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
        for (self.messages.items) |message| {
            self.allocator.free(message.role);
            self.allocator.free(message.content);
        }
        self.messages.deinit(self.allocator);
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.deinit(self.allocator);
        self.registry.deinit();
        self.pricing_table.deinit();
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

    fn initializeClient(self: *Model, options: Options) !void {
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
        client.max_tokens = options.max_tokens;
        client.temperature = options.temperature;
        if (options.override_url) |override_url| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, override_url);
        }
        if (options.system_prompt) |system_prompt| {
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
                    if (self.show_palette) {
                        try self.closePalette(ctx);
                    } else {
                        try self.openPalette(ctx);
                    }
                    ctx.consumeEvent();
                    return;
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
        const status_height: u16 = 1;
        const input_height: u16 = 1;
        const body_height = max.height -| (header_height + status_height + input_height);

        const full_title = try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | {s}/{s} | thinking:{s} | ctx: {d}%", .{
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

        var message_widgets = std.ArrayList(vxfw.Widget).empty;
        defer message_widgets.deinit(ctx.arena);
        const total_widgets = if (self.messages.items.len == 0) 1 else self.messages.items.len + (self.messages.items.len - 1) * 2;
        try message_widgets.ensureTotalCapacity(ctx.arena, total_widgets);
        for (self.messages.items, 0..) |*message, idx| {
            const message_widget = MessageWidget{ .message = message };
            try message_widgets.append(ctx.arena, message_widget.widget());
            if (idx + 1 < self.messages.items.len) {
                const gap = MessageGapWidget{};
                try message_widgets.append(ctx.arena, gap.widget());
                const separator = SeparatorWidget{};
                try message_widgets.append(ctx.arena, separator.widget());
            }
        }

        self.scroll_view.children = .{ .slice = message_widgets.items };
        if (self.messages.items.len > 0) {
            self.scroll_view.item_count = @intCast(message_widgets.items.len);
            self.scroll_view.cursor = @intCast(message_widgets.items.len - 1);
            self.scroll_view.ensureScroll();
        } else {
            self.scroll_view.item_count = 0;
            self.scroll_view.cursor = 0;
        }
        self.scroll_bars.scroll_view = self.scroll_view;
        self.scroll_bars.estimated_content_height = estimateContentHeight(self.messages.items);

        const body_surface = try self.scroll_bars.draw(ctx.withConstraints(
            .{ .width = max.width, .height = body_height },
            .{ .width = max.width, .height = body_height },
        ));
        self.scroll_view = self.scroll_bars.scroll_view;

        const status_text = try std.fmt.allocPrint(ctx.arena, "Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s", .{
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

        const input_widget = InputWidget{ .prompt = "❯ ", .field = &self.input };
        const input_surface = try input_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = input_height },
            .{ .width = max.width, .height = input_height },
        ));

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height), .col = 0 }, .surface = body_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + body_height), .col = 0 }, .surface = status_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + body_height + status_height), .col = 0 }, .surface = input_surface });

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
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        });
    }

    fn clearMessagesUnlocked(self: *Model) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.role);
            self.allocator.free(message.content);
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
        try self.history.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = null,
            .tool_calls = null,
        });
    }

    fn replaceMessageUnlocked(self: *Model, index: usize, role: []const u8, content: []const u8) !void {
        var message = &self.messages.items[index];
        self.allocator.free(message.role);
        self.allocator.free(message.content);
        message.role = try self.allocator.dupe(u8, role);
        message.content = try self.allocator.dupe(u8, content);
    }

    fn appendToMessageUnlocked(self: *Model, index: usize, suffix: []const u8) !void {
        var message = &self.messages.items[index];
        const updated = try self.allocator.alloc(u8, message.content.len + suffix.len);
        @memcpy(updated[0..message.content.len], message.content);
        @memcpy(updated[message.content.len..], suffix);
        self.allocator.free(message.content);
        message.content = updated;
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
        if (content.len == 0) {
            self.finishRequestWithErrorText("No response received from provider");
            return;
        }
        const output_tokens = estimateTextTokens(content);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                try self.replaceMessageUnlocked(index, "assistant", content);
            }
            self.awaiting_first_token = false;
        }

        try self.appendHistoryMessageUnlocked("assistant", content);
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
                self.replaceMessageUnlocked(index, "error", text) catch {
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
            self.replaceMessageUnlocked(index, "assistant", token) catch {};
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
    return .{ .fg = .{ .index = 8 }, .dim = true };
}

fn messageRoleLabel(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return "You";
    if (std.mem.eql(u8, role, "assistant")) return "Assistant";
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    return role;
}

fn estimateContentHeight(messages: []const Message) ?u32 {
    var total: u32 = 0;
    for (messages, 0..) |message, idx| {
        total += @intCast(1 + std.mem.count(u8, message.content, "\n"));
        if (idx + 1 < messages.len) total += 2;
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
