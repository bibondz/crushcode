const std = @import("std");
const file_compat = @import("file_compat");
const color_mod = @import("color");

const Style = color_mod.Style;

/// Stdout-based markdown renderer — outputs ANSI-styled markdown directly to terminal.
/// No TUI Screen or Scrollback dependency. Uses raw ANSI for inline parsing efficiency.
pub const MarkdownRenderer = struct {
    /// Render a complete markdown text (multi-line) to stdout.
    pub fn render(text: []const u8) void {
        var pos: usize = 0;
        var in_code_block = false;
        while (pos < text.len) {
            const eol = if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |i| pos + i else text.len;
            const line = text[pos..eol];

            // Fenced code block toggle: ``` or ~~~
            if (line.len >= 3 and (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~"))) {
                if (!in_code_block) {
                    // Opening fence — print language tag in dimmed style
                    const stdout = file_compat.File.stdout().writer();
                    const lang = std.mem.trim(u8, line[3..], " \t");
                    if (lang.len > 0) {
                        stdout.print("{s}{s}{s}\n", .{ "\x1b[90m", lang, "\x1b[0m" }) catch {};
                    }
                    in_code_block = true;
                } else {
                    // Closing fence
                    in_code_block = false;
                }
                pos = eol + 1;
                continue;
            }

            if (in_code_block) {
                // Inside code block — print with background color
                const stdout = file_compat.File.stdout().writer();
                stdout.print("{s}{s}{s}\n", .{ "\x1b[48;5;236m\x1b[37m", line, "\x1b[0m" }) catch {};
                pos = eol + 1;
                continue;
            }

            renderLine(line);
            const stdout = file_compat.File.stdout().writer();
            stdout.print("\n", .{}) catch {};
            pos = eol + 1;
        }
    }

    /// Render a single line of markdown to stdout.
    pub fn renderLine(line: []const u8) void {
        if (line.len == 0) return;

        // Headers: # h1, ## h2, ### h3, etc.
        if (line[0] == '#') {
            var level: usize = 0;
            while (level < line.len and level < 6 and line[level] == '#') : (level += 1) {}
            var skip: usize = level;
            // skip optional space after #
            if (skip < line.len and line[skip] == ' ') skip += 1;
            const content = if (skip < line.len) line[skip..] else "";

            const stdout = file_compat.File.stdout().writer();
            // Print header prefix in bright_yellow bold
            stdout.print("{s}", .{"\x1b[93m\x1b[1m"}) catch {};
            for (0..level) |_| {
                stdout.print("#", .{}) catch {};
            }
            stdout.print(" {s}", .{"\x1b[0m"}) catch {};
            // Print content in bold
            stdout.print("{s}", .{"\x1b[1m"}) catch {};
            renderInline(content);
            stdout.print("{s}", .{"\x1b[0m"}) catch {};
            return;
        }

        // Blockquote: > text
        if (line.len >= 2 and line[0] == '>' and line[1] == ' ') {
            const stdout = file_compat.File.stdout().writer();
            stdout.print("{s}▎{s} ", .{ "\x1b[94m", "\x1b[0m" }) catch {};
            renderInline(line[2..]);
            return;
        }

        // Unordered list: - item or * item
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            const stdout = file_compat.File.stdout().writer();
            stdout.print("{s}•{s} ", .{ "\x1b[36m", "\x1b[0m" }) catch {};
            renderInline(line[2..]);
            return;
        }

        // Regular line
        renderInline(line);
    }

    /// Render inline markdown formatting (bold, italic, code) to stdout.
    fn renderInline(text: []const u8) void {
        const stdout = file_compat.File.stdout().writer();
        var i: usize = 0;

        while (i < text.len) {
            // Code span: `...`
            if (text[i] == '`') {
                const end = if (std.mem.indexOfScalar(u8, text[i + 1 ..], '`')) |e| i + 1 + e else null;
                if (end) |e| {
                    stdout.print("{s}", .{"\x1b[91m\x1b[100m"}) catch {};
                    stdout.print("{s}", .{text[i + 1 .. e]}) catch {};
                    stdout.print("{s}", .{"\x1b[0m"}) catch {};
                    i = e + 1;
                    continue;
                }
            }

            // Bold+italic: ***...***
            if (i + 2 < text.len and text[i] == '*' and text[i + 1] == '*' and text[i + 2] == '*') {
                // Find closing ***
                if (findClosing(text, i + 3, "***")) |end| {
                    stdout.print("{s}", .{"\x1b[1m\x1b[3m"}) catch {};
                    renderInline(text[i + 3 .. end]);
                    stdout.print("{s}", .{"\x1b[0m"}) catch {};
                    i = end + 3;
                    continue;
                }
            }

            // Bold: **...**
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
                if (findClosing(text, i + 2, "**")) |end| {
                    stdout.print("{s}", .{"\x1b[1m"}) catch {};
                    renderInline(text[i + 2 .. end]);
                    stdout.print("{s}", .{"\x1b[0m"}) catch {};
                    i = end + 2;
                    continue;
                }
            }

            // Italic: *...*
            if (text[i] == '*') {
                if (findClosing(text, i + 1, "*")) |end| {
                    stdout.print("{s}", .{"\x1b[3m"}) catch {};
                    renderInline(text[i + 1 .. end]);
                    stdout.print("{s}", .{"\x1b[0m"}) catch {};
                    i = end + 1;
                    continue;
                }
            }

            // Regular character — just print it
            stdout.print("{c}", .{text[i]}) catch {};
            i += 1;
        }
    }

    /// Find the closing delimiter in text starting from `start`.
    fn findClosing(text: []const u8, start: usize, delimiter: []const u8) ?usize {
        var i: usize = start;
        while (i + delimiter.len <= text.len) {
            if (std.mem.eql(u8, text[i .. i + delimiter.len], delimiter)) {
                return i;
            }
            i += 1;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MarkdownRenderer — render plain text" {
    // Just verify it doesn't crash — output goes to stdout
    MarkdownRenderer.render("Hello world");
}

test "MarkdownRenderer — render header" {
    MarkdownRenderer.renderLine("# Title");
}

test "MarkdownRenderer — render bold" {
    MarkdownRenderer.renderLine("normal **bold** text");
}

test "MarkdownRenderer — render italic" {
    MarkdownRenderer.renderLine("normal *italic* text");
}

test "MarkdownRenderer — render code" {
    MarkdownRenderer.renderLine("use `std.testing` here");
}

test "MarkdownRenderer — render list" {
    MarkdownRenderer.renderLine("- Item one");
}

test "MarkdownRenderer — render blockquote" {
    MarkdownRenderer.renderLine("> Quote text");
}

test "MarkdownRenderer — findClosing finds delimiter" {
    const result = MarkdownRenderer.findClosing("hello**world", 0, "**");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?);
}

test "MarkdownRenderer — findClosing returns null when missing" {
    const result = MarkdownRenderer.findClosing("hello world", 0, "**");
    try std.testing.expect(result == null);
}
