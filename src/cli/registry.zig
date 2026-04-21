const std = @import("std");
const args_mod = @import("args");
const config_mod = @import("config");
const handlers = @import("handlers");

/// Normalized handler signature — all commands use this.
/// Handlers that don't need config simply ignore the second parameter.
pub const HandlerFn = *const fn (args_mod.Args, *config_mod.Config) anyerror!void;

/// A registered command with name, handler, description, and aliases.
pub const Command = struct {
    name: []const u8,
    handler: HandlerFn,
    description: []const u8,
};

// --- Wrapper functions to normalize signatures ---

fn wrapArgsOnly(comptime handler: fn (args_mod.Args) anyerror!void) HandlerFn {
    return struct {
        fn call(args: args_mod.Args, _: *config_mod.Config) anyerror!void {
            return handler(args);
        }
    }.call;
}

fn wrapHelp(args: args_mod.Args, _: *config_mod.Config) anyerror!void {
    _ = args;
    try handlers.printHelp();
}

fn wrapVersion(args: args_mod.Args, _: *config_mod.Config) anyerror!void {
    _ = args;
    try handlers.printVersion();
}

// --- Command table (comptime) ---

const commands = [_]Command{
    .{ .name = "chat", .handler = handlers.handleChat, .description = "Start interactive chat session (streaming)" },
    .{ .name = "read", .handler = wrapArgsOnly(handlers.handleRead), .description = "Read file content" },
    .{ .name = "shell", .handler = wrapArgsOnly(handlers.handleShell), .description = "Execute shell command" },
    .{ .name = "write", .handler = wrapArgsOnly(handlers.handleWrite), .description = "Write content to file" },
    .{ .name = "edit", .handler = wrapArgsOnly(handlers.handleEdit), .description = "Edit/create a file" },
    .{ .name = "git", .handler = wrapArgsOnly(handlers.handleGit), .description = "Git operations" },
    .{ .name = "skill", .handler = wrapArgsOnly(handlers.handleSkill), .description = "Run a skill command" },
    .{ .name = "skills-load", .handler = wrapArgsOnly(handlers.handleSkillsLoad), .description = "Load SKILL.md files" },
    .{ .name = "fallback", .handler = wrapArgsOnly(handlers.handleFallback), .description = "Show fallback chain status" },
    .{ .name = "parallel", .handler = wrapArgsOnly(handlers.handleParallel), .description = "Show parallel executor status" },
    .{ .name = "agents", .handler = wrapArgsOnly(handlers.handleAgents), .description = "Spawn multiple AI agents" },
    .{ .name = "tools", .handler = wrapArgsOnly(handlers.handleTools), .description = "List, enable, disable tools" },
    .{ .name = "plugin", .handler = wrapArgsOnly(handlers.handlePlugin), .description = "Plugin management" },
    .{ .name = "tui", .handler = handlers.handleTUI, .description = "Launch terminal UI" },
    .{ .name = "install", .handler = wrapArgsOnly(handlers.handleInstall), .description = "Show installation instructions" },
    .{ .name = "update", .handler = wrapArgsOnly(handlers.handleUpdate), .description = "Check and install updates" },
    .{ .name = "jobs", .handler = wrapArgsOnly(handlers.handleJobs), .description = "Job control" },
    .{ .name = "capabilities", .handler = wrapArgsOnly(handlers.handleCapabilities), .description = "List registered capabilities" },
    .{ .name = "worktree", .handler = wrapArgsOnly(handlers.handleWorktree), .description = "Manage git worktrees (create, list, remove, cleanup)" },
    .{ .name = "graph", .handler = wrapArgsOnly(handlers.handleGraph), .description = "Analyze codebase with knowledge graph" },
    .{ .name = "agent-loop", .handler = wrapArgsOnly(handlers.handleAgentLoop), .description = "Show agent loop status" },
    .{ .name = "workflow", .handler = wrapArgsOnly(handlers.handleWorkflow), .description = "Show phase workflow progress" },
    .{ .name = "phase-run", .handler = wrapArgsOnly(handlers.handlePhaseRun), .description = "Run multi-phase workflow with adversarial gate checks" },
    .{ .name = "compact", .handler = wrapArgsOnly(handlers.handleCompact), .description = "Show compaction status" },
    .{ .name = "scaffold", .handler = wrapArgsOnly(handlers.handleScaffold), .description = "Project scaffolding — create projects with requirements and phases" },
    .{ .name = "knowledge", .handler = wrapArgsOnly(handlers.handleKnowledge), .description = "Knowledge operations (ingest/query/lint/status)" },
    .{ .name = "worker", .handler = wrapArgsOnly(handlers.handleWorker), .description = "Worker agent execution (run, results, list)" },
    .{ .name = "team", .handler = wrapArgsOnly(handlers.handleTeam), .description = "Multi-agent team coordination (spawn, status, message, list)" },
    .{ .name = "hooks", .handler = wrapArgsOnly(handlers.handleHooks), .description = "Hook execution engine (list, run, test, discover)" },
    .{ .name = "bg", .handler = wrapArgsOnly(handlers.handleBackground), .description = "Background agent scheduler (list, run, status, schedule, results)" },
    .{ .name = "memory", .handler = wrapArgsOnly(handlers.handleMemory), .description = "4-layer memory operations (layers, insights, distill, search, store, stats)" },
    .{ .name = "pipeline", .handler = wrapArgsOnly(handlers.handlePipeline), .description = "Multi-phase skill pipeline (run, status, list, templates, results)" },
    .{ .name = "think", .handler = wrapArgsOnly(handlers.handleThink), .description = "Adversarial thinking tools (challenge, emerge, connect, graduate, history)" },
    .{ .name = "skill-sync", .handler = wrapArgsOnly(handlers.handleSkillSyncCmd), .description = "Skill sync operations (status, import, export, list, validate, conflicts)" },
    .{ .name = "template", .handler = wrapArgsOnly(handlers.handleTemplate), .description = "Template marketplace (list, info, install, uninstall, search)" },
    .{ .name = "skills", .handler = wrapArgsOnly(handlers.handleSkillsResolve), .description = "Resolve/scan skills (resolve, scan)" },
    .{ .name = "list", .handler = wrapArgsOnly(handlers.handleList), .description = "List providers or models" },
    .{ .name = "usage", .handler = wrapArgsOnly(handlers.handleUsage), .description = "Show token usage and costs" },
    .{ .name = "connect", .handler = wrapArgsOnly(handlers.handleConnect), .description = "Add API credentials" },
    .{ .name = "profile", .handler = wrapArgsOnly(handlers.handleProfile), .description = "Manage profiles" },
    .{ .name = "checkpoint", .handler = wrapArgsOnly(handlers.handleCheckpoint), .description = "Manage checkpoints" },
    .{ .name = "diff", .handler = wrapArgsOnly(handlers.handleDiff), .description = "Compare two files" },
    .{ .name = "grep", .handler = wrapArgsOnly(handlers.handleGrep), .description = "AST-grep pattern search" },
    .{ .name = "lsp", .handler = wrapArgsOnly(handlers.handleLSP), .description = "Language Server Protocol client" },
    .{ .name = "mcp", .handler = wrapArgsOnly(handlers.handleMCP), .description = "MCP tools management" },
    .{ .name = "auth", .handler = wrapArgsOnly(handlers.handleAuth), .description = "Manage authentication" },
    .{ .name = "logs", .handler = wrapArgsOnly(handlers.handleLogs), .description = "View structured logs" },
    .{ .name = "sessions", .handler = wrapArgsOnly(handlers.handleSessions), .description = "Manage chat sessions (list, show, delete, clean)" },
    .{ .name = "run", .handler = handlers.handleRun, .description = "Non-interactive: send prompt, output response" },
    .{ .name = "batch", .handler = handlers.handleBatch, .description = "Process prompts from file in batch" },
    .{ .name = "fetch-models", .handler = handlers.handleFetchModels, .description = "Fetch live model list" },
    .{ .name = "help", .handler = wrapHelp, .description = "Show help message" },
    .{ .name = "--help", .handler = wrapHelp, .description = "Show help message" },
    .{ .name = "-h", .handler = wrapHelp, .description = "Show help message" },
    .{ .name = "version", .handler = wrapVersion, .description = "Show version information" },
    .{ .name = "--version", .handler = wrapVersion, .description = "Show version information" },
    .{ .name = "-v", .handler = wrapVersion, .description = "Show version information" },
    .{ .name = "preview", .handler = wrapArgsOnly(handlers.handlePreview), .description = "Preview file with line numbers, highlighting, and diff" },
    .{ .name = "detect", .handler = wrapArgsOnly(handlers.handleDetect), .description = "Detect file type using content analysis (magic bytes + patterns + extension)" },
    .{ .name = "autopilot", .handler = wrapArgsOnly(handlers.handleAutopilot), .description = "Autopilot agents — wire background agents to real work (run, list, status, schedule, run-all)" },
    .{ .name = "crush", .handler = wrapArgsOnly(handlers.handleCrush), .description = "Auto-agentic: plan → execute → verify → commit" },
    .{ .name = "skill-sync", .handler = wrapArgsOnly(handlers.handleSkillSyncCmd), .description = "Sync skills from marketplace" },
    .{ .name = "template", .handler = wrapArgsOnly(handlers.handleTemplate), .description = "Manage project templates" },
};

// --- Comptime string map for O(1) lookup ---

const CommandMap = std.StaticStringMap(Command);

const command_map: CommandMap = blk: {
    var entries: [commands.len]struct { []const u8, Command } = undefined;
    for (&entries, commands[0..]) |*entry, cmd| {
        entry.* = .{ cmd.name, cmd };
    }
    break :blk CommandMap.initComptime(entries);
};

/// Dispatch a command by name. Returns error.CommandNotFound if unknown.
pub fn dispatch(command: []const u8, args: args_mod.Args, config: *config_mod.Config) !void {
    const cmd = command_map.get(command) orelse return error.CommandNotFound;
    return cmd.handler(args, config);
}

/// Check if a command name is registered (including aliases).
pub fn contains(command: []const u8) bool {
    return command_map.get(command) != null;
}
