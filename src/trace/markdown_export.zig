const std = @import("std");
const array_list_compat = @import("array_list_compat");
const reader_mod = @import("trace_reader");

const Allocator = std.mem.Allocator;
const TraceRun = reader_mod.TraceRun;

/// Export a TraceRun as a formatted Markdown string
pub fn exportMarkdown(allocator: Allocator, run: *const TraceRun) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("# Trace Report: {s}\n\n", .{run.trace_id_hex});

    // Summary table
    try w.writeAll("## Summary\n\n");
    try w.writeAll("| Metric | Value |\n");
    try w.writeAll("|--------|-------|\n");
    try w.print("| Duration | {d}ms |\n", .{run.total_duration_ms});
    try w.print("| Cost | ${d:.6} |\n", .{run.total_cost_usd});
    try w.print("| Spans | {d} ({d} LLM, {d} Tool, {d} Agent) |\n", .{
        run.span_count,
        run.llm_count,
        run.tool_count,
        run.agent_count,
    });
    try w.print("| Errors | {d} errors, {d} timeouts |\n\n", .{ run.error_count, run.timeout_count });

    // Spans table
    try w.writeAll("## Spans\n\n");
    try w.writeAll("| # | Name | Kind | Status | Latency | Model | Tokens | Cost |\n");
    try w.writeAll("|---|------|------|--------|---------|-------|--------|------|\n");

    for (run.spans.items, 0..) |span, i| {
        const lat = if (span.latency_ms) |l| l else 0;
        const model = if (span.model) |m| m else "-";
        const tokens_str = if (span.tokens) |tok|
            try std.fmt.allocPrint(allocator, "{d}", .{tok.total orelse 0})
        else
            "-";
        defer if (span.tokens != null) allocator.free(tokens_str);
        const cost_str = if (span.cost_usd) |c|
            try std.fmt.allocPrint(allocator, "${d:.6}", .{c})
        else
            "-";
        defer if (span.cost_usd != null) allocator.free(cost_str);

        try w.print("| {d} | {s} | {s} | {s} | {d}ms | {s} | {s} | {s} |\n", .{
            i + 1,
            span.name,
            @tagName(span.kind),
            @tagName(span.status),
            lat,
            model,
            tokens_str,
            cost_str,
        });
    }

    // Cost breakdown
    try w.writeAll("\n## Cost Breakdown\n\n");
    try w.writeAll("| Model | Prompt | Completion | Total | Cost |\n");
    try w.writeAll("|-------|--------|------------|-------|------|\n");

    for (run.spans.items) |span| {
        if (span.kind == .llm and span.model != null) {
            try w.print("| {s} | {d} | {d} | {d} | ${d:.6} |\n", .{
                span.model.?,
                span.tokens.?.prompt orelse 0,
                span.tokens.?.completion orelse 0,
                span.tokens.?.total orelse 0,
                span.cost_usd orelse 0,
            });
        }
    }

    // Failures section (only if errors exist)
    if (run.error_count > 0 or run.timeout_count > 0) {
        try w.writeAll("\n## Failures\n\n");
        const failures = reader_mod.diagnoseFailures(allocator, run) catch &.{};
        defer allocator.free(failures);
        for (failures) |diag| {
            try w.print("- **{s}** ({s}): {s}\n", .{
                diag.span.name,
                @tagName(diag.class),
                diag.cause_hint,
            });
        }
    }

    return try buf.toOwnedSlice();
}
