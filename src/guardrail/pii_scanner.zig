const std = @import("std");
const pipeline = @import("pipeline.zig");

const GuardrailConfig = pipeline.GuardrailConfig;
const GuardrailResult = pipeline.GuardrailResult;
const Detection = pipeline.Detection;

/// Check if byte is an ASCII letter.
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Check if byte is an ASCII digit.
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Check if byte is alphanumeric.
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

/// Check if byte is a valid email local part character.
fn isEmailLocalChar(c: u8) bool {
    return isAlnum(c) or c == '.' or c == '_' or c == '-' or c == '+';
}

/// Scan for email addresses: local@domain.tld where TLD is 2+ letters.
fn scanEmail(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    if (start >= input.len) return null;
    // Find '@' starting from 'start'
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        if (input[i] != '@') continue;
        // Walk backward to find start of local part
        if (i == 0) continue;
        var local_end: usize = i - 1;
        // Skip trailing dots in local part
        while (local_end > 0 and input[local_end] == '.') : (local_end -= 1) {}
        var local_start: usize = local_end;
        while (local_start > 0 and isEmailLocalChar(input[local_start - 1])) : (local_start -= 1) {}
        if (!isEmailLocalChar(input[local_start])) continue;
        // Ensure at least 1 char in local part
        if (local_end < local_start) continue;
        // Walk forward to find domain
        const dom_start: usize = i + 1;
        if (dom_start >= input.len) continue;
        // Domain must start with alphanumeric
        if (!isAlnum(input[dom_start])) continue;
        var dom_end: usize = dom_start;
        while (dom_end < input.len and (isAlnum(input[dom_end]) or input[dom_end] == '.' or input[dom_end] == '-')) : (dom_end += 1) {}
        dom_end -= 1;
        // Must have at least one dot in domain
        var has_dot = false;
        var dot_pos: usize = 0;
        var d: usize = dom_start;
        while (d <= dom_end) : (d += 1) {
            if (input[d] == '.') {
                has_dot = true;
                dot_pos = d;
            }
        }
        if (!has_dot) continue;
        // TLD must be 2+ letters after last dot
        const tld_start: usize = dot_pos + 1;
        if (tld_start > dom_end) continue;
        var tld_len: usize = 0;
        var t: usize = tld_start;
        while (t <= dom_end and isAlpha(input[t])) : (t += 1) {
            tld_len += 1;
        }
        if (tld_len < 2) continue;
        const match_start = local_start;
        const match_end = dom_end + 1;
        return .{ .start = match_start, .end = match_end };
    }
    return null;
}

/// Scan for US phone numbers: ###-###-#### or (###) ###-####
fn scanPhone(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        // Pattern 1: ###-###-####
        if (i + 12 <= input.len) {
            if (isDigit(input[i]) and isDigit(input[i + 1]) and isDigit(input[i + 2]) and
                input[i + 3] == '-' and
                isDigit(input[i + 4]) and isDigit(input[i + 5]) and isDigit(input[i + 6]) and
                input[i + 7] == '-' and
                isDigit(input[i + 8]) and isDigit(input[i + 9]) and isDigit(input[i + 10]) and isDigit(input[i + 11]))
            {
                return .{ .start = i, .end = i + 12 };
            }
        }
        // Pattern 2: (###) ###-####
        if (i + 14 <= input.len) {
            if (input[i] == '(' and
                isDigit(input[i + 1]) and isDigit(input[i + 2]) and isDigit(input[i + 3]) and
                input[i + 4] == ')' and input[i + 5] == ' ' and
                isDigit(input[i + 6]) and isDigit(input[i + 7]) and isDigit(input[i + 8]) and
                input[i + 9] == '-' and
                isDigit(input[i + 10]) and isDigit(input[i + 11]) and isDigit(input[i + 12]) and isDigit(input[i + 13]))
            {
                return .{ .start = i, .end = i + 14 };
            }
        }
    }
    return null;
}

/// Scan for SSN: ###-##-####
fn scanSSN(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    if (start + 11 > input.len) return null;
    var i: usize = start;
    while (i + 11 <= input.len) : (i += 1) {
        if (isDigit(input[i]) and isDigit(input[i + 1]) and isDigit(input[i + 2]) and
            input[i + 3] == '-' and
            isDigit(input[i + 4]) and isDigit(input[i + 5]) and
            input[i + 6] == '-' and
            isDigit(input[i + 7]) and isDigit(input[i + 8]) and isDigit(input[i + 9]) and isDigit(input[i + 10]))
        {
            return .{ .start = i, .end = i + 11 };
        }
    }
    return null;
}

/// Scan for credit card number: 16 digits possibly separated by spaces or dashes.
fn scanCreditCard(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        if (!isDigit(input[i])) continue;
        // Try to collect 16 digits with optional spaces/dashes
        var digit_count: usize = 0;
        var j: usize = i;
        while (j < input.len and digit_count < 16) : (j += 1) {
            if (isDigit(input[j])) {
                digit_count += 1;
            } else if (input[j] == ' ' or input[j] == '-') {
                // Skip separators
            } else {
                break;
            }
        }
        if (digit_count == 16) {
            return .{ .start = i, .end = j };
        }
    }
    return null;
}

/// Scan for AWS Access Key: AKIA followed by 16 uppercase alphanumeric chars.
fn scanAWSKey(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const prefix = "AKIA";
    var i: usize = start;
    while (i + prefix.len + 16 <= input.len) : (i += 1) {
        if (!std.mem.startsWith(u8, input[i..], prefix)) continue;
        // Check 16 uppercase alphanumeric after prefix
        var valid = true;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const c = input[i + prefix.len + k];
            if (!(isDigit(c) or (c >= 'A' and c <= 'Z'))) {
                valid = false;
                break;
            }
        }
        if (valid) {
            return .{ .start = i, .end = i + prefix.len + 16 };
        }
    }
    return null;
}

/// Check if character is a common identifier char for API key patterns.
fn isIdentChar(c: u8) bool {
    return isAlnum(c) or c == '_' or c == '-';
}

/// Scan for generic API key patterns: api_key/apikey/secret_key/token followed by : or = then 20+ alphanumeric.
fn scanGenericAPIKey(input: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const keywords = [_][]const u8{
        "api_key",
        "apikey",
        "secret_key",
        "token",
    };

    var i: usize = start;
    while (i < input.len) : (i += 1) {
        for (keywords) |kw| {
            if (i + kw.len >= input.len) continue;
            if (!std.mem.startsWith(u8, input[i..], kw)) continue;
            // Ensure keyword boundary
            if (i > 0 and isIdentChar(input[i - 1])) continue;
            const after_kw: usize = i + kw.len;
            if (after_kw >= input.len) continue;
            // Skip optional whitespace
            var pos: usize = after_kw;
            while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t')) : (pos += 1) {}
            if (pos >= input.len) continue;
            // Must be : or =
            if (input[pos] != ':' and input[pos] != '=') continue;
            pos += 1;
            // Skip optional whitespace after separator
            while (pos < input.len and (input[pos] == ' ' or input[pos] == '\t')) : (pos += 1) {}
            if (pos >= input.len) continue;
            // Optionally handle quotes
            const has_quote = (input[pos] == '"' or input[pos] == '\'');
            if (has_quote) pos += 1;
            if (pos >= input.len) continue;
            // Count alphanumeric chars (value)
            const val_start = pos;
            while (pos < input.len and isAlnum(input[pos])) : (pos += 1) {}
            const val_len = pos - val_start;
            if (val_len < 20) continue;
            // Skip trailing quote if present
            if (has_quote and pos < input.len and (input[pos] == '"' or input[pos] == '\'')) {
                pos += 1;
            }
            return .{ .start = i, .end = pos };
        }
    }
    return null;
}

/// Perform full PII scan on input, returning all detections found.
pub fn scanPII(allocator: std.mem.Allocator, input: []const u8) ![]Detection {
    var detections = std.ArrayList(Detection).init(allocator);
    errdefer {
        for (detections.items) |det| {
            allocator.free(det.entity_type);
            allocator.free(det.value);
        }
        detections.deinit();
    }

    // Track positions already matched to avoid excessive overlap
    var pos: usize = 0;

    while (pos < input.len) {
        var found_any = false;
        var best_start: usize = input.len;
        var best_end: usize = input.len;
        var best_type: ?[]const u8 = null;
        var best_redact = false;

        // Check each pattern from current position
        if (scanEmail(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "email";
                best_redact = false;
                found_any = true;
            }
        }
        if (scanSSN(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "ssn";
                best_redact = true;
                found_any = true;
            }
        }
        if (scanPhone(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "phone";
                best_redact = false;
                found_any = true;
            }
        }
        if (scanCreditCard(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "credit_card";
                best_redact = true;
                found_any = true;
            }
        }
        if (scanAWSKey(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "aws_access_key";
                best_redact = true;
                found_any = true;
            }
        }
        if (scanGenericAPIKey(input, pos)) |m| {
            if (m.start < best_start) {
                best_start = m.start;
                best_end = m.end;
                best_type = "api_key";
                best_redact = true;
                found_any = true;
            }
        }

        if (found_any and best_type != null) {
            const value = if (best_redact)
                "***REDACTED***"
            else
                input[best_start..best_end];

            try detections.append(Detection{
                .entity_type = try allocator.dupe(u8, best_type.?),
                .value = try allocator.dupe(u8, value),
                .start_pos = best_start,
                .end_pos = best_end,
            });
            pos = best_end;
        } else {
            pos += 1;
        }
    }

    return try detections.toOwnedSlice();
}

/// Guardrail-compatible check function for the PII scanner.
pub fn check(allocator: std.mem.Allocator, input: []const u8, config: *const GuardrailConfig) anyerror!GuardrailResult {
    _ = config;

    const detections = try scanPII(allocator, input);
    if (detections.len == 0) {
        return GuardrailResult.ok(allocator);
    }

    // Build redacted content
    var redacted = std.ArrayList(u8).init(allocator);
    errdefer redacted.deinit();

    var last_end: usize = 0;
    for (detections) |det| {
        // Append text before this detection
        if (det.start_pos > last_end) {
            try redacted.appendSlice(input[last_end..det.start_pos]);
        }
        // Append redacted value
        try redacted.appendSlice(det.value);
        last_end = det.end_pos;
    }
    // Append remaining text
    if (last_end < input.len) {
        try redacted.appendSlice(input[last_end..]);
    }

    const has_sensitive = for (detections) |det| {
        if (std.mem.eql(u8, det.value, "***REDACTED***")) break true;
    } else false;

    return GuardrailResult{
        .action = if (has_sensitive) .redact else .deny,
        .scanner_name = "pii_scanner",
        .reason = if (detections.len == 1)
            try allocator.dupe(u8, "Detected 1 PII entity")
        else
            try std.fmt.allocPrint(allocator, "Detected {d} PII entities", .{detections.len}),
        .redacted_content = try redacted.toOwnedSlice(),
        .confidence = 0.85,
        .detections = detections,
        .allocator = allocator,
    };
}
