const std = @import("std");
const args_mod = @import("args");
const layered_memory_mod = @import("layered_memory");
const skill_pipeline_mod = @import("skill_pipeline");
const adversarial_mod = @import("adversarial");
const skill_sync_mod = @import("skill_sync");
const template_mod = @import("template");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const file_type_mod = @import("file_type");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleMemory(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode memory <layers|insights|distill|search|store|stats> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  layers                        Show all layers with entry counts\n", .{});
        stdout_print("  insights                      Show insights layer entries with confidence\n", .{});
        stdout_print("  distill                       Trigger manual distillation\n", .{});
        stdout_print("  search \"<query>\"              Search across layers\n", .{});
        stdout_print("  store <layer> <key> \"<value>\" Store an entry in a layer\n", .{});
        stdout_print("  stats                         Show memory statistics\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    var lm = try layered_memory_mod.LayeredMemory.init(allocator, ".");
    defer lm.deinit();

    // Auto-load from disk if persisted data exists
    lm.loadFromDisk() catch {};

    if (std.mem.eql(u8, subcommand, "layers")) {
        lm.printLayers();
    } else if (std.mem.eql(u8, subcommand, "insights")) {
        stdout_print("\n=== Insights Layer ===\n", .{});
        const list = &lm.insights_entries;
        if (list.items.len == 0) {
            stdout_print("  No insights entries.\n", .{});
            stdout_print("  Use 'crushcode memory distill' to create insights from working memory.\n", .{});
        } else {
            for (list.items, 0..) |entry, idx| {
                stdout_print("  {d}. [{s}] {s} = {s} (conf: {d:.2}, src: {s})\n", .{
                    idx + 1,
                    entry.id,
                    entry.key,
                    entry.value,
                    entry.confidence,
                    entry.source,
                });
                if (entry.tags.items.len > 0) {
                    stdout_print("     tags: ", .{});
                    for (entry.tags.items, 0..) |t, ti| {
                        if (ti > 0) stdout_print(", ", .{});
                        stdout_print("{s}", .{t});
                    }
                    stdout_print("\n", .{});
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "distill")) {
        lm.distill_config.min_changes = 1; // Allow manual trigger regardless of change count
        const count = lm.distill() catch {
            stdout_print("Error: distillation failed\n", .{});
            return;
        };
        stdout_print("\n=== Distillation Complete ===\n", .{});
        stdout_print("  Insights created: {d}\n", .{count});
        if (count > 0) {
            try lm.saveToDisk();
            stdout_print("  Memory saved to disk.\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "search")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode memory search \"<query>\"\n", .{});
            return;
        }
        const query = sub_args[0];
        const results = lm.search(query) catch {
            stdout_print("Error: search failed\n", .{});
            return;
        };
        defer allocator.free(results);

        stdout_print("\n=== Search Results for \"{s}\" ===\n", .{query});
        if (results.len == 0) {
            stdout_print("  No results found.\n", .{});
        } else {
            for (results, 0..) |entry, idx| {
                const layer_name = @tagName(entry.layer);
                stdout_print("  {d}. [{s}] {s} = {s}\n", .{
                    idx + 1,
                    layer_name,
                    entry.key,
                    entry.value,
                });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "store")) {
        if (sub_args.len < 3) {
            stdout_print("Usage: crushcode memory store <layer> <key> \"<value>\"\n", .{});
            stdout_print("Layers: session, working, insights, project\n", .{});
            return;
        }
        const layer_str = sub_args[0];
        const key = sub_args[1];
        const value = sub_args[2];

        const layer: layered_memory_mod.MemoryLayer =
            if (std.mem.eql(u8, layer_str, "session")) .session else if (std.mem.eql(u8, layer_str, "working")) .working else if (std.mem.eql(u8, layer_str, "insights")) .insights else if (std.mem.eql(u8, layer_str, "project")) .project else {
                stdout_print("Unknown layer: {s}\nUse: session, working, insights, or project\n", .{layer_str});
                return;
            };

        const entry = lm.store(layer, key, value, "manual", &.{}) catch {
            stdout_print("Error: failed to store entry\n", .{});
            return;
        };

        try lm.saveToDisk();
        stdout_print("Stored [{s}] {s} = {s} (id: {s})\n", .{ layer_str, key, value, entry.id });
    } else if (std.mem.eql(u8, subcommand, "stats")) {
        const stats = lm.getStats();
        stdout_print("\n=== Memory Statistics ===\n", .{});
        stdout_print("  Session entries:  {d}\n", .{stats.session_count});
        stdout_print("  Working entries:  {d}\n", .{stats.working_count});
        stdout_print("  Insights entries: {d}\n", .{stats.insights_count});
        stdout_print("  Project entries:  {d}\n", .{stats.project_count});
        stdout_print("  Total:            {d}\n", .{stats.total});
        stdout_print("  Avg confidence:   {d:.2}\n", .{stats.avg_confidence});
        stdout_print("  Low confidence:   {d}\n", .{stats.low_confidence_count});
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: layers, insights, distill, search, store, or stats\n", .{});
    }
}

/// Global pipeline runner (persists across commands in same process)
var global_pipeline_runner: ?skill_pipeline_mod.PipelineRunner = null;

fn getOrCreatePipelineRunner(allocator: std.mem.Allocator) *skill_pipeline_mod.PipelineRunner {
    if (global_pipeline_runner == null) {
        global_pipeline_runner = skill_pipeline_mod.PipelineRunner.init(allocator, ".crushcode/pipeline-results/") catch {
            stdout_print("Error: failed to initialize pipeline runner\n", .{});
            return &global_pipeline_runner.?;
        };
    }
    return &global_pipeline_runner.?;
}

/// Handle `crushcode pipeline <subcommand>` — multi-phase skill execution engine.
/// Subcommands:
///   run "<template>"   Build and run a pipeline from a built-in template
///   status [idx]       Show pipeline status (or specific pipeline by index)
///   list               List all registered pipelines
///   templates          List available pipeline templates
///   results [idx]      Show pipeline results
pub fn handlePipeline(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode pipeline <run|status|list|templates|results> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  run \"<template>\"   Build and run a pipeline template\n", .{});
        stdout_print("  status [idx]       Show pipeline status\n", .{});
        stdout_print("  list               List all pipelines\n", .{});
        stdout_print("  templates          List available templates\n", .{});
        stdout_print("  results [idx]      Show pipeline results\n", .{});
        stdout_print("\nTemplates: research, refactor, review\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};
    const runner = getOrCreatePipelineRunner(allocator);

    if (std.mem.eql(u8, subcommand, "run")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode pipeline run \"<template>\"\n", .{});
            stdout_print("Templates: research, refactor, review\n", .{});
            return;
        }
        const template_name = sub_args[0];
        const pipeline = runner.buildFromTemplate(template_name) catch |err| {
            if (err == error.UnknownTemplate) {
                stdout_print("Unknown template: {s}\n", .{template_name});
                stdout_print("Available: research, refactor, review\n", .{});
                return;
            }
            stdout_print("Error building template: {}\n", .{err});
            return;
        };

        stdout_print("\n=== Running Pipeline: {s} ===\n", .{pipeline.name});
        stdout_print("  Template:  {s}\n", .{template_name});
        stdout_print("  Steps:     {d}\n", .{pipeline.steps.items.len});
        stdout_print("  Phases:    scan → enrich → create → report\n\n", .{});

        const idx = runner.pipelines.items.len - 1;
        var result = runner.runPipeline(idx) catch |err| {
            stdout_print("Error running pipeline: {}\n", .{err});
            return;
        };
        defer result.deinit(allocator);

        stdout_print("\n=== Pipeline Result ===\n", .{});
        stdout_print("  Pipeline:  {s}\n", .{result.pipeline_name});
        stdout_print("  Status:    {s}\n", .{@tagName(result.status)});
        stdout_print("  Steps:     {d}/{d} completed, {d} failed\n", .{
            result.completed_steps,
            result.total_steps,
            result.failed_steps,
        });
        stdout_print("  Duration:  {d}ms\n", .{result.duration_ms});
        if (result.output_path.len > 0) {
            stdout_print("  Output:    {s}\n", .{result.output_path});
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        if (sub_args.len > 0) {
            const idx = std.fmt.parseInt(usize, sub_args[0], 10) catch {
                stdout_print("Invalid index: {s}\n", .{sub_args[0]});
                return;
            };
            const status_str = runner.getPipelineStatus(idx) catch |err| {
                if (err == error.PipelineNotFound) {
                    stdout_print("Pipeline not found at index {d}\n", .{idx});
                    return;
                }
                stdout_print("Error: {}\n", .{err});
                return;
            };
            defer allocator.free(status_str);
            stdout_print("{s}\n", .{status_str});
        } else {
            // Show all pipelines
            for (runner.pipelines.items, 0..) |_, idx| {
                const status_str = runner.getPipelineStatus(idx) catch continue;
                defer allocator.free(status_str);
                stdout_print("{s}\n", .{status_str});
            }
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        const listing = runner.listPipelines() catch {
            stdout_print("Error listing pipelines\n", .{});
            return;
        };
        defer allocator.free(listing);
        stdout_print("{s}\n", .{listing});
    } else if (std.mem.eql(u8, subcommand, "templates")) {
        const templates = skill_pipeline_mod.PipelineRunner.listTemplates(allocator) catch {
            stdout_print("Error listing templates\n", .{});
            return;
        };
        defer allocator.free(templates);
        stdout_print("{s}\n", .{templates});
    } else if (std.mem.eql(u8, subcommand, "results")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode pipeline results <index>\n", .{});
            return;
        }
        const idx = std.fmt.parseInt(usize, sub_args[0], 10) catch {
            stdout_print("Invalid index: {s}\n", .{sub_args[0]});
            return;
        };
        const results = runner.getResults(idx) catch |err| {
            if (err == error.PipelineNotFound) {
                stdout_print("Pipeline not found at index {d}\n", .{idx});
                return;
            }
            stdout_print("Error: {}\n", .{err});
            return;
        };
        if (results.len == 0) {
            stdout_print("No results yet for pipeline {d}\n", .{idx});
        } else {
            for (results, 0..) |r, i| {
                stdout_print("  {d}. {s} [{s}]\n", .{ i + 1, r.pipeline_name, @tagName(r.status) });
            }
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: run, status, list, templates, or results\n", .{});
    }
}

/// Global thinking engine (persists across commands in same process)
var global_think_engine: ?adversarial_mod.ThinkingEngine = null;

fn getOrCreateThinkEngine(allocator: std.mem.Allocator) *adversarial_mod.ThinkingEngine {
    if (global_think_engine == null) {
        global_think_engine = adversarial_mod.ThinkingEngine.init(allocator);
    }
    return &global_think_engine.?;
}

/// Handle `crushcode think <subcommand>` — adversarial thinking tools.
/// Subcommands:
///   challenge "<idea>"               Argue against an idea using knowledge history
///   emerge                            Surface hidden patterns across accumulated knowledge
///   connect "<topic_a>" "<topic_b>"   Bridge two unrelated domains
///   graduate "<idea>"                 Turn an idea into a structured project plan
///   history                           Show past thinking results
pub fn handleThink(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode think <challenge|emerge|connect|graduate|history> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  challenge \"<idea>\"              Argue against an idea\n", .{});
        stdout_print("  emerge                          Surface hidden patterns\n", .{});
        stdout_print("  connect \"<a>\" \"<b>\"            Bridge two unrelated domains\n", .{});
        stdout_print("  graduate \"<idea>\"               Turn idea into project plan\n", .{});
        stdout_print("  history                         Show past thinking results\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const engine = getOrCreateThinkEngine(allocator);

    if (std.mem.eql(u8, subcommand, "challenge")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode think challenge \"<idea>\"\n", .{});
            return;
        }
        const idea = args.remaining[1];
        const result = engine.challenge(idea) catch {
            stdout_print("Error running challenge\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
        stdout_print("Perspectives generated: {d}\n", .{result.perspectives.len});
    } else if (std.mem.eql(u8, subcommand, "emerge")) {
        const result = engine.emerge() catch {
            stdout_print("Error running emerge\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "connect")) {
        if (args.remaining.len < 3) {
            stdout_print("Usage: crushcode think connect \"<topic_a>\" \"<topic_b>\"\n", .{});
            return;
        }
        const topic_a = args.remaining[1];
        const topic_b = args.remaining[2];
        const result = engine.connect(topic_a, topic_b) catch {
            stdout_print("Error running connect\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "graduate")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode think graduate \"<idea>\"\n", .{});
            return;
        }
        const idea = args.remaining[1];
        const result = engine.graduate(idea) catch {
            stdout_print("Error running graduate\n", .{});
            return;
        };
        defer result.deinit();

        stdout_print("\n{s}\n", .{result.output});
        stdout_print("\nConfidence: {d:.2}\n", .{result.confidence});
    } else if (std.mem.eql(u8, subcommand, "history")) {
        const history = engine.getHistory(20);
        stdout_print("\n=== Thinking History ({d} results) ===\n\n", .{history.len});
        if (history.len == 0) {
            stdout_print("  No thinking results yet. Use challenge, emerge, connect, or graduate first.\n", .{});
        } else {
            for (history, 0..) |item, i| {
                const snippet = if (item.output.len > 60) item.output[0..60] else item.output;
                stdout_print("  {d}. [{s}] confidence={d:.2}\n", .{ i + 1, @tagName(item.mode), item.confidence });
                stdout_print("     Input: {s}\n", .{item.input});
                stdout_print("     Output: {s}...\n", .{snippet});
            }
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: challenge, emerge, connect, graduate, or history\n", .{});
    }
}

pub fn handleSkillSync(args: args_mod.Args) !void {
    skill_sync_mod.handleSkillSync(args.remaining);
}

pub fn handleTemplate(args: args_mod.Args) !void {
    try template_mod.handleTemplate(args.remaining);
}

/// Handle `crushcode preview` — file preview with line numbers, highlighting, and diff
pub fn handlePreview(args: args_mod.Args) !void {
    const code_preview = @import("code_preview");

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode preview <file> [file...]\n", .{});
        stdout_print("       crushcode preview --highlight <line> <file>\n", .{});
        stdout_print("       crushcode preview --snippet <line> <file>\n", .{});
        stdout_print("       crushcode preview --diff <file1> <file2>\n", .{});
        return;
    }

    // Parse flags
    var highlight_line: ?u32 = null;
    var context_lines: u32 = 10;
    var mode: code_preview.PreviewMode = .full;
    var file_start: usize = 0;
    var diff_mode = false;

    var i: usize = 0;
    while (i < args.remaining.len) : (i += 1) {
        if (std.mem.eql(u8, args.remaining[i], "--highlight")) {
            i += 1;
            if (i < args.remaining.len) {
                highlight_line = std.fmt.parseInt(u32, args.remaining[i], 10) catch {
                    stdout_print("Error: invalid line number '{s}'\n", .{args.remaining[i]});
                    return;
                };
                mode = .full;
            }
        } else if (std.mem.eql(u8, args.remaining[i], "--snippet")) {
            i += 1;
            if (i < args.remaining.len) {
                highlight_line = std.fmt.parseInt(u32, args.remaining[i], 10) catch {
                    stdout_print("Error: invalid line number '{s}'\n", .{args.remaining[i]});
                    return;
                };
                mode = .snippet;
            }
        } else if (std.mem.eql(u8, args.remaining[i], "--diff")) {
            diff_mode = true;
        } else if (std.mem.eql(u8, args.remaining[i], "--context")) {
            i += 1;
            if (i < args.remaining.len) {
                context_lines = std.fmt.parseInt(u32, args.remaining[i], 10) catch 10;
            }
        } else {
            // First non-flag = start of file list
            file_start = i;
            break;
        }
    }

    const files = args.remaining[file_start..];

    if (diff_mode) {
        if (files.len < 2) {
            stdout_print("Error: --diff requires two file paths\n", .{});
            return;
        }
        code_preview.printDiff(files[0], files[1]);
        return;
    }

    if (files.len == 0) {
        stdout_print("Error: no file specified\n", .{});
        return;
    }

    for (files) |file_path| {
        code_preview.printPreview(file_path, highlight_line, context_lines, mode);
    }
}

pub fn handleDetect(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var detector = file_type_mod.FileDetector.init(allocator) catch {
        stdout_print("Error: failed to initialize file detector\n", .{});
        return;
    };
    defer detector.deinit();

    // Use global --json flag from args_mod, parse --mime from remaining
    var mime_only = false;
    var files = array_list_compat.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    for (args.remaining) |arg| {
        if (std.mem.eql(u8, arg, "--mime")) {
            mime_only = true;
        } else {
            try files.append(arg);
        }
    }

    if (files.items.len == 0) {
        stdout_print("Usage: crushcode detect [options] <file...>\n\nOptions:\n  --json, -j   Output as JSON\n  --mime       Show MIME type only\n", .{});
        return;
    }

    for (files.items) |file_path| {
        var result = detector.detectFile(file_path) catch {
            stdout_print("Error: could not read '{s}'\n", .{file_path});
            continue;
        };
        defer result.deinit();

        if (args.json) {
            if (result.content_type) |ct| {
                stdout_print(
                    \\{{"file":"{s}","type":"{s}","mime":"{s}","group":"{s}","confidence":{d:.2},"method":"{s}","size":{},"is_text":{}"}}
                    \\
                , .{
                    result.file_path,
                    ct.label,
                    ct.mime_type,
                    ct.group,
                    result.confidence,
                    @tagName(result.detected_by),
                    result.file_size,
                    ct.is_text,
                });
            } else {
                stdout_print(
                    \\{{"file":"{s}","type":null,"confidence":0.00,"method":"{s}","size":{}}}
                    \\
                , .{
                    result.file_path,
                    @tagName(result.detected_by),
                    result.file_size,
                });
            }
        } else if (mime_only) {
            if (result.content_type) |ct| {
                stdout_print("{s}\n", .{ct.mime_type});
            } else {
                stdout_print("application/octet-stream\n", .{});
            }
        } else {
            stdout_print("File: {s}\n", .{result.file_path});
            if (result.content_type) |ct| {
                stdout_print("  Type:        {s}\n", .{ct.label});
                stdout_print("  Description: {s}\n", .{ct.description});
                stdout_print("  MIME:        {s}\n", .{ct.mime_type});
                stdout_print("  Group:       {s}\n", .{ct.group});
                stdout_print("  Text:        {s}\n", .{if (ct.is_text) "yes" else "no"});
            } else {
                stdout_print("  Type:        unknown\n", .{});
            }
            stdout_print("  Confidence:  {d:.0}%\n", .{result.confidence * 100});
            stdout_print("  Method:      {s}\n", .{@tagName(result.detected_by)});
            stdout_print("  Size:        {} bytes\n", .{result.file_size});
            stdout_print("\n", .{});
        }
    }
}
