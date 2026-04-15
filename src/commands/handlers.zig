const std = @import("std");
const args_mod = @import("args");
const config_mod = @import("config");
const chat_mod = @import("chat");
const read_mod = @import("read");
const shell_mod = @import("shell");
const write_mod = @import("write");
const git_mod = @import("git");
const skills_mod = @import("skills");
const install_mod = @import("install");
const jobs_mod = @import("jobs");
const plugin_command = @import("plugin_command");
const lsp_handler = @import("lsp_handler");
const mcp_handler = @import("mcp_handler");
const ai_handlers = @import("ai_handlers");
const tool_handlers = @import("tool_handlers");
const system_handlers = @import("system_handlers");
const experimental_handlers = @import("experimental_handlers");
const auth_cmd_mod = @import("auth_cmd");
const file_compat = @import("file_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

const Config = config_mod.Config;

pub fn tryHandlePluginCommand(command: []const u8) !bool {
    const allocator = std.heap.page_allocator;

    const plugin_cmds = plugin_command.loadDefaultCommands(allocator) catch &[_]plugin_command.PluginCommand{};
    defer plugin_command.freeCommands(allocator, plugin_cmds);

    const user_cmds = plugin_command.loadUserCommands(allocator) catch &[_]plugin_command.PluginCommand{};
    defer plugin_command.freeCommands(allocator, user_cmds);

    if (plugin_command.findCommand(plugin_cmds, command)) |cmd| {
        plugin_command.executeCommand(allocator, cmd) catch |err| {
            stdout_print("Error executing plugin command '{s}': {}\n", .{ command, err });
        };
        return true;
    }

    if (plugin_command.findCommand(user_cmds, command)) |cmd| {
        plugin_command.executeCommand(allocator, cmd) catch |err| {
            stdout_print("Error executing plugin command '{s}': {}\n", .{ command, err });
        };
        return true;
    }

    return false;
}

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
    if (args.tui) {
        try ai_handlers.handleTUI(args, config);
        return;
    }
    try chat_mod.handleChat(args, config);
}

pub fn handleRead(args: args_mod.Args) !void {
    try read_mod.handleRead(args.remaining);
}

pub fn handleShell(args: args_mod.Args) !void {
    try shell_mod.handleShell(args.remaining);
}

pub fn handleWrite(args: args_mod.Args) !void {
    try write_mod.handleWrite(args.remaining);
}

pub fn handleEdit(args: args_mod.Args) !void {
    try write_mod.handleEdit(args.remaining);
}

pub fn handleGit(args: args_mod.Args) !void {
    try git_mod.handleGit(args.remaining);
}

pub fn handleSkill(args: args_mod.Args) !void {
    try skills_mod.handleSkill(args.remaining);
}

pub fn handleInstall(args: args_mod.Args) !void {
    try install_mod.handleInstall(args.remaining);
}

pub fn handleJobs(args: args_mod.Args) !void {
    try jobs_mod.handleJobs(args.remaining);
}

pub fn handleLSP(args: args_mod.Args) !void {
    try lsp_handler.handleLSP(args);
}

pub fn handleMCP(args: args_mod.Args) !void {
    try mcp_handler.handleMCP(args);
}

pub const handleTUI = ai_handlers.handleTUI;
pub const handleFallback = ai_handlers.handleFallback;
pub const handleParallel = ai_handlers.handleParallel;
pub const handleAgents = ai_handlers.handleAgents;
pub const handleConnect = ai_handlers.handleConnect;
pub const handleFetchModels = ai_handlers.handleFetchModels;

pub const handleCapabilities = tool_handlers.handleCapabilities;
pub const handlePlugin = tool_handlers.handlePlugin;
pub const handleSkillsLoad = tool_handlers.handleSkillsLoad;
pub const handleTools = tool_handlers.handleTools;
pub const handleGrep = tool_handlers.handleGrep;

pub const handleList = system_handlers.handleList;
pub const handleCheckpoint = system_handlers.handleCheckpoint;
pub const handleUsage = system_handlers.handleUsage;
pub const handleProfile = system_handlers.handleProfile;
pub const handleWorktree = system_handlers.handleWorktree;
pub const handleDiff = system_handlers.handleDiff;

pub const handleGraph = experimental_handlers.handleGraph;
pub const handleAgentLoop = experimental_handlers.handleAgentLoop;
pub const handleWorkflow = experimental_handlers.handleWorkflow;
pub const handleCompact = experimental_handlers.handleCompact;
pub const handleScaffold = experimental_handlers.handleScaffold;

pub fn handleAuth(args: args_mod.Args) !void {
    try auth_cmd_mod.handleAuth(args.remaining);
}

pub fn printHelp() !void {
    stdout_print(
        \\Crushcode - AI Coding Assistant
        \\
        \\Usage:
        \\  crushcode [command] [options]
        \\
        \\Commands:
        \\  chat           Start interactive chat session (streaming)
        \\  read <file>   Read file content
        \\  shell <cmd>   Execute shell command
        \\  write <path> <content>  Write content to file
        \\  edit <file>   Edit/create a file
        \\  git <subcmd>  Git operations (status, add, commit, push, pull, branch)
        \\  skill <name>  Run a skill command (echo, date, whoami, etc.)
        \\  skills-load [dir]  Load and list SKILL.md files (default: skills/)
        \\  parallel      Show parallel executor status
        \\  agents       Spawn multiple AI agents in parallel
        \\  tools         List, enable, disable, check tools
        \\  tui          Launch interactive terminal UI
        \\  install      Show installation instructions
        \\  jobs         Job control (background jobs)
        \\  capabilities   List registered tools, plugins, and skills
        \\  worktree      Show worktree manager status
        \\  graph          Analyze codebase with knowledge graph
        \\  agent-loop     Show agent loop engine status
        \\  workflow       Show phase workflow progress
        \\  compact        Show context compaction status
        \\  scaffold       Generate project scaffolding
        \\  list           List providers or models
        \\  usage         Show token usage and cost tracking
        \\  connect        Add API credentials for providers
        \\  checkpoint    List, restore, or delete checkpoints
        \\  grep           AST-grep pattern search
        \\  lsp            Language Server Protocol client
        \\  mcp            MCP tools management
        \\  auth           Manage authentication (login, status, logout)
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Chat Commands (in interactive mode):
        \\  /usage         Show session token usage
        \\  /clear         Clear conversation history
        \\  /hooks         Show registered lifecycle hooks
        \\  /checkpoint    Save checkpoint manually
        \\  /agents        Spawn agents for task
        \\  /thinking      Toggle streaming thinking display
        \\  /exit          Exit chat
        \\
        \\Agent Categories (--agents):
        \\  visual-engineering  UI/UX, frontend, design
        \\  ultrabrain         Hard logic, architecture
        \\  deep              Autonomous research + execution
        \\  quick             Single-file changes, typos
        \\  review            Code review and QA
        \\  research          Research and exploration
        \\  general           Default category
        \\Options:
        \\  --provider <id>    Use specific AI provider
        \\  --model <id>       Use specific model
        \\  --profile <name>   Use specific profile
        \\  --config <path>    Use custom config file
        \\  --json, -j         Output JSON Lines (machine-readable)
        \\  --color <mode>     Color output: auto, always, never
        \\  --checkpoint <id>  Restore from checkpoint
        \\  --restore <id>     Restore from checkpoint (alias)
        \\  --agents <cats>    Spawn agents with categories (comma-separated)
        \\  --max-agents <n>   Max concurrent agents (default: 5)
        \\  --memory <path>   Session memory/history file
        \\  --memory-limit <n>  Max messages to remember (default: 100)
        \\  --interactive, -i  Start interactive chat
        \\  --tui              Launch terminal UI
        \\  --stream, -s       Enable streaming output
        \\  --thinking, -t     Show streaming thinking output
        \\  --permission <mode> Permission mode: default, auto, plan, acceptEdits, dontAsk, bypassPermissions
        \\
        \\Examples:
        \\  crushcode chat
        \\  crushcode chat --provider openai --model gpt-4o
        \\  crushcode chat --profile work
        \\  crushcode chat --memory --memory-limit 50
        \\  crushcode agents --agents visual,deep,quick
        \\  crushcode agents --agents research,review --max-agents 3
        \\  crushcode read src/main.zig
        \\  crushcode shell "ls -la"
        \\  crushcode write test.txt "Hello World"
        \\  crushcode parallel
        \\  crushcode usage
        \\  crushcode worktree
        \\  crushcode list --provider openai
        \\  crushcode plugin list
        \\
    , .{});
}

pub fn printVersion() !void {
    stdout_print("Crushcode v0.5.0\n", .{});
}
