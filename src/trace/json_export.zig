const std = @import("std");
const array_list_compat = @import("array_list_compat");
const reader_mod = @import("trace_reader");

const Allocator = std.mem.Allocator;
const TraceRun = reader_mod.TraceRun;

/// Export a TraceRun as a formatted JSON string
pub fn exportJson(allocator: Allocator, run: *const TraceRun) ![]const u8 {
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{");
    try w.print("\"trace_id\":\"{s}\",", .{run.trace_id_hex});
    try w.print("\"total_cost_usd\":{d:.6},", .{run.total_cost_usd});
    try w.print("\"total_duration_ms\":{d},", .{run.total_duration_ms});
    try w.print("\"span_count\":{d},", .{run.span_count});
    try w.print("\"error_count\":{d},", .{run.error_count});
    try w.print("\"timeout_count\":{d},", .{run.timeout_count});
    try w.print("\"llm_count\":{d},", .{run.llm_count});
    try w.print("\"tool_count\":{d},", .{run.tool_count});
    try w.print("\"agent_count\":{d},", .{run.agent_count});
    try w.writeAll("\"spans\":[");

    for (run.spans.items, 0..) |span, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try w.print("\"span_id\":\"{s}\",", .{span.span_id_hex});
        if (span.parent_hex) |p| {
            try w.print("\"parent\":\"{s}\",", .{p});
        } else {
            try w.writeAll("\"parent\":null,");
        }
        try w.print("\"name\":", .{});
        try writeJsonString(w, span.name);
        try w.writeAll(",");
        try w.print("\"kind\":\"{s}\",", .{@tagName(span.kind)});
        try w.print("\"status\":\"{s}\",", .{@tagName(span.status)});
        if (span.latency_ms) |lat| {
            try w.print("\"latency_ms\":{d},", .{lat});
        }
        if (span.model) |m| {
            try w.writeAll("\"model\":");
            try writeJsonString(w, m);
            try w.writeAll(",");
        }
        if (span.tokens) |tok| {
            try w.print("\"tokens\":{{\"prompt\":{d},\"completion\":{d},\"total\":{d}}},", .{
                tok.prompt orelse 0,
                tok.completion orelse 0,
                tok.total orelse 0,
            });
        }
        if (span.cost_usd) |c| {
            try w.print("\"cost_usd\":{d:.6}", .{c});
        } else {
            try w.writeAll("\"cost_usd\":null");
        }
        try w.writeAll("}");
    }

    try w.writeAll("]}");
    return try buf.toOwnedSlice();
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}
