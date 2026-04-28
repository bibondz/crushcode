const std = @import("std");
const array_list_compat = @import("array_list_compat");
const reader_mod = @import("trace_reader");

const Allocator = std.mem.Allocator;
const TraceRun = reader_mod.TraceRun;
const ParsedSpan = reader_mod.ParsedSpan;

/// Convert an integer to f64 (Zig 0.15 requires explicit result type)
inline fn toF(v: anytype) f64 {
    return @as(f64, @floatFromInt(v));
}

/// A single comparison dimension between two runs
pub const MetricDelta = struct {
    name: []const u8, // static string, not owned
    run_a_value: f64,
    run_b_value: f64,
    delta: f64, // run_b - run_a (positive = run_b is higher)
    delta_percent: f64, // percentage change: (delta / run_a_value) * 100, 0 if run_a is 0
    lower_is_better: bool, // true for cost/latency/errors, false for throughput
};

/// Overall comparison verdict
pub const Verdict = enum {
    run_a_better,
    run_b_better,
    similar,
};

/// Per-tool count change between runs
pub const ToolUsageDiff = struct {
    tool_name: []const u8, // owned
    run_a_count: usize,
    run_b_count: usize,
    delta: i32, // run_b - run_a

    pub fn deinit(self: *ToolUsageDiff, allocator: Allocator) void {
        allocator.free(self.tool_name);
    }
};

/// Full comparison result
pub const TraceComparison = struct {
    run_a_id: []const u8, // owned
    run_b_id: []const u8, // owned
    metrics: []MetricDelta, // owned slice
    tool_diffs: []ToolUsageDiff, // owned slice
    verdict: Verdict,
    summary: []const u8, // owned
    allocator: Allocator,

    pub fn deinit(self: *TraceComparison) void {
        self.allocator.free(self.run_a_id);
        self.allocator.free(self.run_b_id);
        self.allocator.free(self.metrics);
        for (self.tool_diffs) |*td| {
            td.deinit(self.allocator);
        }
        self.allocator.free(self.tool_diffs);
        self.allocator.free(self.summary);
    }
};

/// Compute total tokens across all spans in a run
fn totalTokens(run: *const TraceRun) f64 {
    var total: f64 = 0;
    for (run.spans.items) |span| {
        if (span.tokens) |tok| {
            if (tok.total) |t| {
                total += toF(t);
            }
        }
    }
    return total;
}

/// Count tool spans by name
fn countTools(allocator: Allocator, run: *const TraceRun) !std.StringHashMap(usize) {
    var counts = std.StringHashMap(usize).init(allocator);
    for (run.spans.items) |span| {
        if (span.kind == .tool) {
            const entry = try counts.getOrPut(span.name);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }
    }
    return counts;
}

/// Compute delta percent, handling zero denominator
fn deltaPercent(a: f64, b: f64) f64 {
    if (a == 0) return 0;
    return ((b - a) / a) * 100.0;
}

/// Determine verdict from metric deltas
fn computeVerdict(metrics: []const MetricDelta) Verdict {
    var a_wins: usize = 0;
    var b_wins: usize = 0;
    for (metrics) |m| {
        if (m.delta_percent < -5.0) {
            if (m.lower_is_better) a_wins += 1 else b_wins += 1;
        } else if (m.delta_percent > 5.0) {
            if (m.lower_is_better) b_wins += 1 else a_wins += 1;
        }
    }
    const total = metrics.len;
    if (total == 0) return .similar;
    if (a_wins * 2 > total) return .run_a_better;
    if (b_wins * 2 > total) return .run_b_better;
    return .similar;
}

/// Compare two trace runs across multiple dimensions
pub fn compareTraces(allocator: Allocator, run_a: *const TraceRun, run_b: *const TraceRun) !*TraceComparison {
    var metrics_list = array_list_compat.ArrayList(MetricDelta).init(allocator);
    defer metrics_list.deinit();

    const tt_a = totalTokens(run_a);
    const tt_b = totalTokens(run_b);

    // 1. Total Cost
    try metrics_list.append(.{
        .name = "Total Cost",
        .run_a_value = run_a.total_cost_usd,
        .run_b_value = run_b.total_cost_usd,
        .delta = run_b.total_cost_usd - run_a.total_cost_usd,
        .delta_percent = deltaPercent(run_a.total_cost_usd, run_b.total_cost_usd),
        .lower_is_better = true,
    });

    // 2. Total Latency
    try metrics_list.append(.{
        .name = "Latency",
        .run_a_value = toF(run_a.total_duration_ms),
        .run_b_value = toF(run_b.total_duration_ms),
        .delta = toF(run_b.total_duration_ms) - toF(run_a.total_duration_ms),
        .delta_percent = deltaPercent(toF(run_a.total_duration_ms), toF(run_b.total_duration_ms)),
        .lower_is_better = true,
    });

    // 3. Span Count
    try metrics_list.append(.{
        .name = "Span Count",
        .run_a_value = toF(run_a.span_count),
        .run_b_value = toF(run_b.span_count),
        .delta = toF(run_b.span_count) - toF(run_a.span_count),
        .delta_percent = deltaPercent(toF(run_a.span_count), toF(run_b.span_count)),
        .lower_is_better = true,
    });

    // 4. LLM Calls
    try metrics_list.append(.{
        .name = "LLM Calls",
        .run_a_value = toF(run_a.llm_count),
        .run_b_value = toF(run_b.llm_count),
        .delta = toF(run_b.llm_count) - toF(run_a.llm_count),
        .delta_percent = deltaPercent(toF(run_a.llm_count), toF(run_b.llm_count)),
        .lower_is_better = true,
    });

    // 5. Tool Calls
    try metrics_list.append(.{
        .name = "Tool Calls",
        .run_a_value = toF(run_a.tool_count),
        .run_b_value = toF(run_b.tool_count),
        .delta = toF(run_b.tool_count) - toF(run_a.tool_count),
        .delta_percent = deltaPercent(toF(run_a.tool_count), toF(run_b.tool_count)),
        .lower_is_better = true,
    });

    // 6. Error Count
    try metrics_list.append(.{
        .name = "Errors",
        .run_a_value = toF(run_a.error_count),
        .run_b_value = toF(run_b.error_count),
        .delta = toF(run_b.error_count) - toF(run_a.error_count),
        .delta_percent = deltaPercent(toF(run_a.error_count), toF(run_b.error_count)),
        .lower_is_better = true,
    });

    // 7. Token Efficiency (tokens per span)
    const tps_a: f64 = if (run_a.span_count > 0) tt_a / toF(run_a.span_count) else 0;
    const tps_b: f64 = if (run_b.span_count > 0) tt_b / toF(run_b.span_count) else 0;
    try metrics_list.append(.{
        .name = "Token Efficiency",
        .run_a_value = tps_a,
        .run_b_value = tps_b,
        .delta = tps_b - tps_a,
        .delta_percent = deltaPercent(tps_a, tps_b),
        .lower_is_better = true,
    });

    // 8. Cost Efficiency (cost per token)
    const cpt_a: f64 = if (tt_a > 0) run_a.total_cost_usd / tt_a else 0;
    const cpt_b: f64 = if (tt_b > 0) run_b.total_cost_usd / tt_b else 0;
    try metrics_list.append(.{
        .name = "Cost Efficiency",
        .run_a_value = cpt_a,
        .run_b_value = cpt_b,
        .delta = cpt_b - cpt_a,
        .delta_percent = deltaPercent(cpt_a, cpt_b),
        .lower_is_better = true,
    });

    const metrics = try metrics_list.toOwnedSlice();

    // Tool usage diff
    var tools_a = try countTools(allocator, run_a);
    defer tools_a.deinit();
    var tools_b = try countTools(allocator, run_b);
    defer tools_b.deinit();

    var diffs_list = array_list_compat.ArrayList(ToolUsageDiff).init(allocator);
    defer diffs_list.deinit();

    // Collect all unique tool names
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var iter = tools_a.iterator();
    while (iter.next()) |entry| {
        try seen.put(entry.key_ptr.*, {});
    }
    iter = tools_b.iterator();
    while (iter.next()) |entry| {
        try seen.put(entry.key_ptr.*, {});
    }

    var seen_iter = seen.iterator();
    while (seen_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const count_a = tools_a.get(name) orelse 0;
        const count_b = tools_b.get(name) orelse 0;
        try diffs_list.append(.{
            .tool_name = try allocator.dupe(u8, name),
            .run_a_count = count_a,
            .run_b_count = count_b,
            .delta = @as(i32, @intCast(count_b)) - @as(i32, @intCast(count_a)),
        });
    }

    const tool_diffs = try diffs_list.toOwnedSlice();
    const verdict = computeVerdict(metrics);

    // Build summary
    const verdict_str = switch (verdict) {
        .run_a_better => "Run A is better",
        .run_b_better => "Run B is better",
        .similar => "Similar performance",
    };

    const summary = try std.fmt.allocPrint(allocator,
        \\Run A ({s}) vs Run B ({s})
        \\ Cost: {d:.6} -> {d:.6} ({d:.1}%)
        \\ Latency: {d}ms -> {d}ms ({d:.1}%)
        \\ Errors: {d} -> {d}
        \\ Verdict: {s}
    , .{
        run_a.trace_id_hex,
        run_b.trace_id_hex,
        run_a.total_cost_usd,
        run_b.total_cost_usd,
        metrics[0].delta_percent,
        run_a.total_duration_ms,
        run_b.total_duration_ms,
        metrics[1].delta_percent,
        run_a.error_count,
        run_b.error_count,
        verdict_str,
    });

    const result = try allocator.create(TraceComparison);
    result.* = .{
        .run_a_id = try allocator.dupe(u8, run_a.trace_id_hex),
        .run_b_id = try allocator.dupe(u8, run_b.trace_id_hex),
        .metrics = metrics,
        .tool_diffs = tool_diffs,
        .verdict = verdict,
        .summary = summary,
        .allocator = allocator,
    };
    return result;
}

// --- Tests ---

test "compareTraces computes cost delta" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.01,
        .total_duration_ms = 1000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.02,
        .total_duration_ms = 2000,
        .span_count = 8,
        .error_count = 1,
        .timeout_count = 0,
        .llm_count = 5,
        .tool_count = 3,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // Cost delta: run_b - run_a = 0.02 - 0.01 = 0.01
    try testing.expectApproxEqAbs(@as(f64, 0.01), comp.metrics[0].delta, 0.0001);
    try testing.expect(comp.metrics[0].name.len > 0);
}

test "compareTraces computes latency delta" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.01,
        .total_duration_ms = 1000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.01,
        .total_duration_ms = 3000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // Latency delta: 3000 - 1000 = 2000
    try testing.expectApproxEqAbs(@as(f64, 2000), comp.metrics[1].delta, 0.01);
}

test "compareTraces computes tool usage diff" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create spans with tool kind
    const name_read = "read";
    const name_write = "write";
    var span_a1 = ParsedSpan{
        .span_id_hex = "s1",
        .trace_id_hex = "aaa",
        .parent_hex = null,
        .name = name_read,
        .kind = .tool,
        .status = .ok,
        .status_message = null,
        .latency_ms = 100,
        .model = null,
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .allocator = allocator,
    };
    var span_b1 = ParsedSpan{
        .span_id_hex = "s2",
        .trace_id_hex = "bbb",
        .parent_hex = null,
        .name = name_read,
        .kind = .tool,
        .status = .ok,
        .status_message = null,
        .latency_ms = 100,
        .model = null,
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .allocator = allocator,
    };
    var span_b2 = ParsedSpan{
        .span_id_hex = "s3",
        .trace_id_hex = "bbb",
        .parent_hex = null,
        .name = name_write,
        .kind = .tool,
        .status = .ok,
        .status_message = null,
        .latency_ms = 200,
        .model = null,
        .provider = null,
        .tokens = null,
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .allocator = allocator,
    };

    var spans_a = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    try spans_a.append(&span_a1);
    var spans_b = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    try spans_b.append(&span_b1);
    try spans_b.append(&span_b2);

    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = spans_a,
        .total_cost_usd = 0,
        .total_duration_ms = 100,
        .span_count = 1,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 0,
        .tool_count = 1,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = spans_b,
        .total_cost_usd = 0,
        .total_duration_ms = 300,
        .span_count = 2,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 0,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // Should have 2 tool diffs: read (1 vs 1), write (0 vs 1)
    try testing.expect(comp.tool_diffs.len >= 1);
}

test "compareTraces computes token efficiency" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var span_a = ParsedSpan{
        .span_id_hex = "s1",
        .trace_id_hex = "aaa",
        .parent_hex = null,
        .name = "chat",
        .kind = .llm,
        .status = .ok,
        .status_message = null,
        .latency_ms = 500,
        .model = null,
        .provider = null,
        .tokens = .{ .prompt = 100, .completion = 50, .total = 150 },
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .allocator = allocator,
    };
    var span_b = ParsedSpan{
        .span_id_hex = "s2",
        .trace_id_hex = "bbb",
        .parent_hex = null,
        .name = "chat",
        .kind = .llm,
        .status = .ok,
        .status_message = null,
        .latency_ms = 600,
        .model = null,
        .provider = null,
        .tokens = .{ .prompt = 200, .completion = 100, .total = 300 },
        .cost_usd = null,
        .start_time_ns = 0,
        .end_time_ns = null,
        .allocator = allocator,
    };

    var spans_a = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    try spans_a.append(&span_a);
    var spans_b = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
    try spans_b.append(&span_b);

    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = spans_a,
        .total_cost_usd = 0.001,
        .total_duration_ms = 500,
        .span_count = 1,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 1,
        .tool_count = 0,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = spans_b,
        .total_cost_usd = 0.002,
        .total_duration_ms = 600,
        .span_count = 1,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 1,
        .tool_count = 0,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // Token efficiency: 150/1 vs 300/1
    try testing.expectApproxEqAbs(@as(f64, 150.0), comp.metrics[6].run_a_value, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 300.0), comp.metrics[6].run_b_value, 0.01);
}

test "verdict is run_a_better when run_a has lower cost" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // run_a significantly better on cost (50% cheaper)
    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.001,
        .total_duration_ms = 1000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.005,
        .total_duration_ms = 1000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // run_a has lower cost (400% delta), should win
    try testing.expect(comp.verdict == .run_a_better);
}

test "verdict is similar when deltas within 5%" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Nearly identical runs
    var run_a = TraceRun{
        .trace_id_hex = "aaa",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.010,
        .total_duration_ms = 1000,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };
    var run_b = TraceRun{
        .trace_id_hex = "bbb",
        .spans = array_list_compat.ArrayList(*ParsedSpan).init(allocator),
        .total_cost_usd = 0.0102,
        .total_duration_ms = 1010,
        .span_count = 5,
        .error_count = 0,
        .timeout_count = 0,
        .llm_count = 3,
        .tool_count = 2,
        .agent_count = 0,
        .first_ts = null,
        .allocator = allocator,
    };

    var comp = try compareTraces(allocator, &run_a, &run_b);
    defer comp.deinit();

    // All deltas within 5%, should be similar
    try testing.expect(comp.verdict == .similar);
}
