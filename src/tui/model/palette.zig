// src/tui/model/palette.zig
// Command palette UI state management methods extracted from chat_tui_app.zig

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

// Import types from parent
const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

// Import dependencies used by extracted functions
const widget_palette = @import("widget_palette");
const palette_command_data = widget_palette.palette_command_data;
const collectFilteredCommandIndices = widget_palette.collectFilteredCommandIndices;

pub fn resetPaletteInputField(self: *Model) void {
    // Clear text content WITHOUT destroying the TextField widget.
    // deinit+reinit breaks vaxis focus path tracking: the new widget
    // instance won't be found in the surface tree, causing
    //   assert(path.len > 0)  in App.zig FocusHandler.handleEvent
    const alloc = self.palette_input.buf.allocator;
    if (self.palette_input.previous_val.len > 0) {
        alloc.free(self.palette_input.previous_val);
    }
    self.palette_input.previous_val = "";
    self.palette_input.buf.clearAndFree();
    self.palette_input.reset();
}

pub fn clearPaletteFilter(self: *Model) void {
    if (self.palette_filter.len > 0) {
        self.allocator.free(self.palette_filter);
    }
    self.palette_filter = "";
    self.palette_selected = 0;
}

pub fn setPaletteFilter(self: *Model, value: []const u8) !void {
    if (self.palette_filter.len > 0) {
        self.allocator.free(self.palette_filter);
    }
    self.palette_filter = if (value.len == 0) "" else try self.allocator.dupe(u8, value);
    clampPaletteSelection(self);
}

pub fn openPalette(self: *Model, ctx: *vxfw.EventContext) !void {
    self.show_palette = true;
    clearPaletteFilter(self);
    resetPaletteInputField(self);
    // NOTE: Do NOT requestFocus on palette_input — it's buried inside
    // FlexRow → InputWidget → CommandPaletteWidget, so vaxis focus path
    // tracking can never find it. Instead, we forward key events manually
    // in handleEvent when show_palette is true.
    ctx.redraw = true;
}

pub fn closePalette(self: *Model, ctx: *vxfw.EventContext) !void {
    self.show_palette = false;
    clearPaletteFilter(self);
    resetPaletteInputField(self);
    ctx.redraw = true;
}

pub fn clampPaletteSelection(self: *Model) void {
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

pub fn movePaletteSelection(self: *Model, delta: isize) void {
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
