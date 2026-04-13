const std = @import("std");
const file_compat = @import("file_compat");
const color_mod = @import("color");
const array_list_compat = @import("array_list_compat");

const Style = color_mod.Style;
const Color = color_mod.Color;

/// Error severity level for display.
pub const ErrorLevel = enum {
    err,
    warning,
    info,

    fn label(self: ErrorLevel) []const u8 {
        return switch (self) {
            .err => "Error",
            .warning => "Warning",
            .info => "Info",
        };
    }

    fn labelStyle(self: ErrorLevel) Style {
        return switch (self) {
            .err => Style{ .fg = .red, .bold = true },
            .warning => Style{ .fg = .yellow, .bold = true },
            .info => Style{ .fg = .cyan },
        };
    }

    fn borderStyle(self: ErrorLevel) Style {
        return switch (self) {
            .err => Style{ .fg = .red },
            .warning => Style{ .fg = .yellow },
            .info => Style{ .fg = .cyan },
        };
    }

    fn messageStyle(self: ErrorLevel) Style {
        return switch (self) {
            .err => Style{},
            .warning => Style{},
            .info => Style{ .dim = true },
        };
    }
};

/// Print a boxed error/warning/info message to stdout.
/// Output format:
///   ╭─ Error: Title ───────────────╮
///   │ Message line 1                │
///   │ Message line 2                │
///   ╰──────────────────────────────╯
pub fn printBoxed(level: ErrorLevel, title: []const u8, message: []const u8) void {
    const stdout = file_compat.File.stdout().writer();
    const max_width: usize = 60;

    // Split message into lines
    var lines = array_list_compat.ArrayList([]const u8).init(std.heap.page_allocator);
    defer lines.deinit();
    var pos: usize = 0;
    while (pos < message.len) {
        const eol = if (std.mem.indexOfScalar(u8, message[pos..], '\n')) |i| pos + i else message.len;
        const line = message[pos..eol];
        // Word-wrap long lines
        if (line.len <= max_width - 4) {
            lines.append(line) catch break;
        } else {
            // Simple word-wrap
            var wrap_pos: usize = 0;
            while (wrap_pos < line.len) {
                const remaining = line[wrap_pos..];
                const end_pos = if (remaining.len > max_width - 4) max_width - 4 else remaining.len;
                if (end_pos >= remaining.len) {
                    lines.append(remaining) catch break;
                    break;
                }
                // Find last space before end_pos
                var break_at: usize = end_pos;
                while (break_at > 0 and remaining[break_at] != ' ') : (break_at -= 1) {}
                if (break_at == 0) break_at = end_pos; // no space found, hard break
                lines.append(remaining[0..break_at]) catch break;
                wrap_pos += break_at;
                if (wrap_pos < line.len and line[wrap_pos] == ' ') wrap_pos += 1;
            }
        }
        pos = eol + 1;
    }

    // Calculate box width
    const title_text = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}", .{ level.label(), title }) catch title;
    defer if (title_text.ptr != title.ptr) std.heap.page_allocator.free(title_text);
    const header_len = title_text.len + 4; // "╭─ " + " ─" + "╮" = +4
    var content_width: usize = header_len;
    for (lines.items) |line| {
        if (line.len + 4 > content_width) content_width = line.len + 4;
    }
    if (content_width > max_width) content_width = max_width;
    // Ensure minimum width for header
    if (content_width < header_len) content_width = header_len;

    // ╭─ Error: Title ─────╮
    const border_start = level.borderStyle();
    stdout.print("\n", .{}) catch {};
    stdout.print("{s}╭─{s} ", .{ border_start.start(), border_start.reset() }) catch {};
    stdout.print("{s}{s}{s}", .{ level.labelStyle().start(), title_text, level.labelStyle().reset() }) catch {};
    // Fill remaining with ─
    const dash_count = if (content_width > header_len) content_width - header_len else 0;
    stdout.print(" ", .{}) catch {};
    for (0..dash_count) |_| {
        stdout.print("{s}─{s}", .{ border_start.start(), border_start.reset() }) catch {};
    }
    stdout.print("{s}╮{s}\n", .{ border_start.start(), border_start.reset() }) catch {};

    // │ message lines
    for (lines.items) |line| {
        stdout.print("{s}│{s} ", .{ border_start.start(), border_start.reset() }) catch {};
        stdout.print("{s}{s}{s}", .{ level.messageStyle().start(), line, level.messageStyle().reset() }) catch {};
        // Pad to content_width
        const padding = if (content_width > line.len + 4) content_width - line.len - 4 else 0;
        for (0..padding) |_| {
            stdout.print(" ", .{}) catch {};
        }
        stdout.print(" {s}│{s}\n", .{ border_start.start(), border_start.reset() }) catch {};
    }

    // ╰────────────────────╯
    stdout.print("{s}╰", .{border_start.start()}) catch {};
    for (0..content_width - 2) |_| {
        stdout.print("─", .{}) catch {};
    }
    stdout.print("╯{s}\n", .{border_start.reset()}) catch {};
}

/// Print a boxed error message.
pub fn printError(title: []const u8, message: []const u8) void {
    printBoxed(.err, title, message);
}

/// Print a boxed warning message.
pub fn printWarning(title: []const u8, message: []const u8) void {
    printBoxed(.warning, title, message);
}

/// Print a boxed info message.
pub fn printInfo(title: []const u8, message: []const u8) void {
    printBoxed(.info, title, message);
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorLevel — label" {
    try std.testing.expectEqualStrings("Error", ErrorLevel.err.label());
    try std.testing.expectEqualStrings("Warning", ErrorLevel.warning.label());
    try std.testing.expectEqualStrings("Info", ErrorLevel.info.label());
}

test "printError — does not crash" {
    printError("Test Error", "This is a test error message");
}

test "printWarning — does not crash" {
    printWarning("Test Warning", "This is a test warning message");
}

test "printInfo — does not crash" {
    printInfo("Test Info", "This is a test info message");
}

test "printBoxed — multiline message" {
    printBoxed(.err, "Multi-line", "Line one\nLine two\nLine three");
}

test "printBoxed — long message wraps" {
    printBoxed(.warning, "Long Message", "This is a very long message that should be wrapped at the terminal width boundary to prevent ugly overflow in the terminal display");
}
