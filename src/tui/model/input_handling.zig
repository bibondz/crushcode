// src/tui/model/input_handling.zig
// Input field management and string utilities extracted from chat_tui_app.zig

const std = @import("std");

const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

const widget_input = @import("widget_input");
const slash_commands_mod = @import("slash_commands");

/// Slash command names used for autocomplete suggestions in the input field.
const slash_command_names = slash_commands_mod.all_slash_command_names;

/// Reset the input field to its default state, preserving callbacks and prompt.
pub fn resetInputField(self: *Model) void {
    self.input.deinit();
    self.input = widget_input.MultiLineInputState.init(self.allocator);
    self.input.style = .{ .fg = self.current_theme.header_fg };
    self.input.userdata = self;
    self.input.onSubmit = chat_tui_app.onSubmit;
    self.input.prompt = "❯ ";
    self.input.suggestion_list = &slash_command_names;
}

/// Return the prompt string for the current setup phase.
pub fn currentInputPrompt(self: *const Model) []const u8 {
    return switch (self.setup_phase) {
        1 => "Select: ",
        2 => "API key: ",
        3 => "Model: ",
        4 => "Continue: ",
        else => "❯ ",
    };
}

/// Replace the contents of an owned string slot, freeing the old value.
pub fn replaceOwnedString(self: *Model, slot: *[]const u8, value: []const u8) !void {
    const updated = try self.allocator.dupe(u8, value);
    self.allocator.free(slot.*);
    slot.* = updated;
}
