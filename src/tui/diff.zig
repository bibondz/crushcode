const std = @import("std");
const vaxis = @import("vaxis");

const file_header_style: vaxis.Style = .{ .fg = .{ .index = 14 }, .bold = true };
const hunk_header_style: vaxis.Style = .{ .fg = .{ .index = 14 }, .dim = true };
const removed_style: vaxis.Style = .{ .fg = .{ .index = 9 } };
const added_style: vaxis.Style = .{ .fg = .{ .index = 10 } };
const context_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
const line_number_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };

const HunkHeader = struct {
    old_start: usize,
    new_start: usize,
};

pub fn parseDiff(allocator: std.mem.Allocator, diff_text: []const u8, max_lines: usize) ![]vaxis.Segment {
    const text = normalizeDiffText(diff_text);

    var segments = std.ArrayList(vaxis.Segment).empty;
    errdefer segments.deinit(allocator);

    var total_lines: usize = 0;
    var counter: usize = 0;
    while (nextLine(text, &counter)) |_| total_lines += 1;

    var emitted_lines: usize = 0;
    var cursor: usize = 0;
    var old_line: ?usize = null;
    var new_line: ?usize = null;

    while (nextLine(text, &cursor)) |line| {
        if (emitted_lines >= max_lines) {
            const remaining = total_lines - emitted_lines;
            if (remaining > 0) {
                const message = try std.fmt.allocPrint(allocator, "  ... ({d} more lines, diff truncated)", .{remaining});
                try appendSegment(&segments, allocator, message, context_style);
                try appendSegment(&segments, allocator, "\n", context_style);
            }
            break;
        }

        if (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "+++")) {
            try appendLineNumber(&segments, allocator, null);
            try appendSegment(&segments, allocator, line, file_header_style);
            try appendSegment(&segments, allocator, "\n", file_header_style);
        } else if (parseHunkHeader(line)) |header| {
            old_line = header.old_start;
            new_line = header.new_start;
            try appendLineNumber(&segments, allocator, null);
            try appendSegment(&segments, allocator, line, hunk_header_style);
            try appendSegment(&segments, allocator, "\n", hunk_header_style);
        } else if (line.len > 0 and line[0] == '-' and !std.mem.startsWith(u8, line, "---")) {
            try appendLineNumber(&segments, allocator, old_line);
            try appendSegment(&segments, allocator, line, removed_style);
            try appendSegment(&segments, allocator, "\n", removed_style);
            if (old_line) |value| old_line = value + 1;
        } else if (line.len > 0 and line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
            try appendLineNumber(&segments, allocator, new_line);
            try appendSegment(&segments, allocator, line, added_style);
            try appendSegment(&segments, allocator, "\n", added_style);
            if (new_line) |value| new_line = value + 1;
        } else {
            const line_number = if (line.len > 0 and line[0] == ' ') old_line else null;
            try appendLineNumber(&segments, allocator, line_number);
            try appendSegment(&segments, allocator, line, context_style);
            try appendSegment(&segments, allocator, "\n", context_style);
            if (line.len == 0 or line[0] == ' ') {
                if (old_line) |value| old_line = value + 1;
                if (new_line) |value| new_line = value + 1;
            }
        }

        emitted_lines += 1;
    }

    return segments.toOwnedSlice(allocator);
}

fn normalizeDiffText(diff_text: []const u8) []const u8 {
    var text = std.mem.trim(u8, diff_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "```diff")) return text;

    const first_newline = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    text = text[first_newline + 1 ..];
    text = std.mem.trim(u8, text, " \t\r\n");

    if (std.mem.endsWith(u8, text, "```") and std.mem.lastIndexOf(u8, text, "\n```") != null) {
        const closing = std.mem.lastIndexOf(u8, text, "\n```").?;
        text = text[0..closing];
    } else if (std.mem.eql(u8, text, "```")) {
        return "";
    }

    return std.mem.trim(u8, text, " \t\r\n");
}

fn nextLine(text: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= text.len) return null;

    const line_start = cursor.*;
    const newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
    if (newline) |line_end| {
        cursor.* = line_end + 1;
        return text[line_start..line_end];
    }

    cursor.* = text.len;
    return text[line_start..];
}

fn parseHunkHeader(line: []const u8) ?HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@")) return null;

    var index: usize = 2;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    if (index >= line.len or line[index] != '-') return null;
    index += 1;

    const old_start = parseNumber(line, &index) orelse return null;
    if (index < line.len and line[index] == ',') {
        index += 1;
        _ = parseNumber(line, &index) orelse return null;
    }

    while (index < line.len and line[index] == ' ') : (index += 1) {}
    if (index >= line.len or line[index] != '+') return null;
    index += 1;

    const new_start = parseNumber(line, &index) orelse return null;
    if (index < line.len and line[index] == ',') {
        index += 1;
        _ = parseNumber(line, &index) orelse return null;
    }

    return .{ .old_start = old_start, .new_start = new_start };
}

fn parseNumber(text: []const u8, index: *usize) ?usize {
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {}
    if (index.* == start) return null;
    return std.fmt.parseUnsigned(usize, text[start..index.*], 10) catch null;
}

fn appendLineNumber(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, number: ?usize) !void {
    const text = if (number) |value|
        try std.fmt.allocPrint(allocator, "{d: >4} ", .{value})
    else
        try allocator.dupe(u8, "     ");
    try appendSegment(segments, allocator, text, line_number_style);
}

fn appendSegment(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, style: vaxis.Style) !void {
    if (text.len == 0) return;
    try segments.append(allocator, .{ .text = text, .style = style });
}
