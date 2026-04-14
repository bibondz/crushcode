const std = @import("std");
const vaxis = @import("vaxis");

const default_style: vaxis.Style = .{ .fg = .{ .index = 15 } };
const header_style: vaxis.Style = .{ .fg = .{ .index = 15 }, .bold = true };
const inline_code_style: vaxis.Style = .{ .fg = .{ .index = 14 } };
const code_block_style: vaxis.Style = .{ .fg = .{ .index = 14 }, .bg = .{ .index = 236 }, .dim = true };

pub fn parseMarkdown(allocator: std.mem.Allocator, text: []const u8) ![]vaxis.Segment {
    var segments = std.ArrayList(vaxis.Segment).empty;
    errdefer segments.deinit(allocator);

    var line_start: usize = 0;
    var in_code_block = false;
    var emitted_code_language = false;
    var code_language: []const u8 = "";

    while (line_start <= text.len) {
        const maybe_newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = maybe_newline orelse text.len;
        const line = text[line_start..line_end];
        const has_newline = maybe_newline != null;

        if (in_code_block) {
            if (std.mem.startsWith(u8, line, "```")) {
                in_code_block = false;
                emitted_code_language = false;
                code_language = "";
            } else {
                if (!emitted_code_language and code_language.len > 0) {
                    try appendSegment(&segments, allocator, code_language, code_block_style);
                    try appendNewline(&segments, allocator, true, code_block_style);
                    emitted_code_language = true;
                }

                try appendSegment(&segments, allocator, line, code_block_style);
                try appendNewline(&segments, allocator, has_newline, code_block_style);
            }
        } else if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = true;
            emitted_code_language = false;
            code_language = std.mem.trim(u8, line[3..], " \t");
        } else if (parseHeaderLine(line)) |header| {
            try appendSegment(&segments, allocator, header, header_style);
            try appendNewline(&segments, allocator, has_newline, header_style);
        } else if (parseUnorderedListLine(line)) |item| {
            try appendSegment(&segments, allocator, "• ", default_style);
            try appendInline(&segments, allocator, item, default_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else if (parseOrderedListLine(line)) |ordered| {
            try appendSegment(&segments, allocator, ordered.prefix, default_style);
            try appendInline(&segments, allocator, ordered.content, default_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else {
            try appendInline(&segments, allocator, line, default_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        }

        if (!has_newline) break;
        line_start = line_end + 1;
    }

    return segments.toOwnedSlice(allocator);
}

fn appendInline(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, base_style: vaxis.Style) !void {
    var cursor: usize = 0;
    var plain_start: usize = 0;

    while (cursor < text.len) {
        if (text[cursor] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, cursor + 1, '`')) |end| {
                try appendPlainRange(segments, allocator, text, plain_start, cursor, base_style);
                try appendSegment(segments, allocator, text[cursor + 1 .. end], mergeStyle(base_style, .{ .fg = inline_code_style.fg }));
                cursor = end + 1;
                plain_start = cursor;
                continue;
            }
        }

        if (std.mem.startsWith(u8, text[cursor..], "**")) {
            if (std.mem.indexOfPos(u8, text, cursor + 2, "**")) |end| {
                try appendPlainRange(segments, allocator, text, plain_start, cursor, base_style);
                try appendSegment(segments, allocator, text[cursor + 2 .. end], mergeStyle(base_style, .{ .bold = true }));
                cursor = end + 2;
                plain_start = cursor;
                continue;
            }
        }

        if (text[cursor] == '*') {
            if (std.mem.indexOfScalarPos(u8, text, cursor + 1, '*')) |end| {
                try appendPlainRange(segments, allocator, text, plain_start, cursor, base_style);
                try appendSegment(segments, allocator, text[cursor + 1 .. end], mergeStyle(base_style, .{ .italic = true }));
                cursor = end + 1;
                plain_start = cursor;
                continue;
            }
        }

        cursor += 1;
    }

    try appendPlainRange(segments, allocator, text, plain_start, text.len, base_style);
}

fn appendPlainRange(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, start: usize, end: usize, style: vaxis.Style) !void {
    if (end <= start) return;
    try appendSegment(segments, allocator, text[start..end], style);
}

fn appendSegment(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, style: vaxis.Style) !void {
    if (text.len == 0) return;
    try segments.append(allocator, .{ .text = text, .style = style });
}

fn appendNewline(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, enabled: bool, style: vaxis.Style) !void {
    if (!enabled) return;
    try segments.append(allocator, .{ .text = "\n", .style = style });
}

fn mergeStyle(base: vaxis.Style, overlay: vaxis.Style) vaxis.Style {
    var style = base;
    if (overlay.bold) style.bold = true;
    if (overlay.italic) style.italic = true;
    if (overlay.dim) style.dim = true;
    if (!std.meta.eql(overlay.fg, @as(vaxis.Color, .default))) style.fg = overlay.fg;
    if (!std.meta.eql(overlay.bg, @as(vaxis.Color, .default))) style.bg = overlay.bg;
    return style;
}

fn parseHeaderLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "## ")) return std.mem.trimLeft(u8, line[3..], " ");
    if (std.mem.startsWith(u8, line, "# ")) return std.mem.trimLeft(u8, line[2..], " ");
    return null;
}

fn parseUnorderedListLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "- ")) return line[2..];
    if (std.mem.startsWith(u8, line, "* ")) return line[2..];
    return null;
}

const OrderedListLine = struct {
    prefix: []const u8,
    content: []const u8,
};

fn parseOrderedListLine(line: []const u8) ?OrderedListLine {
    var idx: usize = 0;
    while (idx < line.len and std.ascii.isDigit(line[idx])) : (idx += 1) {}
    if (idx == 0 or idx + 1 >= line.len) return null;
    if (line[idx] != '.' or line[idx + 1] != ' ') return null;
    return .{ .prefix = line[0 .. idx + 2], .content = line[idx + 2 ..] };
}
