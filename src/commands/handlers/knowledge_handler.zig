const std = @import("std");
const args_mod = @import("args");
const knowledge_schema = @import("knowledge_schema");
const knowledge_vault_mod = @import("knowledge_vault_mod");
const knowledge_ingest_mod = @import("knowledge_ingest_mod");
const knowledge_query_mod = @import("knowledge_query_mod");
const knowledge_lint_mod = @import("knowledge_lint_mod");
const knowledge_persistence_mod = @import("knowledge_persistence_mod");
const worker_mod = @import("worker");
const hooks_executor_mod = @import("hooks_executor");
const lifecycle = @import("lifecycle_hooks");
const file_compat = @import("file_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Default vault directory for persistence
const default_vault_dir = ".crushcode/knowledge";

/// Handle `crushcode knowledge <subcommand>` — knowledge operations (ingest/query/lint/status/save/load)
pub fn handleKnowledge(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode knowledge <ingest|query|lint|status|save|load> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  ingest <path>   Ingest file or directory into knowledge vault\n", .{});
        stdout_print("  query <text>    Search knowledge base\n", .{});
        stdout_print("  lint            Run health checks on knowledge vault\n", .{});
        stdout_print("  status          Show vault statistics\n", .{});
        stdout_print("  save            Save current vault to disk\n", .{});
        stdout_print("  load            Load vault from disk\n", .{});
        return;
    }

    const subcommand = args.remaining[0];
    const sub_args = if (args.remaining.len > 1) args.remaining[1..] else &[_][]const u8{};

    // Create in-memory vault
    var vault = knowledge_schema.KnowledgeVault.init(allocator, ".knowledge") catch return;
    defer vault.deinit();

    if (std.mem.eql(u8, subcommand, "ingest")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode knowledge ingest <file_or_directory>\n", .{});
            return;
        }

        // Auto-load from disk first if vault exists
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (pers.vaultExists()) {
            _ = pers.loadVault(&vault) catch {};
        }

        var ingester = knowledge_ingest_mod.KnowledgeIngester.init(allocator, &vault);
        const target_path = sub_args[0];

        // Check if it's a file or directory
        const stat = std.fs.cwd().statFile(target_path) catch |err| {
            stdout_print("Error: cannot access '{s}': {}\n", .{ target_path, err });
            return;
        };

        const result = switch (stat.kind) {
            .directory => ingester.ingestDirectory(target_path) catch {
                stdout_print("Error ingesting directory\n", .{});
                return;
            },
            else => ingester.ingestFile(target_path) catch {
                stdout_print("Error ingesting file\n", .{});
                return;
            },
        };

        stdout_print("\n=== Ingest Results ===\n", .{});
        stdout_print("  Created: {d}\n", .{result.nodes_created});
        stdout_print("  Updated: {d}\n", .{result.nodes_updated});
        stdout_print("  Skipped: {d}\n", .{result.nodes_skipped});
        stdout_print("  Errors:  {d}\n", .{result.errors});
        stdout_print("  Vault size: {d} nodes\n", .{vault.count()});

        // Auto-save after ingest
        pers.saveVault(&vault) catch {
            stdout_print("  Warning: failed to auto-save vault to disk\n", .{});
            return;
        };
        stdout_print("  Vault saved to {s}\n", .{default_vault_dir});
    } else if (std.mem.eql(u8, subcommand, "query")) {
        if (sub_args.len == 0) {
            stdout_print("Usage: crushcode knowledge query <search text>\n", .{});
            return;
        }

        // Auto-load from disk if vault is empty and persisted vault exists
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                const load_result = pers.loadVault(&vault) catch {
                    stdout_print("Warning: could not load persisted vault\n", .{});
                    return;
                };
                if (load_result.nodes_loaded > 0) {
                    stdout_print("  Loaded {d} nodes from disk\n", .{load_result.nodes_loaded});
                }
            }
        }

        // Join remaining args as search text
        const search_text = if (sub_args.len > 1)
            std.mem.join(allocator, " ", sub_args) catch return
        else
            sub_args[0];
        defer if (sub_args.len > 1) allocator.free(search_text);

        var querier = knowledge_query_mod.KnowledgeQuerier.init(allocator, &vault);
        const results = querier.query(search_text, 10) catch {
            stdout_print("Error querying knowledge base\n", .{});
            return;
        };
        defer {
            for (results) |*r| r.deinit(allocator);
            allocator.free(results);
        }

        stdout_print("\n=== Query Results for \"{s}\" ===\n", .{search_text});
        if (results.len == 0) {
            stdout_print("  No results found\n", .{});
        } else {
            for (results, 0..) |*r, i| {
                stdout_print("\n  {d}. {s} (relevance: {d:.2})\n", .{ i + 1, r.title, r.relevance });
                stdout_print("     ID: {s}\n", .{r.node_id});
                if (r.source) |s| stdout_print("     Source: {s}\n", .{s});
                stdout_print("     Snippet: {s}\n", .{r.snippet});
            }
        }
    } else if (std.mem.eql(u8, subcommand, "lint")) {
        // Auto-load from disk if vault is empty
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                _ = pers.loadVault(&vault) catch {};
            }
        }

        var linter = knowledge_lint_mod.KnowledgeLinter.init(allocator, &vault);
        const findings = linter.lint() catch {
            stdout_print("Error running linter\n", .{});
            return;
        };
        defer {
            for (findings) |f| {
                f.deinit();
                allocator.destroy(f);
            }
            allocator.free(findings);
        }

        stdout_print("\n=== Knowledge Lint Results ===\n", .{});
        stdout_print("  Nodes checked: {d}\n", .{vault.count()});
        stdout_print("  Findings: {d}\n\n", .{findings.len});

        // Group by severity
        var critical_count: u32 = 0;
        var warning_count: u32 = 0;
        var info_count: u32 = 0;
        for (findings) |f| {
            switch (f.severity) {
                .critical => critical_count += 1,
                .warning => warning_count += 1,
                .info => info_count += 1,
            }
        }
        stdout_print("  Critical: {d} | Warnings: {d} | Info: {d}\n\n", .{ critical_count, warning_count, info_count });

        for (findings) |f| {
            const sev_label = switch (f.severity) {
                .critical => "CRITICAL",
                .warning => "WARNING",
                .info => "INFO",
            };
            stdout_print("  [{s}] {s}: {s}\n", .{ sev_label, @tagName(f.rule), f.message });
            if (f.location) |loc| stdout_print("    Location: {s}\n", .{loc});
            if (f.suggestion) |sug| stdout_print("    Suggestion: {s}\n", .{sug});
        }
    } else if (std.mem.eql(u8, subcommand, "status")) {
        // Auto-load from disk if vault is empty
        if (vault.count() == 0) {
            var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
            if (pers.vaultExists()) {
                _ = pers.loadVault(&vault) catch {};
            }
        }

        var mgr = knowledge_vault_mod.VaultManager.init(allocator, &vault);
        const stats = mgr.getStats();

        // Check persistence status
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        const is_persisted = pers.vaultExists();

        stdout_print("\n=== Knowledge Vault Status ===\n", .{});
        stdout_print("  Path: {s}\n", .{vault.path});
        stdout_print("  Persisted: {s}\n", .{if (is_persisted) "yes (.crushcode/knowledge/)" else "no"});
        stdout_print("  Total nodes: {d}\n", .{stats.total_nodes});
        stdout_print("  File nodes: {d}\n", .{stats.file_nodes});
        stdout_print("  Graph nodes: {d}\n", .{stats.graph_nodes});
        stdout_print("  Manual nodes: {d}\n", .{stats.manual_nodes});
        stdout_print("  AI-generated nodes: {d}\n", .{stats.ai_nodes});
        stdout_print("  Total tags: {d}\n", .{stats.total_tags});
        stdout_print("  Total citations: {d}\n", .{stats.total_citations});
        stdout_print("  Total accesses: {d}\n", .{stats.total_accesses});
        stdout_print("  Avg confidence: {d:.2}\n", .{stats.avg_confidence});
        stdout_print("  Low confidence (<0.3): {d}\n", .{stats.low_confidence_nodes});
    } else if (std.mem.eql(u8, subcommand, "save")) {
        // Auto-load from disk first to preserve existing data
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (pers.vaultExists()) {
            _ = pers.loadVault(&vault) catch {};
        }

        if (vault.count() == 0) {
            stdout_print("Nothing to save. Use 'crushcode knowledge ingest <path>' first.\n", .{});
            return;
        }

        pers.saveVault(&vault) catch {
            stdout_print("Error: failed to save vault to {s}\n", .{default_vault_dir});
            return;
        };
        stdout_print("\n=== Vault Saved ===\n", .{});
        stdout_print("  Location: {s}\n", .{default_vault_dir});
        stdout_print("  Nodes: {d}\n", .{vault.count()});
    } else if (std.mem.eql(u8, subcommand, "load")) {
        var pers = knowledge_persistence_mod.VaultPersistence.init(allocator, default_vault_dir);
        if (!pers.vaultExists()) {
            stdout_print("No persisted vault found at {s}\n", .{default_vault_dir});
            stdout_print("Use 'crushcode knowledge ingest <path>' to create one.\n", .{});
            return;
        }

        const result = pers.loadVault(&vault) catch {
            stdout_print("Error: failed to load vault from {s}\n", .{default_vault_dir});
            return;
        };
        stdout_print("\n=== Vault Loaded ===\n", .{});
        stdout_print("  Location: {s}\n", .{default_vault_dir});
        stdout_print("  Nodes loaded: {d}\n", .{result.nodes_loaded});
        stdout_print("  Nodes failed: {d}\n", .{result.nodes_failed});
        stdout_print("  Unique tags: {d}\n", .{result.tags_found});
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: ingest, query, lint, status, save, or load\n", .{});
    }
}

/// Handle `crushcode worker <subcommand>` — worker agent execution engine.
/// Subcommands:
///   run "<task>" [--specialty <type>] [--model <model>]  Spawn a worker and execute a task
///   results <id>                                         Read and display worker output
///   list                                                 Show all workers and their status
pub fn handleWorker(args: args_mod.Args) !void {
    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode worker <run|results|list> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  run \"<task>\" [--specialty <type>] [--model <model>]  Execute a task in a worker\n", .{});
        stdout_print("  results <id>                                         Read worker output\n", .{});
        stdout_print("  list                                                 Show all workers\n", .{});
        stdout_print("\nSpecialties: researcher, file_ops, executor, publisher, collector\n", .{});
        return;
    }

    const subcommand = args.remaining[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        handleWorkerList();
        return;
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        try handleWorkerRun(args.remaining[1..]);
        return;
    }

    if (std.mem.eql(u8, subcommand, "results")) {
        try handleWorkerResults(args.remaining[1..]);
        return;
    }

    stdout_print("Unknown subcommand: {s}\n", .{subcommand});
    stdout_print("Use: run, results, or list\n", .{});
}

/// Global worker pool (persists across commands in same process)
var global_worker_pool: ?worker_mod.WorkerPool = null;

fn getOrCreatePool(allocator: std.mem.Allocator) *worker_mod.WorkerPool {
    if (global_worker_pool == null) {
        global_worker_pool = worker_mod.WorkerPool.init(allocator);
    }
    return &global_worker_pool.?;
}

/// Handle `crushcode worker run "<task>" [--specialty <type>] [--model <model>]`
fn handleWorkerRun(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode worker run \"<task>\" [--specialty <type>] [--model <model>]\n", .{});
        return;
    }

    var task_prompt: ?[]const u8 = null;
    var specialty: worker_mod.WorkerSpecialty = .researcher;
    var model: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--specialty")) {
            i += 1;
            if (i < sub_args.len) {
                const val = sub_args[i];
                if (std.mem.eql(u8, val, "researcher")) {
                    specialty = .researcher;
                } else if (std.mem.eql(u8, val, "file_ops")) {
                    specialty = .file_ops;
                } else if (std.mem.eql(u8, val, "executor")) {
                    specialty = .executor;
                } else if (std.mem.eql(u8, val, "publisher")) {
                    specialty = .publisher;
                } else if (std.mem.eql(u8, val, "collector")) {
                    specialty = .collector;
                } else {
                    stdout_print("Unknown specialty: {s} (using researcher)\n", .{val});
                }
            }
        } else if (std.mem.startsWith(u8, sub_args[i], "--specialty=")) {
            const val = sub_args[i][11..];
            if (std.mem.eql(u8, val, "file_ops")) specialty = .file_ops;
            if (std.mem.eql(u8, val, "executor")) specialty = .executor;
            if (std.mem.eql(u8, val, "publisher")) specialty = .publisher;
            if (std.mem.eql(u8, val, "collector")) specialty = .collector;
        } else if (std.mem.eql(u8, sub_args[i], "--model")) {
            i += 1;
            if (i < sub_args.len) {
                model = sub_args[i];
            }
        } else if (std.mem.startsWith(u8, sub_args[i], "--model=")) {
            model = sub_args[i][7..];
        } else if (task_prompt == null) {
            task_prompt = sub_args[i];
        }
    }

    const prompt = task_prompt orelse {
        stdout_print("Error: no task prompt provided\n", .{});
        return;
    };

    const pool = getOrCreatePool(allocator);

    const w = if (model) |m|
        try pool.spawnWorkerWithModel(specialty, prompt, m)
    else
        try pool.spawnWorker(specialty, prompt);

    stdout_print("\n=== Worker Spawned ===\n", .{});
    stdout_print("  ID:        {s}\n", .{w.id});
    stdout_print("  Specialty: {s}\n", .{@tagName(w.specialty)});
    if (w.model_preference) |mp| {
        stdout_print("  Model:     {s}\n", .{mp});
    }
    stdout_print("  Status:    {s}\n", .{@tagName(w.status)});
    stdout_print("  Output:    {s}\n", .{w.output_path});
    stdout_print("\nWorker is pending execution. Use `crushcode worker results {s}` to check output.\n", .{w.id});
}

/// Handle `crushcode worker results <id>`
fn handleWorkerResults(sub_args: [][]const u8) !void {
    const allocator = std.heap.page_allocator;

    if (sub_args.len == 0) {
        stdout_print("Usage: crushcode worker results <worker-id>\n", .{});
        return;
    }

    const worker_id = sub_args[0];
    const pool = getOrCreatePool(allocator);

    const status = pool.checkStatus(worker_id);
    stdout_print("\n=== Worker {s} ===\n", .{worker_id});
    stdout_print("  Status: {s}\n", .{@tagName(status)});

    if (status == .completed) {
        const output = pool.getResult(worker_id) catch |err| {
            stdout_print("  Error reading result: {}\n", .{err});
            return;
        };
        if (output) |content| {
            defer allocator.free(content);
            stdout_print("\n--- Output ---\n{s}\n", .{content});
        } else {
            stdout_print("  (no output)\n", .{});
        }
    } else if (status == .running) {
        stdout_print("  Worker is still running...\n", .{});
    } else if (status == .failed) {
        stdout_print("  Worker failed or not found.\n", .{});
    } else if (status == .pending) {
        stdout_print("  Worker is pending execution.\n", .{});
    }
}

/// Handle `crushcode worker list`
fn handleWorkerList() void {
    const pool = getOrCreatePool(std.heap.page_allocator);
    pool.printStatus();
}

/// Handle `crushcode hooks <subcommand>` — hook execution engine management.
/// Subcommands:
///   list               Show all registered hook scripts with status
///   run <hook_name>    Manually trigger a specific hook
///   test               Dry-run all hooks, show what would execute
///   discover           Scan directories and show discovered hooks
pub fn handleHooks(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len == 0) {
        stdout_print("Usage: crushcode hooks <list|run|test|discover> [args...]\n\n", .{});
        stdout_print("Subcommands:\n", .{});
        stdout_print("  list               Show all registered hook scripts\n", .{});
        stdout_print("  run <hook_name>    Manually trigger a hook\n", .{});
        stdout_print("  test               Dry-run all hooks (no execution)\n", .{});
        stdout_print("  discover           Scan .crushcode/hooks/ and .claude/hooks/\n", .{});
        return;
    }

    const subcommand = args.remaining[0];

    // Create a lifecycle hooks instance and executor
    var lifecycle_hooks = lifecycle.LifecycleHooks.init(allocator);
    defer lifecycle_hooks.deinit();

    var executor = hooks_executor_mod.HookExecutor.init(allocator, lifecycle_hooks, ".crushcode/hooks/");
    defer executor.deinit();

    if (std.mem.eql(u8, subcommand, "list")) {
        // Auto-discover before listing
        _ = executor.discoverHooks() catch 0;
        executor.printStatus();
    } else if (std.mem.eql(u8, subcommand, "run")) {
        if (args.remaining.len < 2) {
            stdout_print("Usage: crushcode hooks run <hook_name>\n", .{});
            return;
        }
        const hook_name = args.remaining[1];

        // Auto-discover first
        _ = executor.discoverHooks() catch 0;

        var ctx = lifecycle.HookContext.init(allocator);
        defer ctx.deinit();
        ctx.phase = .pre_tool;

        const result = executor.executeSingle(hook_name, &ctx);
        if (result) |r| {
            defer {
                var mut_r = r;
                mut_r.deinit(allocator);
            }
            const status = if (r.success) "SUCCESS" else "FAILED";
            stdout_print("\n=== Hook Result ===\n", .{});
            stdout_print("  Hook:   {s}\n", .{r.hook_name});
            stdout_print("  Status: {s}\n", .{status});
            stdout_print("  Exit:   {d}\n", .{r.exit_code});
            stdout_print("  Time:   {d}ms\n", .{r.duration_ms});
            if (r.output.len > 0) {
                stdout_print("\n--- Output ---\n{s}\n", .{r.output});
            }
        } else {
            stdout_print("Hook not found: {s}\n", .{hook_name});
            stdout_print("Use 'crushcode hooks list' to see registered hooks.\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "test")) {
        // Auto-discover
        _ = executor.discoverHooks() catch 0;

        executor.dry_run = true;
        stdout_print("\n=== Hook Test (Dry Run) ===\n", .{});

        if (executor.scripts.items.len == 0) {
            stdout_print("  No hook scripts found.\n", .{});
            stdout_print("  Place scripts in .crushcode/hooks/ or .claude/hooks/\n", .{});
            stdout_print("  Naming: pre-tool-*.sh, post-edit-*.sh, etc.\n", .{});
            return;
        }

        // Test each registered hook
        var ctx = lifecycle.HookContext.init(allocator);
        defer ctx.deinit();
        ctx.phase = .pre_tool;

        for (executor.scripts.items) |script| {
            const test_result = executor.testHook(script.name, &ctx);
            if (test_result) |r| {
                defer {
                    var mut_r = r;
                    mut_r.deinit(allocator);
                }
                const enabled = if (script.enabled) "enabled" else "disabled";
                stdout_print("  [{s}] {s} → {s}\n", .{ enabled, script.name, r.output });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "discover")) {
        stdout_print("\n=== Discovering Hooks ===\n", .{});

        const count = executor.discoverHooks() catch 0;

        stdout_print("  Scanned: .crushcode/hooks/\n", .{});
        stdout_print("  Scanned: .claude/hooks/\n", .{});
        stdout_print("  Discovered: {d} hook scripts\n\n", .{count});

        if (count > 0) {
            for (executor.scripts.items) |script| {
                stdout_print("  {s} ({s}) → {s}\n", .{ script.name, @tagName(script.phase), script.script_path });
            }
        } else {
            stdout_print("  No hook scripts found.\n", .{});
            stdout_print("  Create scripts like .crushcode/hooks/pre-tool-lint.sh\n", .{});
        }
    } else {
        stdout_print("Unknown subcommand: {s}\n", .{subcommand});
        stdout_print("Use: list, run, test, or discover\n", .{});
    }
}
