const std = @import("std");

/// Zero-copy JSON string extraction from raw JSON bytes.
/// Finds `"key":"value"` and returns the value slice pointing into the original data.
/// Returns null if the key is not found or the value is not a string.
pub fn extractString(data: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key":"
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 4 > pattern_buf.len) return null;
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..key.len], key);
    pattern_buf[1 + key.len] = '"';
    pattern_buf[2 + key.len] = ':';
    const pattern_end = 3 + key.len;

    // Try both "key":"value" and "key": "value" (with space)
    const patterns = [_][]const u8{
        pattern_buf[0..pattern_end],
        blk: {
            pattern_buf[pattern_end] = ' ';
            break :blk pattern_buf[0 .. pattern_end + 1];
        },
    };

    for (patterns) |pattern| {
        var search_start: usize = 0;
        while (search_start < data.len) {
            const idx = std.mem.indexOf(u8, data[search_start..], pattern) orelse break;
            const abs_idx = search_start + idx;
            const val_start = abs_idx + pattern.len;

            // Expect opening quote
            if (val_start >= data.len or data[val_start] != '"') {
                search_start = abs_idx + 1;
                continue;
            }

            // Find closing quote (handle escaped quotes)
            var i: usize = val_start + 1;
            while (i < data.len) {
                if (data[i] == '\\') {
                    i += 2; // skip escaped character
                    continue;
                }
                if (data[i] == '"') {
                    return data[val_start + 1 .. i];
                }
                i += 1;
            }
            break;
        }
    }
    return null;
}

/// Extract an integer value from raw JSON by key name.
/// Finds `"key":12345` and returns the parsed integer.
pub fn extractInteger(data: []const u8, key: []const u8) ?i64 {
    // Build search pattern: "key":
    var pattern_buf: [256]u8 = undefined;
    if (key.len + 3 > pattern_buf.len) return null;
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..key.len], key);
    pattern_buf[1 + key.len] = '"';
    pattern_buf[2 + key.len] = ':';
    const pattern = pattern_buf[0 .. 3 + key.len];

    var search_start: usize = 0;
    while (search_start < data.len) {
        const idx = std.mem.indexOf(u8, data[search_start..], pattern) orelse break;
        const abs_idx = search_start + idx;
        var i = abs_idx + pattern.len;

        // Skip whitespace
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}

        // Parse digits (with optional negative sign)
        if (i >= data.len) break;
        const start = i;
        if (data[i] == '-') i += 1;
        if (i >= data.len or data[i] < '0' or data[i] > '9') {
            search_start = abs_idx + 1;
            continue;
        }
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
        const num_str = data[start..i];
        return std.fmt.parseInt(i64, num_str, 10) catch null;
    }
    return null;
}
