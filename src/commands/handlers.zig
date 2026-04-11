const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const chat_mod = @import("chat");
const read_mod = @import("read");
const shell_mod = @import("shell");
const write_mod = @import("write");
const git_mod = @import("git");
const skills_mod = @import("skills");
const tui_mod = @import("tui");
const install_mod = @import("install");
const jobs_mod = @import("jobs");
const skills_loader_mod = @import("skills_loader");
const tools_mod = @import("tools");

const Config = config_mod.Config;

pub fn handleChat(args: args_mod.Args, config: *Config) !void {
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

pub fn handleTUI(_: args_mod.Args) !void {
    try tui_mod.runInteractive();
}

pub fn handleInstall(args: args_mod.Args) !void {
    try install_mod.handleInstall(args.remaining);
}

pub fn handleJobs(args: args_mod.Args) !void {
    try jobs_mod.handleJobs(args.remaining);
}

pub fn handleSkillsLoad(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var loader = skills_loader_mod.SkillLoader.init(allocator);
    defer loader.deinit();

    // Default skills directory
    const skills_dir = if (args.remaining.len > 0)
        args.remaining[0]
    else
        "skills";

    loader.loadFromDirectory(skills_dir) catch |err| {
        std.debug.print("Error loading skills from '{s}': {}\n", .{ skills_dir, err });
        return;
    };

    const skills = loader.getSkills();

    if (skills.len == 0) {
        std.debug.print("No skills found in '{s}'\n", .{skills_dir});
        std.debug.print("Create SKILL.md files in subdirectories.\n", .{});
        return;
    }

    std.debug.print("Loaded {} skills from '{s}':\n\n", .{ skills.len, skills_dir });

    for (skills) |skill| {
        std.debug.print("  {s}", .{skill.name});
        if (skill.description.len > 0) {
            std.debug.print(" - {s}", .{skill.description});
        }
        std.debug.print("\n", .{});

        if (skill.triggers.len > 0) {
            std.debug.print("    Triggers: ", .{});
            for (skill.triggers, 0..) |trigger, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{trigger});
            }
            std.debug.print("\n", .{});
        }

        if (skill.tools.len > 0) {
            std.debug.print("    Tools: ", .{});
            for (skill.tools, 0..) |tool, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{tool});
            }
            std.debug.print("\n", .{});
        }
    }

    // Show XML preview
    std.debug.print("\n--- AI Prompt XML Preview ---\n", .{});
    const xml = loader.toPromptXml(allocator) catch |err| {
        std.debug.print("Error generating XML: {}\n", .{err});
        return;
    };
    defer allocator.free(xml);
    std.debug.print("{s}\n", .{xml});
}

pub fn handleTools(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var registry = tools_mod.ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerBuiltinTools();

    // Handle subcommands
    if (args.remaining.len > 0) {
        const subcmd = args.remaining[0];

        if (std.mem.eql(u8, subcmd, "enable") and args.remaining.len > 1) {
            registry.enable(args.remaining[1]);
            std.debug.print("Enabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "disable") and args.remaining.len > 1) {
            registry.disable(args.remaining[1]);
            std.debug.print("Disabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "check") and args.remaining.len > 1) {
            const tool_name = args.remaining[1];
            if (registry.isAvailable(tool_name)) {
                std.debug.print("Tool '{s}' is available ✓\n", .{tool_name});
            } else if (registry.get(tool_name) != null) {
                std.debug.print("Tool '{s}' is registered but disabled ✗\n", .{tool_name});
            } else {
                std.debug.print("Tool '{s}' not found\n", .{tool_name});
            }
            return;
        } else if (std.mem.eql(u8, subcmd, "category") and args.remaining.len > 1) {
            const cat_name = args.remaining[1];
            const category = parseCategory(cat_name) orelse {
                std.debug.print("Unknown category: {s}\n", .{cat_name});
                std.debug.print("Categories: file_ops, shell, git, network, ai, mcp, system, custom\n", .{});
                return;
            };
            const tools_in_cat = registry.getByCategory(allocator, category) catch return;
            defer allocator.free(tools_in_cat);
            std.debug.print("Tools in {s}:\n", .{cat_name});
            for (tools_in_cat) |t| {
                std.debug.print("  - {s}\n", .{t});
            }
            return;
        }
    }

    // Default: list all tools
    registry.printTools();
}

fn parseCategory(name: []const u8) ?tools_mod.Tool.ToolCategory {
    if (std.mem.eql(u8, name, "file_ops")) return .file_ops;
    if (std.mem.eql(u8, name, "shell")) return .shell;
    if (std.mem.eql(u8, name, "git")) return .git;
    if (std.mem.eql(u8, name, "network")) return .network;
    if (std.mem.eql(u8, name, "ai")) return .ai;
    if (std.mem.eql(u8, name, "mcp")) return .mcp;
    if (std.mem.eql(u8, name, "system")) return .system;
    if (std.mem.eql(u8, name, "custom")) return .custom;
    return null;
}

pub fn handleList(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var registry = registry_mod.ProviderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerAllProviders();

    if (args.remaining.len > 0) {
        const provider_name = args.remaining[0];
        if (std.mem.eql(u8, provider_name, "--providers") or std.mem.eql(u8, provider_name, "-p")) {
            try registry.printProviders();
        } else if (std.mem.eql(u8, provider_name, "--models") or std.mem.eql(u8, provider_name, "-m")) {
            if (args.remaining.len < 2) {
                std.debug.print("Error: Provider name required for --models\n\n", .{});
                try printHelp();
                return;
            }
            const provider = args.remaining[1];
            try registry.printModels(provider);
        } else {
            try registry.printModels(provider_name);
        }
    } else {
        try registry.printProviders();
        std.debug.print("\nTo see models for a provider:\n", .{});
        std.debug.print("  crushcode list <provider-name>\n", .{});
        std.debug.print("  crushcode list --models <provider-name>\n", .{});
    }
}

pub fn printHelp() !void {
    std.debug.print(
        \\Crushcode - AI Coding Assistant
        \\
        \\Usage:
        \\  crushcode [command] [options]
        \\
        \\Commands:
        \\  chat           Start interactive chat session
        \\  read <file>   Read file content
        \\  shell <cmd>   Execute shell command
        \\  write <path> <content>  Write content to file
        \\  edit <file>   Edit/create a file
        \\  git <subcmd>  Git operations (status, add, commit, push, pull, branch)
        \\  skill <name>  Run a skill command (echo, date, whoami, etc.)
        \\  skills-load [dir]  Load and list SKILL.md files (default: skills/)
        \\  tools         List, enable, disable, check tools
        \\  tui          Launch interactive terminal UI
        \\  install      Show installation instructions
        \\  jobs         Job control (background jobs)
        \\  list           List providers or models
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Options:
        \\  --provider <id>    Use specific AI provider
        \\  --model <id>       Use specific model
        \\  --config <path>    Use custom config file
        \\
        \\Examples:
        \\  crushcode chat
        \\  crushcode chat --provider openai --model gpt-4o
        \\  crushcode read src/main.zig
        \\  crushcode shell "ls -la"
        \\  crushcode write test.txt "Hello World"
        \\  crushcode list --provider openai
        \\
    , .{});
}

pub fn printVersion() !void {
    std.debug.print("Crushcode v0.1.0\n", .{});
}
