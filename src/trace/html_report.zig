const std = @import("std");
const array_list_compat = @import("array_list_compat");
const reader_mod = @import("trace_reader");

const Allocator = std.mem.Allocator;
const TraceRun = reader_mod.TraceRun;
const ParsedSpan = reader_mod.ParsedSpan;

pub const HtmlReportConfig = struct {
    title: ?[]const u8 = null,
    include_input_output: bool = false,
    max_payload_chars: usize = 500,
};

/// Generate a self-contained HTML report from a TraceRun
pub fn generateHtmlReport(allocator: Allocator, run: *const TraceRun, config: HtmlReportConfig) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    const title = config.title orelse "Trace Report";

    // HTML head
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\"><head>\n");
    try w.writeAll("<meta charset=\"UTF-8\">\n");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try w.print("<title>{s}</title>\n", .{title});
    try w.writeAll("<style>\n");
    try writeCss(w);
    try w.writeAll("</style>\n</head><body>\n");

    // Header
    try w.print("<h1>{s}</h1>\n", .{title});
    try w.print("<p class=\"trace-id\">Trace ID: {s}</p>\n", .{run.trace_id_hex});

    // Summary cards
    try w.writeAll("<div class=\"summary-grid\">\n");
    try w.print("<div class=\"card\"><div class=\"card-label\">Duration</div><div class=\"card-value\">{d}ms</div></div>\n", .{run.total_duration_ms});
    try w.print("<div class=\"card\"><div class=\"card-label\">Cost</div><div class=\"card-value\">${d:.6}</div></div>\n", .{run.total_cost_usd});
    try w.print("<div class=\"card\"><div class=\"card-label\">Spans</div><div class=\"card-value\">{d} <small>({d} LLM, {d} Tool, {d} Agent)</small></div></div>\n", .{ run.span_count, run.llm_count, run.tool_count, run.agent_count });
    try w.print("<div class=\"card\"><div class=\"card-label\">Errors</div><div class=\"card-value\">{d} errors, {d} timeouts</div></div>\n", .{ run.error_count, run.timeout_count });
    try w.writeAll("</div>\n");

    // Timeline section
    try w.writeAll("<h2>Timeline</h2>\n<div class=\"timeline\">\n");
    if (run.spans.items.len > 0) {
        // Find time range
        var min_start: i64 = std.math.maxInt(i64);
        var max_end: i64 = 0;
        for (run.spans.items) |span| {
            if (span.start_time_ns < min_start) min_start = span.start_time_ns;
            if (span.end_time_ns) |e| {
                if (e > max_end) max_end = e;
            } else if (span.start_time_ns > max_end) {
                max_end = span.start_time_ns;
            }
        }
        const range_ns = max_end - min_start;
        const range_f: f64 = if (range_ns > 0) @floatFromInt(range_ns) else 1.0;

        for (run.spans.items) |span| {
            const offset_pct = if (range_ns > 0)
                @as(f64, @floatFromInt(span.start_time_ns - min_start)) / range_f * 100.0
            else
                0;
            const lat_ms = span.latency_ms orelse 0;
            const width_pct = if (run.total_duration_ms > 0)
                @as(f64, @floatFromInt(lat_ms)) / @as(f64, @floatFromInt(run.total_duration_ms)) * 100.0
            else
                0;
            const color = kindColor(span.kind);
            const status_class = switch (span.status) {
                .ok => "status-ok",
                .@"error" => "status-error",
                .timeout => "status-timeout",
            };
            try w.print("<div class=\"timeline-row\"><span class=\"tl-label\">", .{});
            try writeEscaped(w, span.name);
            try w.print(" ({d}ms)</span><div class=\"tl-bar {s}\" style=\"background:{s};left:{d:.1}%;width:{d:.1}%\"></div></div>\n", .{
                lat_ms,
                status_class,
                color,
                offset_pct,
                @max(width_pct, 0.5),
            });
        }
    }
    try w.writeAll("</div>\n");

    // Waterfall chart
    try w.writeAll("<h2>Waterfall</h2>\n<table class=\"waterfall\">\n");
    try w.writeAll("<tr><th>Name</th><th>Kind</th><th>Duration</th><th>Bar</th></tr>\n");
    for (run.spans.items) |span| {
        const lat = span.latency_ms orelse 0;
        const width_pct = if (run.total_duration_ms > 0)
            @as(f64, @floatFromInt(lat)) / @as(f64, @floatFromInt(run.total_duration_ms)) * 100.0
        else
            0;
        try w.writeAll("<tr><td>");
        try writeEscaped(w, span.name);
        try w.print("</td><td class=\"kind-{s}\">{s}</td><td>{d}ms</td>", .{ @tagName(span.kind), @tagName(span.kind), lat });
        try w.print("<td><div class=\"wf-bar\" style=\"background:{s};width:{d:.1}%\"></div></td></tr>\n", .{ kindColor(span.kind), @max(width_pct, 0.5) });
    }
    try w.writeAll("</table>\n");

    // Span tree
    try w.writeAll("<h2>Span Tree</h2>\n<ul class=\"span-tree\">\n");
    // Build parent → children map
    var parent_map = std.StringHashMap(array_list_compat.ArrayList(*ParsedSpan)).init(allocator);
    defer {
        var it = parent_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        parent_map.deinit();
    }
    for (run.spans.items) |span| {
        if (span.parent_hex) |pid| {
            const entry = try parent_map.getOrPut(pid);
            if (!entry.found_existing) entry.value_ptr.* = array_list_compat.ArrayList(*ParsedSpan).init(allocator);
            try entry.value_ptr.append(span);
        }
    }
    // Render root spans (no parent)
    for (run.spans.items) |span| {
        if (span.parent_hex == null) {
            try writeSpanNode(w, span, &parent_map, 0);
        }
    }
    try w.writeAll("</ul>\n");

    // Cost/Token breakdown
    try w.writeAll("<h2>Cost Breakdown</h2>\n<table>\n");
    try w.writeAll("<tr><th>Model</th><th>Prompt</th><th>Completion</th><th>Total</th><th>Cost</th></tr>\n");
    var total_prompt: u32 = 0;
    var total_comp: u32 = 0;
    var total_tok: u32 = 0;
    var total_cost: f64 = 0;
    for (run.spans.items) |span| {
        if (span.kind == .llm and span.model != null) {
            const pt = if (span.tokens) |tok| tok.prompt orelse 0 else 0;
            const ct = if (span.tokens) |tok| tok.completion orelse 0 else 0;
            const tt = if (span.tokens) |tok| tok.total orelse 0 else 0;
            const c = span.cost_usd orelse 0;
            total_prompt += pt;
            total_comp += ct;
            total_tok += tt;
            total_cost += c;
            try w.print("<tr><td>", .{});
            try writeEscaped(w, span.model.?);
            try w.print("</td><td>{d}</td><td>{d}</td><td>{d}</td><td>${d:.6}</td></tr>\n", .{ pt, ct, tt, c });
        }
    }
    try w.print("<tr class=\"total\"><td>Total</td><td>{d}</td><td>{d}</td><td>{d}</td><td>${d:.6}</td></tr>\n", .{ total_prompt, total_comp, total_tok, total_cost });
    try w.writeAll("</table>\n");

    // Failures section
    if (run.error_count > 0 or run.timeout_count > 0) {
        try w.writeAll("<h2>Failures</h2>\n<table>\n");
        try w.writeAll("<tr><th>Span</th><th>Class</th><th>Hint</th><th>Message</th></tr>\n");
        const failures = reader_mod.diagnoseFailures(allocator, run) catch &.{};
        defer allocator.free(failures);
        for (failures) |diag| {
            try w.writeAll("<tr><td>");
            try writeEscaped(w, diag.span.name);
            try w.print("</td><td>{s}</td><td>{s}</td><td>", .{ @tagName(diag.class), diag.cause_hint });
            if (diag.span.status_message) |msg| try writeEscaped(w, msg) else try w.writeAll("-");
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</table>\n");
    }

    try w.writeAll("<script>\nfunction toggleSpan(id){var e=document.getElementById(id);if(e){e.style.display=e.style.display==='none'?'block':'none';}}\n</script>\n");
    try w.writeAll("</body></html>");

    return try buf.toOwnedSlice();
}

fn writeSpanNode(w: anytype, span: *const ParsedSpan, parent_map: anytype, depth: usize) !void {
    const indent = depth * 20;
    const status_class = switch (span.status) {
        .ok => "ok",
        .@"error" => "err",
        .timeout => "tmo",
    };
    const lat = span.latency_ms orelse 0;
    try w.print("<li style=\"margin-left:{d}px\" class=\"span-node\">", .{indent});
    try w.print("<span class=\"badge kind-{s}\">{s}</span> ", .{ @tagName(span.kind), @tagName(span.kind) });
    try writeEscaped(w, span.name);
    try w.print(" <span class=\"badge {s}\">{s}</span> <small>{d}ms</small>", .{ status_class, @tagName(span.status), lat });
    if (span.model) |m| try w.print(" <small>{s}</small>", .{m});

    if (parent_map.get(span.span_id_hex)) |children| {
        if (children.items.len > 0) {
            try w.print(" <a href=\"javascript:void(0)\" onclick=\"toggleSpan('c-{s}')\">[+]</a>", .{span.span_id_hex});
            try w.print("<ul id=\"c-{s}\" style=\"display:none\">\n", .{span.span_id_hex});
            for (children.items) |child| {
                try writeSpanNode(w, child, parent_map, 0);
            }
            try w.writeAll("</ul>\n");
        }
    }
    try w.writeAll("</li>\n");
}

fn kindColor(kind: reader_mod.SpanKind) []const u8 {
    return switch (kind) {
        .llm => "#3498db",
        .tool => "#2ecc71",
        .agent => "#9b59b6",
        .chain => "#e67e22",
        .guardrail => "#e74c3c",
    };
}

fn writeEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

fn writeCss(w: anytype) !void {
    try w.writeAll(
        \\:root{--bg:#1a1a2e;--surface:#16213e;--accent:#0f3460;--text:#e6e6e6;--error:#e74c3c;--ok:#2ecc71;--timeout:#f39c12}
        \\*{box-sizing:border-box;margin:0;padding:0}
        \\body{font-family:'SF Mono',Monaco,Consolas,monospace;background:var(--bg);color:var(--text);max-width:1200px;margin:0 auto;padding:20px;line-height:1.6}
        \\h1{color:#fff;border-bottom:2px solid var(--accent);padding-bottom:10px}
        \\h2{color:#ddd;margin-top:30px;margin-bottom:10px}
        \\.trace-id{color:#888;font-size:0.85em}
        \\.summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:20px 0}
        \\.card{background:var(--surface);border-radius:8px;padding:16px;text-align:center}
        \\.card-label{font-size:0.8em;color:#888;margin-bottom:4px}
        \\.card-value{font-size:1.3em;font-weight:bold}
        \\table{width:100%;border-collapse:collapse;margin:10px 0}
        \\th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #333}
        \\th{background:var(--accent);color:#fff}
        \\.total td{font-weight:bold;border-top:2px solid var(--accent)}
        \\.timeline{position:relative;height:auto;min-height:40px}
        \\.timeline-row{position:relative;height:28px;margin:2px 0;display:flex;align-items:center}
        \\.tl-label{width:200px;font-size:0.8em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\.tl-bar{position:absolute;left:210px;height:18px;border-radius:3px;min-width:3px;opacity:0.8}
        \\.status-error{border:2px dashed var(--error)}
        \\.status-timeout{border:2px dashed var(--timeout)}
        \\.waterfall td{padding:6px 10px}
        \\.wf-bar{height:16px;border-radius:3px;min-width:3px}
        \\.span-tree{list-style:none;padding-left:0}
        \\.span-node{padding:4px 0}
        \\.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:0.75em;font-weight:bold;margin-right:4px}
        \\.kind-llm{background:#3498db33;color:#3498db}
        \\.kind-tool{background:#2ecc7133;color:#2ecc71}
        \\.kind-agent{background:#9b59b633;color:#9b59b6}
        \\.kind-chain{background:#e67e2233;color:#e67e22}
        \\.kind-guardrail{background:#e74c3c33;color:#e74c3c}
        \\.ok{background:var(--ok);color:#fff}
        \\.err{background:var(--error);color:#fff}
        \\.tmo{background:var(--timeout);color:#fff}
        \\small{color:#999}
        \\a{color:#3498db;text-decoration:none;cursor:pointer}
    );
}
