const std = @import("std");
const array_list_compat = @import("array_list_compat");
const pipeline = @import("pipeline.zig");

const GuardrailConfig = pipeline.GuardrailConfig;
const GuardrailResult = pipeline.GuardrailResult;
const Detection = pipeline.Detection;

/// Check if byte is an ASCII digit.
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Check if byte is alphanumeric.
fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// Check if byte is a common token char (alphanumeric, dash, underscore, dot).
fn isTokenChar(c: u8) bool {
    return isAlnum(c) or c == '-' or c == '_' or c == '.';
}

const SecretPattern = struct {
    prefix: []const u8,
    /// Minimum length of the suffix after the prefix
    min_suffix: usize,
    /// Whether suffix must be alphanumeric only
    alnum_only: bool,
    /// Friendly name for the entity_type
    name: []const u8,
};

const secret_patterns = [_]SecretPattern{
    .{ .prefix = "ghp_", .min_suffix = 36, .alnum_only = true, .name = "github_token" },
    .{ .prefix = "gho_", .min_suffix = 36, .alnum_only = true, .name = "github_oauth" },
    .{ .prefix = "sk_live_", .min_suffix = 10, .alnum_only = true, .name = "stripe_live_key" },
    .{ .prefix = "sk_test_", .min_suffix = 10, .alnum_only = true, .name = "stripe_test_key" },
    .{ .prefix = "sk-ant-", .min_suffix = 10, .alnum_only = true, .name = "anthropic_api_key" },
};

/// Scan for prefix-based secret patterns (GitHub tokens, Stripe keys, Anthropic keys).
fn scanPrefixedSecret(input: []const u8, start: usize, pattern: *const SecretPattern) ?struct { start: usize, end: usize } {
    var i: usize = start;
    while (i + pattern.prefix.len + pattern.min_suffix <= input.len) : (i += 1) {
        if (!std.mem.startsWith(u8, input[i..], pattern.prefix)) continue;
        // Check that the character before the prefix is not alphanumeric (word boundary)
        if (i > 0 and isAlnum(input[i - 1])) continue;
        const suffix_start = i + pattern.prefix.len;
        var suffix_len: usize = 0;
        var j: usize = suffix_start;
        while (j < input.len) : (j += 1) {
            if (pattern.alnum_only) {
                if (!isAlnum(input[j])) break;
            } else {
                if (!isTokenChar(input[j])) break;
            }
            suffix_len += 1;
        }
        if (suffix_len >= pattern.min_suffix) {
            return .{ .start = i, .end = suffix_start + suffix_len };
        }
    }
    return null;
}

/// Scan for OpenAI API key: sk- followed by 48+ alphanumeric chars.
fn scanOpenAIKey(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const prefix = "sk-";
    // Must NOT match sk-ant- (Anthropic key)
    const ant_prefix = "sk-ant-";
    var i: usize = start;
    while (i + prefix.len + 48 <= input.len) : (i += 1) {
        if (!std.mem.startsWith(u8, input[i..], prefix)) continue;
        // Exclude Anthropic keys
        if (std.mem.startsWith(u8, input[i..], ant_prefix)) continue;
        // Word boundary
        if (i > 0 and isAlnum(input[i - 1])) continue;
        const suffix_start = i + prefix.len;
        var suffix_len: usize = 0;
        var j: usize = suffix_start;
        while (j < input.len and isAlnum(input[j])) : (j += 1) {
            suffix_len += 1;
        }
        if (suffix_len >= 48) {
            return .{ .start = i, .end = suffix_start + suffix_len };
        }
    }
    return null;
}

/// Scan for Slack tokens: xoxb-, xoxp-, xoxa- followed by alphanumeric + dashes.
fn scanSlackToken(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const prefixes = [_][]const u8{ "xoxb-", "xoxp-", "xoxa-" };
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        for (&prefixes) |prefix| {
            if (i + prefix.len >= input.len) continue;
            if (!std.mem.startsWith(u8, input[i..], prefix)) continue;
            if (i > 0 and isAlnum(input[i - 1])) continue;
            const suffix_start = i + prefix.len;
            var j: usize = suffix_start;
            var has_content = false;
            while (j < input.len and (isAlnum(input[j]) or input[j] == '-' or input[j] == '_')) : (j += 1) {
                has_content = true;
            }
            if (has_content and j - suffix_start >= 10) {
                return .{ .start = i, .end = j };
            }
        }
    }
    return null;
}

/// Scan for generic Bearer token: "Bearer " followed by alphanumeric.dot.alphanumeric.
fn scanBearerToken(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const prefix = "Bearer ";
    var i: usize = start;
    while (i + prefix.len < input.len) : (i += 1) {
        // Case-insensitive match for "Bearer "
        var match = true;
        var k: usize = 0;
        while (k < prefix.len) : (k += 1) {
            const hc = if (input[i + k] >= 'A' and input[i + k] <= 'Z')
                input[i + k] + 32
            else
                input[i + k];
            if (hc != prefix[k]) {
                match = false;
                break;
            }
        }
        if (!match) continue;

        const val_start = i + prefix.len;
        // Read first segment (alphanumeric + underscores)
        var j: usize = val_start;
        while (j < input.len and (isAlnum(input[j]) or input[j] == '_' or input[j] == '-')) : (j += 1) {}
        if (j == val_start) continue;
        // Must have a dot
        if (j >= input.len or input[j] != '.') continue;
        j += 1;
        // Read second segment
        const seg2_start = j;
        while (j < input.len and (isAlnum(input[j]) or input[j] == '_' or input[j] == '-')) : (j += 1) {}
        if (j == seg2_start) continue;
        return .{ .start = i, .end = j };
    }
    return null;
}

/// Scan for private key headers.
fn scanPrivateKey(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const patterns = [_][]const u8{
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
    };
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        for (&patterns) |pattern| {
            if (i + pattern.len > input.len) continue;
            if (std.mem.startsWith(u8, input[i..], pattern)) {
                // Find the end marker
                const end_marker = "-----END";
                var end_pos: usize = i + pattern.len;
                while (end_pos + end_marker.len <= input.len) : (end_pos += 1) {
                    if (std.mem.startsWith(u8, input[end_pos..], end_marker)) {
                        // Advance to the final "-----"
                        var e: usize = end_pos;
                        while (e < input.len and input[e] != '\n') : (e += 1) {}
                        return .{ .start = i, .end = e };
                    }
                }
                // No end marker found; return the start header
                return .{ .start = i, .end = i + pattern.len };
            }
        }
    }
    return null;
}

/// Guardrail-compatible check function for secrets/credential detection.
pub fn check(allocator: std.mem.Allocator, input: []const u8, config: *const GuardrailConfig) anyerror!GuardrailResult {
    _ = config;

    var detections = array_list_compat.ArrayList(Detection).init(allocator);
    errdefer {
        for (detections.items) |det| {
            allocator.free(det.entity_type);
            allocator.free(det.value);
        }
        detections.deinit();
    }

    var pos: usize = 0;

    while (pos < input.len) {
        var found_any = false;
        var best_start: usize = input.len;
        var best_end: usize = input.len;
        var best_name: ?[]const u8 = null;

        // Check prefix-based patterns
        for (&secret_patterns) |pattern| {
            if (scanPrefixedSecret(input, pos, &pattern)) |m| {
                if (m.start < best_start) {
                    best_start = m.start;
                    best_end = m.end;
                    best_name = pattern.name;
                    found_any = true;
                }
            }
        }

        // Check OpenAI key
        if (scanOpenAIKey(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_name = "openai_api_key";
                found_any = true;
            }
        }

        // Check Slack tokens
        if (scanSlackToken(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_name = "slack_token";
                found_any = true;
            }
        }

        // Check Bearer tokens
        if (scanBearerToken(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_name = "bearer_token";
                found_any = true;
            }
        }

        // Check private keys
        if (scanPrivateKey(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_name = "private_key";
                found_any = true;
            }
        }

        if (found_any and best_name != null) {
            try detections.append(Detection{
                .entity_type = try allocator.dupe(u8, "secret"),
                .value = try allocator.dupe(u8, "***REDACTED***"),
                .start_pos = best_start,
                .end_pos = best_end,
            });
            pos = best_end;
        } else {
            pos += 1;
        }
    }

    if (detections.items.len == 0) {
        detections.deinit();
        return GuardrailResult.ok(allocator);
    }

    const det_slice = try detections.toOwnedSlice();
    return GuardrailResult{
        .action = .deny,
        .scanner_name = "secrets_detector",
        .reason = try std.fmt.allocPrint(allocator, "Detected {d} secret{s}", .{ det_slice.len, if (det_slice.len == 1) @as([]const u8, "") else @as([]const u8, "s") }),
        .redacted_content = null,
        .confidence = 0.95,
        .detections = det_slice,
        .allocator = allocator,
    };
}

test "secrets check detects GitHub token" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "my token is ghp_abcdefghijklmnopqrstuvwxyz1234567890abcdef1234567890abcdef1234";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects Stripe live key" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "key: sk_live_1234567890abcdef1234567890";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects Anthropic key" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "api key sk-ant-1234567890abcdef1234567890";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects OpenAI key" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "sk-abcdefghijklmnopqrstuvwxyz1234567890abcdef1234567890abcdef123456";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects Slack token" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "xoxb-1234567890abcdef1234567890abcdef1234";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects Bearer token" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "Bearer abc.def.ghi1234567890";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check detects private key" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "-----BEGIN RSA PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCj...\n-----END PRIVATE KEY-----";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
}

test "secrets check returns ok for clean content" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "hello world, this is clean content";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .allow);
}

test "secrets check detects multiple secrets" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "user: ghp_abcdefghijklmnopqrstuvwxyz1234567890abcdef1234567890abcdef1234, key: -----BEGIN RSA PRIVATE KEY-----";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .deny);
    try testing.expect(result.detections.len >= 2);
}

test "secrets check ignores short prefixes" {
    const testing = @import("std").testing;
    const alloc = testing.allocator;
    const config = pipeline.GuardrailConfig{ .mode = .enforce, .max_input_bytes = 100000 };
    
    const input = "short prefix: ghp_abc";
    const result = try check(alloc, input, &config);
    defer result.deinit();
    
    try testing.expect(result.action == .allow);
}
