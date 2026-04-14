const std = @import("std");
const vaxis = @import("vaxis");

const vxfw = vaxis.vxfw;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

const RoleLabelWidget = struct {
    role: []const u8,
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
                .{ .text = self.role, .style = self.style },
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
        const role_label: RoleLabelWidget = .{ .role = self.message.role, .style = role_style };
        const content = vxfw.Text{
            .text = self.message.content,
            .style = body_style,
            .softwrap = true,
            .width_basis = .parent,
        };

        var row = vxfw.FlexRow{
            .children = &.{
                .{ .widget = role_label.widget(), .flex = 0 },
                .{ .widget = content.widget(), .flex = 1 },
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
        const base_style = vaxis.Style{};
        @memset(surface.buffer, .{ .style = base_style });

        if (border_width > 0) {
            const border_cell: vaxis.Cell = .{
                .char = .{ .grapheme = "│", .width = 1 },
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
        const line = try std.fmt.allocPrint(ctx.arena, "{s}", .{try repeated(ctx.arena, "─", width)});
        const text: vxfw.Text = .{
            .text = line,
            .style = .{ .fg = .{ .index = 8 }, .dim = true },
            .softwrap = false,
            .width_basis = .parent,
        };
        return text.draw(ctx.withConstraints(ctx.min, .{ .width = width, .height = 1 }));
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
        const rich: vxfw.RichText = .{
            .text = &.{
                .{ .text = self.title, .style = .{ .fg = .{ .index = 15 }, .bold = true } },
            },
            .softwrap = false,
            .width_basis = .parent,
        };
        return rich.draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = ctx.max.width, .height = 1 }));
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

pub const Model = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_name: []const u8,
    thinking: bool,
    app: *vxfw.App,
    messages: std.ArrayList(Message),
    input: vxfw.TextField,
    scroll_view: vxfw.ScrollView,
    scroll_bars: vxfw.ScrollBars,
    should_quit: bool,

    pub fn create(allocator: std.mem.Allocator, provider: []const u8, model_name: []const u8) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);

        const app = try allocator.create(vxfw.App);
        errdefer allocator.destroy(app);
        app.* = try vxfw.App.init(allocator);
        errdefer app.deinit();

        model.* = .{
            .allocator = allocator,
            .provider = try allocator.dupe(u8, provider),
            .model_name = try allocator.dupe(u8, model_name),
            .thinking = false,
            .app = app,
            .messages = std.ArrayList(Message).empty,
            .input = vxfw.TextField.init(allocator),
            .scroll_view = .{
                .children = .{ .slice = &.{} },
                .draw_cursor = false,
                .wheel_scroll = 3,
            },
            .scroll_bars = undefined,
            .should_quit = false,
        };
        errdefer model.destroy();

        model.messages = try std.ArrayList(Message).initCapacity(allocator, 8);
        model.input.style = .{ .fg = .{ .index = 15 } };
        model.input.userdata = model;
        model.input.onSubmit = onSubmit;
        model.scroll_bars = .{
            .scroll_view = model.scroll_view,
            .draw_horizontal_scrollbar = false,
            .draw_vertical_scrollbar = true,
            .vertical_scrollbar_thumb = .{ .char = .{ .grapheme = "▐", .width = 1 }, .style = .{ .fg = .{ .index = 8 }, .dim = true } },
            .vertical_scrollbar_hover_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } },
            .vertical_scrollbar_drag_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = .{ .index = 39 } } },
        };

        try model.addMessage("assistant", "TUI chat ready. Type a message and press Enter.");
        return model;
    }

    pub fn destroy(self: *Model) void {
        self.input.deinit();
        for (self.messages.items) |message| {
            self.allocator.free(message.role);
            self.allocator.free(message.content);
        }
        self.messages.deinit(self.allocator);
        self.allocator.free(self.provider);
        self.allocator.free(self.model_name);
        self.app.deinit();
        self.allocator.destroy(self.app);
        self.allocator.destroy(self);
    }

    pub fn run(self: *Model) !void {
        try self.app.run(self.widget(), .{ .framerate = 60 });
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
        switch (event) {
            .init => {
                try ctx.setTitle("Crushcode TUI Chat");
                try ctx.requestFocus(self.input.widget());
                ctx.redraw = true;
            },
            .focus_in => {
                try ctx.requestFocus(self.input.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    self.should_quit = true;
                    ctx.quit = true;
                    ctx.consumeEvent();
                    return;
                }
            },
            else => {},
        }
    }

    fn draw(self: *Model, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        const header_height: u16 = 1;
        const input_height: u16 = 1;
        const body_height = max.height -| (header_height + input_height);

        const title = try std.fmt.allocPrint(ctx.arena, "Crushcode | {s}/{s} | thinking:{s}", .{
            self.provider,
            self.model_name,
            if (self.thinking) "on" else "off",
        });

        const header = HeaderWidget{ .title = title };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = max.width, .height = header_height },
            .{ .width = max.width, .height = header_height },
        ));

        var message_widgets = std.ArrayList(vxfw.Widget).empty;
        defer message_widgets.deinit(ctx.arena);
        const total_widgets = if (self.messages.items.len == 0) 1 else self.messages.items.len * 2 - 1;
        try message_widgets.ensureTotalCapacity(ctx.arena, total_widgets);
        for (self.messages.items, 0..) |*message, idx| {
            const message_widget = MessageWidget{ .message = message };
            try message_widgets.append(ctx.arena, message_widget.widget());
            if (idx + 1 < self.messages.items.len) {
                const separator = SeparatorWidget{};
                try message_widgets.append(ctx.arena, separator.widget());
            }
        }

        self.scroll_view.children = .{ .slice = message_widgets.items };
        if (self.messages.items.len > 0) {
            self.scroll_view.item_count = @intCast(message_widgets.items.len);
            self.scroll_view.cursor = @intCast(message_widgets.items.len - 1);
            self.scroll_view.ensureScroll();
        }
        self.scroll_bars.scroll_view = self.scroll_view;
        self.scroll_bars.estimated_content_height = estimateContentHeight(self.messages.items);

        const body_surface = try self.scroll_bars.draw(ctx.withConstraints(
            .{ .width = max.width, .height = body_height },
            .{ .width = max.width, .height = body_height },
        ));
        self.scroll_view = self.scroll_bars.scroll_view;

        const input_widget = InputWidget{ .prompt = "❯ ", .field = &self.input };
        const input_surface = try input_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = input_height },
            .{ .width = max.width, .height = input_height },
        ));

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface };
        children[1] = .{ .origin = .{ .row = @intCast(header_height), .col = 0 }, .surface = body_surface };
        children[2] = .{ .origin = .{ .row = @intCast(header_height + body_height), .col = 0 }, .surface = input_surface };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn addMessage(self: *Model, role: []const u8, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        });
    }

    fn handleSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (std.mem.eql(u8, trimmed, "/exit")) {
            self.should_quit = true;
            ctx.quit = true;
            return;
        }

        try self.addMessage("user", trimmed);
        self.thinking = true;
        try self.addMessage("assistant", trimmed);
        self.thinking = false;
        ctx.redraw = true;
    }
};

fn onSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.handleSubmit(value, ctx);
}

fn messageRoleStyle(role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = .{ .index = 39 }, .bold = true };
    }
    return .{ .fg = .{ .index = 15 }, .bold = true };
}

fn messageBodyStyle(role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = .{ .index = 2 } };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = .{ .index = 39 } };
    }
    return .{ .fg = .{ .index = 8 }, .dim = true };
}

fn estimateContentHeight(messages: []const Message) ?u32 {
    var total: u32 = 0;
    for (messages, 0..) |message, idx| {
        _ = message;
        total += 2;
        if (idx + 1 < messages.len) total += 1;
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

pub fn run(allocator: std.mem.Allocator, provider: []const u8, model_name: []const u8) !void {
    var model = try Model.create(allocator, provider, model_name);
    defer model.destroy();
    try model.run();
}
