const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const widget_helpers = @import("widget_helpers");
const widget_types = @import("widget_types");

const vxfw = vaxis.vxfw;

const setup_provider_data = widget_types.setup_provider_data;

pub const SetupContext = struct {
    setup_phase: u8,
    provider_name: []const u8,
    model_name: []const u8,
    setup_provider_index: usize,
    setup_feedback: []const u8,
    setup_feedback_is_error: bool,
    theme: *const theme_mod.Theme,
};

pub const SetupProviderRowWidget = struct {
    provider_name: []const u8,
    selected: bool,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const SetupProviderRowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SetupProviderRowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const SetupProviderRowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse ctx.min.width;
        const text = vxfw.RichText{
            .text = &.{
                .{ .text = if (self.selected) "› " else "  ", .style = if (self.selected) .{ .fg = self.theme.setup_selected_fg, .bold = true } else .{ .fg = self.theme.setup_dim_fg, .dim = true } },
                .{ .text = self.provider_name, .style = if (self.selected) .{ .fg = self.theme.setup_text_fg, .bold = true } else .{ .fg = self.theme.setup_text_fg } },
            },
            .softwrap = false,
            .width_basis = .parent,
        };
        return text.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }
};

pub const SetupWizardWidget = struct {
    context: *const SetupContext,

    pub fn widget(self: *const SetupWizardWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SetupWizardWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const SetupWizardWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        const width = max.width;
        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        var row: u16 = 0;
        const theme = self.context.theme;
        try appendSetupText(ctx, &child_list, &row, width, "Welcome to Crushcode!", .{ .fg = theme.setup_text_fg, .bold = true });
        row += 1;

        switch (self.context.setup_phase) {
            1 => {
                try appendSetupText(ctx, &child_list, &row, width, "Choose a provider:", .{ .fg = theme.setup_text_fg, .bold = true });
                try appendSetupText(ctx, &child_list, &row, width, "Use ↑↓ to choose, then press Enter.", .{ .fg = theme.setup_dim_fg, .dim = true });
                row += 1;
                for (setup_provider_data, 0..) |provider_name, idx| {
                    const provider_row = SetupProviderRowWidget{ .provider_name = provider_name, .selected = idx == self.context.setup_provider_index, .theme = theme };
                    const provider_surface = try provider_row.draw(ctx.withConstraints(
                        .{ .width = width, .height = 1 },
                        .{ .width = width, .height = 1 },
                    ));
                    try child_list.append(ctx.arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = provider_surface });
                    row += 1;
                }
            },
            2 => {
                const title = try std.fmt.allocPrint(ctx.arena, "Enter your API key for {s}:", .{self.context.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, title, .{ .fg = theme.setup_text_fg, .bold = true });
                if (setupProviderAllowsEmptyKey(self.context.provider_name)) {
                    try appendSetupText(ctx, &child_list, &row, width, "This provider can use a blank key. Press Enter to continue.", .{ .fg = theme.setup_dim_fg, .dim = true });
                } else {
                    try appendSetupText(ctx, &child_list, &row, width, "Paste the key, then press Enter.", .{ .fg = theme.setup_dim_fg, .dim = true });
                }
            },
            3 => {
                try appendSetupText(ctx, &child_list, &row, width, "Enter default model (or press Enter for default):", .{ .fg = theme.setup_text_fg, .bold = true });
                const provider_line = try std.fmt.allocPrint(ctx.arena, "Provider: {s}", .{self.context.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, provider_line, .{ .fg = theme.setup_dim_fg, .dim = true });
                const default_line = try std.fmt.allocPrint(ctx.arena, "Default: {s}", .{setupDefaultModel(self.context.provider_name)});
                try appendSetupText(ctx, &child_list, &row, width, default_line, .{ .fg = theme.setup_dim_fg, .dim = true });
            },
            4 => {
                try appendSetupText(ctx, &child_list, &row, width, "Setup complete! Press Enter to start chatting.", .{ .fg = theme.setup_success_fg, .bold = true });
                const provider_line = try std.fmt.allocPrint(ctx.arena, "Provider: {s}", .{self.context.provider_name});
                try appendSetupText(ctx, &child_list, &row, width, provider_line, .{ .fg = theme.setup_dim_fg, .dim = true });
                const model_line = try std.fmt.allocPrint(ctx.arena, "Model: {s}", .{self.context.model_name});
                try appendSetupText(ctx, &child_list, &row, width, model_line, .{ .fg = theme.setup_dim_fg, .dim = true });
                const config_line = try std.fmt.allocPrint(ctx.arena, "Config: {s}", .{try setupConfigPath(ctx.arena)});
                try appendSetupText(ctx, &child_list, &row, width, config_line, .{ .fg = theme.setup_dim_fg, .dim = true });
            },
            else => {},
        }

        if (self.context.setup_feedback.len > 0) {
            row += 1;
            try appendSetupText(
                ctx,
                &child_list,
                &row,
                width,
                self.context.setup_feedback,
                if (self.context.setup_feedback_is_error) .{ .fg = theme.setup_error_fg, .bold = true } else .{ .fg = theme.setup_success_fg, .dim = true },
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

// --- Helper functions ---

pub fn appendSetupText(
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
        .{ .width = width, .height = 9999 },
    ));
    try child_list.append(ctx.arena, .{ .origin = .{ .row = row.*, .col = 0 }, .surface = surface });
    row.* += surface.size.height;
}

pub fn setupProviderIndex(provider_name: []const u8) usize {
    for (setup_provider_data, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate, provider_name)) return idx;
    }
    return 0;
}

pub fn setupProviderAllowsEmptyKey(provider_name: []const u8) bool {
    return std.mem.eql(u8, provider_name, "ollama");
}

pub fn setupDefaultModel(provider_name: []const u8) []const u8 {
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

pub fn setupConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/root";
    return std.fmt.allocPrint(allocator, "{s}/.crushcode/config.toml", .{home});
}

const slash_commands_mod = @import("slash_commands");

pub fn isSupportedSlashCommand(value: []const u8) bool {
    // Check prefix-based commands first (not in the static list)
    if (std.mem.startsWith(u8, value, "/resume") or
        std.mem.startsWith(u8, value, "/delete") or
        std.mem.startsWith(u8, value, "/theme") or
        std.mem.startsWith(u8, value, "/skills/auto") or
        std.mem.startsWith(u8, value, "/plan") or
        std.mem.eql(u8, value, "/preview"))
    {
        return true;
    }
    // Delegate to shared registry
    return slash_commands_mod.isSupportedSlashCommand(value);
}

// --- Tests ---

test "setupProviderIndex - known providers" {
    try std.testing.expectEqual(@as(usize, 0), setupProviderIndex("openrouter"));
}

test "setupProviderIndex - unknown returns 0" {
    try std.testing.expectEqual(@as(usize, 0), setupProviderIndex("nonexistent"));
}

test "setupProviderAllowsEmptyKey - ollama only" {
    try std.testing.expect(setupProviderAllowsEmptyKey("ollama"));
    try std.testing.expect(!setupProviderAllowsEmptyKey("openai"));
    try std.testing.expect(!setupProviderAllowsEmptyKey("anthropic"));
    try std.testing.expect(!setupProviderAllowsEmptyKey("openrouter"));
}

test "setupDefaultModel - known providers" {
    try std.testing.expectEqualStrings("gpt-4o", setupDefaultModel("openai"));
    try std.testing.expectEqualStrings("claude-3-5-sonnet-20241022", setupDefaultModel("anthropic"));
    try std.testing.expectEqualStrings("gemma4:31b-cloud", setupDefaultModel("ollama"));
}

test "setupDefaultModel - unknown returns default" {
    try std.testing.expectEqualStrings("default", setupDefaultModel("unknown_provider"));
}

test "isSupportedSlashCommand - exact matches" {
    try std.testing.expect(isSupportedSlashCommand("/clear"));
    try std.testing.expect(isSupportedSlashCommand("/sessions"));
    try std.testing.expect(isSupportedSlashCommand("/model"));
    try std.testing.expect(isSupportedSlashCommand("/help"));
    try std.testing.expect(isSupportedSlashCommand("/compact"));
    try std.testing.expect(isSupportedSlashCommand("/thinking"));
    try std.testing.expect(isSupportedSlashCommand("/ls"));
    try std.testing.expect(isSupportedSlashCommand("/plugins"));
}

test "isSupportedSlashCommand - prefix matches" {
    try std.testing.expect(isSupportedSlashCommand("/resume abc"));
    try std.testing.expect(isSupportedSlashCommand("/delete session-1"));
    try std.testing.expect(isSupportedSlashCommand("/theme dark"));
    try std.testing.expect(isSupportedSlashCommand("/theme"));
}

test "isSupportedSlashCommand - unsupported commands" {
    try std.testing.expect(!isSupportedSlashCommand("/unknown"));
    try std.testing.expect(!isSupportedSlashCommand("clear"));
    try std.testing.expect(!isSupportedSlashCommand(""));
}
