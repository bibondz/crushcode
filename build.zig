const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI module
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Registry module
    const registry_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/registry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Client module
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("registry", registry_mod);

    // Config module
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Provider config module
    const provider_config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/provider_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // File operations module
    const fileops_mod = b.createModule(.{
        .root_source_file = b.path("src/fileops/reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Plugin module
    const plugin_mod = b.createModule(.{ .root_source_file = b.path("src/plugin/interface.zig"), .imports = &.{
        .{ .name = "protocol", .module = b.createModule(.{ .root_source_file = b.path("src/plugin/protocol.zig"), .imports = &.{} }) },
    } });

    // Read module
    const read_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/read.zig"),
        .target = target,
        .optimize = optimize,
    });
    read_mod.addImport("fileops", fileops_mod);

    // Chat module
    const chat_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/chat.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("args", cli_mod);
    chat_mod.addImport("registry", registry_mod);
    chat_mod.addImport("config", config_mod);
    chat_mod.addImport("client", client_mod);
    chat_mod.addImport("provider_config", provider_config_mod);
    chat_mod.addImport("plugin", plugin_mod);

    // Shell module
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/shell.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Write module
    const write_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/write.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Git module
    const git_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/git.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_mod.addImport("shell", shell_mod);

    // Skills module
    const skills_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/skills.zig"),
        .target = target,
        .optimize = optimize,
    });
    skills_mod.addImport("shell", shell_mod);

    // TUI module
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/tui.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install module
    const install_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/install.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Jobs module
    const jobs_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/jobs.zig"),
        .target = target,
        .optimize = optimize,
    });
    jobs_mod.addImport("shell", shell_mod);

    // Quantization module (TurboQuant KV cache compression)
    const quantization_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/rotation.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bitpack_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/bitpack.zig"),
        .target = target,
        .optimize = optimize,
    });

    const value_quant_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/value_quant.zig"),
        .target = target,
        .optimize = optimize,
    });

    const key_quant_mod = b.createModule(.{
        .root_source_file = b.path("src/quantization/key_quant.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link quantization modules
    key_quant_mod.addImport("rotation", quantization_mod);
    value_quant_mod.addImport("bitpack", bitpack_mod);

    // Skills loader module (SKILL.md parsing)
    const skills_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/skills/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tool registry module
    const tools_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/registry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Streaming modules (Phase 14)
    const streaming_types_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const streaming_buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    streaming_buffer_mod.addImport("types", streaming_types_mod);

    const streaming_display_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    streaming_display_mod.addImport("types", streaming_types_mod);

    const ndjson_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/parsers/ndjson.zig"),
        .target = target,
        .optimize = optimize,
    });
    ndjson_mod.addImport("types", streaming_types_mod);

    const sse_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/parsers/sse.zig"),
        .target = target,
        .optimize = optimize,
    });
    sse_mod.addImport("types", streaming_types_mod);

    const streaming_session_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/session.zig"),
        .target = target,
        .optimize = optimize,
    });
    streaming_session_mod.addImport("types", streaming_types_mod);
    streaming_session_mod.addImport("buffer", streaming_buffer_mod);
    streaming_session_mod.addImport("display", streaming_display_mod);
    streaming_session_mod.addImport("ndjson_mod", ndjson_mod);
    streaming_session_mod.addImport("sse_mod", sse_mod);

    // Wire streaming into chat module
    chat_mod.addImport("streaming", streaming_session_mod);

    // Usage tracking modules (Phase 15)
    const usage_tracker_mod = b.createModule(.{
        .root_source_file = b.path("src/usage/tracker.zig"),
        .target = target,
        .optimize = optimize,
    });

    const usage_pricing_mod = b.createModule(.{
        .root_source_file = b.path("src/usage/pricing.zig"),
        .target = target,
        .optimize = optimize,
    });

    const usage_budget_mod = b.createModule(.{
        .root_source_file = b.path("src/usage/budget.zig"),
        .target = target,
        .optimize = optimize,
    });

    const usage_report_mod = b.createModule(.{
        .root_source_file = b.path("src/usage/report.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Edit validation modules (Phase 16)
    const hashline_mod = b.createModule(.{
        .root_source_file = b.path("src/edit/hashline.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hash_index_mod = b.createModule(.{
        .root_source_file = b.path("src/edit/hash_index.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_index_mod.addImport("hashline", hashline_mod);

    const conflict_mod = b.createModule(.{
        .root_source_file = b.path("src/edit/conflict.zig"),
        .target = target,
        .optimize = optimize,
    });

    const validated_edit_mod = b.createModule(.{
        .root_source_file = b.path("src/edit/validated_edit.zig"),
        .target = target,
        .optimize = optimize,
    });
    validated_edit_mod.addImport("hashline", hashline_mod);
    validated_edit_mod.addImport("hash_index", hash_index_mod);
    validated_edit_mod.addImport("conflict", conflict_mod);

    // Handlers module
    const handlers_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/handlers.zig"),
        .target = target,
        .optimize = optimize,
    });
    handlers_mod.addImport("args", cli_mod);
    handlers_mod.addImport("registry", registry_mod);
    handlers_mod.addImport("config", config_mod);
    handlers_mod.addImport("chat", chat_mod);
    handlers_mod.addImport("read", read_mod);
    handlers_mod.addImport("shell", shell_mod);
    handlers_mod.addImport("write", write_mod);
    handlers_mod.addImport("git", git_mod);
    handlers_mod.addImport("skills", skills_mod);
    handlers_mod.addImport("tui", tui_mod);
    handlers_mod.addImport("install", install_mod);
    handlers_mod.addImport("jobs", jobs_mod);
    handlers_mod.addImport("skills_loader", skills_loader_mod);
    handlers_mod.addImport("tools", tools_mod);
    handlers_mod.addImport("usage_tracker", usage_tracker_mod);
    handlers_mod.addImport("usage_pricing", usage_pricing_mod);

    // Main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("args", cli_mod);
    main_mod.addImport("handlers", handlers_mod);
    main_mod.addImport("config", config_mod);
    main_mod.addImport("provider_config", provider_config_mod);
    main_mod.addImport("plugin", plugin_mod);

    // Phase 14-16 modules — registered on main for availability
    main_mod.addImport("streaming", streaming_session_mod);
    main_mod.addImport("usage_tracker", usage_tracker_mod);
    main_mod.addImport("usage_pricing", usage_pricing_mod);
    main_mod.addImport("usage_budget", usage_budget_mod);
    main_mod.addImport("usage_report", usage_report_mod);
    main_mod.addImport("validated_edit", validated_edit_mod);

    // Phase 17-22 modules
    const fallback_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/fallback.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parallel_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/parallel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const skill_import_mod = b.createModule(.{
        .root_source_file = b.path("src/skills/import.zig"),
        .target = target,
        .optimize = optimize,
    });

    const worktree_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/worktree.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lifecycle_hooks_mod = b.createModule(.{
        .root_source_file = b.path("src/hooks/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
    });

    const intent_gate_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/intent_gate.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Register Phase 17-22 modules on main
    main_mod.addImport("fallback", fallback_mod);
    main_mod.addImport("parallel", parallel_mod);
    main_mod.addImport("skill_import", skill_import_mod);
    main_mod.addImport("worktree", worktree_mod);
    main_mod.addImport("lifecycle_hooks", lifecycle_hooks_mod);
    main_mod.addImport("intent_gate", intent_gate_mod);

    // Wire Phase 17-22 modules into command handlers
    chat_mod.addImport("intent_gate", intent_gate_mod);
    chat_mod.addImport("lifecycle_hooks", lifecycle_hooks_mod);
    handlers_mod.addImport("fallback", fallback_mod);
    handlers_mod.addImport("parallel", parallel_mod);
    handlers_mod.addImport("worktree", worktree_mod);
    handlers_mod.addImport("skill_import", skill_import_mod);

    // Phase 23: Codebase Knowledge Graph (Graphify-inspired)
    const graph_types_mod = b.createModule(.{
        .root_source_file = b.path("src/graph/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const graph_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/graph/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    graph_parser_mod.addImport("types", graph_types_mod);

    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/graph/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    graph_mod.addImport("types", graph_types_mod);
    graph_mod.addImport("parser", graph_parser_mod);

    // Phase 24: Agent Loop Engine (OpenHarness-inspired)
    const agent_loop_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/loop.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Phase 25: Phase Workflow System (GSD-inspired)
    const workflow_mod = b.createModule(.{
        .root_source_file = b.path("src/workflow/phase.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Phase 26: Auto-Context Compaction (OpenHarness-inspired)
    const compaction_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/compaction.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Phase 27: Project Scaffolding (GSD-inspired)
    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/scaffold/project.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Register Phase 23-27 modules on main
    main_mod.addImport("graph", graph_mod);
    main_mod.addImport("agent_loop", agent_loop_mod);
    main_mod.addImport("workflow", workflow_mod);
    main_mod.addImport("compaction", compaction_mod);
    main_mod.addImport("scaffold", scaffold_mod);

    // Wire Phase 23-27 into handlers
    handlers_mod.addImport("graph", graph_mod);
    handlers_mod.addImport("agent_loop", agent_loop_mod);
    handlers_mod.addImport("workflow", workflow_mod);
    handlers_mod.addImport("compaction", compaction_mod);
    handlers_mod.addImport("scaffold", scaffold_mod);

    // Wire compaction into chat for auto-compaction
    chat_mod.addImport("compaction", compaction_mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "crushcode",
        .root_module = main_mod,
    });

    b.installArtifact(exe);
}
