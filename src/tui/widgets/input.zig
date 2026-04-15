const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme");
const multiline = @import("multiline_input");

const vxfw = vaxis.vxfw;

pub const MultiLineInputState = multiline.MultiLineInputState;

/// Legacy single-line InputWidget — used by palette.zig and setup wizard.
/// Wraps a vxfw.TextField with a prompt prefix.
pub const InputWidget = struct {
    prompt: []const u8,
    field: *vxfw.TextField,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const InputWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = legacyTypeErasedDrawFn,
        };
    }

    fn legacyTypeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const InputWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const InputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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

/// Multi-line InputWidget — used by the chat TUI for multi-line text input.
/// Renders a prompt prefix on the first row, supports Shift+Enter for newlines,
/// and auto-grows from 3 to 5 rows based on content.
pub const MultiLineInputWidget = struct {
    prompt: []const u8,
    state: *MultiLineInputState,
    theme: *const theme_mod.Theme,

    pub fn widget(self: *const MultiLineInputWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = mlTypeErasedDrawFn,
        };
    }

    fn mlTypeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MultiLineInputWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const MultiLineInputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        std.debug.assert(ctx.max.width != null);
        const max_width = ctx.max.width.?;

        const prompt_display_width: u16 = @intCast(ctx.stringWidth(self.prompt));
        const text_width = max_width -| prompt_display_width;
        const display_rows = self.state.currentDisplayRows(text_width);
        const text_rows = self.state.textOnlyDisplayRows(text_width);
        const surface_height = @max(ctx.min.height, display_rows);

        // Create surface
        var surface = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = max_width, .height = surface_height },
        );

        const style = self.state.style;
        const base: vaxis.Cell = .{ .style = style };
        @memset(surface.buffer, base);

        if (max_width == 0) return surface;

        // Get the full text
        const full_text = try self.state.buf.dupe();
        defer self.state.buf.allocator.free(full_text);

        // Render prompt on first row
        var prompt_col: u16 = 0;
        var piter = vaxis.unicode.graphemeIterator(self.prompt);
        while (piter.next()) |grapheme| {
            const g = grapheme.bytes(self.prompt);
            const w: u8 = @intCast(ctx.stringWidth(g));
            if (prompt_col + w > max_width) break;
            surface.writeCell(prompt_col, 0, .{
                .char = .{ .grapheme = g, .width = w },
                .style = .{ .fg = self.theme.accent, .bold = true },
            });
            prompt_col += w;
        }

        // Render text lines (only in the text area rows, not the popup area)
        const cursor_pos = self.state.cursorPosition();
        var line_iter = std.mem.splitSequence(u8, full_text, "\n");
        var visual_row: u16 = 0;
        var logical_row: usize = 0;

        while (line_iter.next()) |line_text| : (logical_row += 1) {
            if (visual_row >= text_rows) break;

            const col_start: u16 = if (logical_row == 0) prompt_col else 0;
            var col: u16 = col_start;
            var cursor_display_col: u16 = col_start;
            var found_cursor = false;

            var giter = vaxis.unicode.graphemeIterator(line_text);
            var byte_count: usize = 0;
            while (giter.next()) |grapheme| {
                const g = grapheme.bytes(line_text);
                const w: u8 = @intCast(ctx.stringWidth(g));

                // Track cursor position before rendering this grapheme
                if (logical_row == cursor_pos.row and !found_cursor) {
                    if (byte_count >= cursor_pos.col_byte) {
                        cursor_display_col = col;
                        found_cursor = true;
                    }
                }

                // Handle line wrapping
                if (col + w > max_width) {
                    visual_row += 1;
                    if (visual_row >= text_rows) break;
                    col = 0;
                }

                if (col + w <= max_width) {
                    surface.writeCell(col, visual_row, .{
                        .char = .{ .grapheme = g, .width = w },
                        .style = style,
                    });
                }
                col += w;
                byte_count += grapheme.len;
            }

            // Set cursor for this logical line
            if (logical_row == cursor_pos.row) {
                if (!found_cursor) cursor_display_col = col;
                if (visual_row < text_rows) {
                    surface.cursor = .{ .col = cursor_display_col, .row = visual_row };
                }
            }

            visual_row += 1;
        }

        // Empty buffer — cursor after prompt
        if (full_text.len == 0) {
            surface.cursor = .{ .col = prompt_col, .row = 0 };
        }

        // --- Render suggestion popup below text area ---
        if (self.state.show_suggestions and self.state.suggestion_count > 0 and text_rows < surface_height) {
            const visible = @min(self.state.suggestion_count, 5);
            const popup_height = visible + 2; // +2 for border top/bottom
            const popup_start: u16 = text_rows;

            if (popup_start + popup_height <= surface_height and max_width >= 2) {
                const border_style: vaxis.Style = .{ .fg = self.theme.border };
                const border_bg: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = border_style };

                // Top border
                surface.writeCell(0, popup_start, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = border_style });
                surface.writeCell(max_width - 1, popup_start, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = border_style });
                for (1..@intCast(max_width - 1)) |c| {
                    surface.writeCell(@intCast(c), popup_start, border_bg);
                }

                // Suggestion rows
                for (0..visible) |i| {
                    const row: u16 = popup_start + 1 + @as(u16, @intCast(i));
                    const is_selected = (i == self.state.suggestion_selected);

                    const row_style: vaxis.Style = if (is_selected)
                        .{ .fg = self.theme.header_bg, .bg = self.theme.accent }
                    else
                        .{ .fg = self.theme.header_fg };

                    const row_bg: vaxis.Cell = .{ .style = row_style };
                    // Fill row with style
                    for (0..@intCast(max_width)) |c| {
                        surface.writeCell(@intCast(c), row, row_bg);
                    }

                    // Side borders
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    surface.writeCell(max_width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });

                    // Render suggestion name
                    const name = self.state.filteredSuggestionName(i) orelse continue;
                    const name_style: vaxis.Style = if (is_selected)
                        .{ .fg = self.theme.header_bg, .bg = self.theme.accent, .bold = true }
                    else
                        .{ .fg = self.theme.accent, .bold = true };

                    // Write " " then name
                    surface.writeCell(1, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = row_style });
                    var name_col: u16 = 2;
                    var niter = vaxis.unicode.graphemeIterator(name);
                    while (niter.next()) |grapheme| {
                        const g = grapheme.bytes(name);
                        const w: u8 = @intCast(ctx.stringWidth(g));
                        if (name_col + w >= max_width - 1) break;
                        surface.writeCell(name_col, row, .{
                            .char = .{ .grapheme = g, .width = w },
                            .style = name_style,
                        });
                        name_col += w;
                    }
                }

                // Bottom border
                const bottom_row: u16 = popup_start + 1 + @as(u16, @intCast(visible));
                surface.writeCell(0, bottom_row, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = border_style });
                surface.writeCell(max_width - 1, bottom_row, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = border_style });
                for (1..@intCast(max_width - 1)) |c| {
                    surface.writeCell(@intCast(c), bottom_row, border_bg);
                }
            }
        }

        return surface;
    }
};
