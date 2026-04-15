const std = @import("std");
const vaxis = @import("vaxis");

const file_header_style: vaxis.Style = .{ .fg = .{ .index = 14 }, .bold = true };
const hunk_header_style: vaxis.Style = .{ .fg = .{ .index = 14 }, .dim = true };
const removed_style: vaxis.Style = .{ .fg = .{ .index = 9 } };
const added_style: vaxis.Style = .{ .fg = .{ .index = 10 } };
const context_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
const line_number_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };

/// Highlighted word styles — brighter/underlined for changed words within diff lines.
const removed_word_style: vaxis.Style = .{ .fg = .{ .index = 9 }, .bold = true, .ul_style = .single };
const added_word_style: vaxis.Style = .{ .fg = .{ .index = 10 }, .bold = true, .ul_style = .single };

const HunkHeader = struct {
    old_start: usize,
    new_start: usize,
};

pub fn parseDiff(allocator: std.mem.Allocator, diff_text: []const u8, max_lines: usize) ![]vaxis.Segment {
    const text = normalizeDiffText(diff_text);

    var segments = std.ArrayList(vaxis.Segment).empty;
    errdefer segments.deinit(allocator);

    // Collect all lines first for lookahead
    var all_lines = std.ArrayList([]const u8).empty;
    defer all_lines.deinit(allocator);
    {
        var counter: usize = 0;
        while (nextLine(text, &counter)) |line| {
            try all_lines.append(allocator, line);
        }
    }

    var emitted_lines: usize = 0;
    var old_line: ?usize = null;
    var new_line: ?usize = null;
    var idx: usize = 0;

    while (idx < all_lines.items.len) : (idx += 1) {
        if (emitted_lines >= max_lines) {
            const remaining = all_lines.items.len - emitted_lines;
            if (remaining > 0) {
                const message = try std.fmt.allocPrint(allocator, "  ... ({d} more lines, diff truncated)", .{remaining});
                try appendSegment(&segments, allocator, message, context_style);
                try appendSegment(&segments, allocator, "\n", context_style);
            }
            break;
        }

        const line = all_lines.items[idx];

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
            // Look ahead for a paired '+' line to do word-level diff
            const old_content = line[1..];

            // Consume consecutive '-' lines, then look for '+' lines
            var minus_count: usize = 1;
            var j: usize = idx + 1;
            while (j < all_lines.items.len and all_lines.items[j].len > 0 and all_lines.items[j][0] == '-' and !std.mem.startsWith(u8, all_lines.items[j], "---")) : ({
                j += 1;
                minus_count += 1;
            }) {}
            // Now look for '+' lines
            var plus_count: usize = 0;
            const plus_start = j;
            while (j < all_lines.items.len and all_lines.items[j].len > 0 and all_lines.items[j][0] == '+' and !std.mem.startsWith(u8, all_lines.items[j], "+++")) : ({
                j += 1;
                plus_count += 1;
            }) {}

            // If we have exactly 1:1 pairing, do word-level diff
            if (minus_count == 1 and plus_count >= 1) {
                const plus_line = all_lines.items[plus_start];
                const new_content = plus_line[1..];

                // Word-diff the removed line
                try appendLineNumber(&segments, allocator, old_line);
                try appendWordDiffSegments(&segments, allocator, old_content, removed_style, removed_word_style, "-");
                try appendSegment(&segments, allocator, "\n", removed_style);
                if (old_line) |value| old_line = value + 1;

                // Word-diff the first added line
                try appendLineNumber(&segments, allocator, new_line);
                try appendWordDiffSegments(&segments, allocator, new_content, added_style, added_word_style, "+");
                try appendSegment(&segments, allocator, "\n", added_style);
                if (new_line) |value| new_line = value + 1;

                // Additional '+' lines as regular added
                var k: usize = plus_start + 1;
                while (k < plus_start + plus_count) : (k += 1) {
                    try appendLineNumber(&segments, allocator, new_line);
                    try appendSegment(&segments, allocator, all_lines.items[k], added_style);
                    try appendSegment(&segments, allocator, "\n", added_style);
                    if (new_line) |value| new_line = value + 1;
                }

                emitted_lines += 1 + plus_count;
                idx = plus_start + plus_count - 1; // -1 because loop does idx += 1
                continue;
            }

            // No word-diff pairing — emit normally
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

/// Append word-level diff segments for a single line content.
/// `content` is the line without the +/- prefix.
/// `base_style` is the line-level style (removed or added).
/// `highlight_style` is the style for changed words.
/// `prefix` is "+" or "-" to prepend.
fn appendWordDiffSegments(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, content: []const u8, base_style: vaxis.Style, highlight_style: vaxis.Style, prefix: []const u8) !void {
    // Split content into words (splitting on whitespace)
    // For each word, check if it looks like a changed token
    // Simple heuristic: words that are identifiers, numbers, or strings get highlighted
    // For a basic word-diff: we highlight words that are not common English articles/prepositions
    // and appear to be code tokens (contain _, camelCase, etc.)
    // Simpler approach: just emit prefix + content with highlight on "inner changed" parts
    // by splitting on spaces and highlighting non-whitespace clusters

    try appendSegment(segments, allocator, prefix, base_style);

    if (content.len == 0) return;

    // Emit content character by character, grouping runs of same word-boundary status
    // For word-level diff without a paired comparison, we use a simple heuristic:
    // highlight words that look like identifiers/strings/code tokens
    var i: usize = 0;
    var run_start: usize = 0;
    var in_word = false;

    while (i <= content.len) : (i += 1) {
        const ch: u8 = if (i < content.len) content[i] else ' ';
        const is_word_char = i < content.len and !std.ascii.isWhitespace(ch);

        if (is_word_char != in_word) {
            // Boundary transition — emit the run
            if (i > run_start) {
                const run = content[run_start..i];
                if (in_word) {
                    // Word run — check if it's a highlightable token
                    if (isHighlightableToken(run)) {
                        try appendSegment(segments, allocator, run, highlight_style);
                    } else {
                        try appendSegment(segments, allocator, run, base_style);
                    }
                } else {
                    // Whitespace run
                    try appendSegment(segments, allocator, run, base_style);
                }
            }
            run_start = i;
            in_word = is_word_char;
        }
    }
}

/// Check if a word token should be highlighted in the diff.
/// Simple heuristic: highlight tokens that look like code identifiers,
/// numbers, strings, or operators (not common English words).
fn isHighlightableToken(word: []const u8) bool {
    if (word.len == 0) return false;
    // Single-character tokens: highlight operators
    if (word.len == 1) {
        return switch (word[0]) {
            '{', '}', '(', ')', '[', ']', ';', ':', '=', '<', '>', '!', '+', '-', '*', '/', '&', '|', '^', '%', '~', '?', ',', '.' => true,
            else => false,
        };
    }
    // Numbers
    if (std.ascii.isDigit(word[0])) return true;
    // String literals
    if (word[0] == '"' or word[0] == '\'' or word[0] == '`') return true;
    // Identifiers with underscores or mixed case (camelCase)
    for (word) |ch| {
        if (ch == '_' or std.ascii.isDigit(ch)) return true;
        // Mixed case (camelCase indicator)
        if (ch >= 'A' and ch <= 'Z') return true;
    }
    return false;
}
