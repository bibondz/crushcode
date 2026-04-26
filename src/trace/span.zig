const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Re-export context module for consumers that need trace/span context
pub const context = @import("context.zig");

const Allocator = std.mem.Allocator;

/// Kind of span for categorizing operations
pub const SpanKind = enum {
    llm,
    tool,
    agent,
    chain,
    guardrail,
};

/// Status of a completed span
pub const SpanStatus = enum {
    ok,
    @"error",
    timeout,
};

const max_payload_size: usize = 4096;
const truncation_suffix = "...<truncated>";

/// Truncate data to max_payload_size bytes, appending truncation suffix when needed
fn truncate(allocator: Allocator, data: []const u8) ![]const u8 {
    if (data.len <= max_payload_size) {
        return try allocator.dupe(u8, data);
    }
    const result = try allocator.alloc(u8, max_payload_size + truncation_suffix.len);
    @memcpy(result[0..max_payload_size], data[0..max_payload_size]);
    @memcpy(result[max_payload_size .. max_payload_size + truncation_suffix.len], truncation_suffix);
    return result;
}

/// A single observable operation within a trace.
/// Tracks timing, cost, and I/O for LLM calls, tool executions, agent steps, etc.
pub const Span = struct {
    id: [16]u8,
    trace_id: [16]u8,
    parent_span_id: ?[16]u8,
    name: []const u8,
    kind: SpanKind,
    start_time_ns: i64,
    end_time_ns: ?i64,
    latency_ms: ?u64,
    status: SpanStatus,
    status_message: ?[]const u8,
    input_json: ?[]const u8,
    output_json: ?[]const u8,
    model: ?[]const u8,
    provider: ?[]const u8,
    prompt_tokens: ?u32,
    completion_tokens: ?u32,
    total_tokens: ?u32,
    cost_usd: ?f64,
    allocator: Allocator,

    /// Create a new span with a random ID and current monotonic timestamp.
    /// All string fields are owned by the span's allocator.
    pub fn init(allocator: Allocator, trace_id: [16]u8, parent_id: ?[16]u8, name: []const u8, kind: SpanKind) !*Span {
        const span = try allocator.create(Span);
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        span.* = .{
            .id = id,
            .trace_id = trace_id,
            .parent_span_id = parent_id,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .start_time_ns = @intCast(std.time.nanoTimestamp()),
            .end_time_ns = null,
            .latency_ms = null,
            .status = .ok,
            .status_message = null,
            .input_json = null,
            .output_json = null,
            .model = null,
            .provider = null,
            .prompt_tokens = null,
            .completion_tokens = null,
            .total_tokens = null,
            .cost_usd = null,
            .allocator = allocator,
        };
        return span;
    }

    /// End the span, recording status and optional output.
    /// Calculates latency from the difference between end and start timestamps.
    pub fn end(self: *Span, status: SpanStatus, output: ?[]const u8) void {
        const end_ts = std.time.nanoTimestamp();
        self.end_time_ns = @intCast(end_ts);
        const diff = end_ts - @as(i128, @intCast(self.start_time_ns));
        if (diff >= 0) {
            self.latency_ms = @intCast(@divTrunc(diff, 1_000_000));
        }
        self.status = status;
        if (output) |out| {
            self.output_json = truncate(self.allocator, out) catch null;
        }
    }

    /// Free all owned strings and the span itself
    pub fn deinit(self: *Span) void {
        self.allocator.free(self.name);
        if (self.status_message) |msg| self.allocator.free(msg);
        if (self.input_json) |inp| self.allocator.free(inp);
        if (self.output_json) |out| self.allocator.free(out);
        if (self.model) |m| self.allocator.free(m);
        if (self.provider) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }
};

/// A collection of spans forming a complete request chain.
/// All spans in a trace share the same trace_id for correlation.
pub const Trace = struct {
    id: [16]u8,
    session_id: []const u8,
    spans: array_list_compat.ArrayList(*Span),
    total_cost_usd: f64,
    total_duration_ms: u64,
    start_time_ns: i64,
    allocator: Allocator,

    /// Create a new trace with a random ID for the given session
    pub fn init(allocator: Allocator, session_id: []const u8) !*Trace {
        const trace = try allocator.create(Trace);
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        trace.* = .{
            .id = id,
            .session_id = try allocator.dupe(u8, session_id),
            .spans = array_list_compat.ArrayList(*Span).init(allocator),
            .total_cost_usd = 0,
            .total_duration_ms = 0,
            .start_time_ns = @intCast(std.time.nanoTimestamp()),
            .allocator = allocator,
        };
        return trace;
    }

    /// Create a root span (no parent) attached to this trace
    pub fn rootSpan(self: *Trace, name: []const u8, kind: SpanKind) !*Span {
        const span = try Span.init(self.allocator, self.id, null, name, kind);
        try self.spans.append(span);
        return span;
    }

    /// Create a child span under the given parent span
    pub fn childSpan(self: *Trace, parent: *Span, name: []const u8, kind: SpanKind) !*Span {
        const span = try Span.init(self.allocator, self.id, parent.id, name, kind);
        try self.spans.append(span);
        return span;
    }

    /// Finalize the trace: sum all span costs and calculate total wall-clock duration
    pub fn finish(self: *Trace) void {
        self.total_cost_usd = 0;
        var max_end: i64 = 0;
        for (self.spans.items) |span| {
            self.total_cost_usd += span.cost_usd orelse 0;
            if (span.end_time_ns) |et| {
                if (et > max_end) max_end = et;
            }
        }
        if (max_end > self.start_time_ns) {
            const diff = max_end - self.start_time_ns;
            self.total_duration_ms = @intCast(@divTrunc(diff, 1_000_000));
        }
    }

    /// Free all spans, the session_id, and the trace itself
    pub fn deinit(self: *Trace) void {
        for (self.spans.items) |span| {
            span.deinit();
        }
        self.spans.deinit();
        self.allocator.free(self.session_id);
        self.allocator.destroy(self);
    }
};
