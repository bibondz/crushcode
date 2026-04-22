/// Shared string utility functions.
const std = @import("std");

/// Count the number of lines in content.
/// An empty string has 0 lines. A non-empty string has 1 + (number of '\n') lines.
/// Trailing newlines count as additional lines (e.g. "a\n" → 2, "a\nb\n" → 3).
pub fn countLines(content: []const u8) u32 {
    if (content.len == 0) return 0;
    var count: u32 = 1;
    for (content) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

test "countLines - empty string" {
    try std.testing.expectEqual(@as(u32, 0), countLines(""));
}

test "countLines - single line no newline" {
    try std.testing.expectEqual(@as(u32, 1), countLines("hello"));
}

test "countLines - two lines" {
    try std.testing.expectEqual(@as(u32, 2), countLines("hello\nworld"));
}

test "countLines - trailing newline" {
    try std.testing.expectEqual(@as(u32, 2), countLines("hello\n"));
}

test "countLines - multiple trailing newlines" {
    try std.testing.expectEqual(@as(u32, 4), countLines("a\nb\n\n"));
}

test "countLines - only newlines" {
    try std.testing.expectEqual(@as(u32, 3), countLines("\n\n"));
}
