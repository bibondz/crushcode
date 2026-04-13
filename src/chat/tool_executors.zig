const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const core = @import("core_api");
const agent_loop_mod = @import("agent_loop");
const json_output_mod = @import("json_output");
const permission_mod = @import("permission_evaluate");

const AgentLoop = agent_loop_mod.AgentLoop;
const ToolExecutor = agent_loop_mod.ToolExecutor;
const ToolResult = agent_loop_mod.ToolResult;
const PermissionEvaluator = permission_mod.PermissionEvaluator;
const PermissionRequest = permission_mod.PermissionRequest;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub const ToolExecution = struct {
    display: []const u8,
    result: []const u8,
};

const BuiltinToolDefinition = struct {
    name: []const u8,
    executor: ToolExecutor,
};

threadlocal var active_evaluator: ?*PermissionEvaluator = null;
threadlocal var active_json_output: json_output_mod.JsonOutput = .{ .enabled = false };

pub fn setPermissionEvaluator(evaluator: ?*PermissionEvaluator) void {
    active_evaluator = evaluator;
}

pub fn setJsonOutput(json_out: json_output_mod.JsonOutput) void {
    active_json_output = json_out;
}

fn buildToolFailure(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall, err: anyerror) !ToolExecution {
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 {s} → error: {s}\n", .{ tool_call.name, @errorName(err) }),
        .result = try std.fmt.allocPrint(allocator, "Tool execution failed: {s}", .{@errorName(err)}),
    };
}

fn elapsedMillis(start_ms: i64) u64 {
    const end_ms = std.time.milliTimestamp();
    if (end_ms <= start_ms) {
        return 0;
    }
    return @as(u64, @intCast(end_ms - start_ms));
}

fn adaptToolExecution(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
    implementation: *const fn (std.mem.Allocator, core.ParsedToolCall) anyerror!ToolExecution,
) !ToolResult {
    const start_ms = std.time.milliTimestamp();
    const tool_call = core.ParsedToolCall{
        .id = call_id,
        .name = tool_name,
        .arguments = arguments,
    };

    active_json_output.emitToolCall(tool_name, call_id, arguments);

    if (active_evaluator) |evaluator| {
        var req = PermissionRequest.init(tool_name, "execute", allocator) catch unreachable;
        defer req.deinit(allocator);
        const perm_result = evaluator.evaluate(&req);
        switch (perm_result.action) {
            .deny => {
                const msg = perm_result.error_message orelse "Permission denied";
                out("\n\x1b[31m[Permission Denied]\x1b[0m {s}\n", .{msg});
                return try ToolResult.init(allocator, call_id, msg, false);
            },
            .ask => {
                out("\n\x1b[33m[Permission] {s} operation requested — allow? [y/N]\x1b[0m ", .{tool_name});
                var buf: [16]u8 = undefined;
                const stdin = file_compat.File.stdin().reader();
                const answer = stdin.readUntilDelimiterOrEof(&buf, '\n') catch "n" orelse "n";
                if (answer.len == 0 or !(answer[0] == 'y' or answer[0] == 'Y')) {
                    return try ToolResult.init(allocator, call_id, "User denied permission", false);
                }
            },
            .allow => {
                out("\n\x1b[2m[Permission] {s} → allowed\x1b[0m\n", .{tool_name});
            },
        }
    } else {
        const is_shell = std.mem.eql(u8, tool_name, "shell");
        const is_write = std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit");
        if (is_shell or is_write) {
            out("\n\x1b[33m[Permission] {s} operation requested\x1b[0m\n", .{tool_name});
        }
    }

    var success = true;
    const execution = implementation(allocator, tool_call) catch |err| blk: {
        success = false;
        break :blk try buildToolFailure(allocator, tool_call, err);
    };
    defer allocator.free(execution.display);
    defer allocator.free(execution.result);

    out("\n{s}", .{execution.display});
    active_json_output.emitToolResult(call_id, execution.result, success);

    var result = try ToolResult.init(allocator, call_id, execution.result, success);
    result.duration_ms = elapsedMillis(start_ms);
    return result;
}

fn readFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "read_file", arguments, executeReadFileTool);
}

fn shellExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "shell", arguments, executeShellTool);
}

fn writeFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "write_file", arguments, executeWriteFileTool);
}

fn globExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "glob", arguments, executeGlobTool);
}

fn grepExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "grep", arguments, executeGrepTool);
}

fn editExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "edit", arguments, executeEditTool);
}

const builtin_tool_bindings = [_]BuiltinToolDefinition{
    .{ .name = "read_file", .executor = readFileExecutor },
    .{ .name = "shell", .executor = shellExecutor },
    .{ .name = "write_file", .executor = writeFileExecutor },
    .{ .name = "glob", .executor = globExecutor },
    .{ .name = "grep", .executor = grepExecutor },
    .{ .name = "edit", .executor = editExecutor },
};

fn getExecutorForTool(name: []const u8) ?ToolExecutor {
    inline for (builtin_tool_bindings) |tool_binding| {
        if (std.mem.eql(u8, name, tool_binding.name)) {
            return tool_binding.executor;
        }
    }

    return null;
}

pub fn collectSupportedToolSchemas(allocator: std.mem.Allocator, tool_schemas: []const core.ToolSchema) ![]const core.ToolSchema {
    var supported = array_list_compat.ArrayList(core.ToolSchema).init(allocator);
    errdefer supported.deinit();

    for (tool_schemas) |schema| {
        if (getExecutorForTool(schema.name) != null) {
            try supported.append(schema);
        }
    }

    return supported.toOwnedSlice();
}

pub fn registerBuiltinAgentTools(agent_loop: *AgentLoop, tool_schemas: []const core.ToolSchema) !void {
    for (tool_schemas) |schema| {
        if (getExecutorForTool(schema.name)) |executor| {
            try agent_loop.registerTool(schema.name, executor);
        }
    }
}

fn executeReadFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ReadFileArgs = struct { path: []const u8 };

    var parsed = try std.json.parseFromSlice(ReadFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().openFile(parsed.value.path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, stat.size }),
        .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, stat.size, content }),
    };
}

fn executeShellTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ShellArgs = struct {
        command: []const u8,
        timeout: ?u32 = null,
    };

    var parsed = try std.json.parseFromSlice(ShellArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.timeout) |secs| {
        if (secs > 0) {
            const cmd = try std.fmt.allocPrint(allocator, "timeout --signal=KILL {d} sh -c {s}", .{ secs, parsed.value.command });
            defer allocator.free(cmd);
            const argv: [3][]const u8 = .{ "sh", "-c", cmd };
            var child = std.process.Child.init(&argv, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            _ = try child.spawn();

            var stdout = std.ArrayListUnmanaged(u8){};
            var stderr = std.ArrayListUnmanaged(u8){};
            defer {
                stdout.deinit(allocator);
                stderr.deinit(allocator);
            }

            try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
            const term = try child.wait();
            const exit_code: u8 = switch (term) {
                .Exited => |code| @intCast(code),
                .Signal => |code| @intCast(code),
                else => 1,
            };
            const timed_out = exit_code == 124;
            return .{
                .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\", timeout={d}s) → exit {d}{s}\n", .{ parsed.value.command, secs, exit_code, if (timed_out) " (TIMEOUT)" else "" }),
                .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout.items, stderr.items }),
            };
        }
    }

    const argv: [3][]const u8 = .{ "sh", "-c", parsed.value.command };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\") → exit {d}\n", .{ parsed.value.command, exit_code }),
        .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout.items, stderr.items }),
    };
}

fn executeWriteFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const WriteFileArgs = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(WriteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    try file.writeAll(parsed.value.content);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 write_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, parsed.value.content.len }),
        .result = try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ parsed.value.content.len, parsed.value.path }),
    };
}

fn executeGlobTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GlobArgs = struct {
        pattern: []const u8,
        max_results: ?u32 = 50,
    };

    var parsed = try std.json.parseFromSlice(GlobArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const max = parsed.value.max_results orelse 50;
    const find_cmd = try std.fmt.allocPrint(allocator, "find . -name '{s}' -type f 2>/dev/null | head -{d}", .{ parsed.value.pattern, max });
    defer allocator.free(find_cmd);

    const argv: [3][]const u8 = .{ "sh", "-c", find_cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    _ = try child.wait();

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, stdout.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 glob(\"{s}\") → {d} files\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} files matching '{s}':\n{s}", .{ count, parsed.value.pattern, stdout.items }),
    };
}

fn executeGrepTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GrepArgs = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        include: ?[]const u8 = null,
        max_results: ?u32 = 50,
    };

    var parsed = try std.json.parseFromSlice(GrepArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const max = parsed.value.max_results orelse 50;
    const search_path = parsed.value.path orelse ".";

    var cmd_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer cmd_buf.deinit();
    const writer = cmd_buf.writer();

    try writer.print("grep -rn --binary-files=without-match '{s}' '{s}'", .{ parsed.value.pattern, search_path });
    if (parsed.value.include) |inc| {
        try writer.print(" --include='{s}'", .{inc});
    }
    try writer.print(" 2>/dev/null | head -{d}", .{max});

    const argv: [3][]const u8 = .{ "sh", "-c", cmd_buf.items };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    _ = try child.wait();

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, stdout.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 grep(\"{s}\") → {d} matches\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} matches for '{s}':\n{s}", .{ count, parsed.value.pattern, stdout.items }),
    };
}

fn executeEditTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const EditArgs = struct {
        file_path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
    };

    var parsed = try std.json.parseFromSlice(EditArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().openFile(parsed.value.file_path, .{});
    defer file.close();
    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    const pos = std.mem.indexOf(u8, content, parsed.value.old_string) orelse {
        return error.OldStringNotFound;
    };

    const after_first = pos + parsed.value.old_string.len;
    if (std.mem.indexOf(u8, content[after_first..], parsed.value.old_string)) |_| {
        return error.MultipleMatches;
    }

    var new_content = array_list_compat.ArrayList(u8).init(allocator);
    defer new_content.deinit();
    try new_content.appendSlice(content[0..pos]);
    try new_content.appendSlice(parsed.value.new_string);
    try new_content.appendSlice(content[after_first..]);

    const out_file = try std.fs.cwd().createFile(parsed.value.file_path, .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);

    const lines_before = countLines(content);
    const lines_after = countLines(new_content.items);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 edit(\"{s}\") → replaced {d} chars with {d} chars\n", .{ parsed.value.file_path, parsed.value.old_string.len, parsed.value.new_string.len }),
        .result = try std.fmt.allocPrint(allocator, "Edited {s}: replaced text at position {d}. File: {d} lines → {d} lines", .{ parsed.value.file_path, pos, lines_before, lines_after }),
    };
}

fn countLines(text: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, text, "\n");
    while (lines.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn executeBuiltinTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return executeReadFileTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "shell")) {
        return executeShellTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return executeWriteFileTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "glob")) {
        return executeGlobTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "grep")) {
        return executeGrepTool(allocator, tool_call);
    }
    if (std.mem.eql(u8, tool_call.name, "edit")) {
        return executeEditTool(allocator, tool_call);
    }
    return error.UnsupportedTool;
}
