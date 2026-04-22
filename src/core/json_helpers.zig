/// Shared JSON helper functions — lightweight field extraction without full parse.
const std = @import("std");

/// Extract a string field value from a JSON string (simple inline parser).
/// Finds `"field_name":"value"` patterns, handling whitespace after the colon.
/// Returns the value without quotes. Caller does NOT own the returned slice.
pub fn extractJsonStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(full_needle);

    const idx = std.mem.indexOf(u8, json, full_needle) orelse return null;
    const rest = json[idx + full_needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\n' or rest[i] == '\r' or rest[i] == ':')) {
        i += 1;
    }
    if (i >= rest.len) return null;

    // Expect opening quote
    if (rest[i] != '"') return null;
    i += 1;

    // Find closing quote (handle escaped quotes)
    const value_start = i;
    while (i < rest.len) {
        if (rest[i] == '"' and (i == 0 or rest[i - 1] != '\\')) {
            break;
        }
        i += 1;
    }
    if (i >= rest.len) return null;

    return rest[value_start..i];
}
