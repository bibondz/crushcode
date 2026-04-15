const std = @import("std");
const vaxis = @import("vaxis");

pub const MarkdownTheme = struct {
    default_fg: vaxis.Color,
    header_fg: vaxis.Color,
    inline_code_fg: vaxis.Color,
    code_bg: vaxis.Color,
    code_fg: vaxis.Color,
    keyword_fg: vaxis.Color,
    string_fg: vaxis.Color,
    comment_fg: vaxis.Color,
    number_fg: vaxis.Color,
    blockquote_fg: vaxis.Color,
    link_fg: vaxis.Color,
    table_border_fg: vaxis.Color,
    task_done_fg: vaxis.Color,
    task_undone_fg: vaxis.Color,
};

pub fn markdownThemeFromAppTheme(theme: *const @import("theme").Theme) MarkdownTheme {
    return .{
        .default_fg = theme.md_default_fg,
        .header_fg = theme.md_header_fg,
        .inline_code_fg = theme.md_inline_code_fg,
        .code_bg = theme.md_code_bg,
        .code_fg = theme.md_code_fg,
        .keyword_fg = theme.md_keyword_fg,
        .string_fg = theme.md_string_fg,
        .comment_fg = theme.md_comment_fg,
        .number_fg = theme.md_number_fg,
        .blockquote_fg = theme.md_blockquote_fg,
        .link_fg = theme.md_link_fg,
        .table_border_fg = theme.md_table_border_fg,
        .task_done_fg = theme.md_task_done_fg,
        .task_undone_fg = theme.md_task_undone_fg,
    };
}

const zig_keywords = [_][]const u8{ "pub", "fn", "const", "var", "try", "return", "if", "else", "switch", "while", "for", "struct", "enum", "error", "defer", "break", "continue" };
const python_keywords = [_][]const u8{ "def", "class", "import", "from", "return", "if", "else", "elif", "for", "while", "try", "except", "with", "async", "await" };
const javascript_keywords = [_][]const u8{ "function", "const", "let", "var", "return", "if", "else", "for", "while", "try", "catch", "async", "await", "import", "export", "class" };
const shell_keywords = [_][]const u8{ "if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function" };

const CodeLanguage = enum {
    plain,
    zig,
    python,
    javascript,
    shell,
};

const TableRow = struct {
    line: []const u8,
    has_newline: bool,
    is_separator: bool,
};

const BlockquoteLine = struct {
    level: usize,
    content: []const u8,
};

const TaskListLine = struct {
    level: usize,
    done: bool,
    content: []const u8,
};

const NestedUnorderedListLine = struct {
    level: usize,
    content: []const u8,
};

const NestedOrderedListLine = struct {
    level: usize,
    prefix: []const u8,
    content: []const u8,
};

const InlineLink = struct {
    label: []const u8,
    end: usize,
};

pub fn parseMarkdown(allocator: std.mem.Allocator, text: []const u8, md_theme: MarkdownTheme) ![]vaxis.Segment {
    // Build styles from theme
    const default_style: vaxis.Style = .{ .fg = md_theme.default_fg };
    const header_style: vaxis.Style = .{ .fg = md_theme.header_fg, .bold = true };
    const inline_code_fg = md_theme.inline_code_fg;
    const code_block_style: vaxis.Style = .{ .fg = md_theme.code_fg, .bg = md_theme.code_bg, .dim = true };
    const code_keyword_style: vaxis.Style = .{ .fg = md_theme.keyword_fg, .bg = md_theme.code_bg, .bold = true };
    const code_string_style: vaxis.Style = .{ .fg = md_theme.string_fg, .bg = md_theme.code_bg };
    const code_comment_style: vaxis.Style = .{ .fg = md_theme.comment_fg, .bg = md_theme.code_bg, .dim = true };
    const code_number_style: vaxis.Style = .{ .fg = md_theme.number_fg, .bg = md_theme.code_bg };
    const blockquote_style: vaxis.Style = .{ .fg = md_theme.blockquote_fg, .dim = true };
    const link_style: vaxis.Style = .{ .fg = md_theme.link_fg };
    const table_border_style: vaxis.Style = .{ .fg = md_theme.table_border_fg, .dim = true };
    const hr_style: vaxis.Style = .{ .fg = md_theme.table_border_fg, .dim = true };
    const task_done_style: vaxis.Style = .{ .fg = md_theme.task_done_fg };
    const task_undone_style: vaxis.Style = .{ .fg = md_theme.task_undone_fg };

    var segments = std.ArrayList(vaxis.Segment).empty;
    errdefer segments.deinit(allocator);

    var line_start: usize = 0;
    var in_code_block = false;
    var emitted_code_language = false;
    var code_language: []const u8 = "";
    var code_language_kind: CodeLanguage = .plain;

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
                code_language_kind = .plain;
            } else {
                if (!emitted_code_language and code_language.len > 0) {
                    try appendSegment(&segments, allocator, code_language, code_block_style);
                    try appendNewline(&segments, allocator, true, code_block_style);
                    emitted_code_language = true;
                }

                if (code_language_kind == .plain) {
                    try appendSegment(&segments, allocator, line, code_block_style);
                } else {
                    try appendHighlightedCodeLine(&segments, allocator, line, code_language_kind, code_block_style, code_keyword_style, code_string_style, code_comment_style, code_number_style);
                }
                try appendNewline(&segments, allocator, has_newline, code_block_style);
            }
        } else if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = true;
            emitted_code_language = false;
            code_language = std.mem.trim(u8, line[3..], " \t");
            code_language_kind = parseCodeLanguage(code_language);
        } else if (isTableLine(line)) {
            line_start = try parseTableBlock(&segments, allocator, text, line_start, default_style, header_style, table_border_style);
            continue;
        } else if (parseBlockquoteLine(line)) |quote| {
            try appendIndent(&segments, allocator, quote.level, "┃ ", blockquote_style);
            try appendInline(&segments, allocator, quote.content, blockquote_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, blockquote_style);
        } else if (parseHorizontalRuleLine(line)) |rule_width| {
            try appendRepeatedLiteral(&segments, allocator, "─", rule_width, hr_style);
            try appendNewline(&segments, allocator, has_newline, hr_style);
        } else if (parseHeaderLine(line)) |header| {
            // Visual differentiation by header level
            const prefix: []const u8 = switch (header.level) {
                1 => "▓ ",
                2 => "▒ ",
                3 => "░ ",
                4 => "▸ ",
                5 => "◦ ",
                6 => "· ",
                else => "",
            };
            try appendSegment(&segments, allocator, prefix, header_style);
            try appendInline(&segments, allocator, header.content, header_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, header_style);
        } else if (parseTaskListLine(line)) |task| {
            try appendIndent(&segments, allocator, task.level, "  ", default_style);
            try appendSegment(&segments, allocator, if (task.done) "☑ " else "☐ ", if (task.done) task_done_style else task_undone_style);
            try appendInline(&segments, allocator, task.content, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else if (parseNestedUnorderedListLine(line)) |nested| {
            try appendIndent(&segments, allocator, nested.level, "  ", default_style);
            try appendSegment(&segments, allocator, "• ", default_style);
            try appendInline(&segments, allocator, nested.content, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else if (parseNestedOrderedListLine(line)) |nested| {
            try appendIndent(&segments, allocator, nested.level, "  ", default_style);
            try appendSegment(&segments, allocator, nested.prefix, default_style);
            try appendInline(&segments, allocator, nested.content, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else if (parseUnorderedListLine(line)) |item| {
            try appendSegment(&segments, allocator, "• ", default_style);
            try appendInline(&segments, allocator, item, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else if (parseOrderedListLine(line)) |ordered| {
            try appendSegment(&segments, allocator, ordered.prefix, default_style);
            try appendInline(&segments, allocator, ordered.content, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        } else {
            try appendInline(&segments, allocator, line, default_style, inline_code_fg, link_style);
            try appendNewline(&segments, allocator, has_newline, default_style);
        }

        if (!has_newline) break;
        line_start = line_end + 1;
    }

    return segments.toOwnedSlice(allocator);
}

fn appendInline(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, base_style: vaxis.Style, inline_code_fg: vaxis.Color, link_sty: vaxis.Style) !void {
    var cursor: usize = 0;
    var plain_start: usize = 0;

    while (cursor < text.len) {
        if (text[cursor] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, cursor + 1, '`')) |end| {
                try appendPlainRange(segments, allocator, text, plain_start, cursor, base_style);
                try appendSegment(segments, allocator, text[cursor + 1 .. end], mergeStyle(base_style, .{ .fg = inline_code_fg }));
                cursor = end + 1;
                plain_start = cursor;
                continue;
            }
        }

        if (parseInlineLink(text, cursor)) |link| {
            try appendPlainRange(segments, allocator, text, plain_start, cursor, base_style);
            try appendInline(segments, allocator, link.label, mergeStyle(base_style, link_sty), inline_code_fg, link_sty);
            cursor = link.end;
            plain_start = cursor;
            continue;
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

fn appendHighlightedCodeLine(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, line: []const u8, language: CodeLanguage, code_block_sty: vaxis.Style, code_keyword_sty: vaxis.Style, code_string_sty: vaxis.Style, code_comment_sty: vaxis.Style, code_number_sty: vaxis.Style) !void {
    var cursor: usize = 0;
    var plain_start: usize = 0;

    while (cursor < line.len) {
        if (isCommentStart(line, cursor)) {
            try appendPlainRange(segments, allocator, line, plain_start, cursor, code_block_sty);
            try appendSegment(segments, allocator, line[cursor..], code_comment_sty);
            return;
        }

        if (isQuote(line[cursor])) {
            const end = consumeString(line, cursor);
            try appendPlainRange(segments, allocator, line, plain_start, cursor, code_block_sty);
            try appendSegment(segments, allocator, line[cursor..end], code_string_sty);
            cursor = end;
            plain_start = cursor;
            continue;
        }

        if (isNumberStart(line, cursor)) {
            const end = consumeNumber(line, cursor);
            try appendPlainRange(segments, allocator, line, plain_start, cursor, code_block_sty);
            try appendSegment(segments, allocator, line[cursor..end], code_number_sty);
            cursor = end;
            plain_start = cursor;
            continue;
        }

        if (isIdentifierStart(line[cursor])) {
            const end = consumeIdentifier(line, cursor);
            const token = line[cursor..end];
            if (isKeyword(language, token)) {
                try appendPlainRange(segments, allocator, line, plain_start, cursor, code_block_sty);
                try appendSegment(segments, allocator, token, code_keyword_sty);
                cursor = end;
                plain_start = cursor;
                continue;
            }

            cursor = end;
            continue;
        }

        cursor += 1;
    }

    try appendPlainRange(segments, allocator, line, plain_start, line.len, code_block_sty);
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

fn appendIndent(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, level: usize, unit: []const u8, style: vaxis.Style) !void {
    var index: usize = 0;
    while (index < level) : (index += 1) {
        try appendSegment(segments, allocator, unit, style);
    }
}

fn appendRepeatedLiteral(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, literal: []const u8, count: usize, style: vaxis.Style) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        try appendSegment(segments, allocator, literal, style);
    }
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

fn parseTableBlock(segments: *std.ArrayList(vaxis.Segment), allocator: std.mem.Allocator, text: []const u8, block_start: usize, default_sty: vaxis.Style, header_sty: vaxis.Style, table_border_sty: vaxis.Style) !usize {
    var rows = std.ArrayList(TableRow).empty;
    defer rows.deinit(allocator);

    var position = block_start;
    while (position <= text.len) {
        const maybe_newline = std.mem.indexOfScalarPos(u8, text, position, '\n');
        const line_end = maybe_newline orelse text.len;
        const line = text[position..line_end];
        if (!isTableLine(line)) break;

        try rows.append(allocator, .{
            .line = line,
            .has_newline = maybe_newline != null,
            .is_separator = isTableSeparatorLine(line),
        });

        if (maybe_newline == null) {
            position = text.len + 1;
            break;
        }
        position = line_end + 1;
    }

    var max_columns: usize = 0;
    for (rows.items) |row| {
        max_columns = @max(max_columns, countTableCells(row.line));
    }
    if (max_columns == 0) return position;

    const widths = try allocator.alloc(usize, max_columns);
    defer allocator.free(widths);
    @memset(widths, 0);

    for (rows.items) |row| {
        if (row.is_separator) continue;

        var column: usize = 0;
        while (column < max_columns) : (column += 1) {
            const cell = tableCellAt(row.line, column) orelse "";
            widths[column] = @max(widths[column], inlineDisplayWidth(cell));
        }
    }

    const has_header = rows.items.len > 1 and !rows.items[0].is_separator and rows.items[1].is_separator;

    for (rows.items, 0..) |row, row_index| {
        if (row.is_separator) {
            try appendSegment(segments, allocator, "│", table_border_sty);

            var column: usize = 0;
            while (column < max_columns) : (column += 1) {
                try appendRepeatedLiteral(segments, allocator, "─", widths[column] + 2, table_border_sty);
                try appendSegment(segments, allocator, "│", table_border_sty);
            }

            try appendNewline(segments, allocator, row.has_newline, table_border_sty);
            continue;
        }

        const row_style = if (has_header and row_index == 0) header_sty else default_sty;
        try appendSegment(segments, allocator, "│ ", table_border_sty);

        var column: usize = 0;
        while (column < max_columns) : (column += 1) {
            const cell = tableCellAt(row.line, column) orelse "";
            try appendInline(segments, allocator, cell, row_style, row_style.fg, .{ .fg = row_style.fg });
            try appendRepeatedLiteral(segments, allocator, " ", widths[column] - inlineDisplayWidth(cell), row_style);

            if (column + 1 < max_columns) {
                try appendSegment(segments, allocator, " │ ", table_border_sty);
            } else {
                try appendSegment(segments, allocator, " │", table_border_sty);
            }
        }

        try appendNewline(segments, allocator, row.has_newline, row_style);
    }

    return position;
}

fn isTableLine(line: []const u8) bool {
    return line.len > 0 and line[0] == '|';
}

fn trimTableLine(line: []const u8) []const u8 {
    if (line.len == 0) return line;

    var start: usize = 0;
    var end = line.len;
    if (line[start] == '|') start += 1;
    if (end > start and line[end - 1] == '|') end -= 1;
    return line[start..end];
}

fn countTableCells(line: []const u8) usize {
    const trimmed = trimTableLine(line);
    if (trimmed.len == 0) return 1;

    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, trimmed, '|');
    while (iterator.next()) |_| {
        count += 1;
    }
    return count;
}

fn tableCellAt(line: []const u8, target_index: usize) ?[]const u8 {
    const trimmed = trimTableLine(line);
    if (trimmed.len == 0) return if (target_index == 0) "" else null;

    var index: usize = 0;
    var iterator = std.mem.splitScalar(u8, trimmed, '|');
    while (iterator.next()) |cell| : (index += 1) {
        if (index == target_index) {
            return std.mem.trim(u8, cell, " \t");
        }
    }
    return null;
}

fn isTableSeparatorLine(line: []const u8) bool {
    const trimmed = trimTableLine(line);
    if (trimmed.len == 0) return false;

    var found_cell = false;
    var iterator = std.mem.splitScalar(u8, trimmed, '|');
    while (iterator.next()) |cell| {
        const part = std.mem.trim(u8, cell, " \t");
        if (part.len < 3) return false;
        for (part) |char| {
            if (char != '-') return false;
        }
        found_cell = true;
    }
    return found_cell;
}

fn inlineDisplayWidth(text: []const u8) usize {
    var cursor: usize = 0;
    var plain_start: usize = 0;
    var width: usize = 0;

    while (cursor < text.len) {
        if (text[cursor] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, cursor + 1, '`')) |end| {
                width += cursor - plain_start;
                width += end - (cursor + 1);
                cursor = end + 1;
                plain_start = cursor;
                continue;
            }
        }

        if (parseInlineLink(text, cursor)) |link| {
            width += cursor - plain_start;
            width += inlineDisplayWidth(link.label);
            cursor = link.end;
            plain_start = cursor;
            continue;
        }

        if (std.mem.startsWith(u8, text[cursor..], "**")) {
            if (std.mem.indexOfPos(u8, text, cursor + 2, "**")) |end| {
                width += cursor - plain_start;
                width += inlineDisplayWidth(text[cursor + 2 .. end]);
                cursor = end + 2;
                plain_start = cursor;
                continue;
            }
        }

        if (text[cursor] == '*') {
            if (std.mem.indexOfScalarPos(u8, text, cursor + 1, '*')) |end| {
                width += cursor - plain_start;
                width += inlineDisplayWidth(text[cursor + 1 .. end]);
                cursor = end + 1;
                plain_start = cursor;
                continue;
            }
        }

        cursor += 1;
    }

    width += text.len - plain_start;
    return width;
}

fn parseInlineLink(text: []const u8, start: usize) ?InlineLink {
    if (start >= text.len or text[start] != '[') return null;

    const label_end = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;

    const url_end = std.mem.indexOfScalarPos(u8, text, label_end + 2, ')') orelse return null;
    return .{ .label = text[start + 1 .. label_end], .end = url_end + 1 };
}

fn parseCodeLanguage(tag: []const u8) CodeLanguage {
    if (tag.len == 0) return .plain;
    if (std.ascii.eqlIgnoreCase(tag, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(tag, "python") or std.ascii.eqlIgnoreCase(tag, "py")) return .python;
    if (std.ascii.eqlIgnoreCase(tag, "javascript") or std.ascii.eqlIgnoreCase(tag, "js") or std.ascii.eqlIgnoreCase(tag, "typescript") or std.ascii.eqlIgnoreCase(tag, "ts") or std.ascii.eqlIgnoreCase(tag, "jsx") or std.ascii.eqlIgnoreCase(tag, "tsx")) return .javascript;
    if (std.ascii.eqlIgnoreCase(tag, "shell") or std.ascii.eqlIgnoreCase(tag, "bash") or std.ascii.eqlIgnoreCase(tag, "sh") or std.ascii.eqlIgnoreCase(tag, "zsh")) return .shell;
    return .plain;
}

fn isKeyword(language: CodeLanguage, token: []const u8) bool {
    const keywords = switch (language) {
        .zig => zig_keywords[0..],
        .python => python_keywords[0..],
        .javascript => javascript_keywords[0..],
        .shell => shell_keywords[0..],
        .plain => return false,
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn isCommentStart(line: []const u8, index: usize) bool {
    if (line[index] == '#') return true;
    return index + 1 < line.len and line[index] == '/' and line[index + 1] == '/';
}

fn isQuote(char: u8) bool {
    return char == '\'' or char == '"' or char == '`';
}

fn isIdentifierStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_';
}

fn isIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn isNumberStart(line: []const u8, index: usize) bool {
    if (!std.ascii.isDigit(line[index])) return false;
    if (index == 0) return true;
    return !isIdentifierChar(line[index - 1]);
}

fn consumeString(line: []const u8, start: usize) usize {
    const quote = line[start];
    var index = start + 1;

    while (index < line.len) : (index += 1) {
        if (line[index] == '\\' and index + 1 < line.len) {
            index += 1;
            continue;
        }
        if (line[index] == quote) return index + 1;
    }

    return line.len;
}

fn consumeNumber(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len and (std.ascii.isDigit(line[index]) or line[index] == '_' or line[index] == '.')) : (index += 1) {}
    return index;
}

fn consumeIdentifier(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len and isIdentifierChar(line[index])) : (index += 1) {}
    return index;
}

const HeaderLine = struct {
    level: usize,
    content: []const u8,
};

fn parseHeaderLine(line: []const u8) ?HeaderLine {
    if (line.len < 2 or line[0] != '#') return null;
    var level: usize = 0;
    var idx: usize = 0;
    while (idx < line.len and idx < 6 and line[idx] == '#') {
        level += 1;
        idx += 1;
    }
    if (idx >= line.len or line[idx] != ' ') return null;
    return .{ .level = level, .content = std.mem.trimLeft(u8, line[idx + 1 ..], " ") };
}

fn parseBlockquoteLine(line: []const u8) ?BlockquoteLine {
    if (line.len == 0 or line[0] != '>') return null;

    var index: usize = 0;
    var level: usize = 0;
    while (index < line.len and line[index] == '>') {
        level += 1;
        index += 1;
        if (index < line.len and line[index] == ' ') index += 1;
    }

    if (level == 0) return null;
    return .{ .level = level, .content = std.mem.trimLeft(u8, line[index..], " ") };
}

fn parseHorizontalRuleLine(line: []const u8) ?usize {
    const trimmed = std.mem.trimRight(u8, line, " \t");
    if (trimmed.len < 3) return null;

    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return null;

    for (trimmed) |char| {
        if (char != marker) return null;
    }
    return trimmed.len;
}

fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn parseTaskListLine(line: []const u8) ?TaskListLine {
    const leading_spaces = countLeadingSpaces(line);
    const trimmed = line[leading_spaces..];
    if (trimmed.len < 6) return null;
    if (trimmed[0] != '-' or trimmed[1] != ' ' or trimmed[2] != '[' or trimmed[4] != ']' or trimmed[5] != ' ') return null;

    const state = trimmed[3];
    if (state != 'x' and state != 'X' and state != ' ') return null;

    return .{
        .level = leading_spaces / 2,
        .done = state == 'x' or state == 'X',
        .content = trimmed[6..],
    };
}

fn parseNestedUnorderedListLine(line: []const u8) ?NestedUnorderedListLine {
    const leading_spaces = countLeadingSpaces(line);
    if (leading_spaces < 2) return null;

    const trimmed = line[leading_spaces..];
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
        return .{ .level = leading_spaces / 2, .content = trimmed[2..] };
    }
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

fn parseNestedOrderedListLine(line: []const u8) ?NestedOrderedListLine {
    const leading_spaces = countLeadingSpaces(line);
    if (leading_spaces < 2) return null;

    const trimmed = line[leading_spaces..];
    const ordered = parseOrderedListLine(trimmed) orelse return null;
    return .{ .level = leading_spaces / 2, .prefix = ordered.prefix, .content = ordered.content };
}
