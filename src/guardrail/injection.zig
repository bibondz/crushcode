const std = @import("std");
const pipeline = @import("pipeline.zig");

const GuardrailConfig = pipeline.GuardrailConfig;
const GuardrailResult = pipeline.GuardrailResult;
const Detection = pipeline.Detection;

/// Case-insensitive ASCII character comparison.
fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Case-insensitive substring search. Returns start index or null.
fn findCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Check if needle appears case-insensitively in haystack starting at pos.
fn startsWithCI(haystack: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > haystack.len) return false;
    var j: usize = 0;
    while (j < needle.len) : (j += 1) {
        if (toLower(haystack[pos + j]) != toLower(needle[j])) return false;
    }
    return true;
}

const InjectionPattern = struct {
    phrase: []const u8,
    confidence: f64,
    is_partial: bool,
};

/// Known injection phrases to detect (exact phrase matches).
const exact_patterns = [_]InjectionPattern{
    .{ .phrase = "ignore previous instructions", .confidence = 0.9, .is_partial = false },
    .{ .phrase = "ignore all previous", .confidence = 0.9, .is_partial = false },
    .{ .phrase = "disregard your instructions", .confidence = 0.9, .is_partial = false },
    .{ .phrase = "[INST]", .confidence = 0.9, .is_partial = false },
    .{ .phrase = "<<SYS>>", .confidence = 0.9, .is_partial = false },
};

/// Suspicious delimiter patterns.
const delimiter_patterns = [_]InjectionPattern{
    .{ .phrase = "####", .confidence = 0.5, .is_partial = true },
    .{ .phrase = "****", .confidence = 0.5, .is_partial = true },
};

/// Guardrail-compatible check function for prompt injection detection.
pub fn check(allocator: std.mem.Allocator, input: []const u8, config: *const GuardrailConfig) anyerror!GuardrailResult {
    _ = config;

    var detections = std.ArrayList(Detection).init(allocator);
    errdefer {
        for (detections.items) |det| {
            allocator.free(det.entity_type);
            allocator.free(det.value);
        }
        detections.deinit();
    }

    var max_confidence: f64 = 0.0;

    // Check exact phrase patterns
    for (&exact_patterns) |pattern| {
        var search_start: usize = 0;
        while (findCI(input[search_start..], pattern.phrase)) |rel_pos| {
            const abs_pos = search_start + rel_pos;
            try detections.append(Detection{
                .entity_type = try allocator.dupe(u8, "prompt_injection"),
                .value = try allocator.dupe(u8, input[abs_pos .. abs_pos + pattern.phrase.len]),
                .start_pos = abs_pos,
                .end_pos = abs_pos + pattern.phrase.len,
            });
            if (pattern.confidence > max_confidence) {
                max_confidence = pattern.confidence;
            }
            search_start = abs_pos + pattern.phrase.len;
        }
    }

    // Check "you are now" + ("DAN" or "jailbreak") pattern
    {
        var search_start: usize = 0;
        while (findCI(input[search_start..], "you are now")) |rel_pos| {
            const abs_pos = search_start + rel_pos;
            const after = abs_pos + "you are now".len;
            // Skip whitespace
            var k: usize = after;
            while (k < input.len and (input[k] == ' ' or input[k] == '\t')) : (k += 1) {}
            if (startsWithCI(input, k, "DAN") or findCI(input[k .. @min(k + 40, input.len)], "jailbreak") != null) {
                const end_pos = if (startsWithCI(input, k, "DAN"))
                    k + 3
                else if (findCI(input[k .. @min(k + 40, input.len)], "jailbreak")) |jp|
                    k + jp + "jailbreak".len
                else
                    k;
                try detections.append(Detection{
                    .entity_type = try allocator.dupe(u8, "prompt_injection"),
                    .value = try allocator.dupe(u8, input[abs_pos..end_pos]),
                    .start_pos = abs_pos,
                    .end_pos = end_pos,
                });
                if (0.9 > max_confidence) max_confidence = 0.9;
            }
            search_start = abs_pos + "you are now".len;
        }
    }

    // Check "system prompt" + ("reveal"/"show"/"output") pattern
    {
        var search_start: usize = 0;
        while (findCI(input[search_start..], "system prompt")) |rel_pos| {
            const abs_pos = search_start + rel_pos;
            const after = abs_pos + "system prompt".len;
            var k: usize = after;
            while (k < input.len and (input[k] == ' ' or input[k] == '\t')) : (k += 1) {}
            const tail = input[k .. @min(k + 30, input.len)];
            const found_reveal = findCI(tail, "reveal") != null;
            const found_show = findCI(tail, "show") != null;
            const found_output = findCI(tail, "output") != null;
            if (found_reveal or found_show or found_output) {
                const action_word: []const u8 = if (found_reveal) "reveal" else if (found_show) "show" else "output";
                const action_pos = findCI(tail, action_word).?;
                const end_pos = k + action_pos + action_word.len;
                try detections.append(Detection{
                    .entity_type = try allocator.dupe(u8, "prompt_injection"),
                    .value = try allocator.dupe(u8, input[abs_pos..end_pos]),
                    .start_pos = abs_pos,
                    .end_pos = end_pos,
                });
                if (0.9 > max_confidence) max_confidence = 0.9;
            }
            search_start = abs_pos + "system prompt".len;
        }
    }

    // Check delimiter injection at start of input (skip leading whitespace)
    {
        var line_start: usize = 0;
        while (line_start < input.len and (input[line_start] == ' ' or input[line_start] == '\t' or input[line_start] == '\n' or input[line_start] == '\r')) : (line_start += 1) {}
        for (&delimiter_patterns) |pattern| {
            if (startsWithCI(input, line_start, pattern.phrase)) {
                try detections.append(Detection{
                    .entity_type = try allocator.dupe(u8, "prompt_injection"),
                    .value = try allocator.dupe(u8, pattern.phrase),
                    .start_pos = line_start,
                    .end_pos = line_start + pattern.phrase.len,
                });
                if (pattern.confidence > max_confidence) {
                    max_confidence = pattern.confidence;
                }
            }
        }
    }

    if (detections.items.len == 0) {
        detections.deinit();
        return GuardrailResult.ok(allocator);
    }

    const det_slice = try detections.toOwnedSlice();
    return GuardrailResult{
        .action = .deny,
        .scanner_name = "injection_detector",
        .reason = try std.fmt.allocPrint(allocator, "Detected {d} prompt injection pattern{s}", .{ det_slice.len, if (det_slice.len == 1) @as([]const u8, "") else @as([]const u8, "s") }),
        .redacted_content = null,
        .confidence = max_confidence,
        .detections = det_slice,
        .allocator = allocator,
    };
}
