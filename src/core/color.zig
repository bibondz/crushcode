const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Typed color specification system — replaces raw ANSI escape codes
/// with composable, type-safe styles.
///
/// Usage:
///   const s = Style{ .fg = .cyan, .bold = true };
///   print("{s}Hello{s}", .{ s.start(), s.reset() });
///
/// Reference: ripgrep typed color specs (F22)
pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    default,

    pub fn ansiCode(self: Color) []const u8 {
        return switch (self) {
            .black => "30",
            .red => "31",
            .green => "32",
            .yellow => "33",
            .blue => "34",
            .magenta => "35",
            .cyan => "36",
            .white => "37",
            .bright_black => "90",
            .bright_red => "91",
            .bright_green => "92",
            .bright_yellow => "93",
            .bright_blue => "94",
            .bright_magenta => "95",
            .bright_cyan => "96",
            .bright_white => "97",
            .default => "39",
        };
    }
};

/// A composable text style with foreground, background, and attributes
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    /// Predefined styles for common CLI output patterns
    pub const success = Style{ .fg = .bright_green, .bold = true };
    pub const err = Style{ .fg = .bright_red, .bold = true };
    pub const warning = Style{ .fg = .bright_yellow };
    pub const info = Style{ .fg = .bright_blue };
    pub const dimmed = Style{ .fg = .bright_black };
    pub const heading = Style{ .fg = .bright_cyan, .bold = true };
    pub const muted = Style{ .fg = .bright_black };
    pub const accent = Style{ .fg = .bright_magenta };
    pub const highlight = Style{ .fg = .bright_yellow, .bold = true };
    pub const prompt_user = Style{ .fg = .bright_cyan, .bold = true };
    pub const prompt_assistant = Style{ .fg = .bright_green, .bold = true };
    pub const permission_denied = Style{ .fg = .red };
    pub const permission_request = Style{ .fg = .yellow };
    pub const permission_allowed = Style{ .dim = true };
    pub const hook_info = Style{ .dim = true };
    pub const token_info = Style{ .dim = true };

    /// Get the ANSI start sequence for this style
    pub fn start(self: Style) []const u8 {
        // These are comptime-known strings stored in the binary's data section
        if (self.bold and self.dim) {
            return switch (self.fg) {
                .default => "\x1b[1;2m",
                .red => "\x1b[1;2;31m",
                .green => "\x1b[1;2;32m",
                .yellow => "\x1b[1;2;33m",
                .cyan => "\x1b[1;2;36m",
                else => "\x1b[1;2m",
            };
        }
        if (self.bold) {
            return switch (self.fg) {
                .default => "\x1b[1m",
                .red => "\x1b[1;31m",
                .green => "\x1b[1;32m",
                .yellow => "\x1b[1;33m",
                .blue => "\x1b[1;34m",
                .magenta => "\x1b[1;35m",
                .cyan => "\x1b[1;36m",
                .white => "\x1b[1;37m",
                .bright_red => "\x1b[1;91m",
                .bright_green => "\x1b[1;92m",
                .bright_yellow => "\x1b[1;93m",
                .bright_cyan => "\x1b[1;96m",
                else => "\x1b[1m",
            };
        }
        if (self.dim) {
            return switch (self.fg) {
                .default => "\x1b[2m",
                .red => "\x1b[2;31m",
                .green => "\x1b[2;32m",
                .yellow => "\x1b[2;33m",
                .cyan => "\x1b[2;36m",
                else => "\x1b[2m",
            };
        }
        return switch (self.fg) {
            .default => "",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }

    /// Get the ANSI reset sequence
    pub fn reset(self: Style) []const u8 {
        _ = self;
        return "\x1b[0m";
    }

    /// Apply style to text, returning an allocated string
    pub fn format(self: Style, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        const s = self.start();
        const r = self.reset();
        if (s.len == 0) return allocator.dupe(u8, text);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ s, text, r });
    }
};

/// Convenience function: style a string slice for inline use in format strings
/// Example: std.debug.print("{s}Error:{s} something broke\n", .{ Style.err.start(), Style.err.reset() });
/// But simpler: use Style.start() and Style.reset() directly in format args

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Color - ansiCode returns valid codes" {
    try testing.expectEqualStrings("31", Color.red.ansiCode());
    try testing.expectEqualStrings("32", Color.green.ansiCode());
    try testing.expectEqualStrings("36", Color.cyan.ansiCode());
    try testing.expectEqualStrings("33", Color.yellow.ansiCode());
    try testing.expectEqualStrings("39", Color.default.ansiCode());
}

test "Style - start returns empty for default" {
    const s = Style{ .fg = .default };
    try testing.expectEqualStrings("", s.start());
}

test "Style - start returns correct ANSI for basic colors" {
    try testing.expectEqualStrings("\x1b[31m", Style.err.start());
    try testing.expectEqualStrings("\x1b[32m", Style.success.start());
    try testing.expectEqualStrings("\x1b[33m", Style.warning.start());
    try testing.expectEqualStrings("\x1b[36m", Style.info.start());
}

test "Style - start handles bold" {
    const s = Style{ .fg = .red, .bold = true };
    try testing.expectEqualStrings("\x1b[1;31m", s.start());
}

test "Style - start handles dim" {
    const s = Style{ .fg = .yellow, .dim = true };
    try testing.expectEqualStrings("\x1b[2;33m", s.start());
}

test "Style - reset returns standard reset" {
    const s = Style{ .fg = .red, .bold = true };
    try testing.expectEqualStrings("\x1b[0m", s.reset());
}

test "Style - format wraps text with ANSI codes" {
    const result = try Style.err.format(testing.allocator, "fail");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\x1b[1;31mfail\x1b[0m", result);
}

test "Style - format with default style returns plain text" {
    const s = Style{ .fg = .default };
    const result = try s.format(testing.allocator, "plain");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("plain", result);
}

test "Style - predefined styles have correct start sequences" {
    try testing.expectEqualStrings("\x1b[1;32m", Style.success.start());
    try testing.expectEqualStrings("\x1b[1;31m", Style.err.start());
    try testing.expectEqualStrings("\x1b[33m", Style.warning.start());
    try testing.expectEqualStrings("\x1b[36m", Style.info.start());
    try testing.expectEqualStrings("\x1b[2m", Style.dimmed.start());
}
