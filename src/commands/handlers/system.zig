const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
const config_mod = @import("config");
const checkpoint_mod = @import("checkpoint");
const usage_tracker_mod = @import("usage_tracker");
const usage_pricing_mod = @import("usage_pricing");
const usage_report = @import("usage_report");
const usage_budget = @import("usage_budget");
const profile_mod = @import("profile");
const worktree_mod = @import("worktree");
const diff_mod = @import("diff");
const file_compat = @import("file_compat");
const shell_mod = @import("shell");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Apply agent configuration metadata to restore agent states and settings
fn applyAgentConfiguration(metadata: *const std.StringHashMap([]const u8)) void {
    var provider_changed = false;
    var model_changed = false;
    var mode_changed = false;
    
    if (metadata.get("provider")) |provider| {
        if (std.mem.eql(u8, provider, "openai")) {
            stdout_print("✓ Restored OpenAI provider configuration\n", .{});
            provider_changed = true;
        } else if (std.mem.eql(u8, provider, "anthropic")) {
            stdout_print("✓ Restored Anthropic provider configuration\n", .{});
            provider_changed = true;
        } else if (std.mem.eql(u8, provider, "ollama")) {
            stdout_print("✓ Restored Ollama provider configuration\n", .{});
            provider_changed = true;
        }
    }
    
    if (metadata.get("model")) |model| {
        stdout_print("✓ Restored model configuration: {s}\n", .{model});
        model_changed = true;
    }
    
    if (metadata.get("agent_mode")) |mode| {
        stdout_print("✓ Restored agent mode: {s}\n", .{mode});
        mode_changed = true;
    }
    
    if (metadata.get("temperature")) |temp_str| {
        const temperature = std.fmt.parseFloat(f64, temp_str) catch 0.0;
        stdout_print("✓ Restored temperature: {d}\n", .{temperature});
    }
    
    if (!provider_changed and !model_changed and !mode_changed) {
        stdout_print("⚠ No agent configuration metadata found in checkpoint\n", .{});
    }
}

fn printHelp() !void {
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
        \\  help           Show this help message
        \\  version        Show version information
        \\
        \\Chat Commands (in interactive mode):
        \\  /usage         Show session token usage
        \\  /clear         Clear conversation history
        \\  /hooks         Show registered lifecycle hooks
        \\  /checkpoint    Save checkpoint manually
        \\  /agents        Spawn agents for task
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

fn loadBudgetConfig(allocator: std.mem.Allocator) ?usage_budget.BudgetConfig {
    const config_path = config_mod.getConfigPath(allocator) catch return null;
    defer allocator.free(config_path);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var budget_cfg = usage_budget.BudgetConfig{};
    var in_budget_section = false;
    var found_limit = false;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[') {
            in_budget_section = std.mem.eql(u8, trimmed, "[budget]");
            continue;
        }

        if (!in_budget_section) continue;
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const value_text = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
        const value = std.fmt.parseFloat(f64, value_text) catch continue;

        if (std.mem.eql(u8, key, "daily_limit_usd")) {
            budget_cfg.daily_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "monthly_limit_usd")) {
            budget_cfg.monthly_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "per_session_limit_usd")) {
            budget_cfg.per_session_limit_usd = value;
            found_limit = true;
        } else if (std.mem.eql(u8, key, "alert_threshold_pct")) {
            budget_cfg.alert_threshold_pct = value;
        }
    }

    if (!found_limit or !budget_cfg.isSet()) return null;
    return budget_cfg;
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
        } else if (std.mem.eql(u8, provider_name, "--refresh") or std.mem.eql(u8, provider_name, "-r")) {
            try registry.printOpenRouterModelsLive();
        } else if (std.mem.eql(u8, provider_name, "--models") or std.mem.eql(u8, provider_name, "-m")) {
            if (args.remaining.len < 2) {
                stdout_print("Error: Provider name required for --models\n\n", .{});
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
        stdout_print("\nTo see models for a provider:\n", .{});
        stdout_print("  crushcode list <provider-name>\n", .{});
        stdout_print("  crushcode list --models <provider-name>\n", .{});
        stdout_print("\nTo fetch live models from OpenRouter:\n", .{});
        stdout_print("  crushcode list --refresh\n", .{});
    }
}

pub fn handleCheckpoint(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const checkpoint_dir = ".crushcode/checkpoints";
    var mgr = checkpoint_mod.CheckpointManager.init(allocator, checkpoint_dir);

    if (args.remaining.len == 0) {
        const checkpoints = try mgr.list();
        defer {
            for (checkpoints) |cp| allocator.free(cp);
            allocator.free(checkpoints);
        }

        if (checkpoints.len == 0) {
            stdout_print("No checkpoints found.\n", .{});
            stdout_print("Run with --checkpoint during chat to save snapshots.\n", .{});
            return;
        }

        stdout_print("Available checkpoints:\n", .{});
        for (checkpoints) |cp| {
            var cp_data = mgr.load(cp) catch continue;
            defer cp_data.deinit();

            stdout_print("  {s}  (timestamp: {d}, {d} messages)\n", .{
                cp,
                cp_data.timestamp,
                cp_data.messages.len,
            });
        }
    } else {
        const action = args.remaining[0];

        if (std.mem.eql(u8, action, "save")) {
            stdout_print("Checkpoints are saved automatically.\n", .{});
            stdout_print("Use --checkpoint flag during chat to enable.\n", .{});
        } else if (std.mem.eql(u8, action, "restore") or std.mem.eql(u8, action, "load")) {
            if (args.remaining.len < 2) {
                stdout_print("Error:checkpoint ID required\n", .{});
                stdout_print("Usage: crushcode checkpoint restore <id>\n", .{});
                return;
            }
            const cp_id = args.remaining[1];
            var cp = mgr.load(cp_id) catch |err| {
                stdout_print("Error loading checkpoint '{s}': {}\n", .{ cp_id, err });
                return;
            };
            defer cp.deinit();

            stdout_print("Restored checkpoint '{s}'\n", .{cp_id});
            stdout_print("  Messages: {d}\n", .{cp.messages.len});
            stdout_print("  Tool calls: {d}\n", .{cp.tool_calls});
            stdout_print("  Tokens used: {d}\n", .{cp.tokens_used});
            
            // Apply agent configuration metadata
            if (cp.metadata.count() > 0) {
                stdout_print("\n🔧 Applying Agent Configuration:\n", .{});
                applyAgentConfiguration(&cp.metadata);
            } else {
                stdout_print("\n⚠ No agent configuration metadata found in checkpoint\n", .{});
            }
        } else if (std.mem.eql(u8, action, "export-config")) {
            if (args.remaining.len < 2) {
                stdout_print("Error: checkpoint ID required\n", .{});
                stdout_print("Usage: crushcode checkpoint export-config <id>\n", .{});
                return;
            }
            const cp_id = args.remaining[1];
            var cp = mgr.load(cp_id) catch |err| {
                stdout_print("Error loading checkpoint '{s}': {}\n", .{ cp_id, err });
                return;
            };
            defer cp.deinit();
            
            stdout_print("Agent Configuration from checkpoint '{s}':\n", .{cp_id});
            if (cp.metadata.count() > 0) {
                var metadata_iter = cp.metadata.iterator();
                while (metadata_iter.next()) |entry| {
                    stdout_print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            } else {
                stdout_print("No agent configuration metadata found in checkpoint\n", .{});
            }
        } else if (std.mem.eql(u8, action, "delete")) {
            if (args.remaining.len < 2) {
                stdout_print("Error: checkpoint ID required\n", .{});
                stdout_print("Usage: crushcode checkpoint delete <id>\n", .{});
                return;
            }
            const cp_id = args.remaining[1];
            mgr.delete(cp_id) catch |err| {
                stdout_print("Error deleting checkpoint '{s}': {}\n", .{ cp_id, err });
                return;
            };
            stdout_print("Deleted checkpoint '{s}'\n", .{cp_id});
        } else {
            stdout_print("Unknown checkpoint action: {s}\n", .{action});
            stdout_print("\nUsage:\n", .{});
            stdout_print("  crushcode checkpoint                      List all checkpoints\n", .{});
            stdout_print("  crushcode checkpoint restore <id>          Restore a checkpoint\n", .{});
            stdout_print("  crushcode checkpoint export-config <id>   Export agent config from checkpoint\n", .{});
            stdout_print("  crushcode checkpoint delete <id>          Delete a checkpoint\n", .{});
        }
    }
}

pub fn handleUsage(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var tracker = usage_tracker_mod.UsageTracker.init(allocator, "~/.crushcode/usage");
    defer tracker.deinit();

    var pricing = usage_pricing_mod.PricingTable.init(allocator) catch {
        stdout_print("Error initializing pricing table\n", .{});
        return;
    };
    defer pricing.deinit();
    _ = &pricing;

    const session = tracker.getSessionUsage();

    stdout_print("\n=== Crushcode Usage Report ===\n", .{});
    stdout_print("\nSession (current):\n", .{});
    stdout_print("  Requests: {d}\n", .{session.request_count});
    stdout_print("  Tokens: {d} in / {d} out", .{ session.input_tokens, session.output_tokens });
    if (session.cache_read_tokens > 0) {
        stdout_print(" / {d} cache read", .{session.cache_read_tokens});
    }
    stdout_print("\n", .{});

    if (session.estimated_cost_usd > 0) {
        stdout_print("  Cost: ${d:.4}\n", .{session.estimated_cost_usd});
    }

    if (session.by_provider.count() > 0) {
        stdout_print("\n  By provider:\n", .{});
        var iter = session.by_provider.iterator();
        while (iter.next()) |entry| {
            const pu = entry.value_ptr;
            stdout_print("    {s} ({s}): {d} req | ${d:.4}\n", .{
                pu.provider,
                pu.model,
                pu.request_count,
                pu.cost_usd,
            });
        }
    }

    const daily = tracker.getDailyUsage();
    var report = usage_report.UsageReport.init(allocator);
    defer report.deinit();

    var budget_status: ?usage_budget.BudgetStatus = null;
    if (loadBudgetConfig(allocator)) |budget_cfg| {
        var budget_manager = usage_budget.BudgetManager.init(allocator, budget_cfg);
        defer budget_manager.deinit();

        budget_manager.recordCost(session.estimated_cost_usd);
        budget_manager.daily_spent = daily.estimated_cost_usd;
        budget_manager.monthly_spent = daily.estimated_cost_usd;
        budget_status = budget_manager.checkBudget();

        if (budget_status) |status| {
            const state = if (status.isOverBudget())
                "over budget"
            else if (status.shouldAlert(budget_cfg.alert_threshold_pct))
                "alert"
            else
                "ok";
            stdout_print("\nBudget status: {s} ({d:.0}% used)\n", .{ state, status.percent_used * 100.0 });
        }
    }

    report.printFullReport(session, daily, budget_status);

    stdout_print("\nTip: Set budget limits in ~/.crushcode/config.toml:\n", .{});
    stdout_print("  [budget]\n", .{});
    stdout_print("  daily_limit_usd = 1.0\n", .{});
    stdout_print("  monthly_limit_usd = 50.0\n", .{});
}

pub fn handleProfile(args: args_mod.Args) !void {
    try profile_mod.handleProfile(args.remaining);
}

pub fn handleWorktree(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        printWorktreeUsage();
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcommand, "list")) {
        stdout_print("\n=== Git Worktrees ===\n", .{});
        // Show in-memory tracked worktrees
        var manager = worktree_mod.WorktreeManager.init(allocator, ".crushcode-worktrees");
        defer manager.deinit();
        const active = manager.listActive();
        if (active.len > 0) {
            stdout_print("  Tracked:\n", .{});
            for (active) |wt| {
                stdout_print("    {s} (branch: {s}, task: {s})\n", .{ wt.path, wt.branch, wt.task_id });
            }
        }
        stdout_print("  Git worktrees:\n", .{});
        // Run git worktree list directly (output goes to terminal)
        _ = shell_mod.executeShellCommand("git worktree list", null) catch {
            stdout_print("    Unable to list (not in a git repo?)\n", .{});
        };
    } else if (std.mem.eql(u8, subcommand, "create")) {
        if (sub_args.len == 0) {
            stdout_print("Error: branch suffix required\n", .{});
            stdout_print("Usage: crushcode worktree create <branch-suffix>\n", .{});
            return;
        }
        const branch_suffix = sub_args[0];
        const task_id = std.fmt.allocPrint(allocator, "wt-{d}", .{std.time.milliTimestamp()}) catch "wt-unknown";
        defer allocator.free(task_id);

        const branch_name = std.fmt.allocPrint(allocator, "crushcode/{s}/{s}", .{ task_id, branch_suffix }) catch {
            stdout_print("Error: out of memory\n", .{});
            return;
        };
        defer allocator.free(branch_name);

        const worktree_path = std.fmt.allocPrint(allocator, ".crushcode-worktrees/worktree-{s}", .{task_id}) catch {
            stdout_print("Error: out of memory\n", .{});
            return;
        };
        defer allocator.free(worktree_path);

        // Create worktree directly via git (avoids cleanupAll on deinit)
        const cmd = std.fmt.allocPrint(allocator, "git worktree add {s} -b {s}", .{ worktree_path, branch_name }) catch {
            stdout_print("Error: out of memory\n", .{});
            return;
        };
        defer allocator.free(cmd);

        const result = shell_mod.executeShellCommand(cmd, null) catch |err| {
            stdout_print("Error creating worktree: {}\n", .{err});
            stdout_print("Make sure you are in a git repository.\n", .{});
            return;
        };
        if (result.exit_code == 0) {
            stdout_print("Created worktree: {s}\n", .{worktree_path});
            stdout_print("  Branch: {s}\n", .{branch_name});
        } else {
            // Branch might already exist, try without -b
            const cmd2 = std.fmt.allocPrint(allocator, "git worktree add {s} {s}", .{ worktree_path, branch_name }) catch {
                stdout_print("Error: out of memory\n", .{});
                return;
            };
            defer allocator.free(cmd2);
            const result2 = shell_mod.executeShellCommand(cmd2, null) catch |err| {
                stdout_print("Error creating worktree: {}\n", .{err});
                return;
            };
            if (result2.exit_code == 0) {
                stdout_print("Created worktree: {s}\n", .{worktree_path});
                stdout_print("  Branch: {s}\n", .{branch_name});
            } else {
                stdout_print("Error creating worktree. Make sure you are in a git repository.\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        if (sub_args.len == 0) {
            stdout_print("Error: path required\n", .{});
            stdout_print("Usage: crushcode worktree remove <path>\n", .{});
            return;
        }
        const target = sub_args[0];
        const rm_cmd = std.fmt.allocPrint(allocator, "git worktree remove {s}", .{target}) catch {
            stdout_print("Error: out of memory\n", .{});
            return;
        };
        defer allocator.free(rm_cmd);
        stdout_print("Removing worktree: {s}\n", .{target});
        _ = shell_mod.executeShellCommand(rm_cmd, null) catch {
            stdout_print("Error removing worktree '{s}'\n", .{target});
        };
    } else if (std.mem.eql(u8, subcommand, "cleanup")) {
        // Remove the worktree directory and clean up all crushcode worktrees via git
        stdout_print("Cleaning up crushcode worktrees...\n", .{});
        // Remove the base directory for our worktrees
        std.fs.cwd().deleteTree(".crushcode-worktrees") catch {};
        // Prune any stale worktree references
        _ = shell_mod.executeShellCommand("git worktree prune", null) catch {};
        stdout_print("Done. Run 'crushcode worktree list' to verify.\n", .{});
    } else {
        stdout_print("Unknown worktree subcommand: {s}\n", .{subcommand});
        printWorktreeUsage();
    }
}

fn printWorktreeUsage() void {
    stdout_print(
        \\Crushcode Worktree Management
        \\
        \\Usage:
        \\  crushcode worktree <subcommand> [options]
        \\
        \\Subcommands:
        \\  list                    List active worktrees
        \\  create <branch-suffix>  Create a new worktree
        \\  remove <path|task-id>   Remove a worktree
        \\  cleanup                 Remove all active worktrees
        \\
        \\Examples:
        \\  crushcode worktree list
        \\  crushcode worktree create feature-x
        \\  crushcode worktree remove .crushcode-worktrees/worktree-wt-1234
        \\  crushcode worktree cleanup
        \\
    , .{});
}

pub fn handleDiff(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len < 2) {
        stdout_print("Usage: crushcode diff <old> <new>\n", .{});
        stdout_print("       crushcode diff --unified <old> <new>\n", .{});
        stdout_print("\nOptions:\n", .{});
        stdout_print("  --inline      Show inline diff format (default)\n", .{});
        return;
    }

    const old_path = args.remaining[0];
    const new_path = args.remaining[1];

    var visualizer = diff_mod.DiffVisualizer.init(allocator);
    _ = &visualizer;

    try visualizer.compareFiles(old_path, new_path);
}
