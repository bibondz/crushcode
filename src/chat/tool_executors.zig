const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const core = @import("core_api");
const agent_loop_mod = @import("agent_loop");
const json_output_mod = @import("json_output");
const permission_mod = @import("permission_evaluate");
const audit_mod = @import("permission_audit");
const shell_state_mod = @import("shell_state");
const blocklist_mod = @import("permission_blocklist");
const safelist_mod = @import("permission_safelist");
const myers = @import("myers");
const file_tracker_mod = @import("file_tracker");

const AgentLoop = agent_loop_mod.AgentLoop;
const ToolExecutor = agent_loop_mod.ToolExecutor;
const ToolResult = agent_loop_mod.ToolResult;
const PermissionEvaluator = permission_mod.PermissionEvaluator;
const PermissionRequest = permission_mod.PermissionRequest;
const PermissionAuditLogger = audit_mod.PermissionAuditLogger;
const ShellState = shell_state_mod.ShellState;
const CommandBlocklist = blocklist_mod.CommandBlocklist;
const SafeCommandList = safelist_mod.SafeCommandList;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Maximum tool output size before truncation (30KB)
const MAX_TOOL_OUTPUT_BYTES: usize = 30 * 1024;

/// Truncate output using smart midpoint style (first 40% + last 40%).
/// Returns a new allocation when truncation occurs; returns the original
/// slice directly when within limits (no extra allocation).
fn truncateToolOutput(allocator: std.mem.Allocator, original: []const u8) ![]const u8 {
    if (original.len <= MAX_TOOL_OUTPUT_BYTES) {
        return original;
    }
    const head_size = MAX_TOOL_OUTPUT_BYTES * 40 / 100;
    const tail_size = MAX_TOOL_OUTPUT_BYTES * 40 / 100;
    const removed_bytes = original.len - head_size - tail_size;
    return try std.fmt.allocPrint(allocator, "{s}\n\n... [{d} bytes truncated — use grep/read_file for specific sections] ...\n\n{s}", .{
        original[0..head_size],
        removed_bytes,
        original[original.len - tail_size ..],
    });
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
threadlocal var active_audit_logger: ?*PermissionAuditLogger = null;
threadlocal var active_shell_state: ?*ShellState = null;
threadlocal var active_blocklist: ?*CommandBlocklist = null;
threadlocal var active_safelist: ?*SafeCommandList = null;
threadlocal var active_json_output: json_output_mod.JsonOutput = .{ .enabled = false };
threadlocal var active_file_tracker: ?*file_tracker_mod.FileTracker = null;
threadlocal var active_agent_mode: agent_loop_mod.AgentMode = .execute;

pub fn setPermissionEvaluator(evaluator: ?*PermissionEvaluator) void {
    active_evaluator = evaluator;
}

pub fn setPermissionAuditLogger(logger: ?*PermissionAuditLogger) void {
    active_audit_logger = logger;
}

pub fn setShellState(state: ?*ShellState) void {
    active_shell_state = state;
}

pub fn setCommandBlocklist(blocklist: ?*CommandBlocklist) void {
    active_blocklist = blocklist;
}

pub fn setSafeCommandList(safelist: ?*SafeCommandList) void {
    active_safelist = safelist;
}

pub fn setJsonOutput(json_out: json_output_mod.JsonOutput) void {
    active_json_output = json_out;
}

pub fn setFileTracker(tracker: ?*file_tracker_mod.FileTracker) void {
    active_file_tracker = tracker;
}

pub fn setAgentMode(mode: agent_loop_mod.AgentMode) void {
    active_agent_mode = mode;
}

fn buildToolFailure(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall, err: anyerror) !ToolExecution {
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 {s} → error: {s}\n", .{ tool_call.name, @errorName(err) }),
        .result = try std.fmt.allocPrint(allocator, "Tool execution failed: {s}", .{@errorName(err)}),
    };
}

fn buildValidationError(allocator: std.mem.Allocator, tool_name: []const u8, message: []const u8) !ToolExecution {
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 {s} → validation error: {s}\n", .{ tool_name, message }),
        .result = try std.fmt.allocPrint(allocator, "Validation error: {s}", .{message}),
    };
}

fn isSystemPath(path: []const u8) bool {
    const prefixes = [_][]const u8{ "/etc/", "/proc/", "/sys/" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
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

    // Agent mode check — restrict tools based on plan/build/execute mode
    const current_mode = active_agent_mode;
    if (!current_mode.isToolAllowed(tool_name)) {
        const mode_err_msg = std.fmt.allocPrint(
            allocator,
            "Tool '{s}' is not available in {s} mode. Available tools: {s}. Use /mode to switch modes.",
            .{ tool_name, current_mode.toString(), current_mode.allowedToolsList() },
        ) catch "Tool restricted by agent mode";
        out("\n\x1b[33m[Mode Restriction]\x1b[0m {s}\n", .{mode_err_msg});
        return try ToolResult.init(allocator, call_id, mode_err_msg, false);
    }

    // Phase 27: 3-tier permission check — blocklist → safelist → evaluator
    // For shell commands, extract the actual command string for blocklist/safelist matching
    const command_for_check: ?[]const u8 = blk: {
        if (!std.mem.eql(u8, tool_name, "shell")) break :blk null;
        // Quick parse to get the command field from arguments
        // Try to extract "command" field from JSON arguments
        const cmd_key = "\"command\"";
        if (std.mem.indexOf(u8, arguments, cmd_key)) |key_pos| {
            const after_key = arguments[key_pos + cmd_key.len ..];
            // Skip whitespace and colon
            var i: usize = 0;
            while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) i += 1;
            if (i < after_key.len and after_key[i] == '"') {
                i += 1;
                const start = i;
                while (i < after_key.len and after_key[i] != '"') {
                    if (after_key[i] == '\\' and i + 1 < after_key.len) i += 2 else i += 1;
                }
                break :blk arguments[key_pos + cmd_key.len ..][start..][0 .. i - start];
            }
        }
        break :blk null;
    };

    // Tier 1: Blocklist — hard deny for dangerous commands
    if (command_for_check) |cmd| {
        if (active_blocklist) |bl| {
            if (bl.isBlocked(cmd)) |matched_pattern| {
                const msg = std.fmt.allocPrint(allocator, "Command blocked by security policy (matched: {s})", .{matched_pattern}) catch "Command blocked by security policy";
                out("\n\x1b[31m[Security Block]\x1b[0m {s}\n", .{msg});
                if (active_audit_logger) |logger| {
                    logger.logDecision(tool_name, "execute", .deny, false) catch {};
                }
                return try ToolResult.init(allocator, call_id, msg, false);
            }
        }
    }

    // In build mode, shell commands always require approval (override safelist)
    const build_mode_shell_restricted = current_mode == .build and std.mem.eql(u8, tool_name, "shell");

    // Tier 2: Safelist — auto-approve known safe commands (unless build mode restricts shell)
    const safelist_approved = if (build_mode_shell_restricted) false else blk: {
        if (command_for_check) |cmd| {
            if (active_safelist) |sl| {
                if (sl.isSafe(cmd)) {
                    if (active_audit_logger) |logger| {
                        logger.logDecision(tool_name, "execute", .allow, true) catch {};
                    }
                    break :blk true;
                }
            }
        }
        break :blk false;
    };

    // Tier 3: Evaluator — existing permission evaluator (skipped if safelist-approved)
    if (!safelist_approved) {
        if (active_evaluator) |evaluator| {
            var req = PermissionRequest.init(tool_name, "execute", allocator) catch unreachable;
            defer req.deinit(allocator);
            const perm_result = evaluator.evaluate(&req);
            switch (perm_result.action) {
                .deny => {
                    const msg = perm_result.error_message orelse "Permission denied";
                    out("\n\x1b[31m[Permission Denied]\x1b[0m {s}\n", .{msg});
                    if (active_audit_logger) |logger| {
                        logger.logDecision(tool_name, "execute", .deny, perm_result.auto_approved) catch {};
                    }
                    return try ToolResult.init(allocator, call_id, msg, false);
                },
                .ask => {
                    out("\n\x1b[33m[Permission] {s} operation requested — allow? [y/N]\x1b[0m ", .{tool_name});
                    var buf: [16]u8 = undefined;
                    const stdin = file_compat.File.stdin().reader();
                    const answer = stdin.readUntilDelimiterOrEof(&buf, '\n') catch "n" orelse "n";
                    if (answer.len == 0 or !(answer[0] == 'y' or answer[0] == 'Y')) {
                        if (active_audit_logger) |logger| {
                            logger.logDecision(tool_name, "execute", .deny, false) catch {};
                        }
                        return try ToolResult.init(allocator, call_id, "User denied permission", false);
                    }
                    if (active_audit_logger) |logger| {
                        logger.logDecision(tool_name, "execute", .allow, false) catch {};
                    }
                },
                .allow => {
                    out("\n\x1b[2m[Permission] {s} → allowed\x1b[0m\n", .{tool_name});
                    if (active_audit_logger) |logger| {
                        logger.logDecision(tool_name, "execute", .allow, perm_result.auto_approved) catch {};
                    }
                },
            }
        } else {
            const is_shell = std.mem.eql(u8, tool_name, "shell");
            const is_write = std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit");
            if (is_shell or is_write) {
                out("\n\x1b[33m[Permission] {s} operation requested\x1b[0m\n", .{tool_name});
            }
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

    if (parsed.value.path.len == 0) {
        return buildValidationError(allocator, "read_file", "read_file requires a 'path' parameter. Provide the file path to read.");
    }
    if (isSystemPath(parsed.value.path)) {
        const msg = try std.fmt.allocPrint(allocator, "Reading system files is not allowed. Path: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return buildValidationError(allocator, "read_file", msg);
    }

    // Check file tracker cache before reading
    if (active_file_tracker) |tracker| {
        if (tracker.getCached(parsed.value.path)) |cached| {
            // Truncate cached content
            const truncated = try truncateToolOutput(allocator, cached);
            const truncated_owned = if (truncated.ptr == cached.ptr) try allocator.dupe(u8, truncated) else truncated;
            defer {
                if (truncated.ptr != cached.ptr) allocator.free(truncated);
            }
            return .{
                .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes (cached)\n", .{ parsed.value.path, cached.len }),
                .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, cached.len, truncated_owned }),
            };
        }
    }

    const file = try std.fs.cwd().openFile(parsed.value.path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    // Track the file after reading
    if (active_file_tracker) |tracker| {
        tracker.track(parsed.value.path, content, stat) catch {};
    }

    // Truncate file content
    const truncated = try truncateToolOutput(allocator, content);
    const truncated_owned = if (truncated.ptr == content.ptr) try allocator.dupe(u8, truncated) else truncated;
    defer {
        if (truncated.ptr != content.ptr) allocator.free(truncated);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes\n", .{ parsed.value.path, stat.size }),
        .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, stat.size, truncated_owned }),
    };
}

fn executeShellTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ShellArgs = struct {
        command: []const u8,
        timeout: ?u32 = null,
    };

    var parsed = try std.json.parseFromSlice(ShellArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.command.len == 0) {
        return buildValidationError(allocator, "shell", "shell requires a 'command' parameter. Provide the shell command to execute.");
    }
    if (parsed.value.command.len >= 10000) {
        const msg = try std.fmt.allocPrint(allocator, "Command too long ({d} chars). Maximum is 10000 characters.", .{parsed.value.command.len});
        defer allocator.free(msg);
        return buildValidationError(allocator, "shell", msg);
    }

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
            // Truncate stdout only — preserve exit_code and stderr formatting
            const truncated_stdout = try truncateToolOutput(allocator, stdout.items);
            defer {
                if (truncated_stdout.ptr != stdout.items.ptr) allocator.free(truncated_stdout);
            }
            return .{
                .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\", timeout={d}s) → exit {d}{s}\n", .{ parsed.value.command, secs, exit_code, if (timed_out) " (TIMEOUT)" else "" }),
                .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, truncated_stdout, stderr.items }),
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

    // Truncate stdout only — preserve exit_code and stderr formatting
    const truncated_stdout = try truncateToolOutput(allocator, stdout.items);
    defer {
        if (truncated_stdout.ptr != stdout.items.ptr) allocator.free(truncated_stdout);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\") → exit {d}\n", .{ parsed.value.command, exit_code }),
        .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, truncated_stdout, stderr.items }),
    };
}

fn executeWriteFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const WriteFileArgs = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(WriteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.path.len == 0) {
        return buildValidationError(allocator, "write_file", "write_file requires a 'path' parameter.");
    }
    if (parsed.value.content.len == 0) {
        return buildValidationError(allocator, "write_file", "write_file requires 'content' to write.");
    }
    if (isSystemPath(parsed.value.path)) {
        const msg = try std.fmt.allocPrint(allocator, "Writing to system files is not allowed. Path: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return buildValidationError(allocator, "write_file", msg);
    }

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    try file.writeAll(parsed.value.content);

    // Invalidate cache after write
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.path);
    }

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

    if (parsed.value.pattern.len == 0) {
        return buildValidationError(allocator, "glob", "glob requires a 'pattern' parameter (e.g., '**/*.zig').");
    }

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

    // Truncate glob output
    const truncated_output = try truncateToolOutput(allocator, stdout.items);
    defer {
        if (truncated_output.ptr != stdout.items.ptr) allocator.free(truncated_output);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 glob(\"{s}\") → {d} files\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} files matching '{s}':\n{s}", .{ count, parsed.value.pattern, truncated_output }),
    };
}

fn tryExecuteRg(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, include: ?[]const u8, max_results: u32) ?ToolExecution {
    // Build argv: rg --no-heading --line-number --color=never
    // If include: add --glob=INCLUDE
    // Add --max-count=N for max_results
    // Add pattern and path
    // Use std.process.Child directly (NOT through sh -c)
    // If rg not found (spawn fails or exit 127): return null
    // Otherwise: return ToolExecution with results

    var argv_list = array_list_compat.ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();

    argv_list.append("rg") catch return null;
    argv_list.append("--no-heading") catch return null;
    argv_list.append("--line-number") catch return null;
    argv_list.append("--color=never") catch return null;

    if (include) |inc| {
        const glob_arg = std.fmt.allocPrint(allocator, "--glob={s}", .{inc}) catch return null;
        argv_list.append(glob_arg) catch return null;
    }

    if (max_results > 0) {
        const max_arg = std.fmt.allocPrint(allocator, "--max-count={d}", .{max_results}) catch return null;
        argv_list.append(max_arg) catch return null;
    }

    argv_list.append(pattern) catch return null;
    argv_list.append(path) catch return null;

    const argv = argv_list.toOwnedSlice() catch return null;
    defer allocator.free(argv);

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const spawn_result = child.spawn();
    if (spawn_result) |success| {
        _ = success;
    } else |err| {
        // If rg is not found, return null to fallback to grep
        if (err == error.FileNotFound) {
            return null;
        }
        return null;
    }

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

    child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024) catch return null;

    const term = child.wait() catch return null;
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 1,
    };

    // Exit code 127 means command not found (rg not installed)
    if (exit_code == 127) {
        return null;
    }

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, stdout.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    // Truncate rg output
    const truncated_output = truncateToolOutput(allocator, stdout.items) catch return null;
    defer {
        if (truncated_output.ptr != stdout.items.ptr) allocator.free(truncated_output);
    }
    return .{
        .display = std.fmt.allocPrint(allocator, "🔧 rg(\"{s}\") → {d} matches\n", .{ pattern, count }) catch return null,
        .result = std.fmt.allocPrint(allocator, "Found {d} matches for '{s}':\n{s}", .{ count, pattern, truncated_output }) catch return null,
    };
}

fn tryExecuteGrep(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, include: ?[]const u8, max_results: u32) !ToolExecution {
    var cmd_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer cmd_buf.deinit();
    const writer = cmd_buf.writer();

    try writer.print("grep -rn --binary-files=without-match '{s}' '{s}'", .{ pattern, path });
    if (include) |inc| {
        try writer.print(" --include='{s}'", .{inc});
    }
    try writer.print(" 2>/dev/null | head -{d}", .{max_results});

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

    // Truncate grep output
    const truncated_output = try truncateToolOutput(allocator, stdout.items);
    defer {
        if (truncated_output.ptr != stdout.items.ptr) allocator.free(truncated_output);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 grep(\"{s}\") → {d} matches\n", .{ pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} matches for '{s}':\n{s}", .{ count, pattern, truncated_output }),
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

    if (parsed.value.pattern.len == 0) {
        return buildValidationError(allocator, "grep", "grep requires a 'pattern' parameter to search for.");
    }

    const search_path = parsed.value.path orelse ".";
    const include = parsed.value.include;
    const max_results = parsed.value.max_results orelse 50;

    // Try ripgrep first
    if (tryExecuteRg(allocator, parsed.value.pattern, search_path, include, max_results)) |result| {
        return result;
    }
    // Fallback to grep
    return tryExecuteGrep(allocator, parsed.value.pattern, search_path, include, max_results);
}

fn executeEditTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const EditArgs = struct {
        file_path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
    };

    var parsed = try std.json.parseFromSlice(EditArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.file_path.len == 0) {
        return buildValidationError(allocator, "edit", "edit requires 'file_path' parameter.");
    }
    if (parsed.value.old_string.len == 0) {
        return buildValidationError(allocator, "edit", "edit requires 'old_string' to find in the file.");
    }
    if (std.mem.eql(u8, parsed.value.old_string, parsed.value.new_string)) {
        return buildValidationError(allocator, "edit", "old_string and new_string are identical. No change needed.");
    }

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

    // Invalidate cache after edit
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.file_path);
    }

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
    // Guard: empty arguments would cause a confusing JSON parse error downstream;
    // return a descriptive validation error instead.
    if (tool_call.arguments.len == 0) {
        return buildValidationError(allocator, tool_call.name, "Tool call requires non-empty arguments JSON.");
    }
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

/// Generate a unified diff preview for an edit operation (does NOT apply the edit).
pub fn previewEditDiff(allocator: std.mem.Allocator, file_path: []const u8, old_string: []const u8, new_string: []const u8) !?[]const u8 {
    // Read current file content
    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    // Find old_string in file (same logic as executeEditTool)
    const pos = std.mem.indexOf(u8, content, old_string) orelse return null;
    const after_first = pos + old_string.len;
    // Check uniqueness
    if (std.mem.indexOf(u8, content[after_first..], old_string)) |_| return null;

    // Build new content in-memory
    var new_content = array_list_compat.ArrayList(u8).init(allocator);
    defer new_content.deinit();
    try new_content.appendSlice(content[0..pos]);
    try new_content.appendSlice(new_string);
    try new_content.appendSlice(content[after_first..]);

    // Generate diff
    var result = try myers.MyersDiff.diff(allocator, content, new_content.items);
    defer result.deinit();

    if (result.hunks.len == 0) return null;
    return try myers.formatUnifiedDiff(allocator, &result, file_path, file_path);
}

/// Generate a unified diff preview for a write_file operation (does NOT write).
pub fn previewWriteDiff(allocator: std.mem.Allocator, file_path: []const u8, new_content: []const u8) !?[]const u8 {
    const old_content = std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch return null;
    defer allocator.free(old_content);

    var result = try myers.MyersDiff.diff(allocator, old_content, new_content);
    defer result.deinit();

    if (result.hunks.len == 0) return null;
    return try myers.formatUnifiedDiff(allocator, &result, file_path, file_path);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "executeBuiltinTool - read_file nonexistent returns error" {
    const tool_call = core.ParsedToolCall{
        .id = "te-1",
        .name = "read_file",
        .arguments = "{\"path\": \"/tmp/crushcode_nonexistent_file_xyz_12345.txt\"}",
    };
    const result = executeBuiltinTool(std.testing.allocator, tool_call);
    try std.testing.expectError(error.FileNotFound, result);
}

test "executeBuiltinTool - empty arguments JSON" {
    const tool_call = core.ParsedToolCall{
        .id = "te-2",
        .name = "read_file",
        .arguments = "",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Validation error") != null);
}

test "executeBuiltinTool - shell empty command" {
    const tool_call = core.ParsedToolCall{
        .id = "te-3",
        .name = "shell",
        .arguments = "{\"command\": \"\"}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Validation error") != null);
}

test "executeBuiltinTool - glob no matches returns empty" {
    const tool_call = core.ParsedToolCall{
        .id = "te-4",
        .name = "glob",
        .arguments = "{\"pattern\": \"*.nonexistent_ext_xyz_98765\"}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Found 0 files") != null);
}

test "executeBuiltinTool - edit old_string not found" {
    const tmp_path = "/tmp/crushcode_test_edit_notfound.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello world");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"file_path\": \"{s}\", \"old_string\": \"nonexistent_text\", \"new_string\": \"replaced\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-5",
        .name = "edit",
        .arguments = args,
    };
    const result = executeBuiltinTool(std.testing.allocator, tool_call);
    try std.testing.expectError(error.OldStringNotFound, result);
}

test "executeBuiltinTool - write_file to invalid path" {
    const tool_call = core.ParsedToolCall{
        .id = "te-6",
        .name = "write_file",
        .arguments = "{\"path\": \"/nonexistent_dir_xyz_9999/subdir/file.txt\", \"content\": \"test\"}",
    };
    const result = executeBuiltinTool(std.testing.allocator, tool_call);
    try std.testing.expectError(error.FileNotFound, result);
}

test "executeBuiltinTool - unknown tool name returns UnsupportedTool" {
    const tool_call = core.ParsedToolCall{
        .id = "te-7",
        .name = "unknown_tool_xyz",
        .arguments = "{}",
    };
    const result = executeBuiltinTool(std.testing.allocator, tool_call);
    try std.testing.expectError(error.UnsupportedTool, result);
}

test "executeBuiltinTool - write_file and read_file round-trip" {
    const tmp_path = "/tmp/crushcode_test_roundtrip.txt";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Write
    const write_call = core.ParsedToolCall{
        .id = "te-rt-1",
        .name = "write_file",
        .arguments = "{\"path\": \"/tmp/crushcode_test_roundtrip.txt\", \"content\": \"round trip content\"}",
    };
    const write_exec = try executeBuiltinTool(std.testing.allocator, write_call);
    defer std.testing.allocator.free(write_exec.display);
    defer std.testing.allocator.free(write_exec.result);

    // Read back
    const read_call = core.ParsedToolCall{
        .id = "te-rt-2",
        .name = "read_file",
        .arguments = "{\"path\": \"/tmp/crushcode_test_roundtrip.txt\"}",
    };
    const read_exec = try executeBuiltinTool(std.testing.allocator, read_call);
    defer std.testing.allocator.free(read_exec.display);
    defer std.testing.allocator.free(read_exec.result);
    try std.testing.expect(std.mem.indexOf(u8, read_exec.result, "round trip content") != null);
}

test "executeBuiltinTool - shell captures stdout" {
    const tool_call = core.ParsedToolCall{
        .id = "te-8",
        .name = "shell",
        .arguments = "{\"command\": \"echo test_output_42\"}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "test_output_42") != null);
}

test "executeBuiltinTool - edit replaces text correctly" {
    const tmp_path = "/tmp/crushcode_test_edit_correct.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("foo bar baz");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"file_path\": \"{s}\", \"old_string\": \"bar\", \"new_string\": \"qux\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-9",
        .name = "edit",
        .arguments = args,
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);

    // Verify
    const verify = try std.fs.cwd().openFile(tmp_path, .{});
    defer verify.close();
    const content = try verify.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.eql(u8, content, "foo qux baz"));
}
