const std = @import("std");
const array_list_compat = @import("array_list_compat");
const span_mod = @import("span");

const Allocator = std.mem.Allocator;
pub const SpanKind = span_mod.SpanKind;
pub const SpanStatus = span_mod.SpanStatus;

/// Maximum file size for DoS protection (10MB)
const max_file_size: usize = 10 * 1024 * 1024;

/// Maximum line count per trace file
const max_line_count: usize = 10_000;

/// Lightweight deserialized span with owned strings
pub const ParsedSpan = struct {
    span_id_hex: []const u8,
    trace_id_hex: []const u8,
    parent_hex: ?[]const u8,
    name: []const u8,
    kind: SpanKind,
    status: SpanStatus,
    latency_ms: ?u64,
    model: ?[]const u8,
    provider: ?[]const u8,
    tokens: ?TokenCounts,
    cost_usd: ?f64,
    start_time_ns: i64,
    end_time_ns: ?i64,
    status_message: ?[]const u8,
    allocator: Allocator,

    /// Free all owned strings and the span itself
    pub fn deinit(self: *ParsedSpan) void {
        self.allocator.free(self.span_id_hex);
        self.allocator.free(self.trace_id_hex);
        if (self.parent_hex) |h| self.allocator.free(h);
        self.allocator.free(self.name);
        if (self.model) |m| self.allocator.free(m);
        if (self.provider) |p| self.allocator.free(p);
        if (self.status_message) |msg| self.allocator.free(msg);
        self.allocator.destroy(self);
    }
};

/// Token usage counts
pub const TokenCounts = struct {
    prompt: ?u32,
    completion: ?u32,
    total: ?u32,
};

/// Optional filter for spans
pub const SpanFilter = struct {
    kind: ?SpanKind = null,
    status: ?SpanStatus = null,
    model: ?[]const u8 = null,
    min_time_ns: ?i64 = null,
    max_time_ns: ?i64 = null,

    /// Check if a span matches this filter
    pub fn matches(self: *const SpanFilter, span: *const ParsedSpan) bool {
        if (self.kind) |k| {
            if (span.kind != k) return false;
        }
        if (self.status) |s| {
            if (span.status != s) return false;
        }
        if (self.model) |m| {
            if (span.model) |span_model| {
                if (!std.mem.eql(u8, span_model, m)) return false;
            } else {
                return false;
            }
        }
        if (self.min_time_ns) |min| {
            if (span.start_time_ns < min) return false;
        }
        if (self.max_time_ns) |max| {
            if (span.start_time_ns > max) return false;
        }
        return true;
    }
};

/// Loaded trace with computed metadata
pub const TraceRun = struct {
    trace_id_hex: []const u8,
    spans: array_list_compat.ArrayList(*ParsedSpan),
    total_cost_usd: f64,
    total_duration_ms: u64,
    span_count: usize,
    error_count: usize,
    timeout_count: usize,
    llm_count: usize,
    tool_count: usize,
    agent_count: usize,
    first_ts: i64,
    allocator: Allocator,

    /// Free all spans and the trace itself
    pub fn deinit(self: *TraceRun) void {
        for (self.spans.items) |span| {
            span.deinit();
        }
        self.spans.deinit();
        self.allocator.free(self.trace_id_hex);
        self.allocator.destroy(self);
    }
};

/// Classification of failure type
pub const FailureClass = enum {
    timeout,
    rate_limit,
    auth_error,
    network_error,
    server_error,
    tool_error,
    unknown,
};

/// Diagnosis of a failed span
pub const FailureDiagnosis = struct {
    span: *const ParsedSpan,
    class: FailureClass,
    cause_hint: []const u8,
};

/// JSON-serializable representation (matches writer.zig SpanRecord)
const SpanRecordJson = struct {
    ts: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent: ?[]const u8,
    name: []const u8,
    kind: []const u8,
    status: []const u8,
    latency_ms: ?u64,
    model: ?[]const u8,
    tokens: ?TokenRecordJson,
    cost_usd: ?f64,
    status_message: ?[]const u8 = null,
};

const TokenRecordJson = struct {
    prompt: ?u32,
    completion: ?u32,
    total: ?u32,
};

/// Parse a single JSON line into a ParsedSpan
pub fn parseSpanRecord(allocator: Allocator, json_line: []const u8) !*ParsedSpan {
    const record = try std.json.parseFromSlice(SpanRecordJson, allocator, json_line, .{ .ignore_unknown_fields = true });
    defer record.deinit();

    const r = record.value;

    const kind = std.meta.stringToEnum(SpanKind, r.kind) orelse return error.InvalidKind;
    const status = std.meta.stringToEnum(SpanStatus, r.status) orelse return error.InvalidStatus;

    const span = try allocator.create(ParsedSpan);
    const start_time_ns = try iso8601ToEpochNs(r.ts);

    var tokens: ?TokenCounts = null;
    if (r.tokens) |t| {
        tokens = TokenCounts{
            .prompt = t.prompt,
            .completion = t.completion,
            .total = t.total,
        };
    }

    span.* = .{
        .span_id_hex = try allocator.dupe(u8, r.span_id),
        .trace_id_hex = try allocator.dupe(u8, r.trace_id),
        .parent_hex = if (r.parent) |p| try allocator.dupe(u8, p) else null,
        .name = try allocator.dupe(u8, r.name),
        .kind = kind,
        .status = status,
        .latency_ms = r.latency_ms,
        .model = if (r.model) |m| try allocator.dupe(u8, m) else null,
        .provider = null,
        .tokens = tokens,
        .cost_usd = r.cost_usd,
        .start_time_ns = start_time_ns,
        .end_time_ns = if (r.latency_ms) |lat| start_time_ns + (@as(i64, @intCast(lat)) * 1_000_000) else null,
        .status_message = if (r.status_message) |msg| try allocator.dupe(u8, msg) else null,
        .allocator = allocator,
    };

    return span;
}

/// List all .jsonl trace files in the traces directory
pub fn listTraceFiles(allocator: Allocator, traces_dir: []const u8) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(traces_dir, .{ .iterate = true });
    defer dir.close();

    var files = array_list_compat.ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".jsonl")) continue;

        const filename = try allocator.dupe(u8, entry.name);
        try files.append(filename);
    }

    // Sort alphabetically
    std.sort.insertion([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const result = try files.toOwnedSlice();
    return result;
}

/// Load a trace from its JSONL file
pub fn loadTrace(allocator: Allocator, traces_dir: []const u8, trace_id_hex: []const u8) !*TraceRun {
    const filename = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ traces_dir, trace_id_hex });
    defer allocator.free(filename);

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > max_file_size) return error.FileTooLarge;

    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    var spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    errdefer {
        for (spans.items) |span| span.deinit();
        spans.deinit();
    }

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        if (line_count > max_line_count) return error.TooManyLines;

        const span = try parseSpanRecord(allocator, line);
        try spans.append(span);
    }

    // Compute metadata
    var total_cost_usd: f64 = 0;
    var total_duration_ms: u64 = 0;
    var error_count: usize = 0;
    var timeout_count: usize = 0;
    var llm_count: usize = 0;
    var tool_count: usize = 0;
    var agent_count: usize = 0;
    var first_ts: i64 = std.math.maxInt(i64);
    var last_ts: i64 = std.math.minInt(i64);

    for (spans.items) |span| {
        total_cost_usd += span.cost_usd orelse 0;
        if (span.end_time_ns) |et| {
            if (et > last_ts) last_ts = et;
        }
        if (span.start_time_ns < first_ts) first_ts = span.start_time_ns;

        if (span.status == .@"error") error_count += 1;
        if (span.status == .timeout) timeout_count += 1;

        switch (span.kind) {
            .llm => llm_count += 1,
            .tool => tool_count += 1,
            .agent => agent_count += 1,
            else => {},
        }
    }

    if (first_ts != std.math.maxInt(i64) and last_ts != std.math.minInt(i64)) {
        const diff_ns = last_ts - first_ts;
        total_duration_ms = @intCast(@divTrunc(diff_ns, 1_000_000));
    }

    const trace = try allocator.create(TraceRun);
    trace.* = .{
        .trace_id_hex = try allocator.dupe(u8, trace_id_hex),
        .spans = spans,
        .total_cost_usd = total_cost_usd,
        .total_duration_ms = total_duration_ms,
        .span_count = spans.items.len,
        .error_count = error_count,
        .timeout_count = timeout_count,
        .llm_count = llm_count,
        .tool_count = tool_count,
        .agent_count = agent_count,
        .first_ts = first_ts,
        .allocator = allocator,
    };

    return trace;
}

/// Filter spans using the given filter
pub fn filterSpans(allocator: Allocator, run: *const TraceRun, filter: SpanFilter) ![]*ParsedSpan {
    var result = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    errdefer result.deinit();

    for (run.spans.items) |span| {
        if (filter.matches(span)) {
            try result.append(span);
        }
    }

    return result.toOwnedSlice();
}

/// Classify a failure by analyzing status_message patterns
pub fn classifyFailure(span: *const ParsedSpan) FailureDiagnosis {
    const msg = span.status_message orelse "";

    // Timeout patterns
    if (span.status == .timeout or std.mem.indexOf(u8, msg, "timeout") != null) {
        return .{
            .span = span,
            .class = .timeout,
            .cause_hint = "Operation exceeded time limit",
        };
    }

    // Rate limit patterns
    if (std.mem.indexOf(u8, msg, "rate limit") != null or
        std.mem.indexOf(u8, msg, "429") != null or
        std.mem.indexOf(u8, msg, "too many requests") != null)
    {
        return .{
            .span = span,
            .class = .rate_limit,
            .cause_hint = "API rate limit exceeded",
        };
    }

    // Auth error patterns
    if (std.mem.indexOf(u8, msg, "unauthorized") != null or
        std.mem.indexOf(u8, msg, "401") != null or
        std.mem.indexOf(u8, msg, "invalid api key") != null or
        std.mem.indexOf(u8, msg, "authentication") != null)
    {
        return .{
            .span = span,
            .class = .auth_error,
            .cause_hint = "Invalid or missing API credentials",
        };
    }

    // Network error patterns
    if (std.mem.indexOf(u8, msg, "connection") != null or
        std.mem.indexOf(u8, msg, "network") != null or
        std.mem.indexOf(u8, msg, "ECONNREFUSED") != null or
        std.mem.indexOf(u8, msg, "ETIMEDOUT") != null or
        std.mem.indexOf(u8, msg, "dns") != null)
    {
        return .{
            .span = span,
            .class = .network_error,
            .cause_hint = "Network connectivity issue",
        };
    }

    // Server error patterns
    if (std.mem.indexOf(u8, msg, "500") != null or
        std.mem.indexOf(u8, msg, "502") != null or
        std.mem.indexOf(u8, msg, "503") != null or
        std.mem.indexOf(u8, msg, "internal server error") != null or
        std.mem.indexOf(u8, msg, "service unavailable") != null)
    {
        return .{
            .span = span,
            .class = .server_error,
            .cause_hint = "Server-side error (retry)",
        };
    }

    // Tool error patterns
    if (span.kind == .tool or
        std.mem.indexOf(u8, msg, "tool") != null or
        std.mem.indexOf(u8, msg, "command failed") != null or
        std.mem.indexOf(u8, msg, "execution error") != null)
    {
        return .{
            .span = span,
            .class = .tool_error,
            .cause_hint = "Tool execution failed",
        };
    }

    return .{
        .span = span,
        .class = .unknown,
        .cause_hint = "Unknown failure cause",
    };
}

/// Diagnose all failures in a trace run
pub fn diagnoseFailures(allocator: Allocator, run: *const TraceRun) ![]FailureDiagnosis {
    var result = array_list_compat.ArrayList(FailureDiagnosis).init(allocator);
    errdefer result.deinit();

    for (run.spans.items) |span| {
        if (span.status == .@"error" or span.status == .timeout) {
            const diagnosis = classifyFailure(span);
            // Copy the cause_hint since it's a string literal
            const hint = try allocator.dupe(u8, diagnosis.cause_hint);
            try result.append(.{
                .span = diagnosis.span,
                .class = diagnosis.class,
                .cause_hint = hint,
            });
        }
    }

    return result.toOwnedSlice();
}

/// Parse ISO8601 timestamp to epoch nanoseconds
/// Format: "YYYY-MM-DDTHH:MM:SSZ"
pub fn iso8601ToEpochNs(iso: []const u8) !i64 {
    if (iso.len != 20) return error.InvalidFormat;

    // Validate separators: "-" at positions 4 and 7, "T" at 10, ":" at 13 and 16, "Z" at 19
    if (iso[4] != '-' or iso[7] != '-' or iso[10] != 'T' or
        iso[13] != ':' or iso[16] != ':' or iso[19] != 'Z')
    {
        return error.InvalidFormat;
    }

    // Parse year: YYYY
    const year = try std.fmt.parseInt(u16, iso[0..4], 10);

    // Parse month: MM
    const month = try std.fmt.parseInt(u8, iso[5..7], 10);
    if (month < 1 or month > 12) return error.InvalidMonth;

    // Parse day: DD
    const day = try std.fmt.parseInt(u8, iso[8..10], 10);
    if (day < 1 or day > 31) return error.InvalidDay;

    // Parse hour: HH
    const hour = try std.fmt.parseInt(u8, iso[11..13], 10);
    if (hour > 23) return error.InvalidHour;

    // Parse minute: MM
    const minute = try std.fmt.parseInt(u8, iso[14..16], 10);
    if (minute > 59) return error.InvalidMinute;

    // Parse second: SS
    const second = try std.fmt.parseInt(u8, iso[17..19], 10);
    if (second > 59) return error.InvalidSecond;

    // Use std.time to convert to epoch seconds
    // Build a date and time
    const epoch_seconds = try epochSeconds(year, month, day, hour, minute, second);

    return epoch_seconds * 1_000_000_000;
}

/// Convert calendar date/time to Unix epoch seconds
fn epochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) !i64 {
    // Days since Unix epoch (1970-01-01)
    const total_days = try daysSinceEpoch(year, month, day);

    // Seconds since midnight
    const seconds_of_day = @as(u64, hour) * 3600 + @as(u64, minute) * 60 + @as(u64, second);

    return @as(i64, @intCast(total_days * 86400)) + @as(i64, @intCast(seconds_of_day));
}

/// Calculate days since Unix epoch (1970-01-01)
fn daysSinceEpoch(year: u16, month: u8, day: u8) !i64 {
    var days: i64 = 0;

    // Add full years
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) @as(i64, 366) else 365;
    }

    // Add full months for current year
    const month_days = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        var dim: u8 = month_days[m - 1];
        if (m == 2 and isLeapYear(year)) dim = 29;
        days += @as(i64, dim);
    }

    // Add days in current month
    days += @as(i64, day) - 1;

    return days;
}

/// Check if a year is a leap year
fn isLeapYear(year: u16) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

test "parseSpanRecord parses valid JSON" {
    const allocator = std.testing.allocator;

    const json = "{\"ts\":\"2026-04-28T12:00:00Z\",\"trace_id\":\"abc123\",\"span_id\":\"def456\",\"parent\":null,\"name\":\"test\",\"kind\":\"llm\",\"status\":\"ok\",\"latency_ms\":1500,\"model\":\"gpt-4\",\"tokens\":{\"prompt\":100,\"completion\":50,\"total\":150},\"cost_usd\":0.003}";

    const span = try parseSpanRecord(allocator, json);
    defer span.deinit();

    try std.testing.expectEqual(SpanKind.llm, span.kind);
    try std.testing.expectEqual(SpanStatus.ok, span.status);
    try std.testing.expectEqual(@as(?u64, 1500), span.latency_ms);
    try std.testing.expect(std.mem.eql(u8, span.model.?, "gpt-4"));
    try std.testing.expect(span.tokens != null);
    try std.testing.expectEqual(@as(?u32, 100), span.tokens.?.prompt);
    try std.testing.expectEqual(@as(?f64, 0.003), span.cost_usd);
}

test "parseSpanRecord handles null parent" {
    const allocator = std.testing.allocator;

    const json = "{\"ts\":\"2026-04-28T12:00:00Z\",\"trace_id\":\"abc\",\"span_id\":\"def\",\"parent\":null,\"name\":\"test\",\"kind\":\"tool\",\"status\":\"ok\",\"latency_ms\":100,\"model\":null,\"tokens\":null,\"cost_usd\":null}";

    const span = try parseSpanRecord(allocator, json);
    defer span.deinit();

    try std.testing.expect(span.parent_hex == null);
    try std.testing.expect(span.model == null);
    try std.testing.expect(span.tokens == null);
    try std.testing.expect(span.cost_usd == null);
}

test "parseSpanRecord handles error status" {
    const allocator = std.testing.allocator;

    const json = "{\"ts\":\"2026-04-28T12:00:00Z\",\"trace_id\":\"abc\",\"span_id\":\"def\",\"parent\":null,\"name\":\"test\",\"kind\":\"llm\",\"status\":\"error\",\"latency_ms\":null,\"model\":\"gpt-4\",\"tokens\":null,\"cost_usd\":null,\"status_message\":\"rate limit exceeded\"}";

    const span = try parseSpanRecord(allocator, json);
    defer span.deinit();

    try std.testing.expectEqual(SpanStatus.@"error", span.status);
    try std.testing.expect(std.mem.eql(u8, span.status_message.?, "rate limit exceeded"));
}

test "SpanFilter matches by kind" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(ParsedSpan);
    defer span.deinit();
    span.* = .{
        .span_id_hex = try allocator.dupe(u8, "def"),
        .trace_id_hex = try allocator.dupe(u8, "abc"),
        .parent_hex = null,
        .name = try allocator.dupe(u8, "test"),
        .kind = .llm,
        .status = .ok,
        .latency_ms = 100,
        .model = try allocator.dupe(u8, "gpt-4"),
        .provider = null,
        .tokens = null,
        .cost_usd = 0.001,
        .start_time_ns = 0,
        .end_time_ns = 100000000,
        .status_message = null,
        .allocator = allocator,
    };

    var filter = SpanFilter{ .kind = .llm };
    try std.testing.expect(filter.matches(span));

    filter.kind = .tool;
    try std.testing.expect(!filter.matches(span));
}

test "SpanFilter matches by status" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(ParsedSpan);
    defer span.deinit();
    span.* = .{
        .span_id_hex = try allocator.dupe(u8, "def"),
        .trace_id_hex = try allocator.dupe(u8, "abc"),
        .parent_hex = null,
        .name = try allocator.dupe(u8, "test"),
        .kind = .llm,
        .status = .@"error",
        .latency_ms = 100,
        .model = null,
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = 100000000,
        .status_message = null,
        .allocator = allocator,
    };

    var filter = SpanFilter{ .status = .@"error" };
    try std.testing.expect(filter.matches(span));

    filter.status = .ok;
    try std.testing.expect(!filter.matches(span));
}

test "SpanFilter matches by model" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(ParsedSpan);
    defer span.deinit();
    span.* = .{
        .span_id_hex = try allocator.dupe(u8, "def"),
        .trace_id_hex = try allocator.dupe(u8, "abc"),
        .parent_hex = null,
        .name = try allocator.dupe(u8, "test"),
        .kind = .llm,
        .status = .ok,
        .latency_ms = 100,
        .model = try allocator.dupe(u8, "gpt-4"),
        .provider = null,
        .tokens = null,
        .cost_usd = 0.001,
        .start_time_ns = 0,
        .end_time_ns = 100000000,
        .status_message = null,
        .allocator = allocator,
    };

    var filter = SpanFilter{ .model = "gpt-4" };
    try std.testing.expect(filter.matches(span));

    filter.model = "gpt-3.5";
    try std.testing.expect(!filter.matches(span));
}

test "classifyFailure detects timeout" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(ParsedSpan);
    defer span.deinit();
    span.* = .{
        .span_id_hex = try allocator.dupe(u8, "def"),
        .trace_id_hex = try allocator.dupe(u8, "abc"),
        .parent_hex = null,
        .name = try allocator.dupe(u8, "test"),
        .kind = .llm,
        .status = .timeout,
        .latency_ms = null,
        .model = try allocator.dupe(u8, "gpt-4"),
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .status_message = try allocator.dupe(u8, "operation timeout"),
        .allocator = allocator,
    };

    const diagnosis = classifyFailure(span);
    try std.testing.expectEqual(FailureClass.timeout, diagnosis.class);
}

test "classifyFailure detects rate limit" {
    const allocator = std.testing.allocator;

    const span = try allocator.create(ParsedSpan);
    defer span.deinit();
    span.* = .{
        .span_id_hex = try allocator.dupe(u8, "def"),
        .trace_id_hex = try allocator.dupe(u8, "abc"),
        .parent_hex = null,
        .name = try allocator.dupe(u8, "test"),
        .kind = .llm,
        .status = .@"error",
        .latency_ms = null,
        .model = try allocator.dupe(u8, "gpt-4"),
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .status_message = try allocator.dupe(u8, "429 rate limit exceeded"),
        .allocator = allocator,
    };

    const diagnosis = classifyFailure(span);
    try std.testing.expectEqual(FailureClass.rate_limit, diagnosis.class);
}

test "iso8601ToEpochNs parses valid timestamp" {
    const ns = try iso8601ToEpochNs("2026-04-28T12:00:00Z");

    // 2026-04-28 12:00:00 UTC
    // Verified: 1777377600 epoch seconds
    const expected_ns: i64 = 1777377600 * 1_000_000_000;

    try std.testing.expectEqual(expected_ns, ns);
}

test "iso8601ToEpochNs rejects invalid format" {
    try std.testing.expectError(error.InvalidFormat, iso8601ToEpochNs("2026-04-28T12:00:00"));
    try std.testing.expectError(error.InvalidFormat, iso8601ToEpochNs("2026/04/28T12:00:00Z"));
    try std.testing.expectError(error.InvalidMonth, iso8601ToEpochNs("2026-13-28T12:00:00Z"));
    try std.testing.expectError(error.InvalidDay, iso8601ToEpochNs("2026-04-32T12:00:00Z"));
    try std.testing.expectError(error.InvalidHour, iso8601ToEpochNs("2026-04-28T24:00:00Z"));
    try std.testing.expectError(error.InvalidMinute, iso8601ToEpochNs("2026-04-28T12:60:00Z"));
    try std.testing.expectError(error.InvalidSecond, iso8601ToEpochNs("2026-04-28T12:00:60Z"));
}
