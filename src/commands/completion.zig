const std = @import("std");
const args_mod = @import("args");
const file_compat = @import("file_compat");

/// All registered command names for completion
const commands = [_][]const u8{
    "chat",       "read",         "shell",       "write",      "edit",
    "git",        "skill",        "skills-load", "fallback",   "parallel",
    "agents",     "tools",        "plugin",      "tui",        "install",
    "update",     "jobs",         "capabilities", "worktree",  "graph",
    "agent-loop", "workflow",     "phase-run",   "compact",    "scaffold",
    "knowledge",  "worker",       "team",        "hooks",      "bg",
    "memory",     "pipeline",     "think",       "skill-sync", "template",
    "skills",     "list",         "usage",       "connect",    "profile",
    "checkpoint", "diff",         "grep",        "lsp",        "mcp",
    "auth",       "logs",         "sessions",    "run",        "batch",
    "fetch-models", "help",       "version",     "preview",    "detect",
    "autopilot",  "crush",        "completion",
};

/// All supported AI provider names for --provider completion
const providers = [_][]const u8{
    "openai",     "anthropic",    "gemini",      "xai",
    "mistral",    "groq",         "deepseek",    "together",
    "azure",      "vertexai",     "bedrock",     "ollama",
    "lm_studio",  "llamacpp",     "openrouter",  "zai",
    "vercel_gateway", "opencode_zen", "opencode_go", "mock",
    "mock_perf",
};

/// Global flags for completion
const flags_list = [_][]const u8{
    "--provider",
    "--model",
    "--profile",
    "--config",
    "--interactive",
    "--tui",
    "--json",
    "--stream",
    "--color",
    "--help",
    "--version",
};

pub fn handleCompletion(args: args_mod.Args) !void {
    const stdout = file_compat.File.stdout();

    // Determine shell type from remaining args or $SHELL env var
    const shell = if (args.remaining.len > 0)
        args.remaining[0]
    else
        detectShell();

    if (shell == null) {
        stdout.writeAll("Usage: crushcode completion [bash|zsh|fish]\n") catch {};
        return;
    }

    const s = shell.?;

    if (std.mem.eql(u8, s, "bash")) {
        try generateBash(stdout);
    } else if (std.mem.eql(u8, s, "zsh")) {
        try generateZsh(stdout);
    } else if (std.mem.eql(u8, s, "fish")) {
        try generateFish(stdout);
    } else {
        const w = stdout.writer();
        w.print("Unsupported shell: {s}\nUsage: crushcode completion [bash|zsh|fish]\n", .{s}) catch {};
    }
}

/// Auto-detect shell from $SHELL environment variable
fn detectShell() ?[]const u8 {
    const shell_env = file_compat.getEnv("SHELL") orelse return null;

    // Extract basename from path like /bin/bash, /usr/bin/zsh, etc.
    var start: usize = shell_env.len;
    while (start > 0) {
        start -= 1;
        if (shell_env[start] == '/') {
            start += 1;
            break;
        }
    }
    if (start >= shell_env.len) return null;

    const basename = shell_env[start..];

    if (std.mem.eql(u8, basename, "bash")) return "bash";
    if (std.mem.eql(u8, basename, "zsh")) return "zsh";
    if (std.mem.eql(u8, basename, "fish")) return "fish";

    return null;
}

fn generateBash(stdout: file_compat.File) !void {
    const w = stdout.writer();

    try w.writeAll(
        \\#!/bin/bash
        \\# Bash completion for crushcode
        \\
        \\_crushcode() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    local commands="
    );

    for (commands, 0..) |cmd, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(cmd);
    }

    try w.writeAll(
        \\"
        \\
        \\    local flags="
    );

    for (flags_list, 0..) |flag, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(flag);
    }

    try w.writeAll(
        \\"
        \\
        \\    local providers="
    );

    for (providers, 0..) |prov, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(prov);
    }

    try w.writeAll(
        \\"
        \\
        \\    # Complete flags that take values
        \\    case $prev in
        \\        --provider)
        \\            COMPREPLY=($(compgen -W "$providers" -- "$cur"))
        \\            return
        \\            ;;
        \\        --model|--profile|--config|--color)
        \\            return
        \\            ;;
        \\    esac
        \\
        \\    # Complete flags
        \\    if [[ $cur == --* ]]; then
        \\        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
        \\        return
        \\    fi
        \\
        \\    # Complete commands (only if no command yet)
        \\    local has_command=0
        \\    for word in "${words[@]:1}"; do
        \\        if [[ "$word" != --* ]]; then
        \\            has_command=1
        \\            break
        \\        fi
        \\    done
        \\
        \\    if [[ $has_command -eq 0 ]]; then
        \\        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        \\    fi
        \\}
        \\
        \\complete -F _crushcode crushcode
        \\
    );
}

fn generateZsh(stdout: file_compat.File) !void {
    const w = stdout.writer();

    try w.writeAll(
        \\#compdef crushcode
        \\# Zsh completion for crushcode
        \\
        \\_crushcode() {
        \\    local -a commands
        \\    commands=(
    );

    for (commands) |cmd| {
        try w.print("        '{s}'\n", .{cmd});
    }

    try w.writeAll(
        \\    )
        \\
        \\    local -a providers
        \\    providers=(
    );

    for (providers) |prov| {
        try w.print("        '{s}'\n", .{prov});
    }

    try w.writeAll(
        \\    )
        \\
        \\    _arguments -C \
        \\        '1:command:->command' \
        \\        '*::arg:->args' \
        \\        '--provider[Specify AI provider]:provider:$providers' \
        \\        '--model[Specify model]:model:' \
        \\        '--profile[Use profile]:profile:' \
        \\        '--config[Config file path]:config:_files' \
        \\        '--interactive[Start interactive mode]' \
        \\        '--tui[Launch terminal UI]' \
        \\        '--json[Output JSON]' \
        \\        '--stream[Enable streaming]' \
        \\        '--color[Color mode]:color:(auto always never)' \
        \\        '--help[Show help]' \
        \\        '--version[Show version]'
        \\
        \\    case $state in
        \\        command)
        \\            _describe 'command' commands
        \\            ;;
        \\        args)
        \\            case $words[1] in
        \\                --provider)
        \\                    _describe 'provider' providers
        \\                    ;;
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\
        \\_crushcode "$@"
        \\
    );
}

fn generateFish(stdout: file_compat.File) !void {
    const w = stdout.writer();

    try w.writeAll(
        \\# Fish completion for crushcode
        \\
    );

    for (commands) |cmd| {
        try w.print("complete -c crushcode -n '__fish_use_subcommand' -a '{s}'\n", .{cmd});
    }

    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l provider -d 'Specify AI provider'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l model -d 'Specify model'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l profile -d 'Use profile'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l config -d 'Config file path' -r\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l interactive -d 'Start interactive mode'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l tui -d 'Launch terminal UI'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l json -d 'Output JSON'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l stream -d 'Enable streaming'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l color -d 'Color mode' -r\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l help -d 'Show help'\n");
    try w.writeAll("complete -c crushcode -n '__fish_use_subcommand' -l version -d 'Show version'\n");

    for (providers) |prov| {
        try w.print("complete -c crushcode -n '__fish_seen_subcommand_from --provider' -a '{s}'\n", .{prov});
    }

    try w.writeAll("\n");
}
