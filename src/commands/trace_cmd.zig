const std = @import("std");
const args_mod = @import("args");
const reader_mod = @import("trace_reader");
const comparison_mod = @import("trace_comparison");
const html_report_mod = @import("trace_html_report");
const json_export_mod = @import("trace_json_export");
const markdown_export_mod = @import("trace_markdown_export");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;
const TraceRun = reader_mod.TraceRun;
const SpanFilter = reader_mod.SpanFilter;
const SpanKind = reader_mod.SpanKind;

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleTrace(args: args_mod.Args) !void {
    const remaining = args.remaining;
    if (remaining.len == 0) {
        try printTraceHelp();
        return;
    }

    const subcommand = remaining[0];
    const sub_args = if (remaining.len > 1) remaining[1..] else remaining[0..0];

    if (std.mem.eql(u8, subcommand, "list")) {
        try handleList(sub_args);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        try handleShow(sub_args);
    } else if (std.mem.eql(u8, subcommand, "compare")) {
        try handleCompare(sub_args);
    } else if (std.mem.eql(u8, subcommand, "export")) {
        try handleExport(sub_args);
    } else if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help")) {
        try printTraceHelp();
    } else {
        stdout_print("Unknown trace subcommand: {s}\n\n", .{subcommand});
        try printTraceHelp();
    }
}

fn handleList(_: [][]const u8) !void {
    const allocator = std.heap.page_allocator;
    const traces_dir = ".traces";

    var dir = std.fs.cwd().openDir(traces_dir, .{}) catch {
        stdout_print("No traces directory found ({s}). Run a chat session first.\n", .{traces_dir});
        return;
    };
    dir.close();

    const files = reader_mod.listTraceFiles(allocator, traces_dir) catch {
        stdout_print("Error listing trace files.\n", .{});
        return;
    };
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    if (files.len == 0) {
        stdout_print("No trace files found in {s}.\n", .{traces_dir});
        return;
    }

    stdout_print("Trace files ({d}):\n", .{files.len});
    for (files, 0..) |file, i| {
        // Strip .jsonl extension for display
        const display_name = if (file.len > 6) file[0 .. file.len - 6] else file;
        stdout_print("  {d}. {s}\n", .{ i + 1, display_name });
    }
}

fn handleShow(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;
    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode trace show <trace-id> [--filter kind=llm|tool|agent]\n", .{});
        return;
    }

    const trace_id = sub_args[0];
    const traces_dir = ".traces";

    const run = reader_mod.loadTrace(allocator, traces_dir, trace_id) catch |err| {
        stdout_print("Error loading trace '{s}': {}\n", .{ trace_id, err });
        return;
    };
    defer run.deinit();

    // Parse optional filter
    var filter = SpanFilter{};
    for (sub_args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=kind=")) {
            const kind_str = arg[14..];
            if (std.meta.stringToEnum(SpanKind, kind_str)) |k| {
                filter.kind = k;
            }
        }
    }

    // Print summary
    stdout_print("=== Trace: {s} ===\n", .{run.trace_id_hex});
    stdout_print("Duration: {d}ms | Cost: ${d:.6}\n", .{ run.total_duration_ms, run.total_cost_usd });
    stdout_print("Spans: {d} ({d} LLM, {d} Tool, {d} Agent)\n", .{ run.span_count, run.llm_count, run.tool_count, run.agent_count });
    if (run.error_count > 0 or run.timeout_count > 0) {
        stdout_print("Issues: {d} errors, {d} timeouts\n", .{ run.error_count, run.timeout_count });
    }
    stdout_print("\n", .{});

    // Print spans
    for (run.spans.items, 0..) |span, i| {
        if (!filter.matches(span)) continue;

        const lat = if (span.latency_ms) |l| l else 0;
        const model_str = if (span.model) |m| m else "";
        const tokens_str = if (span.tokens) |tok|
            try std.fmt.allocPrint(allocator, "tok:{d}", .{tok.total orelse 0})
        else
            "";
        defer if (span.tokens != null) allocator.free(tokens_str);
        const cost_str = if (span.cost_usd) |c|
            try std.fmt.allocPrint(allocator, " ${d:.6}", .{c})
        else
            "";
        defer if (span.cost_usd != null) allocator.free(cost_str);

        stdout_print("  [{d}] {s} ({s}/{s}) {d}ms {s}{s}{s}\n", .{
            i + 1,
            span.name,
            @tagName(span.kind),
            @tagName(span.status),
            lat,
            model_str,
            tokens_str,
            cost_str,
        });
    }

    // Show failures if any
    if (run.error_count > 0 or run.timeout_count > 0) {
        stdout_print("\n--- Failures ---\n", .{});
        const failures = reader_mod.diagnoseFailures(allocator, run) catch &.{};
        defer allocator.free(failures);
        for (failures) |diag| {
            stdout_print("  {s}: [{s}] {s}\n", .{
                diag.span.name,
                @tagName(diag.class),
                diag.cause_hint,
            });
        }
    }
}

fn handleCompare(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;
    if (sub_args.len < 2) {
        stdout_print("Usage: crushcode trace compare <trace-id-a> <trace-id-b>\n", .{});
        return;
    }

    const trace_a_id = sub_args[0];
    const trace_b_id = sub_args[1];
    const traces_dir = ".traces";

    const run_a = reader_mod.loadTrace(allocator, traces_dir, trace_a_id) catch |err| {
        stdout_print("Error loading trace A '{s}': {}\n", .{ trace_a_id, err });
        return;
    };
    defer run_a.deinit();

    const run_b = reader_mod.loadTrace(allocator, traces_dir, trace_b_id) catch |err| {
        stdout_print("Error loading trace B '{s}': {}\n", .{ trace_b_id, err });
        return;
    };
    defer run_b.deinit();

    const comp = comparison_mod.compareTraces(allocator, run_a, run_b) catch |err| {
        stdout_print("Error comparing traces: {}\n", .{err});
        return;
    };
    defer comp.deinit();

    // Print comparison
    stdout_print("=== Trace Comparison ===\n", .{});
    stdout_print("A: {s}  vs  B: {s}\n\n", .{ comp.run_a_id, comp.run_b_id });

    for (comp.metrics) |m| {
        const arrow = if (m.delta > 0) "↑" else if (m.delta < 0) "↓" else "=";
        const better = if (m.delta == 0) "" else if ((m.delta > 0) != m.lower_is_better) " ✓" else " ✗";
        stdout_print("  {s}: {d:.3} → {d:.3} ({s}{d:.1}%{s})\n", .{
            m.name,
            m.run_a_value,
            m.run_b_value,
            arrow,
            m.delta_percent,
            better,
        });
    }

    if (comp.tool_diffs.len > 0) {
        stdout_print("\n  Tool usage changes:\n", .{});
        for (comp.tool_diffs) |td| {
            const arrow = if (td.delta > 0) "+" else "";
            stdout_print("    {s}: {d} → {d} ({s}{d})\n", .{
                td.tool_name,
                td.run_a_count,
                td.run_b_count,
                arrow,
                td.delta,
            });
        }
    }

    stdout_print("\n  Verdict: {s}\n", .{@tagName(comp.verdict)});
    stdout_print("  {s}\n", .{comp.summary});
}

fn handleExport(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;
    if (sub_args.len < 2) {
        stdout_print("Usage: crushcode trace export <format> <trace-id> [--output <file>]\n\n", .{});
        stdout_print("Formats: html, json, markdown\n", .{});
        return;
    }

    const format = sub_args[0];
    const trace_id = sub_args[1];
    const traces_dir = ".traces";

    // Optional output file
    var output_file: ?[]const u8 = null;
    var i: usize = 2;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 < sub_args.len) {
                i += 1;
                output_file = sub_args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_file = arg[9..];
        }
    }

    const run = reader_mod.loadTrace(allocator, traces_dir, trace_id) catch |err| {
        stdout_print("Error loading trace '{s}': {}\n", .{ trace_id, err });
        return;
    };
    defer run.deinit();

    var output_buf: []const u8 = "";
    var owns_output = false;

    if (std.mem.eql(u8, format, "html") or std.mem.eql(u8, format, "htm")) {
        const result = html_report_mod.generateHtmlReport(allocator, run, .{}) catch |err| {
            stdout_print("Error generating HTML report: {}\n", .{err});
            return;
        };
        output_buf = result;
        owns_output = true;
    } else if (std.mem.eql(u8, format, "json")) {
        const result = json_export_mod.exportJson(allocator, run) catch |err| {
            stdout_print("Error generating JSON export: {}\n", .{err});
            return;
        };
        output_buf = result;
        owns_output = true;
    } else if (std.mem.eql(u8, format, "markdown") or std.mem.eql(u8, format, "md")) {
        const result = markdown_export_mod.exportMarkdown(allocator, run) catch |err| {
            stdout_print("Error generating Markdown export: {}\n", .{err});
            return;
        };
        output_buf = result;
        owns_output = true;
    } else {
        stdout_print("Unknown format '{s}'. Use: html, json, markdown\n", .{format});
        return;
    }
    defer if (owns_output) allocator.free(output_buf);

    // Write to file or stdout
    if (output_file) |path| {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            stdout_print("Error writing to '{s}': {}\n", .{ path, err });
            return;
        };
        defer file.close();
        file.writeAll(output_buf) catch |err| {
            stdout_print("Write error: {}\n", .{err});
            return;
        };
        stdout_print("Exported trace '{s}' to {s}\n", .{ trace_id, path });
    } else {
        stdout_print("{s}\n", .{output_buf});
    }
}

fn printTraceHelp() !void {
    stdout_print(
        \\Trace — Inspect, compare, and export AI session traces
        \\
        \\Usage:
        \\  crushcode trace <subcommand> [options]
        \\
        \\Subcommands:
        \\  list                              List available trace files
        \\  show <trace-id> [--filter kind=X] Show trace details with optional filter
        \\  compare <trace-a> <trace-b>       Compare two trace runs
        \\  export <format> <trace-id> [-o F] Export trace as html, json, or markdown
        \\  help                              Show this help message
        \\
        \\Examples:
        \\  crushcode trace list
        \\  crushcode trace show abc123
        \\  crushcode trace show abc123 --filter=kind=llm
        \\  crushcode trace compare abc123 def456
        \\  crushcode trace export html abc123 -o report.html
        \\  crushcode trace export json abc123
        \\  crushcode trace export markdown abc123 -o trace.md
        \\
        \\Forge alias: crushcode lens <subcommand> (→ trace)
        \\
    , .{});
}
