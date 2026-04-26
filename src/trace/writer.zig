const std = @import("std");
const span_mod = @import("span.zig");

const Allocator = std.mem.Allocator;
const Span = span_mod.Span;
const Trace = span_mod.Trace;

/// JSON-serializable representation of a span for trace file output
const SpanRecord = struct {
    ts: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent: ?[]const u8,
    name: []const u8,
    kind: []const u8,
    status: []const u8,
    latency_ms: ?u64,
    model: ?[]const u8,
    tokens: ?TokenRecord,
    cost_usd: ?f64,
};

/// Token usage sub-record for JSON serialization
const TokenRecord = struct {
    prompt: ?u32,
    completion: ?u32,
    total: ?u32,
};

/// Encode a 16-byte ID as a lowercase hex string (32 chars)
fn hexEncode(allocator: Allocator, bytes: *const [16]u8) ![]const u8 {
    const hex_bytes = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex_bytes);
}

/// Convert Unix epoch seconds to ISO8601 format (YYYY-MM-DDTHH:MM:SSZ)
fn epochToIso8601(allocator: Allocator, epoch_seconds: i64) ![]const u8 {
    // Days since Unix epoch
    const total_days: i64 = @divTrunc(epoch_seconds, 86400);
    const secs_of_day: i64 = @mod(epoch_seconds, 86400);

    // Estimate year from total_days
    var remaining_days: i64 = total_days;
    var year: i64 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    // Month and day lookup
    const month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: i64 = 0;
    while (month < 12) {
        var dim: i64 = month_days[@intCast(month)];
        if (month == 1 and isLeapYear(year)) dim = 29;
        if (remaining_days < dim) break;
        remaining_days -= dim;
        month += 1;
    }
    const day: i64 = remaining_days + 1;
    const month_1indexed: i64 = month + 1;

    // Time of day
    const hour: i64 = @divTrunc(secs_of_day, 3600);
    const minute: i64 = @divTrunc(@mod(secs_of_day, 3600), 60);
    const second: i64 = @mod(secs_of_day, 60);

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(year)),
        @as(u64, @intCast(month_1indexed)),
        @as(u64, @intCast(day)),
        @as(u64, @intCast(hour)),
        @as(u64, @intCast(minute)),
        @as(u64, @intCast(second)),
    });
}

fn isLeapYear(year: i64) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

/// JSONL append-only trace writer.
/// Each span is serialized as a single JSON line appended to `{traces_dir}/{hex(trace_id)}.jsonl`.
pub const TraceWriter = struct {
    allocator: Allocator,
    traces_dir: []const u8,

    /// Create a new TraceWriter that persists traces to the given directory
    pub fn init(allocator: Allocator, traces_dir: []const u8) !TraceWriter {
        return TraceWriter{
            .allocator = allocator,
            .traces_dir = try allocator.dupe(u8, traces_dir),
        };
    }

    /// Append a single span as a JSON line to its trace file.
    /// Creates the traces directory and file if they don't exist.
    pub fn writeSpan(self: *TraceWriter, s: *const Span) !void {
        // Ensure traces directory exists
        std.fs.cwd().makePath(self.traces_dir) catch {};

        // Build filename: {traces_dir}/{hex(trace_id)}.jsonl
        const trace_id_hex = std.fmt.bytesToHex(&s.trace_id, .lower);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}.jsonl", .{
            self.traces_dir,
            &trace_id_hex,
        });
        defer self.allocator.free(filename);

        // Build JSON record from span fields
        const ts = try epochToIso8601(self.allocator, std.time.timestamp());
        defer self.allocator.free(ts);

        const trace_hex = try hexEncode(self.allocator, &s.trace_id);
        defer self.allocator.free(trace_hex);

        const span_hex = try hexEncode(self.allocator, &s.id);
        defer self.allocator.free(span_hex);

        const parent_hex: ?[]const u8 = if (s.parent_span_id) |pid|
            try hexEncode(self.allocator, &pid)
        else
            null;
        defer {
            if (parent_hex) |h| self.allocator.free(h);
        }

        // Only emit tokens sub-object if any token field is set
        var tokens: ?TokenRecord = null;
        if (s.prompt_tokens != null or s.completion_tokens != null or s.total_tokens != null) {
            tokens = TokenRecord{
                .prompt = s.prompt_tokens,
                .completion = s.completion_tokens,
                .total = s.total_tokens,
            };
        }

        const record = SpanRecord{
            .ts = ts,
            .trace_id = trace_hex,
            .span_id = span_hex,
            .parent = parent_hex,
            .name = s.name,
            .kind = @tagName(s.kind),
            .status = @tagName(s.status),
            .latency_ms = s.latency_ms,
            .model = s.model,
            .tokens = tokens,
            .cost_usd = s.cost_usd,
        };

        const json_line = try stringifyJson(self.allocator, record);
        defer self.allocator.free(json_line);

        // Append JSON line to the trace file
        const file = try std.fs.cwd().createFile(filename, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(json_line);
        try file.writeAll("\n");
    }

    /// Write all spans from a finished trace to the JSONL file
    pub fn writeTrace(self: *TraceWriter, trace: *const Trace) !void {
        for (trace.spans.items) |s| {
            try self.writeSpan(s);
        }
    }

    /// Free the owned traces_dir string
    pub fn deinit(self: *TraceWriter) void {
        self.allocator.free(self.traces_dir);
    }
};

/// Serialize a value to a JSON string using std.json.fmt
fn stringifyJson(allocator: Allocator, value: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}
