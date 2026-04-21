const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme_mod = @import("theme");
const widget_helpers = @import("widget_helpers");
const myers = @import("myers");

const drawBorder = widget_helpers.drawBorder;

/// Decision state for each hunk in the preview.
pub const HunkDecision = enum { pending, applied, rejected };

/// Data context fed from chat_tui_app into the widget.
/// The caller (chat_tui_app) owns the decisions slice and mutates it
/// based on key events handled in Model.update().
pub const DiffPreviewContext = struct {
    hunks: []const myers.DiffHunk,
    file_path: []const u8,
    tool_name: []const u8,
    theme: *const theme_mod.Theme,
    current_hunk: usize = 0,
    decisions: []HunkDecision,
    completed: bool = false,
};

/// A pure-display vxfw widget that renders a single Myers diff hunk
/// with apply/reject status indicators. Key handling is done externally
/// in chat_tui_app.zig Model.update().
pub const DiffPreviewWidget = struct {
    context: *DiffPreviewContext,

    pub fn widget(self: *const DiffPreviewWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const DiffPreviewWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const DiffPreviewWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const cx = self.context;
        const theme = cx.theme;

        // Edge case: no hunks
        if (cx.hunks.len == 0) {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        }

        // Clamp current_hunk into valid range
        const hunk_idx = @min(cx.current_hunk, cx.hunks.len - 1);
        const hunk = cx.hunks[hunk_idx];
        const total_hunks = cx.hunks.len;
        const decision = if (hunk_idx < cx.decisions.len) cx.decisions[hunk_idx] else HunkDecision.pending;

        // Calculate layout dimensions — same pattern as permission.zig
        const max = widget_helpers.maxOrFallback(ctx, 80, 24);
        var width: u16 = @min(max.width -| 4, @as(u16, 84));
        if (width < 36) width = @min(max.width, @as(u16, 36));
        if (width == 0) width = max.width;
        const inner_width = width -| 4;

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);

        var current_row: u16 = 1;

        // ─── Header: file path + hunk counter ───
        const title_text = try std.fmt.allocPrint(ctx.arena, "Edit Preview: {s}", .{cx.file_path});
        const hunk_counter = try std.fmt.allocPrint(ctx.arena, "Hunk {d}/{d}", .{ hunk_idx + 1, total_hunks });

        const header_segments = &[_]vaxis.Segment{
            .{ .text = title_text, .style = .{ .fg = theme.header_fg, .bold = true } },
            .{ .text = "  ", .style = .{} },
            .{ .text = hunk_counter, .style = .{ .fg = theme.dimmed } },
        };
        const header_rich = vxfw.RichText{
            .text = header_segments,
            .softwrap = false,
            .width_basis = .parent,
        };
        const header_surf = try header_rich.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = header_surf });
        current_row += 2;

        // ─── Stats line: adds/dels for this hunk + decision badge ───
        var adds: usize = 0;
        var dels: usize = 0;
        for (hunk.lines) |line| {
            switch (line.kind) {
                .insert => adds += 1,
                .delete => dels += 1,
                .equal => {},
            }
        }

        const badge_text: []const u8 = switch (decision) {
            .applied => " [APPLIED]",
            .rejected => " [REJECTED]",
            .pending => "",
        };
        const badge_fg: vaxis.Color = switch (decision) {
            .applied => theme.tool_success,
            .rejected => theme.tool_error,
            .pending => theme.dimmed,
        };

        const stats_text = try std.fmt.allocPrint(ctx.arena, "+{d} additions, -{d} deletions", .{ adds, dels });
        const stats_rich = if (decision != .pending)
            vxfw.RichText{
                .text = &[_]vaxis.Segment{
                    .{ .text = stats_text, .style = .{ .fg = theme.dimmed } },
                    .{ .text = badge_text, .style = .{ .fg = badge_fg, .bold = true } },
                },
                .softwrap = false,
                .width_basis = .parent,
            }
        else
            vxfw.RichText{
                .text = &[_]vaxis.Segment{
                    .{ .text = stats_text, .style = .{ .fg = theme.dimmed } },
                },
                .softwrap = false,
                .width_basis = .parent,
            };

        const stats_surf = try stats_rich.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = stats_surf });
        current_row += 2;

        // ─── Diff lines with color coding ───
        // Use theme diff colors directly (same values as diffThemeFromAppTheme returns)
        const insert_style: vaxis.Style = .{ .fg = theme.diff_added_fg };
        const delete_style: vaxis.Style = .{ .fg = theme.diff_removed_fg };
        const context_style: vaxis.Style = .{ .fg = theme.diff_context_fg, .dim = true };
        const line_num_style: vaxis.Style = .{ .fg = theme.diff_context_fg, .dim = true };

        // Cap visible lines to avoid overflowing the widget
        const max_visible_lines: u16 = @min(@as(u16, 15), max.height -| 10);
        var lines_drawn: u16 = 0;

        for (hunk.lines) |line| {
            if (lines_drawn >= max_visible_lines) {
                const remaining = hunk.lines.len - @as(usize, lines_drawn);
                const truncation = try std.fmt.allocPrint(ctx.arena, "  ... ({d} more lines)", .{remaining});
                const trunc_text = vxfw.Text{
                    .text = truncation,
                    .style = context_style,
                    .softwrap = false,
                    .width_basis = .parent,
                };
                const trunc_surf = try trunc_text.draw(ctx.withConstraints(
                    .{ .width = inner_width, .height = 1 },
                    .{ .width = inner_width, .height = 1 },
                ));
                try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = trunc_surf });
                current_row += 1;
                break;
            }

            // Pick line number: new for inserts, old for deletes, old for equal
            const line_num: ?u32 = switch (line.kind) {
                .insert => line.new_line_num,
                .delete => line.old_line_num,
                .equal => line.old_line_num,
            };
            const num_str = if (line_num) |n|
                try std.fmt.allocPrint(ctx.arena, "{d: >4}", .{n})
            else
                "    ";

            const prefix: []const u8 = switch (line.kind) {
                .insert => "+",
                .delete => "-",
                .equal => " ",
            };
            const line_style: vaxis.Style = switch (line.kind) {
                .insert => insert_style,
                .delete => delete_style,
                .equal => context_style,
            };

            // Build segments: line_num (dim) | prefix + content (colored by kind)
            const line_segments = &[_]vaxis.Segment{
                .{ .text = num_str, .style = line_num_style },
                .{ .text = " ", .style = line_num_style },
                .{ .text = prefix, .style = line_style },
                .{ .text = line.content, .style = line_style },
            };
            const line_rich = vxfw.RichText{
                .text = line_segments,
                .softwrap = false,
                .width_basis = .parent,
            };
            const line_surf = try line_rich.draw(ctx.withConstraints(
                .{ .width = inner_width, .height = 1 },
                .{ .width = inner_width, .height = 1 },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = line_surf });
            current_row += 1;
            lines_drawn += 1;
        }

        current_row += 1; // blank line before footer

        // ─── Footer: key hints with colored segments ───
        const footer_segments = &[_]vaxis.Segment{
            .{ .text = "[y] Apply  ", .style = .{ .fg = theme.tool_success, .bold = true } },
            .{ .text = "[n] Reject  ", .style = .{ .fg = theme.tool_error, .bold = true } },
            .{ .text = "[a] Apply All  ", .style = .{ .fg = theme.header_fg, .bold = true } },
            .{ .text = "[q] Reject All", .style = .{ .fg = theme.dimmed, .bold = true } },
        };
        const footer_rich = vxfw.RichText{
            .text = footer_segments,
            .softwrap = false,
            .width_basis = .parent,
        };
        const footer_surf = try footer_rich.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = footer_surf });
        current_row += 1;

        // ─── Summary line: applied/rejected/remaining counts ───
        var applied_count: usize = 0;
        var rejected_count: usize = 0;
        var pending_count: usize = 0;
        for (cx.decisions) |d| {
            switch (d) {
                .applied => applied_count += 1,
                .rejected => rejected_count += 1,
                .pending => pending_count += 1,
            }
        }
        const summary_text = try std.fmt.allocPrint(ctx.arena, "Applied: {d}  Rejected: {d}  Remaining: {d}", .{ applied_count, rejected_count, pending_count });
        const summary_widget = vxfw.Text{
            .text = summary_text,
            .style = .{ .fg = theme.dimmed },
            .softwrap = false,
            .width_basis = .parent,
        };
        const summary_surf = try summary_widget.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 1 },
            .{ .width = inner_width, .height = 1 },
        ));
        try child_list.append(ctx.arena, .{ .origin = .{ .row = current_row, .col = 2 }, .surface = summary_surf });
        current_row += 1;

        // ─── Compose final surface with border ───
        const height: u16 = current_row + 1;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        @memset(surface.buffer, .{ .style = .{ .bg = theme.code_bg } });
        drawBorder(&surface, .{ .fg = theme.tool_pending });

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
