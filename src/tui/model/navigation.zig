// src/tui/model/navigation.zig
// Message navigation, selection, copy, and edit extracted from chat_tui_app.zig

const std = @import("std");
const vxfw = @import("vaxis").vxfw;

const chat_tui_app = @import("../chat_tui_app.zig");
const Model = chat_tui_app.Model;

const helpers = @import("helpers.zig");

/// Given the current scroll_view cursor position, determine which message
/// index it corresponds to. Only every-third cursor position (i.e. 0, 3, 6, …)
/// is a MessageWidget. The last visible message has no trailing gap/sep.
/// Returns null if cursor is not on a MessageWidget or the index is out of range.
pub fn scrollCursorToMessageIndex(self: *const Model) ?usize {
    const cursor = self.scroll_view.cursor;
    // Only cursor positions divisible by 3 point at a MessageWidget
    if (cursor % 3 != 0) return null;
    const visible_idx = cursor / 3;

    const messages = self.messages.items;
    var count: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and helpers.findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
        if (count == visible_idx) return idx;
        count += 1;
    }
    return null;
}

/// Select the message currently under the scroll cursor.
pub fn selectMessageAtCursor(self: *Model, ctx: *vxfw.EventContext) !void {
    if (scrollCursorToMessageIndex(self)) |msg_idx| {
        if (self.selected_message_index) |prev| {
            if (prev == msg_idx) {
                // Toggle off if already selected
                self.selected_message_index = null;
                ctx.consumeAndRedraw();
                return;
            }
        }
        self.selected_message_index = msg_idx;
    }
    ctx.consumeAndRedraw();
}

/// Copy selected message content to system clipboard.
pub fn copySelectedMessage(self: *Model, ctx: *vxfw.EventContext, content_only: bool) !void {
    const msg_idx = self.selected_message_index orelse return;
    if (msg_idx >= self.messages.items.len) return;

    const message = self.messages.items[msg_idx];
    const text = if (content_only)
        message.content
    else
        try std.fmt.allocPrint(self.allocator, "[{s}]\n{s}", .{ message.role, message.content });

    try ctx.copyToClipboard(text);
    if (!content_only) self.allocator.free(text);

    self.toast_stack.push("Copied to clipboard", .success) catch {};
    ctx.consumeAndRedraw();
}

/// Copy selected message content into the input field for re-editing.
pub fn editSelectedMessage(self: *Model, ctx: *vxfw.EventContext) !void {
    const msg_idx = self.selected_message_index orelse return;
    if (msg_idx >= self.messages.items.len) return;

    const content = self.messages.items[msg_idx].content;
    try self.input.insertSliceAtCursor(content);

    // Exit scroll mode and focus the input
    self.scroll_mode = false;
    self.auto_scroll = true;
    self.selected_message_index = null;
    self.toast_stack.push("Message copied to input", .info) catch {};
    // NOTE: No requestFocus — Model stays focused, keys forwarded manually
    ctx.consumeAndRedraw();
}
