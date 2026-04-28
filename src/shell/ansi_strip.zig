const std = @import("std");

/// Strip ANSI escape sequences from input string.
/// Supports CSI (Control Sequence Introducer), OSC (Operating System Command), and SGR sequences.
/// Returns a new allocated string with all ANSI escape sequences removed.
pub fn stripAnsiEscapes(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Output buffer: worst case is all text (no escapes), so allocate same size
    var output_buf = try allocator.alloc(u8, input.len);
    errdefer allocator.free(output_buf);

    var write_idx: usize = 0;
    var i: usize = 0;

    // State machine: 0=TEXT, 1=ESCAPE, 2=CSI, 3=OSC
    var state: u2 = 0;

    while (i < input.len) {
        const byte = input[i];

        switch (state) {
            0 => { // TEXT: copy bytes, on ESC go to state 1
                if (byte == 0x1b) {
                    state = 1;
                } else {
                    output_buf[write_idx] = byte;
                    write_idx += 1;
                }
                i += 1;
            },
            1 => { // ESCAPE: check next byte
                if (byte == '[') {
                    // CSI sequence: \x1b[
                    state = 2;
                } else if (byte == ']') {
                    // OSC sequence: \x1b]
                    state = 3;
                } else {
                    // Invalid escape, discard ESC and this byte, back to TEXT
                    state = 0;
                }
                i += 1;
            },
            2 => { // CSI: consume until final byte [0x40-0x7E]
                // CSI parameters: [0-9;?]*
                if (byte >= 0x40 and byte <= 0x7E) {
                    // Final byte found, discard entire sequence, back to TEXT
                    state = 0;
                }
                i += 1;
            },
            3 => { // OSC: consume until BEL (0x07) or ST (ESC + \)
                if (byte == 0x07) {
                    // BEL terminator
                    state = 0;
                    i += 1;
                } else if (byte == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                    // ST terminator: ESC + \
                    state = 0;
                    i += 2;
                } else {
                    i += 1;
                }
            },
        }
    }

    // If we end in a non-TEXT state, we discard any partial sequence
    const result = try allocator.dupe(u8, output_buf[0..write_idx]);
    allocator.free(output_buf);
    return result;
}

// ==================== TESTS ====================

test "stripAnsiEscapes: CSI color codes" {
    const input = "\x1b[31mhello\x1b[0m";
    const expected = "hello";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: CSI cursor movement" {
    const input = "\x1b[2J\x1b[H";
    const expected = "";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: OSC with BEL" {
    const input = "\x1b]0;window-title\x07";
    const expected = "";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: OSC with ST" {
    const input = "\x1b]0;title\x1b\\";
    const expected = "";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: Mixed content" {
    const input = "\x1b[1;32mOK\x1b[0m: done";
    const expected = "OK: done";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: Plain text unchanged" {
    const input = "hello world";
    const expected = "hello world";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: Empty input" {
    const input = "";
    const expected = "";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: Complex real-world" {
    const input = "\x1b[?1049h\x1b[1;1H\x1b[K\x1b[32m✓\x1b[0m tests passed";
    const expected = "✓ tests passed";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripAnsiEscapes: Multiple CSI params" {
    const input = "\x1b[38;5;196mred\x1b[0m";
    const expected = "red";

    const result = try stripAnsiEscapes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}
