const std = @import("std");
const string_utils = @import("string_utils");
const json_helpers = @import("json_helpers");
const process = @import("process");
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
const web_fetch_mod = @import("web_fetch");
const web_search_mod = @import("web_search");
const image_display_mod = @import("image_display");
const edit_batch_mod = @import("edit_batch");
const lsp_tools_mod = @import("lsp_tools");
const checkpoint_mod = @import("safety_checkpoint");
const session_db_mod = @import("session_db");
const todo_mod = @import("todo");
const apply_patch_mod = @import("apply_patch");
const question_mod = @import("question");
const hooks_mod = @import("hooks_registry");
const subagent_mod = @import("subagent");
const hashline_edit_mod = @import("hashline_edit");

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

const BuiltinDispatchEntry = struct {
    name: []const u8,
    executor: *const fn (std.mem.Allocator, core.ParsedToolCall) anyerror!ToolExecution,
};

threadlocal var active_evaluator: ?*PermissionEvaluator = null;
threadlocal var active_audit_logger: ?*PermissionAuditLogger = null;
threadlocal var active_shell_state: ?*ShellState = null;
threadlocal var active_blocklist: ?*CommandBlocklist = null;
threadlocal var active_safelist: ?*SafeCommandList = null;
threadlocal var active_json_output: json_output_mod.JsonOutput = .{ .enabled = false };
threadlocal var active_file_tracker: ?*file_tracker_mod.FileTracker = null;
threadlocal var active_agent_mode: agent_loop_mod.AgentMode = .execute;
threadlocal var active_checkpoint_manager: ?*checkpoint_mod.CheckpointManager = null;
threadlocal var active_session_db_ref: ?*session_db_mod.SessionDB = null;
threadlocal var active_checkpoint_session_id: []const u8 = "";
threadlocal var active_hook_registry: ?*hooks_mod.HookRegistry = null;
threadlocal var hashline_mode: bool = false;

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

pub fn setCheckpointManager(mgr: ?*checkpoint_mod.CheckpointManager) void {
    active_checkpoint_manager = mgr;
}

pub fn setSessionDbForCheckpoint(db: ?*session_db_mod.SessionDB) void {
    active_session_db_ref = db;
}

pub fn setCheckpointSessionId(session_id: []const u8) void {
    active_checkpoint_session_id = session_id;
}

pub fn setHookRegistry(registry: ?*hooks_mod.HookRegistry) void {
    active_hook_registry = registry;
}

pub fn setHashlineMode(enabled: bool) void {
    hashline_mode = enabled;
}

/// Attempt to snapshot a file before a destructive operation.
/// Non-blocking: logs and continues on failure.
fn checkpointBeforeWrite(file_path: []const u8, operation: []const u8) void {
    const cp = active_checkpoint_manager orelse return;
    const db = active_session_db_ref orelse return;
    const sid = active_checkpoint_session_id;
    if (sid.len == 0) return;
    cp.snapshotFile(db, sid, file_path, operation) catch |err| {
        std.log.warn("[checkpoint] snapshotFile failed for {s}: {}", .{ file_path, err });
    };
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

/// Validates that a string field is non-empty. Returns buildValidationError result via
/// optional — use as: `if (try requireField(allocator, "tool", "msg", value)) |r| return r;`
/// Collapses the 3-line `if (len==0) { return buildValidationError(...); }` pattern to 1 line.
fn requireField(allocator: std.mem.Allocator, tool_name: []const u8, message: []const u8, value: []const u8) !?ToolExecution {
    if (value.len == 0) {
        return try buildValidationError(allocator, tool_name, message);
    }
    return null;
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

    // PreToolUse hook — abort if any hook returns non-zero
    if (active_hook_registry) |registry| {
        var ctx = hooks_mod.HookContext{
            .hook_type = .PreToolUse,
            .tool_name = tool_name,
            .arguments = arguments,
            .timestamp = std.time.milliTimestamp(),
        };
        if (!(registry.shouldProceed(&ctx) catch true)) {
            return try ToolResult.init(allocator, call_id, "Tool execution blocked by hook", false);
        }
    }

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
            eval: {
                var req = PermissionRequest.init(tool_name, "execute", allocator) catch |err| {
                    std.log.warn("PermissionRequest.init failed: {} — skipping evaluator", .{err});
                    break :eval;
                };
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

    // PostToolUse hook
    if (active_hook_registry) |registry| {
        var ctx = hooks_mod.HookContext{
            .hook_type = .PostToolUse,
            .tool_name = tool_name,
            .arguments = arguments,
            .result = execution.result,
            .timestamp = std.time.milliTimestamp(),
        };
        const results = registry.executeHooks(&ctx) catch &.{};
        defer {
            for (results) |*r| r.deinit(allocator);
            if (results.len > 0) allocator.free(results);
        }
    }

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

fn listDirectoryExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "list_directory", arguments, executeListDirectoryTool);
}

fn createFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "create_file", arguments, executeCreateFileTool);
}

fn moveFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "move_file", arguments, executeMoveFileTool);
}

fn copyFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "copy_file", arguments, executeCopyFileTool);
}

fn deleteFileExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "delete_file", arguments, executeDeleteFileTool);
}

fn fileInfoExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "file_info", arguments, executeFileInfoTool);
}

// Git and search tool executors
fn gitStatusExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "git_status", arguments, executeGitStatusTool);
}

fn gitDiffExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "git_diff", arguments, executeGitDiffTool);
}

fn gitLogExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "git_log", arguments, executeGitLogTool);
}

fn searchFilesExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "search_files", arguments, executeSearchFilesTool);
}

fn runTestsExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "run_tests", arguments, executeRunTestsTool);
}

// Web tool executors
fn webFetchExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "web_fetch", arguments, executeWebFetchTool);
}

fn webSearchExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "web_search", arguments, executeWebSearchTool);
}

fn imageDisplayExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "image_display", arguments, executeImageDisplayTool);
}

fn editBatchExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "edit_batch", arguments, executeEditBatchTool);
}

// LSP tool executors
fn lspDefinitionExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_definition", arguments, executeLspDefinitionTool);
}

fn lspReferencesExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_references", arguments, executeLspReferencesTool);
}

fn lspDiagnosticsExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_diagnostics", arguments, executeLspDiagnosticsTool);
}

fn lspHoverExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_hover", arguments, executeLspHoverTool);
}

fn lspSymbolsExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_symbols", arguments, executeLspSymbolsTool);
}

fn lspRenameExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "lsp_rename", arguments, executeLspRenameTool);
}

fn todoWriteExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "todo_write", arguments, executeTodoWriteTool);
}

fn applyPatchExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "apply_patch", arguments, executeApplyPatchTool);
}

fn questionExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "question", arguments, executeQuestionTool);
}

fn subagentExecutor(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) !ToolResult {
    return adaptToolExecution(allocator, call_id, "subagent", arguments, executeSubagentTool);
}

const builtin_tool_bindings = [_]BuiltinToolDefinition{
    .{ .name = "read_file", .executor = readFileExecutor },
    .{ .name = "shell", .executor = shellExecutor },
    .{ .name = "write_file", .executor = writeFileExecutor },
    .{ .name = "glob", .executor = globExecutor },
    .{ .name = "grep", .executor = grepExecutor },
    .{ .name = "edit", .executor = editExecutor },
    .{ .name = "list_directory", .executor = listDirectoryExecutor },
    .{ .name = "create_file", .executor = createFileExecutor },
    .{ .name = "move_file", .executor = moveFileExecutor },
    .{ .name = "copy_file", .executor = copyFileExecutor },
    .{ .name = "delete_file", .executor = deleteFileExecutor },
    .{ .name = "file_info", .executor = fileInfoExecutor },
    .{ .name = "git_status", .executor = gitStatusExecutor },
    .{ .name = "git_diff", .executor = gitDiffExecutor },
    .{ .name = "git_log", .executor = gitLogExecutor },
    .{ .name = "search_files", .executor = searchFilesExecutor },
    .{ .name = "run_tests", .executor = runTestsExecutor },
    .{ .name = "web_fetch", .executor = webFetchExecutor },
    .{ .name = "web_search", .executor = webSearchExecutor },
    .{ .name = "image_display", .executor = imageDisplayExecutor },
    .{ .name = "edit_batch", .executor = editBatchExecutor },
    .{ .name = "lsp_definition", .executor = lspDefinitionExecutor },
    .{ .name = "lsp_references", .executor = lspReferencesExecutor },
    .{ .name = "lsp_diagnostics", .executor = lspDiagnosticsExecutor },
    .{ .name = "lsp_hover", .executor = lspHoverExecutor },
    .{ .name = "lsp_symbols", .executor = lspSymbolsExecutor },
    .{ .name = "lsp_rename", .executor = lspRenameExecutor },
    .{ .name = "todo_write", .executor = todoWriteExecutor },
    .{ .name = "apply_patch", .executor = applyPatchExecutor },
    .{ .name = "question", .executor = questionExecutor },
    .{ .name = "subagent", .executor = subagentExecutor },
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

    if (try requireField(allocator, "read_file", "read_file requires a 'path' parameter. Provide the file path to read.", parsed.value.path)) |r| return r;
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

    // Track the file after reading — stores mtime for stale-check before edits
    if (active_file_tracker) |tracker| {
        tracker.track(parsed.value.path, content, stat) catch {};
    }

    // Truncate file content
    const truncated = try truncateToolOutput(allocator, content);
    const truncated_owned = if (truncated.ptr == content.ptr) try allocator.dupe(u8, truncated) else truncated;
    defer {
        if (truncated.ptr != content.ptr) allocator.free(truncated);
    }

    // Format with hashline annotations when mode is enabled
    if (hashline_mode) {
        const annotated = hashline_edit_mod.formatFileWithHashlineEdit(allocator, truncated_owned) catch truncated_owned;
        const annotated_owned = if (annotated.ptr == truncated_owned.ptr) try allocator.dupe(u8, annotated) else annotated;
        defer {
            if (annotated.ptr != truncated_owned.ptr) allocator.free(annotated);
        }
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 read_file(\"{s}\") → {d} bytes [hashline]\n", .{ parsed.value.path, stat.size }),
            .result = try std.fmt.allocPrint(allocator, "=== {s} ({d} bytes) ===\n{s}", .{ parsed.value.path, stat.size, annotated_owned }),
        };
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

    if (try requireField(allocator, "shell", "shell requires a 'command' parameter. Provide the shell command to execute.", parsed.value.command)) |r| return r;
    if (parsed.value.command.len >= 10000) {
        const msg = try std.fmt.allocPrint(allocator, "Command too long ({d} chars). Maximum is 10000 characters.", .{parsed.value.command.len});
        defer allocator.free(msg);
        return buildValidationError(allocator, "shell", msg);
    }

    if (parsed.value.timeout) |secs| {
        if (secs > 0) {
            const cmd = try std.fmt.allocPrint(allocator, "timeout --signal=KILL {d} sh -c {s}", .{ secs, parsed.value.command });
            defer allocator.free(cmd);
            const result = try process.runShellCommand(allocator, cmd);
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            const exit_code = result.exit_code;
            const timed_out = exit_code == 124;
            // Truncate stdout only — preserve exit_code and stderr formatting
            const truncated_stdout = try truncateToolOutput(allocator, result.stdout);
            defer {
                if (truncated_stdout.ptr != result.stdout.ptr) allocator.free(truncated_stdout);
            }
            return .{
                .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\", timeout={d}s) → exit {d}{s}\n", .{ parsed.value.command, secs, exit_code, if (timed_out) " (TIMEOUT)" else "" }),
                .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, truncated_stdout, result.stderr }),
            };
        }
    }

    const result = try process.runShellCommand(allocator, parsed.value.command);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const exit_code = result.exit_code;

    // Truncate stdout only — preserve exit_code and stderr formatting
    const truncated_stdout = try truncateToolOutput(allocator, result.stdout);
    defer {
        if (truncated_stdout.ptr != result.stdout.ptr) allocator.free(truncated_stdout);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 shell(\"{s}\") → exit {d}\n", .{ parsed.value.command, exit_code }),
        .result = try std.fmt.allocPrint(allocator, "exit_code: {d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, truncated_stdout, result.stderr }),
    };
}

fn executeWriteFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const WriteFileArgs = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(WriteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "write_file", "write_file requires a 'path' parameter.", parsed.value.path)) |r| return r;
    if (try requireField(allocator, "write_file", "write_file requires 'content' to write.", parsed.value.content)) |r| return r;
    if (isSystemPath(parsed.value.path)) {
        const msg = try std.fmt.allocPrint(allocator, "Writing to system files is not allowed. Path: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return buildValidationError(allocator, "write_file", msg);
    }

    // [Safety] Write-before-read guard: reject if file exists but was never read
    // This prevents blind overwrites — the AI must read a file before modifying it.
    if (active_file_tracker) |tracker| {
        if (tracker.files.get(parsed.value.path) == null) {
            // File was never tracked (never read). Check if file actually exists.
            if (std.fs.cwd().statFile(parsed.value.path)) |_| {
                return buildValidationError(allocator, "write_file",
                    "File has not been read in this session. Read the file first before overwriting to prevent data loss.");
            } else |_| {}
        }
    }

    // [Safety] mtime check for existing files: warn if file changed since last read
    blk: {
        if (active_file_tracker) |tracker| {
            if (tracker.files.get(parsed.value.path)) |tracked| {
                const current_file = std.fs.cwd().openFile(parsed.value.path, .{}) catch break :blk;
                defer current_file.close();
                const current_stat = current_file.stat() catch break :blk;
                if (current_stat.mtime != tracked.mtime) {
                    return buildValidationError(allocator, "write_file",
                        "File has been modified since last read (external change detected). Re-read the file before overwriting.");
                }
            }
        }
    }

    // Checkpoint: snapshot current file content before overwriting
    checkpointBeforeWrite(parsed.value.path, "write_file");

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

    if (try requireField(allocator, "glob", "glob requires a 'pattern' parameter (e.g., '**/*.zig').", parsed.value.pattern)) |r| return r;

    const max = parsed.value.max_results orelse 50;
    const find_cmd = try std.fmt.allocPrint(allocator, "find . -name '{s}' -type f 2>/dev/null | head -{d}", .{ parsed.value.pattern, max });
    defer allocator.free(find_cmd);

    const result = try process.runShellCommand(allocator, find_cmd);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    // Truncate glob output
    const truncated_output = try truncateToolOutput(allocator, result.stdout);
    defer {
        if (truncated_output.ptr != result.stdout.ptr) allocator.free(truncated_output);
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

/// Try ast-grep (sg) binary for AST-aware code search.
/// Returns null if sg is not installed or fails to spawn.
/// Falls back gracefully so rg/grep can take over.
fn tryExecuteSg(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, language: ?[]const u8, max_results: u32) ?ToolExecution {
    // Build argv: sg run -p '<pattern>' --json [path]
    // Optionally add -l <language> if provided
    var argv_list = array_list_compat.ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();

    argv_list.append("sg") catch return null;
    argv_list.append("run") catch return null;

    const pattern_arg = std.fmt.allocPrint(allocator, "-p{s}", .{pattern}) catch return null;
    argv_list.append(pattern_arg) catch return null;

    argv_list.append("--json") catch return null;

    if (language) |lang| {
        const lang_arg = std.fmt.allocPrint(allocator, "-l{s}", .{lang}) catch return null;
        argv_list.append(lang_arg) catch return null;
    }

    argv_list.append(path) catch return null;

    const argv = argv_list.toOwnedSlice() catch return null;
    defer allocator.free(argv);

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const spawn_result = child.spawn();
    if (spawn_result) |success| {
        _ = success;
    } else |_| {
        // sg not found or failed to spawn — return null for rg/grep fallback
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

    // Exit code 1 in sg means no matches (not an error), 2+ means error
    if (exit_code >= 127) return null;

    // Parse JSON output: [{ "text": "...", "file": "...", "range": { ... } }, ...]
    const output = stdout.items;
    if (output.len == 0) return null;

    // Quick check: output should start with '[' for valid JSON array
    var trimmed = std.mem.trimLeft(u8, output, " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '[') return null;

    // Count matches by counting '"file":' occurrences (lightweight)
    var count: u32 = 0;
    var pos: usize = 0;
    while (pos < trimmed.len) : (pos += 1) {
        if (std.mem.startsWith(u8, trimmed[pos..], "\"file\"")) {
            count += 1;
            pos += 5; // skip past "file"
        }
    }

    if (count == 0) return null;

    // Parse each match to produce human-readable output
    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    const SgMatch = struct {
        text: []const u8,
        file: []const u8,
        range: struct {
            start: struct {
                line: u32,
                column: u32,
            },
            end: struct {
                line: u32,
                column: u32,
            },
        },
    };

    const parsed = std.json.parseFromSlice([]SgMatch, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var shown: u32 = 0;
    for (parsed.value) |match_item| {
        if (max_results > 0 and shown >= max_results) break;
        writer.print("{s}:{d}:{d}: {s}\n", .{
            match_item.file,
            match_item.range.start.line + 1, // sg uses 0-indexed lines
            match_item.range.start.column,
            std.mem.trim(u8, match_item.text, " \t\n\r"),
        }) catch return null;
        shown += 1;
    }

    const result_str = result_buf.toOwnedSlice() catch return null;

    // Truncate sg output
    const truncated_output = truncateToolOutput(allocator, result_str) catch return null;
    defer {
        if (truncated_output.ptr != result_str.ptr) allocator.free(truncated_output);
    }

    return .{
        .display = std.fmt.allocPrint(allocator, "🔧 sg(\"{s}\") → {d} AST matches\n", .{ pattern, shown }) catch return null,
        .result = std.fmt.allocPrint(allocator, "Found {d} AST matches for '{s}' (ast-grep):\n{s}", .{ shown, pattern, truncated_output }) catch return null,
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

    const result = try process.runShellCommand(allocator, cmd_buf.items);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    // Truncate grep output
    const truncated_output = try truncateToolOutput(allocator, result.stdout);
    defer {
        if (truncated_output.ptr != result.stdout.ptr) allocator.free(truncated_output);
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

    if (try requireField(allocator, "grep", "grep requires a 'pattern' parameter to search for.", parsed.value.pattern)) |r| return r;

    const search_path = parsed.value.path orelse ".";
    const include = parsed.value.include;
    const max_results = parsed.value.max_results orelse 50;

    // 3-tier search: ast-grep (sg) → ripgrep (rg) → grep
    // sg provides AST-aware matching when installed; falls back gracefully.

    // Detect language from include pattern for sg (e.g., "*.zig" → "Zig")
    const sg_language: ?[]const u8 = sg_language: {
        if (include) |inc| {
            // Map common extensions to ast-grep language names
            if (std.mem.endsWith(u8, inc, ".ts") or std.mem.endsWith(u8, inc, ".tsx")) break :sg_language "TypeScript";
            if (std.mem.endsWith(u8, inc, ".js") or std.mem.endsWith(u8, inc, ".jsx")) break :sg_language "JavaScript";
            if (std.mem.endsWith(u8, inc, ".py")) break :sg_language "Python";
            if (std.mem.endsWith(u8, inc, ".rs")) break :sg_language "Rust";
            if (std.mem.endsWith(u8, inc, ".go")) break :sg_language "Go";
            if (std.mem.endsWith(u8, inc, ".java")) break :sg_language "Java";
            if (std.mem.endsWith(u8, inc, ".c")) break :sg_language "C";
            if (std.mem.endsWith(u8, inc, ".cpp") or std.mem.endsWith(u8, inc, ".cc") or std.mem.endsWith(u8, inc, ".cxx")) break :sg_language "Cpp";
            if (std.mem.endsWith(u8, inc, ".zig")) break :sg_language "Zig"; // sg doesn't support Zig but try anyway
        }
        break :sg_language null;
    };

    // Tier 1: ast-grep (sg) — AST-aware structural search
    if (tryExecuteSg(allocator, parsed.value.pattern, search_path, sg_language, max_results)) |result| {
        return result;
    }
    // Tier 2: ripgrep (rg)
    if (tryExecuteRg(allocator, parsed.value.pattern, search_path, include, max_results)) |result| {
        return result;
    }
    // Tier 3: grep (POSIX fallback)
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

    if (try requireField(allocator, "edit", "edit requires 'file_path' parameter.", parsed.value.file_path)) |r| return r;
    if (try requireField(allocator, "edit", "edit requires 'old_string' to find in the file.", parsed.value.old_string)) |r| return r;
    if (std.mem.eql(u8, parsed.value.old_string, parsed.value.new_string)) {
        return buildValidationError(allocator, "edit", "old_string and new_string are identical. No change needed.");
    }

    // [Safety] Write-before-read guard: reject if file was never read in this session
    if (active_file_tracker) |tracker| {
        if (tracker.files.get(parsed.value.file_path) == null) {
            return buildValidationError(allocator, "edit",
                "File has not been read in this session. Read the file first before editing to prevent data corruption.");
        }
    }

    // [Safety] mtime check: reject if file changed since last read
    // Compare current mtime against tracked mtime from the last read_file call
    blk: {
        if (active_file_tracker) |tracker| {
            if (tracker.files.get(parsed.value.file_path)) |tracked| {
                const current_file = std.fs.cwd().openFile(parsed.value.file_path, .{}) catch break :blk;
                defer current_file.close();
                const current_stat = current_file.stat() catch break :blk;
                if (current_stat.mtime != tracked.mtime) {
                    return buildValidationError(allocator, "edit",
                        "File has been modified since last read (external change detected). Re-read the file before editing to avoid data corruption.");
                }
            }
        }
    }

    // Checkpoint: snapshot current file content before editing
    checkpointBeforeWrite(parsed.value.file_path, "edit");

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

    // [Quality] Auto LSP diagnostics after edit — check for type errors
    var diag_note: ?[]const u8 = null;
    {
        const diag_args = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\"}}", .{parsed.value.file_path});
        defer allocator.free(diag_args);
        if (lsp_tools_mod.executeDiagnostics(allocator, diag_args)) |diag_result| {
            defer allocator.free(diag_result);
            // Check if result contains errors (look for "error" or "Error" in output)
            if (std.mem.indexOf(u8, diag_result, "error") != null or std.mem.indexOf(u8, diag_result, "Error") != null) {
                // Count approximate issues
                var count: u32 = 0;
                var idx: usize = 0;
                while (std.mem.indexOf(u8, diag_result[idx..], "error") orelse std.mem.indexOf(u8, diag_result[idx..], "Error")) |match_pos| {
                    count += 1;
                    idx += match_pos + 5;
                    if (idx >= diag_result.len) break;
                }
                if (count > 0) {
                    diag_note = try std.fmt.allocPrint(allocator, "\n⚠️ ~{d} issue(s) detected by LSP after edit. Run lsp_diagnostics for details.", .{count});
                }
            }
        } else |_| {
            // LSP not available or failed — silently skip auto-diag
        }
    }
    defer if (diag_note) |n| allocator.free(n);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 edit(\"{s}\") → replaced {d} chars with {d} chars{s}\n", .{ parsed.value.file_path, parsed.value.old_string.len, parsed.value.new_string.len, diag_note orelse "" }),
        .result = try std.fmt.allocPrint(allocator, "Edited {s}: replaced text at position {d}. File: {d} lines → {d} lines{s}", .{ parsed.value.file_path, pos, lines_before, lines_after, diag_note orelse "" }),
    };
}

fn executeGitStatusTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    _ = tool_call;

    const result = try process.runShellCommand(allocator, "git status --porcelain 2>&1");
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    const exit_code = result.exit_code;

    if (exit_code != 0) {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 git_status → not a git repository\n", .{}),
            .result = try std.fmt.allocPrint(allocator, "Not a git repository (exit code {d})", .{exit_code}),
        };
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 git_status → clean\n", .{}),
            .result = try allocator.dupe(u8, "Working tree clean"),
        };
    }

    const truncated = try truncateToolOutput(allocator, trimmed);
    const truncated_owned = if (truncated.ptr == trimmed.ptr) try allocator.dupe(u8, truncated) else truncated;
    defer {
        if (truncated.ptr != trimmed.ptr) allocator.free(truncated);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 git_status → {d} bytes\n", .{trimmed.len}),
        .result = truncated_owned,
    };
}

fn executeGitDiffTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GitDiffArgs = struct {
        target: ?[]const u8 = null,
        file_path: ?[]const u8 = null,
        staged: bool = false,
    };

    var parsed = try std.json.parseFromSlice(GitDiffArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var cmd_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer cmd_buf.deinit();
    const writer = cmd_buf.writer();

    try writer.writeAll("git diff");

    if (parsed.value.staged) {
        try writer.writeAll(" --cached");
    }

    if (parsed.value.target) |target| {
        try writer.print(" {s}", .{target});
    }

    if (parsed.value.file_path) |fp| {
        try writer.print(" -- {s}", .{fp});
    }

    // Redirect stderr to stdout so we can capture error messages
    try writer.writeAll(" 2>&1");

    const result = try process.runShellCommand(allocator, cmd_buf.items);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 git_diff → no changes\n", .{}),
            .result = try allocator.dupe(u8, "No changes"),
        };
    }

    // Truncate to 500 lines
    const truncated = try truncateToolOutput(allocator, trimmed);
    const truncated_owned = if (truncated.ptr == trimmed.ptr) try allocator.dupe(u8, truncated) else truncated;
    defer {
        if (truncated.ptr != trimmed.ptr) allocator.free(truncated);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 git_diff → {d} bytes\n", .{trimmed.len}),
        .result = truncated_owned,
    };
}

fn executeGitLogTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const GitLogArgs = struct {
        count: ?u32 = 10,
        oneline: bool = true,
        file_path: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(GitLogArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const count = parsed.value.count orelse 10;

    var cmd_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer cmd_buf.deinit();
    const writer = cmd_buf.writer();

    try writer.writeAll("git log");
    if (parsed.value.oneline) {
        try writer.writeAll(" --oneline");
    }
    try writer.print(" -n {d}", .{count});

    if (parsed.value.file_path) |fp| {
        try writer.print(" -- {s}", .{fp});
    }

    try writer.writeAll(" 2>&1");

    const result = try process.runShellCommand(allocator, cmd_buf.items);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const truncated = try truncateToolOutput(allocator, result.stdout);
    const truncated_owned = if (truncated.ptr == result.stdout.ptr) try allocator.dupe(u8, truncated) else truncated;
    defer {
        if (truncated.ptr != result.stdout.ptr) allocator.free(truncated);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 git_log(-n{d}) → {d} bytes\n", .{ count, result.stdout.len }),
        .result = truncated_owned,
    };
}

fn executeSearchFilesTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const SearchFilesArgs = struct {
        pattern: []const u8,
        directory: ?[]const u8 = null,
        max_results: ?u32 = 50,
    };

    var parsed = try std.json.parseFromSlice(SearchFilesArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "search_files", "search_files requires a 'pattern' parameter (e.g., '*.zig').", parsed.value.pattern)) |r| return r;

    const directory = parsed.value.directory orelse ".";
    const max_results = parsed.value.max_results orelse 50;

    const find_cmd = try std.fmt.allocPrint(allocator, "find '{s}' -name '{s}' -type f 2>/dev/null | head -{d}", .{ directory, parsed.value.pattern, max_results });
    defer allocator.free(find_cmd);

    const result = try process.runShellCommand(allocator, find_cmd);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }

    const truncated_output = try truncateToolOutput(allocator, result.stdout);
    defer {
        if (truncated_output.ptr != result.stdout.ptr) allocator.free(truncated_output);
    }
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 search_files(\"{s}\") → {d} files\n", .{ parsed.value.pattern, count }),
        .result = try std.fmt.allocPrint(allocator, "Found {d} files matching '{s}':\n{s}", .{ count, parsed.value.pattern, truncated_output }),
    };
}

fn executeRunTestsTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const RunTestsArgs = struct {
        filter: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(RunTestsArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Detect test command from project type
    const test_cmd: []const u8 = blk: {
        if (std.fs.cwd().access("build.zig", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "zig build test --cache-dir /tmp/zigcache 2>&1 | grep -i \"{s}\"; zig build test --cache-dir /tmp/zigcache 2>&1", .{f})
            else
                "zig build test --cache-dir /tmp/zigcache 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("Cargo.toml", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "cargo test \"{s}\" 2>&1", .{f})
            else
                "cargo test 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("go.mod", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "go test -run \"{s}\" ./... 2>&1", .{f})
            else
                "go test ./... 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("package.json", .{})) {
            break :blk "npm test 2>&1";
        } else |_| {}
        if (std.fs.cwd().access("pytest.ini", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "pytest -k \"{s}\" 2>&1", .{f})
            else
                "pytest 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("pyproject.toml", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "pytest -k \"{s}\" 2>&1", .{f})
            else
                "pytest 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("setup.py", .{})) {
            const cmd = if (parsed.value.filter) |f|
                try std.fmt.allocPrint(allocator, "pytest -k \"{s}\" 2>&1", .{f})
            else
                "pytest 2>&1";
            break :blk cmd;
        } else |_| {}
        if (std.fs.cwd().access("Makefile", .{})) {
            break :blk "make test 2>&1";
        } else |_| {}
        break :blk "echo 'No test command detected for this project'";
    };

    const result = try process.runShellCommand(allocator, test_cmd);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const output = if (result.stderr.len > 0 and result.stdout.len == 0) result.stderr else result.stdout;
    const truncated_output = try truncateToolOutput(allocator, output);
    defer {
        if (truncated_output.ptr != output.ptr) allocator.free(truncated_output);
    }

    // Determine pass/fail from exit code
    const status_text: []const u8 = if (result.exit_code == 0) "PASSED" else "FAILED";
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 run_tests() → {s} (exit {d})\n", .{ status_text, result.exit_code }),
        .result = try std.fmt.allocPrint(allocator, "Test results ({s}, exit code {d}):\n{s}", .{ status_text, result.exit_code, truncated_output }),
    };
}

fn formatFileSize(bytes: u64) struct { value: f64, unit: []const u8 } {
    if (bytes < 1024) return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
    const kb: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) return .{ .value = kb, .unit = "KB" };
    const mb: f64 = kb / 1024.0;
    if (mb < 1024.0) return .{ .value = mb, .unit = "MB" };
    const gb: f64 = mb / 1024.0;
    return .{ .value = gb, .unit = "GB" };
}

fn executeListDirectoryTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const ListDirArgs = struct {
        path: ?[]const u8 = null,
        show_hidden: bool = false,
    };

    var parsed = try std.json.parseFromSlice(ListDirArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const dir_path = parsed.value.path orelse ".";
    const show_hidden = parsed.value.show_hidden;

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var entries = array_list_compat.ArrayList([]const u8).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

        const type_str: []const u8 = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "other",
        };

        var size_str: []const u8 = "";
        if (entry.kind == .file) {
            if (dir.statFile(entry.name)) |stat| {
                const fmt = formatFileSize(stat.size);
                const tmp = try std.fmt.allocPrint(allocator, ", {d:.1}{s}", .{ fmt.value, fmt.unit });
                size_str = tmp;
            } else |_| {}
        }
        defer if (size_str.len > 0) allocator.free(size_str);

        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        const line = try std.fmt.allocPrint(allocator, "{s}{s} ({s}{s})", .{ entry.name, suffix, type_str, size_str });
        try entries.append(line);
    }

    // Sort entries alphabetically
    std.sort.insertion([]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var result_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer result_buf.deinit();
    const writer = result_buf.writer();

    try writer.print("Directory listing: {s} ({d} entries)\n", .{ dir_path, entries.items.len });
    for (entries.items) |entry_line| {
        try writer.print("  {s}\n", .{entry_line});
    }

    const result_str = try result_buf.toOwnedSlice();
    const truncated = try truncateToolOutput(allocator, result_str);
    defer {
        if (truncated.ptr != result_str.ptr) allocator.free(truncated);
        allocator.free(result_str);
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 list_directory(\"{s}\") → {d} entries\n", .{ dir_path, entries.items.len }),
        .result = if (truncated.ptr == result_str.ptr) try allocator.dupe(u8, truncated) else truncated,
    };
}

fn executeCreateFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const CreateFileArgs = struct {
        path: []const u8,
        content: []const u8 = "",
    };

    var parsed = try std.json.parseFromSlice(CreateFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "create_file", "create_file requires a 'path' parameter.", parsed.value.path)) |r| return r;

    // Check if file already exists
    if (std.fs.cwd().openFile(parsed.value.path, .{})) |_| {
        return buildValidationError(allocator, "create_file", "File already exists. Use write_file to overwrite.");
    } else |_| {}

    // Create parent directories if needed
    if (std.fs.path.dirname(parsed.value.path)) |dir_part| {
        if (dir_part.len > 0) {
            std.fs.cwd().makePath(dir_part) catch {};
        }
    }

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();
    if (parsed.value.content.len > 0) {
        try file.writeAll(parsed.value.content);
    }

    // Invalidate cache after create
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.path);
    }

    const content_len = parsed.value.content.len;
    const result_msg = if (content_len > 0)
        try std.fmt.allocPrint(allocator, "Created file: {s} ({d} bytes)", .{ parsed.value.path, content_len })
    else
        try std.fmt.allocPrint(allocator, "Created file: {s}", .{parsed.value.path});
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 create_file(\"{s}\")\n", .{parsed.value.path}),
        .result = result_msg,
    };
}

fn executeMoveFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const MoveFileArgs = struct {
        source: []const u8,
        destination: []const u8,
    };

    var parsed = try std.json.parseFromSlice(MoveFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "move_file", "move_file requires a 'source' parameter.", parsed.value.source)) |r| return r;
    if (try requireField(allocator, "move_file", "move_file requires a 'destination' parameter.", parsed.value.destination)) |r| return r;

    // Create parent directories for destination if needed
    if (std.fs.path.dirname(parsed.value.destination)) |dir_part| {
        if (dir_part.len > 0) {
            std.fs.cwd().makePath(dir_part) catch {};
        }
    }

    // Checkpoint: snapshot source file before moving (enables /rewind)
    checkpointBeforeWrite(parsed.value.source, "move_file");

    // Try atomic rename first (same filesystem)
    std.fs.cwd().rename(parsed.value.source, parsed.value.destination) catch {
        // Fallback: copy + delete for cross-device moves
        const src_file = try std.fs.cwd().openFile(parsed.value.source, .{});
        defer src_file.close();
        const src_stat = try src_file.stat();

        const content = try src_file.readToEndAlloc(allocator, src_stat.size);
        defer allocator.free(content);

        const dst_file = try std.fs.cwd().createFile(parsed.value.destination, .{});
        defer dst_file.close();
        try dst_file.writeAll(content);

        try std.fs.cwd().deleteFile(parsed.value.source);
    };

    // Invalidate cache
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.source);
        tracker.invalidate(parsed.value.destination);
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 move_file(\"{s}\" → \"{s}\")\n", .{ parsed.value.source, parsed.value.destination }),
        .result = try std.fmt.allocPrint(allocator, "Moved {s} → {s}", .{ parsed.value.source, parsed.value.destination }),
    };
}

fn executeCopyFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const CopyFileArgs = struct {
        source: []const u8,
        destination: []const u8,
    };

    var parsed = try std.json.parseFromSlice(CopyFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "copy_file", "copy_file requires a 'source' parameter.", parsed.value.source)) |r| return r;
    if (try requireField(allocator, "copy_file", "copy_file requires a 'destination' parameter.", parsed.value.destination)) |r| return r;

    const src_file = try std.fs.cwd().openFile(parsed.value.source, .{});
    defer src_file.close();
    const src_stat = try src_file.stat();

    if (src_stat.kind != .file) {
        return buildValidationError(allocator, "copy_file", "Source is not a regular file. Only files can be copied.");
    }

    const content = try src_file.readToEndAlloc(allocator, src_stat.size);
    defer allocator.free(content);

    // Create parent directories for destination if needed
    if (std.fs.path.dirname(parsed.value.destination)) |dir_part| {
        if (dir_part.len > 0) {
            std.fs.cwd().makePath(dir_part) catch {};
        }
    }

    const dst_file = try std.fs.cwd().createFile(parsed.value.destination, .{});
    defer dst_file.close();
    try dst_file.writeAll(content);

    // Invalidate cache
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.destination);
    }

    const fmt = formatFileSize(src_stat.size);
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 copy_file(\"{s}\" → \"{s}\") → {d:.1}{s}\n", .{ parsed.value.source, parsed.value.destination, fmt.value, fmt.unit }),
        .result = try std.fmt.allocPrint(allocator, "Copied {s} → {s} ({d} bytes)", .{ parsed.value.source, parsed.value.destination, src_stat.size }),
    };
}

fn executeDeleteFileTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const DeleteFileArgs = struct {
        path: []const u8,
    };

    var parsed = try std.json.parseFromSlice(DeleteFileArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "delete_file", "delete_file requires a 'path' parameter.", parsed.value.path)) |r| return r;

    // Safety: block paths containing wildcard or parent traversal
    if (std.mem.indexOf(u8, parsed.value.path, "*") != null) {
        return buildValidationError(allocator, "delete_file", "Wildcard paths are not allowed for deletion. Specify an exact file path.");
    }
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) {
        return buildValidationError(allocator, "delete_file", "Parent directory traversal (..) is not allowed in delete paths.");
    }
    if (parsed.value.path.len > 0 and parsed.value.path[0] == '/') {
        return buildValidationError(allocator, "delete_file", "Absolute paths are not allowed for deletion. Use a relative path.");
    }

    // Check it's a file (not a directory) and get size
    const stat = std.fs.cwd().statFile(parsed.value.path) catch |err| {
        return buildValidationError(allocator, "delete_file", switch (err) {
            error.FileNotFound => "File not found.",
            error.IsDir => "Path is a directory. Directory deletion is not supported for safety. Use shell with caution.",
            else => "Cannot access file.",
        });
    };

    if (stat.kind == .directory) {
        return buildValidationError(allocator, "delete_file", "Directory deletion is not supported for safety. Use shell with caution.");
    }

    // Safety: block files larger than 1MB
    if (stat.size > 1024 * 1024) {
        const msg = try std.fmt.allocPrint(allocator, "File is too large to delete safely ({d} bytes > 1MB). Use shell for large file cleanup.", .{stat.size});
        defer allocator.free(msg);
        return buildValidationError(allocator, "delete_file", msg);
    }

    // Checkpoint: snapshot file content before deleting (enables /rewind)
    checkpointBeforeWrite(parsed.value.path, "delete_file");

    try std.fs.cwd().deleteFile(parsed.value.path);

    // Invalidate cache
    if (active_file_tracker) |tracker| {
        tracker.invalidate(parsed.value.path);
    }

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 delete_file(\"{s}\")\n", .{parsed.value.path}),
        .result = try std.fmt.allocPrint(allocator, "Deleted: {s}", .{parsed.value.path}),
    };
}

fn executeFileInfoTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const FileInfoArgs = struct {
        path: []const u8,
    };

    var parsed = try std.json.parseFromSlice(FileInfoArgs, allocator, tool_call.arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (try requireField(allocator, "file_info", "file_info requires a 'path' parameter.", parsed.value.path)) |r| return r;

    const stat = try std.fs.cwd().statFile(parsed.value.path);

    const type_str: []const u8 = switch (stat.kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "unknown",
    };

    const fmt = formatFileSize(stat.size);

    // Convert modified timestamp to epoch seconds
    const mtime_sec = @divTrunc(stat.mtime, std.time.ns_per_s);
    const mtime_epoch: u64 = if (mtime_sec >= 0) @intCast(mtime_sec) else 0;

    // Format time as YYYY-MM-DD HH:MM:SS using a simple calculation
    const days_since_epoch: u64 = mtime_epoch / 86400;
    const time_of_day: u64 = mtime_epoch % 86400;
    const hours: u64 = time_of_day / 3600;
    const minutes: u64 = (time_of_day % 3600) / 60;
    const seconds: u64 = time_of_day % 60;

    // Calculate year/month/day from days since epoch
    var year: u64 = 1970;
    var remaining_days = days_since_epoch;
    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }
    const month_days = [_]u64{ 31, if (isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u64 = 0;
    for (month_days) |days_in_month| {
        if (remaining_days < days_in_month) break;
        remaining_days -= days_in_month;
        month += 1;
    }
    const day: u64 = remaining_days + 1;
    month += 1; // 1-indexed

    // Permissions — extracted from mode bits
    const mode_bits: u32 = @intCast(stat.mode);
    var perm_buf: [10]u8 = undefined;
    perm_buf[0] = if (stat.kind == .directory) 'd' else '-';
    perm_buf[1] = if ((mode_bits & 0o400) != 0) 'r' else '-';
    perm_buf[2] = if ((mode_bits & 0o200) != 0) 'w' else '-';
    perm_buf[3] = if ((mode_bits & 0o100) != 0) 'x' else '-';
    perm_buf[4] = if ((mode_bits & 0o040) != 0) 'r' else '-';
    perm_buf[5] = if ((mode_bits & 0o020) != 0) 'w' else '-';
    perm_buf[6] = if ((mode_bits & 0o010) != 0) 'x' else '-';
    perm_buf[7] = if ((mode_bits & 0o004) != 0) 'r' else '-';
    perm_buf[8] = if ((mode_bits & 0o002) != 0) 'w' else '-';
    perm_buf[9] = if ((mode_bits & 0o001) != 0) 'x' else '-';

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 file_info(\"{s}\")\n", .{parsed.value.path}),
        .result = try std.fmt.allocPrint(allocator, "File: {s}\nSize: {d} bytes ({d:.1}{s})\nType: {s}\nModified: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\nPermissions: {s}", .{
            parsed.value.path,
            stat.size,
            fmt.value,
            fmt.unit,
            type_str,
            year,
            month,
            day,
            hours,
            minutes,
            seconds,
            perm_buf[0..],
        }),
    };
}

fn isLeapYear(year: u64) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

const countLines = string_utils.countLines;

const extractJsonStringField = json_helpers.extractJsonStringField;

fn executeEditBatchTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const preview = edit_batch_mod.previewBatchEdit(allocator, tool_call.arguments) catch |err|
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 edit_batch → validation error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Validation failed: {s}", .{@errorName(err)}),
        };

    const result = edit_batch_mod.applyBatchEdit(allocator, tool_call.arguments) catch |err| {
        allocator.free(preview);
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 edit_batch → error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}),
        };
    };

    if (result.success) {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 edit_batch → {d} edits applied\n", .{result.applied_edits}),
            .result = preview,
        };
    } else {
        allocator.free(preview);
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 edit_batch → failed at edit {d} (rolled back)\n", .{result.failed_edit_index orelse 0}),
            .result = result.error_message orelse "Unknown error",
        };
    }
}

fn executeWebFetchTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const args = tool_call.arguments;

    // Parse URL from arguments — try "url" field first, then "path"
    const url = blk: {
        if (extractJsonStringField(args, "url")) |u| break :blk u;
        if (extractJsonStringField(args, "path")) |p| break :blk p;
        return buildValidationError(allocator, "web_fetch", "Missing 'url' parameter. Usage: {\"url\": \"https://...\"}");
    };

    out("\n\x1b[36m🌐 Fetching:\x1b[0m {s}\n", .{url});

    const result = web_fetch_mod.fetchUrl(allocator, url) catch |err| {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🌐 web_fetch → error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Failed to fetch URL: {s}", .{@errorName(err)}),
        };
    };

    const truncated = truncateToolOutput(allocator, result.body) catch result.body;

    return .{
        .display = try std.fmt.allocPrint(allocator, "🌐 web_fetch → {s} ({d} bytes)\n", .{url, result.body.len}),
        .result = try std.fmt.allocPrint(allocator, "URL: {s}\nStatus: {d}\nContent-Type: {s}\n\n{s}", .{ result.url, result.status_code, result.content_type, truncated }),
    };
}

fn executeWebSearchTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const args = tool_call.arguments;

    const query = extractJsonStringField(args, "query") orelse
        return buildValidationError(allocator, "web_search", "Missing 'query' parameter. Usage: {\"query\": \"search terms\", \"max_results\": 5}");

    const max_results: usize = blk: {
        if (extractJsonStringField(args, "max_results")) |mr| {
            break :blk std.fmt.parseInt(usize, mr, 10) catch 5;
        }
        break :blk 5;
    };

    out("\n\x1b[36m🔍 Searching:\x1b[0m {s}\n", .{query});

    const response = web_search_mod.searchWeb(allocator, query, max_results) catch |err| {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔍 web_search → error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Search failed: {s}", .{@errorName(err)}),
        };
    };
    defer response.deinit(allocator);

    const formatted = web_search_mod.formatResults(allocator, &response) catch "Search completed but formatting failed";
    const truncated = truncateToolOutput(allocator, formatted) catch formatted;

    return .{
        .display = try std.fmt.allocPrint(allocator, "🔍 web_search → {d} results for: {s}\n", .{response.results.len, query}),
        .result = truncated,
    };
}

fn executeImageDisplayTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const args = tool_call.arguments;
    const file_path = extractJsonStringField(args, "file_path") orelse
        return buildValidationError(allocator, "image_display", "Missing 'file_path' parameter. Usage: {\"file_path\": \"/path/to/image.png\"}");

    out("\n\x1b[36m🖼 Loading image:\x1b[0m {s}\n", .{file_path});

    const info = image_display_mod.loadImageInfo(allocator, file_path) catch |err| {
        return .{
            .display = try std.fmt.allocPrint(allocator, "🖼 image_display → error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Failed to load image: {s}", .{@errorName(err)}),
        };
    };
    defer info.deinit(allocator);

    const formatted = try image_display_mod.formatImageInfo(allocator, &info);

    return .{
        .display = try std.fmt.allocPrint(allocator, "🖼 image_display → {s} ({s} {d}x{d})\n", .{ file_path, info.format, info.width, info.height }),
        .result = formatted,
    };
}

/// Generic LSP tool executor — eliminates 6 identical per-tool wrappers.
/// The comptime `tool_name` is concatenated into format strings at compile time
/// via Zig's `++` operator; `executor_fn` is monomorphised per call site.
fn executeLspTool(
    allocator: std.mem.Allocator,
    tool_call: core.ParsedToolCall,
    comptime tool_name: []const u8,
    comptime executor_fn: fn (std.mem.Allocator, []const u8) anyerror![]const u8,
) !ToolExecution {
    const result = executor_fn(allocator, tool_call.arguments) catch |err|
        return .{
            .display = try std.fmt.allocPrint(allocator, "🔧 " ++ tool_name ++ " → error: {s}\n", .{@errorName(err)}),
            .result = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}),
        };
    return .{
        .display = try std.fmt.allocPrint(allocator, "🔧 " ++ tool_name ++ " → success\n", .{}),
        .result = result,
    };
}

fn executeLspDefinitionTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_definition", lsp_tools_mod.executeDefinition);
}

fn executeLspReferencesTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_references", lsp_tools_mod.executeReferences);
}

fn executeLspDiagnosticsTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_diagnostics", lsp_tools_mod.executeDiagnostics);
}

fn executeLspHoverTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_hover", lsp_tools_mod.executeHover);
}

fn executeLspSymbolsTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_symbols", lsp_tools_mod.executeSymbols);
}

fn executeLspRenameTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) anyerror!ToolExecution {
    return executeLspTool(allocator, tool_call, "lsp_rename", lsp_tools_mod.executeRename);
}

fn executeTodoWriteTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const result = todo_mod.executeTodoWriteTool(allocator, tool_call) catch |err|
        return buildToolFailure(allocator, tool_call, err);
    return .{
        .display = result.display,
        .result = result.result,
    };
}

fn executeApplyPatchTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const result = apply_patch_mod.executeApplyPatchTool(allocator, tool_call) catch |err|
        return buildToolFailure(allocator, tool_call, err);
    return .{
        .display = result.display,
        .result = result.result,
    };
}

fn executeQuestionTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const result = question_mod.executeQuestionTool(allocator, tool_call) catch |err|
        return buildToolFailure(allocator, tool_call, err);
    return .{
        .display = result.display,
        .result = result.result,
    };
}

fn executeSubagentTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    const result = subagent_mod.executeSubagentTool(allocator, tool_call.arguments) catch |err|
        return buildToolFailure(allocator, tool_call, err);
    return .{
        .display = result.display,
        .result = result.result,
    };
}

pub fn executeBuiltinTool(allocator: std.mem.Allocator, tool_call: core.ParsedToolCall) !ToolExecution {
    // Guard: empty arguments would cause a confusing JSON parse error downstream;
    // return a descriptive validation error instead.
    if (tool_call.arguments.len == 0) {
        return buildValidationError(allocator, tool_call.name, "Tool call requires non-empty arguments JSON.");
    }

    const dispatch = [_]BuiltinDispatchEntry{
        .{ .name = "read_file", .executor = executeReadFileTool },
        .{ .name = "shell", .executor = executeShellTool },
        .{ .name = "write_file", .executor = executeWriteFileTool },
        .{ .name = "glob", .executor = executeGlobTool },
        .{ .name = "grep", .executor = executeGrepTool },
        .{ .name = "edit", .executor = executeEditTool },
        .{ .name = "list_directory", .executor = executeListDirectoryTool },
        .{ .name = "create_file", .executor = executeCreateFileTool },
        .{ .name = "move_file", .executor = executeMoveFileTool },
        .{ .name = "copy_file", .executor = executeCopyFileTool },
        .{ .name = "delete_file", .executor = executeDeleteFileTool },
        .{ .name = "file_info", .executor = executeFileInfoTool },
        .{ .name = "git_status", .executor = executeGitStatusTool },
        .{ .name = "git_diff", .executor = executeGitDiffTool },
        .{ .name = "git_log", .executor = executeGitLogTool },
        .{ .name = "search_files", .executor = executeSearchFilesTool },
        .{ .name = "web_fetch", .executor = executeWebFetchTool },
        .{ .name = "web_search", .executor = executeWebSearchTool },
        .{ .name = "image_display", .executor = executeImageDisplayTool },
        .{ .name = "edit_batch", .executor = executeEditBatchTool },
        .{ .name = "lsp_definition", .executor = executeLspDefinitionTool },
        .{ .name = "lsp_references", .executor = executeLspReferencesTool },
        .{ .name = "lsp_diagnostics", .executor = executeLspDiagnosticsTool },
        .{ .name = "lsp_hover", .executor = executeLspHoverTool },
        .{ .name = "lsp_symbols", .executor = executeLspSymbolsTool },
        .{ .name = "lsp_rename", .executor = executeLspRenameTool },
        .{ .name = "todo_write", .executor = executeTodoWriteTool },
        .{ .name = "apply_patch", .executor = executeApplyPatchTool },
        .{ .name = "question", .executor = executeQuestionTool },
        .{ .name = "subagent", .executor = executeSubagentTool },
    };

    for (dispatch) |entry| {
        if (std.mem.eql(u8, tool_call.name, entry.name)) {
            return entry.executor(allocator, tool_call);
        }
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

test "executeBuiltinTool - grep finds pattern in file" {
    const tmp_path = "/tmp/crushcode_test_grep_42.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello zig world\nfoo bar baz\nzig is great");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\": \"zig\", \"path\": \"{s}\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-10",
        .name = "grep",
        .arguments = args,
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Found") != null);
}

test "executeBuiltinTool - grep no matches returns empty" {
    const tmp_path = "/tmp/crushcode_test_grep_nomatch.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello world\nfoo bar");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\": \"zzzz_nonexistent_pattern_xyz\", \"path\": \"{s}\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-11",
        .name = "grep",
        .arguments = args,
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Found 0") != null);
}

test "executeBuiltinTool - search_files finds pattern" {
    const tmp_path = "/tmp/crushcode_test_search_unique_77.zig";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("const foo = 42;");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\": \"crushcode_test_search_unique_77.zig\", \"directory\": \"/tmp\"}}", .{});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-12",
        .name = "search_files",
        .arguments = args,
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "crushcode_test_search_unique_77.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "Found 1") != null);
}

test "executeBuiltinTool - git_status returns output" {
    const tool_call = core.ParsedToolCall{
        .id = "te-13",
        .name = "git_status",
        .arguments = "{}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    // Should contain "git_status" in display or "clean"/"Working tree" in result
    const has_display = std.mem.indexOf(u8, execution.display, "git_status") != null;
    const has_result = std.mem.indexOf(u8, execution.result, "clean") != null or
        std.mem.indexOf(u8, execution.result, "Working tree") != null or
        execution.result.len > 0;
    try std.testing.expect(has_display or has_result);
}

test "executeBuiltinTool - git_log returns output" {
    const tool_call = core.ParsedToolCall{
        .id = "te-14",
        .name = "git_log",
        .arguments = "{\"count\": 3}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.display, "git_log") != null);
    // Result should contain commit info (hash) or be non-empty
    try std.testing.expect(execution.result.len > 0);
}

test "executeBuiltinTool - git_diff returns output" {
    const tool_call = core.ParsedToolCall{
        .id = "te-15",
        .name = "git_diff",
        .arguments = "{}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.display, "git_diff") != null);
    // Result is either "No changes" or actual diff content
    try std.testing.expect(execution.result.len > 0);
}

test "executeBuiltinTool - shell captures stderr" {
    const tool_call = core.ParsedToolCall{
        .id = "te-16",
        .name = "shell",
        .arguments = "{\"command\": \"echo ok_stdout_42 && echo err_stderr_77 >&2\"}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "ok_stdout_42") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "err_stderr_77") != null);
}

test "executeBuiltinTool - list_directory lists files" {
    const tool_call = core.ParsedToolCall{
        .id = "te-17",
        .name = "list_directory",
        .arguments = "{\"path\": \"/tmp\"}",
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.display, "list_directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.display, "entries") != null);
    try std.testing.expect(execution.result.len > 0);
}

test "executeBuiltinTool - create_file and delete_file" {
    // Use relative path since delete_file rejects absolute paths
    const rel_path = "crushcode_test_create_del_88.txt";
    // Clean up in case file exists from a prior run
    std.fs.cwd().deleteFile(rel_path) catch {};
    defer std.fs.cwd().deleteFile(rel_path) catch {};

    // Create
    const create_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\", \"content\": \"test content abc\"}}", .{rel_path});
    defer std.testing.allocator.free(create_args);

    const create_call = core.ParsedToolCall{
        .id = "te-18a",
        .name = "create_file",
        .arguments = create_args,
    };
    const create_exec = try executeBuiltinTool(std.testing.allocator, create_call);
    defer std.testing.allocator.free(create_exec.display);
    defer std.testing.allocator.free(create_exec.result);
    try std.testing.expect(std.mem.indexOf(u8, create_exec.result, "Created file") != null);

    // Verify file exists
    const verify = try std.fs.cwd().openFile(rel_path, .{});
    verify.close();

    // Delete
    const delete_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\"}}", .{rel_path});
    defer std.testing.allocator.free(delete_args);

    const delete_call = core.ParsedToolCall{
        .id = "te-18b",
        .name = "delete_file",
        .arguments = delete_args,
    };
    const delete_exec = try executeBuiltinTool(std.testing.allocator, delete_call);
    defer std.testing.allocator.free(delete_exec.display);
    defer std.testing.allocator.free(delete_exec.result);
    try std.testing.expect(std.mem.indexOf(u8, delete_exec.result, "Deleted") != null);

    // Verify file is gone
    const gone = std.fs.cwd().openFile(rel_path, .{});
    try std.testing.expectError(error.FileNotFound, gone);
}

test "executeBuiltinTool - file_info returns file details" {
    const tmp_path = "/tmp/crushcode_test_fileinfo_99.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello file info test");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "te-19",
        .name = "file_info",
        .arguments = args,
    };
    const execution = try executeBuiltinTool(std.testing.allocator, tool_call);
    defer std.testing.allocator.free(execution.display);
    defer std.testing.allocator.free(execution.result);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "file") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.result, "bytes") != null or
        std.mem.indexOf(u8, execution.result, "B") != null);
}
