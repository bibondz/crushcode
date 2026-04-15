/// MultiLineInputState — a multi-line text input widget for vxfw.
///
/// Supports:
///   - Multi-line text with newline insertion via Shift+Enter
///   - Enter (without Shift) submits the message
///   - Auto-grows from min_display_rows to max_display_rows
///   - Cursor navigation across lines
///   - Standard editing keys (backspace, delete, arrows, home/end, Ctrl+A/E/K/U)
///   - Prompt prefix (e.g. "❯ ") on the first row
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;
const Key = vaxis.Key;
const unicode = vaxis.unicode;

pub const MultiLineInputState = @This();

pub const CursorPos = struct {
    row: usize,
    col_byte: usize,
};

// --- Gap Buffer ---

pub const GapBuffer = struct {
    allocator: Allocator,
    buffer: []u8,
    cursor: usize,
    gap_size: usize,

    pub fn init(allocator: Allocator) GapBuffer {
        return .{
            .allocator = allocator,
            .buffer = &.{},
            .cursor = 0,
            .gap_size = 0,
        };
    }

    pub fn deinit(self: *GapBuffer) void {
        self.allocator.free(self.buffer);
    }

    pub fn firstHalf(self: GapBuffer) []const u8 {
        return self.buffer[0..self.cursor];
    }

    pub fn secondHalf(self: GapBuffer) []const u8 {
        return self.buffer[self.cursor + self.gap_size ..];
    }

    pub fn grow(self: *GapBuffer, n: usize) Allocator.Error!void {
        const new_size = self.buffer.len + n + 512;
        const new_memory = try self.allocator.alloc(u8, new_size);
        @memcpy(new_memory[0..self.cursor], self.firstHalf());
        const second_half = self.secondHalf();
        @memcpy(new_memory[new_size - second_half.len ..], second_half);
        self.allocator.free(self.buffer);
        self.buffer = new_memory;
        self.gap_size = new_size - second_half.len - self.cursor;
    }

    pub fn insertSliceAtCursor(self: *GapBuffer, slice: []const u8) Allocator.Error!void {
        if (slice.len == 0) return;
        if (self.gap_size <= slice.len) try self.grow(slice.len);
        @memcpy(self.buffer[self.cursor .. self.cursor + slice.len], slice);
        self.cursor += slice.len;
        self.gap_size -= slice.len;
    }

    pub fn moveGapLeft(self: *GapBuffer, n: usize) void {
        const new_idx = self.cursor -| n;
        const dst = self.buffer[new_idx + self.gap_size ..];
        const src = self.buffer[new_idx..self.cursor];
        std.mem.copyForwards(u8, dst, src);
        self.cursor = new_idx;
    }

    pub fn moveGapRight(self: *GapBuffer, n: usize) void {
        const new_idx = self.cursor + n;
        if (new_idx + self.gap_size > self.buffer.len) return;
        const dst = self.buffer[self.cursor..];
        const src = self.buffer[self.cursor + self.gap_size .. new_idx + self.gap_size];
        std.mem.copyForwards(u8, dst, src);
        self.cursor = new_idx;
    }

    pub fn growGapLeft(self: *GapBuffer, n: usize) void {
        self.gap_size += n;
        self.cursor -|= n;
    }

    pub fn growGapRight(self: *GapBuffer, n: usize) void {
        self.gap_size = @min(self.gap_size + n, self.buffer.len - self.cursor);
    }

    pub fn clearAndFree(self: *GapBuffer) void {
        self.cursor = 0;
        self.allocator.free(self.buffer);
        self.buffer = &.{};
        self.gap_size = 0;
    }

    pub fn dupe(self: *const GapBuffer) Allocator.Error![]const u8 {
        const first_half = self.firstHalf();
        const second_half = self.secondHalf();
        const buf = try self.allocator.alloc(u8, first_half.len + second_half.len);
        @memcpy(buf[0..first_half.len], first_half);
        @memcpy(buf[first_half.len..], second_half);
        return buf;
    }

    pub fn toOwnedSlice(self: *GapBuffer) Allocator.Error![]const u8 {
        const slice = try self.dupe();
        self.clearAndFree();
        return slice;
    }

    pub fn realLength(self: *const GapBuffer) usize {
        return self.firstHalf().len + self.secondHalf().len;
    }
};

// --- Multi-line input state ---

buf: GapBuffer,
style: vaxis.Style = .{},

/// Callbacks
userdata: ?*anyopaque = null,
onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
onChange: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

previous_val: []const u8 = "",

/// Display constraints
min_display_rows: u16 = 3,
max_display_rows: u16 = 5,

/// Prompt prefix (e.g. "❯ ") — rendered on the first row
prompt: []const u8 = "❯ ",

/// Slash command autocomplete state
show_suggestions: bool = false,
suggestion_list: []const []const u8 = &.{},
suggestion_selected: usize = 0,
suggestion_count: usize = 0,
suggestion_filtered: [64]usize = [_]usize{0} ** 64,

pub fn init(allocator: Allocator) MultiLineInputState {
    return .{
        .buf = GapBuffer.init(allocator),
    };
}

pub fn deinit(self: *MultiLineInputState) void {
    self.buf.allocator.free(self.previous_val);
    self.buf.deinit();
}

pub fn widget(self: *MultiLineInputState) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *MultiLineInputState = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *MultiLineInputState = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

// --- Event handling ---

pub fn handleEvent(self: *MultiLineInputState, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .focus_out, .focus_in => ctx.redraw = true,
        .key_press => |key| {
            // --- Suggestion autocomplete key handling ---
            if (self.show_suggestions) {
                // Escape → dismiss suggestions
                if (key.matches(Key.escape, .{})) {
                    self.dismissSuggestions();
                    return ctx.consumeAndRedraw();
                }
                // Tab or Enter (without shift) → accept selected suggestion
                if (key.matches(Key.tab, .{}) or key.matches(Key.enter, .{})) {
                    self.acceptSuggestion();
                    return self.checkChanged(ctx);
                }
                // Up arrow → navigate suggestions up
                if (key.matches(Key.up, .{})) {
                    if (self.suggestion_selected > 0) {
                        self.suggestion_selected -= 1;
                    }
                    return ctx.consumeAndRedraw();
                }
                // Down arrow → navigate suggestions down
                if (key.matches(Key.down, .{})) {
                    if (self.suggestion_selected + 1 < self.suggestion_count) {
                        self.suggestion_selected += 1;
                    }
                    return ctx.consumeAndRedraw();
                }
            }
            // Shift+Enter = insert newline
            if (key.matches(Key.enter, .{ .shift = true })) {
                try self.buf.insertSliceAtCursor("\n");
                return self.checkChanged(ctx);
            }
            // Enter (without shift) = submit
            if (key.matches(Key.enter, .{})) {
                if (self.onSubmit) |onSubmitFn| {
                    const value = try self.toOwnedSlice();
                    const allocator = self.buf.allocator;
                    defer allocator.free(value);
                    try onSubmitFn(self.userdata, ctx, value);
                    return ctx.consumeAndRedraw();
                }
            }
            if (key.matches(Key.backspace, .{})) {
                self.deleteBeforeCursor();
                return self.checkChanged(ctx);
            }
            if (key.matches(Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
                self.deleteAfterCursor();
                return self.checkChanged(ctx);
            }
            if (key.matches(Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
                self.cursorLeft();
                return ctx.consumeAndRedraw();
            }
            if (key.matches(Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
                self.cursorRight();
                return ctx.consumeAndRedraw();
            }
            if (key.matches(Key.up, .{})) {
                self.cursorUp();
                return ctx.consumeAndRedraw();
            }
            if (key.matches(Key.down, .{})) {
                self.cursorDown();
                return ctx.consumeAndRedraw();
            }
            if (key.matches('a', .{ .ctrl = true }) or key.matches(Key.home, .{})) {
                self.moveToLineStart();
                return ctx.consumeAndRedraw();
            }
            if (key.matches('e', .{ .ctrl = true }) or key.matches(Key.end, .{})) {
                self.moveToLineEnd();
                return ctx.consumeAndRedraw();
            }
            if (key.matches('k', .{ .ctrl = true })) {
                self.deleteToEndOfLine();
                return self.checkChanged(ctx);
            }
            if (key.matches('u', .{ .ctrl = true })) {
                self.deleteToStartOfLine();
                return self.checkChanged(ctx);
            }
            // Regular text input
            if (key.text) |text| {
                try self.buf.insertSliceAtCursor(text);
                return self.checkChanged(ctx);
            }
        },
        .paste => |paste_text| {
            try self.buf.insertSliceAtCursor(paste_text);
            return self.checkChanged(ctx);
        },
        else => {},
    }
}

fn checkChanged(self: *MultiLineInputState, ctx: *vxfw.EventContext) anyerror!void {
    ctx.consumeAndRedraw();
    const onChange = self.onChange orelse return;
    const new = try self.buf.dupe();
    defer {
        self.buf.allocator.free(self.previous_val);
        self.previous_val = new;
    }
    if (std.mem.eql(u8, new, self.previous_val)) return;
    self.updateSuggestions();
    try onChange(self.userdata, ctx, new);
}

// --- Cursor position helpers ---

/// Compute the (row, col_byte) position of the cursor in the full text.
/// col_byte is the byte offset within the current line (not grapheme count).
pub fn cursorPosition(self: *const MultiLineInputState) CursorPos {
    const first_half = self.buf.firstHalf();
    var row: usize = 0;
    var line_start: usize = 0;
    for (first_half, 0..) |byte, i| {
        if (byte == '\n') {
            row += 1;
            line_start = i + 1;
        }
    }
    return .{ .row = row, .col_byte = first_half.len - line_start };
}

/// Count the number of lines in the full text
pub fn lineCount(self: *const MultiLineInputState) usize {
    const first_half = self.buf.firstHalf();
    const second_half = self.buf.secondHalf();
    var count: usize = 1;
    for (first_half) |byte| {
        if (byte == '\n') count += 1;
    }
    for (second_half) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// Get the byte offset of the start of a given line (0-indexed) in the full text.
fn lineStartOffset(self: *const MultiLineInputState, target_row: usize) usize {
    const first_half = self.buf.firstHalf();
    const second_half = self.buf.secondHalf();
    const total_len = first_half.len + second_half.len;
    var row: usize = 0;
    for (first_half, 0..) |byte, i| {
        if (row == target_row) return i;
        if (byte == '\n') row += 1;
    }
    for (second_half, 0..) |byte, si| {
        if (row == target_row) return first_half.len + si;
        if (byte == '\n') row += 1;
    }
    return total_len;
}

/// Get the byte length of a specific line (0-indexed), excluding the trailing newline.
/// This works on the dupe'd full text to handle the gap buffer split.
fn lineByteLenFromText(full_text: []const u8, target_row: usize) usize {
    var row: usize = 0;
    var line_len: usize = 0;
    for (full_text) |byte| {
        if (row == target_row) {
            if (byte == '\n') return line_len;
            line_len += 1;
        } else {
            if (byte == '\n') row += 1;
        }
    }
    return line_len;
}

/// Extract the text of a specific line (0-indexed) from the full text.
fn getLineFromText(full_text: []const u8, target_row: usize) []const u8 {
    var row: usize = 0;
    var line_start: usize = 0;
    for (full_text, 0..) |byte, i| {
        if (row == target_row) {
            if (byte == '\n') return full_text[line_start..i];
        } else {
            if (byte == '\n') {
                row += 1;
                line_start = i + 1;
            }
        }
    }
    if (row == target_row) return full_text[line_start..];
    return "";
}

// --- Cursor movement ---

pub fn cursorLeft(self: *MultiLineInputState) void {
    const first_half = self.buf.firstHalf();
    if (first_half.len == 0) return;
    var iter = unicode.graphemeIterator(first_half);
    var len: usize = 0;
    while (iter.next()) |grapheme| {
        len = grapheme.len;
    }
    self.buf.moveGapLeft(len);
}

pub fn cursorRight(self: *MultiLineInputState) void {
    const second_half = self.buf.secondHalf();
    var iter = unicode.graphemeIterator(second_half);
    const grapheme = iter.next() orelse return;
    self.buf.moveGapRight(grapheme.len);
}

pub fn cursorUp(self: *MultiLineInputState) void {
    const pos = self.cursorPosition();
    if (pos.row == 0) return;

    // Determine current line start in first_half
    const current_line_start = blk: {
        const first_half = self.buf.firstHalf();
        var i: usize = first_half.len;
        while (i > 0) {
            i -= 1;
            if (first_half[i] == '\n') break :blk i + 1;
        }
        break :blk 0;
    };
    const col_byte = self.buf.cursor - current_line_start;

    // Move to start of current line
    self.buf.moveGapLeft(self.buf.cursor - current_line_start);
    // Move past the \n into previous line
    if (self.buf.cursor > 0) {
        self.buf.moveGapLeft(1);
    }

    // Find start of previous line
    const prev_line_start = blk: {
        const fh = self.buf.firstHalf();
        var i: usize = fh.len;
        while (i > 0) {
            i -= 1;
            if (fh[i] == '\n') break :blk i + 1;
        }
        break :blk 0;
    };
    self.buf.moveGapLeft(self.buf.cursor - prev_line_start);

    // Move right by min(col_byte, prev_line_byte_len) through graphemes
    const prev_len = prevLineByteLen(self, pos.row - 1);
    const target_col = @min(col_byte, prev_len);
    moveRightBytes(self, target_col);
}

fn prevLineByteLen(self: *MultiLineInputState, target_row: usize) usize {
    const first_half = self.buf.firstHalf();
    const second_half = self.buf.secondHalf();
    var row: usize = 0;
    var line_len: usize = 0;
    for (first_half) |byte| {
        if (row == target_row) {
            if (byte == '\n') return line_len;
            line_len += 1;
        } else {
            if (byte == '\n') row += 1;
        }
    }
    for (second_half) |byte| {
        if (row == target_row) {
            if (byte == '\n') return line_len;
            line_len += 1;
        } else {
            if (byte == '\n') row += 1;
        }
    }
    return line_len;
}

fn moveRightBytes(self: *MultiLineInputState, target: usize) void {
    var moved: usize = 0;
    while (moved < target) {
        const second_half = self.buf.secondHalf();
        if (second_half.len == 0) break;
        if (second_half[0] == '\n') break;
        var iter = unicode.graphemeIterator(second_half);
        const grapheme = iter.next() orelse break;
        self.buf.moveGapRight(grapheme.len);
        moved += grapheme.len;
    }
}

pub fn cursorDown(self: *MultiLineInputState) void {
    const pos = self.cursorPosition();
    const total_lines = self.lineCount();
    if (pos.row >= total_lines - 1) return;

    const current_line_start = self.lineStartOffset(pos.row);
    const col_byte = self.buf.cursor - current_line_start;

    // Move to end of current line
    self.moveToLineEnd();
    // Move past the newline
    {
        const second_half = self.buf.secondHalf();
        if (second_half.len > 0 and second_half[0] == '\n') {
            self.buf.moveGapRight(1);
        }
    }

    // Now at start of next line — move right by min(col_byte, next_line_len)
    const next_len = prevLineByteLen(self, pos.row + 1);
    const target_col = @min(col_byte, next_len);
    moveRightBytes(self, target_col);
}

fn moveToLineStart(self: *MultiLineInputState) void {
    const first_half = self.buf.firstHalf();
    var i: usize = first_half.len;
    while (i > 0) {
        i -= 1;
        if (first_half[i] == '\n') {
            self.buf.moveGapLeft(self.buf.cursor - (i + 1));
            return;
        }
    }
    self.buf.moveGapLeft(self.buf.cursor);
}

fn moveToLineEnd(self: *MultiLineInputState) void {
    const second_half = self.buf.secondHalf();
    var len_to_end: usize = 0;
    for (second_half) |byte| {
        if (byte == '\n') break;
        len_to_end += 1;
    }
    // Move through graphemes for proper unicode handling
    var moved: usize = 0;
    while (moved < len_to_end) {
        const sh = self.buf.secondHalf();
        if (sh.len == 0) break;
        if (sh[0] == '\n') break;
        var iter = unicode.graphemeIterator(sh);
        const grapheme = iter.next() orelse break;
        self.buf.moveGapRight(grapheme.len);
        moved += grapheme.len;
    }
}

fn deleteToEndOfLine(self: *MultiLineInputState) void {
    const second_half = self.buf.secondHalf();
    var len_to_end: usize = 0;
    for (second_half) |byte| {
        if (byte == '\n') break;
        len_to_end += 1;
    }
    self.buf.growGapRight(len_to_end);
}

fn deleteToStartOfLine(self: *MultiLineInputState) void {
    const first_half = self.buf.firstHalf();
    var i: usize = first_half.len;
    while (i > 0) {
        i -= 1;
        if (first_half[i] == '\n') {
            i += 1;
            break;
        }
    }
    const to_delete = self.buf.cursor - i;
    self.buf.moveGapLeft(to_delete);
    self.buf.growGapRight(to_delete);
}

pub fn deleteBeforeCursor(self: *MultiLineInputState) void {
    const first_half = self.buf.firstHalf();
    if (first_half.len == 0) return;
    var iter = unicode.graphemeIterator(first_half);
    var len: usize = 0;
    while (iter.next()) |grapheme| {
        len = grapheme.len;
    }
    self.buf.growGapLeft(len);
}

pub fn deleteAfterCursor(self: *MultiLineInputState) void {
    const second_half = self.buf.secondHalf();
    var iter = unicode.graphemeIterator(second_half);
    const grapheme = iter.next() orelse return;
    self.buf.growGapRight(grapheme.len);
}

// --- Suggestion autocomplete ---

/// Update the filtered suggestion list based on the current line content.
/// Call this after text changes.
fn updateSuggestions(self: *MultiLineInputState) void {
    self.show_suggestions = false;
    self.suggestion_count = 0;

    if (self.suggestion_list.len == 0) return;

    const full_text = self.buf.dupe() catch return;
    defer self.buf.allocator.free(full_text);

    const pos = self.cursorPosition();
    const line = getLineFromText(full_text, pos.row);

    if (line.len == 0 or line[0] != '/') return;

    const partial = line[1..]; // text after the leading /
    var count: usize = 0;
    for (self.suggestion_list, 0..) |name, i| {
        // Command names start with '/', so compare after stripping it
        const cmd: []const u8 = if (name.len > 0 and name[0] == '/') name[1..] else name;
        if (std.mem.startsWith(u8, cmd, partial)) {
            if (count < self.suggestion_filtered.len) {
                self.suggestion_filtered[count] = i;
            }
            count += 1;
        }
    }

    // Don't show suggestions when there's exactly one match that is exact
    if (count == 1) {
        const match_name = self.suggestion_list[self.suggestion_filtered[0]];
        const match_cmd: []const u8 = if (match_name.len > 0 and match_name[0] == '/') match_name[1..] else match_name;
        if (std.mem.eql(u8, match_cmd, partial)) return;
    }

    if (count > 0) {
        self.show_suggestions = true;
        self.suggestion_count = count;
        if (self.suggestion_selected >= count) {
            self.suggestion_selected = 0;
        }
    }
}

/// Accept the currently selected suggestion: replace the current line with it.
fn acceptSuggestion(self: *MultiLineInputState) void {
    if (!self.show_suggestions or self.suggestion_count == 0) return;
    if (self.suggestion_selected >= self.suggestion_count) return;

    const idx = self.suggestion_filtered[self.suggestion_selected];
    const suggestion_name = self.suggestion_list[idx];

    const pos = self.cursorPosition();
    const line_start = self.lineStartOffset(pos.row);

    // Move cursor to line start
    if (self.buf.cursor > line_start) {
        self.buf.moveGapLeft(self.buf.cursor - line_start);
    }

    // Delete to end of line (not including the newline)
    {
        const second_half = self.buf.secondHalf();
        var line_end_len: usize = 0;
        for (second_half) |byte| {
            if (byte == '\n') break;
            line_end_len += 1;
        }
        self.buf.growGapRight(line_end_len);
    }

    // Insert the suggestion name
    self.buf.insertSliceAtCursor(suggestion_name) catch return;

    // Close suggestions
    self.show_suggestions = false;
    self.suggestion_count = 0;
}

/// Close suggestions without accepting.
fn dismissSuggestions(self: *MultiLineInputState) void {
    self.show_suggestions = false;
    self.suggestion_count = 0;
}

/// Get the name of the Nth filtered suggestion.
pub fn filteredSuggestionName(self: *const MultiLineInputState, index: usize) ?[]const u8 {
    if (index >= self.suggestion_count) return null;
    const idx = self.suggestion_filtered[index];
    if (idx >= self.suggestion_list.len) return null;
    return self.suggestion_list[idx];
}

/// Returns the number of extra rows needed for the suggestion popup (0 if hidden).
pub fn suggestionPopupHeight(self: *const MultiLineInputState) u16 {
    if (!self.show_suggestions or self.suggestion_count == 0) return 0;
    const visible = @min(self.suggestion_count, 5);
    return @intCast(visible + 2); // content rows + top/bottom border
}

/// Returns display rows for text only (excluding suggestion popup).
pub fn textOnlyDisplayRows(self: *const MultiLineInputState, available_width: u16) u16 {
    if (available_width == 0) return self.min_display_rows;

    const full_text = self.buf.dupe() catch return self.min_display_rows;
    defer self.buf.allocator.free(full_text);

    var display_rows: u16 = 0;
    var line_iter = std.mem.splitSequence(u8, full_text, "\n");
    while (line_iter.next()) |line_text| {
        if (line_text.len == 0) {
            display_rows += 1;
        } else {
            var width: usize = 0;
            var giter = unicode.graphemeIterator(line_text);
            while (giter.next()) |grapheme| {
                const g = grapheme.bytes(line_text);
                width += vaxis.gwidth.gwidth(g, .unicode);
            }
            const wrapped_rows = @max(1, (width + available_width - 1) / available_width);
            display_rows += @intCast(wrapped_rows);
        }
    }

    return std.math.clamp(display_rows, self.min_display_rows, self.max_display_rows);
}

// --- Public API ---

pub fn insertSliceAtCursor(self: *MultiLineInputState, data: []const u8) Allocator.Error!void {
    var iter = unicode.graphemeIterator(data);
    while (iter.next()) |text| {
        try self.buf.insertSliceAtCursor(text.bytes(data));
    }
}

pub fn clearAndFree(self: *MultiLineInputState) void {
    self.buf.clearAndFree();
    self.reset();
}

pub fn toOwnedSlice(self: *MultiLineInputState) Allocator.Error![]const u8 {
    defer self.reset();
    return self.buf.toOwnedSlice();
}

pub fn reset(self: *MultiLineInputState) void {
    self.buf.allocator.free(self.previous_val);
    self.previous_val = "";
}

/// Returns the number of display rows needed for the current content,
/// clamped between min_display_rows and max_display_rows, plus suggestion
/// popup rows if visible.
/// `available_width` is the number of columns available for text (excluding prompt).
pub fn currentDisplayRows(self: *const MultiLineInputState, available_width: u16) u16 {
    var result = self.textOnlyDisplayRows(available_width);
    result += self.suggestionPopupHeight();
    return result;
}

// --- Drawing ---

pub fn draw(self: *MultiLineInputState, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.width != null);
    const max_width = ctx.max.width.?;

    const prompt_display_width: u16 = @intCast(ctx.stringWidth(self.prompt));
    const text_width = max_width -| prompt_display_width;

    const display_rows = self.currentDisplayRows(text_width);
    const surface_height = @max(ctx.min.height, display_rows);

    var surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = max_width, .height = surface_height },
    );

    const base: vaxis.Cell = .{ .style = self.style };
    @memset(surface.buffer, base);

    if (max_width == 0) return surface;

    // Get the full text
    const full_text = try self.buf.dupe();
    defer self.buf.allocator.free(full_text);

    // Render prompt on first row
    var prompt_col: u16 = 0;
    var piter = unicode.graphemeIterator(self.prompt);
    while (piter.next()) |grapheme| {
        const g = grapheme.bytes(self.prompt);
        const w: u8 = @intCast(ctx.stringWidth(g));
        if (prompt_col + w > max_width) break;
        surface.writeCell(prompt_col, 0, .{
            .char = .{ .grapheme = g, .width = w },
            .style = .{ .fg = self.style.fg, .bold = true },
        });
        prompt_col += w;
    }

    // Render text lines
    const cursor_pos = self.cursorPosition();
    var line_iter = std.mem.splitSequence(u8, full_text, "\n");
    var visual_row: u16 = 0;
    var logical_row: usize = 0;

    while (line_iter.next()) |line_text| : (logical_row += 1) {
        if (visual_row >= surface_height) break;

        const col_start: u16 = if (logical_row == 0) prompt_col else 0;
        var col: u16 = col_start;
        var cursor_display_col: u16 = col_start;
        var found_cursor = false;

        var giter = unicode.graphemeIterator(line_text);
        var byte_count: usize = 0;
        while (giter.next()) |grapheme| {
            const g = grapheme.bytes(line_text);
            const w: u8 = @intCast(ctx.stringWidth(g));

            // Track cursor position before rendering
            if (logical_row == cursor_pos.row and !found_cursor) {
                if (byte_count >= cursor_pos.col_byte) {
                    cursor_display_col = col;
                    found_cursor = true;
                }
            }

            // Handle line wrapping
            if (col + w > max_width) {
                visual_row += 1;
                if (visual_row >= surface_height) break;
                col = 0;
            }

            if (col + w <= max_width) {
                surface.writeCell(col, visual_row, .{
                    .char = .{ .grapheme = g, .width = w },
                    .style = self.style,
                });
            }
            col += w;
            byte_count += grapheme.len;
        }

        // Set cursor for this logical line
        if (logical_row == cursor_pos.row) {
            if (!found_cursor) cursor_display_col = col;
            if (visual_row < surface_height) {
                surface.cursor = .{ .col = cursor_display_col, .row = visual_row };
            }
        }

        visual_row += 1;
    }

    // Empty buffer — cursor after prompt
    if (full_text.len == 0) {
        surface.cursor = .{ .col = prompt_col, .row = 0 };
    }

    return surface;
}
