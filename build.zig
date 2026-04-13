const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const compat_array_list_mod = b.createModule(.{
        .root_source_file = b.path("src/compat/array_list.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compat_file_mod = b.createModule(.{
        .root_source_file = b.path("src/compat/file.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // Protocol modules — standalone type definitions
    const ai_types_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/ai_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tool_types_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/tool_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tool_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/config/tool_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_loader_mod.addImport("tool_types", tool_types_mod);

    // Client module
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("registry", registry_mod);
    client_mod.addImport("ai_types", ai_types_mod);
    client_mod.addImport("tool_types", tool_types_mod);

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

    // TOML parser module
    const toml_mod = b.createModule(.{
        .root_source_file = b.path("src/config/toml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Auth module (credentials storage)
    const auth_mod = b.createModule(.{
        .root_source_file = b.path("src/config/auth.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Profile module (named configuration profiles)
    const profile_mod = b.createModule(.{
        .root_source_file = b.path("src/config/profile.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Connect module (interactive provider setup)
    const connect_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/connect.zig"),
        .target = target,
        .optimize = optimize,
    });
    connect_mod.addImport("auth", auth_mod);
    connect_mod.addImport("registry", registry_mod);
    connect_mod.addImport("config", config_mod);

    config_mod.addImport("toml", toml_mod);
    provider_config_mod.addImport("toml", toml_mod);

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
    chat_mod.addImport("ai_types", ai_types_mod);
    chat_mod.addImport("registry", registry_mod);
    chat_mod.addImport("config", config_mod);
    chat_mod.addImport("profile", profile_mod);
    chat_mod.addImport("client", client_mod);
    chat_mod.addImport("provider_config", provider_config_mod);
    chat_mod.addImport("plugin", plugin_mod);
    chat_mod.addImport("tool_loader", tool_loader_mod);

    const plugin_command_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/plugin_command.zig"),
        .target = target,
        .optimize = optimize,
    });
    const default_commands_mod = b.createModule(.{
        .root_source_file = b.path("src/config/default_commands.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin_command_mod.addImport("default_commands", default_commands_mod);

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

    // TUI backend module
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("tui", tui_mod);

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

    const core_api_mod = b.createModule(.{
        .root_source_file = b.path("src/core/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_api_mod.addImport("ai_types", ai_types_mod);
    core_api_mod.addImport("tool_types", tool_types_mod);
    core_api_mod.addImport("client", client_mod);
    core_api_mod.addImport("streaming_types", streaming_types_mod);
    core_api_mod.addImport("streaming", streaming_session_mod);
    core_api_mod.addImport("streaming_buffer", streaming_buffer_mod);
    core_api_mod.addImport("streaming_display", streaming_display_mod);

    // Add core_api to TUI module
    tui_mod.addImport("core_api", core_api_mod);

    // Wire streaming into chat module
    chat_mod.addImport("streaming", streaming_session_mod);
    chat_mod.addImport("core_api", core_api_mod);

    // JSON Lines output module (ripgrep-inspired --json flag)
    const json_output_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming/json_output.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("json_output", json_output_mod);

    // Permission system module (Phase 5)
    const permission_evaluate_mod = b.createModule(.{
        .root_source_file = b.path("src/permission/evaluate.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("permission_evaluate", permission_evaluate_mod);

    // Theme/color system module (Phase 6)
    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/theme/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("theme", theme_mod);

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

    // AST-grep module (Phase 10)
    const ast_grep_mod = b.createModule(.{
        .root_source_file = b.path("src/edit/ast_grep.zig"),
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
    handlers_mod.addImport("ai_types", ai_types_mod);
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
    handlers_mod.addImport("plugin_command", plugin_command_mod);
    handlers_mod.addImport("skills_loader", skills_loader_mod);
    handlers_mod.addImport("tools", tools_mod);
    handlers_mod.addImport("usage_tracker", usage_tracker_mod);
    handlers_mod.addImport("usage_pricing", usage_pricing_mod);
    handlers_mod.addImport("core_api", core_api_mod);
    handlers_mod.addImport("connect", connect_mod);
    handlers_mod.addImport("profile", profile_mod);
    handlers_mod.addImport("json_output", json_output_mod);

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
    main_mod.addImport("tui", tui_mod);

    // Phase 14-16 modules — registered on main for availability
    main_mod.addImport("streaming", streaming_session_mod);
    main_mod.addImport("usage_tracker", usage_tracker_mod);
    main_mod.addImport("usage_pricing", usage_pricing_mod);
    main_mod.addImport("usage_budget", usage_budget_mod);
    main_mod.addImport("usage_report", usage_report_mod);
    main_mod.addImport("validated_edit", validated_edit_mod);
    main_mod.addImport("profile", profile_mod);
    main_mod.addImport("json_output", json_output_mod);

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

    // Memory module (Phase 9 - session persistence)
    const memory_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/memory.zig"),
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

    // Checkpoint module (Phase 7 - session persistence)
    const checkpoint_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/checkpoint.zig"),
        .target = target,
        .optimize = optimize,
    });

    // LSP module (Phase 11 - Language Server Protocol client)
    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/client.zig"),
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
    main_mod.addImport("checkpoint", checkpoint_mod);
    main_mod.addImport("memory", memory_mod);
    main_mod.addImport("lsp", lsp_mod);

    // Wire Phase 17-22 modules into command handlers
    chat_mod.addImport("intent_gate", intent_gate_mod);
    chat_mod.addImport("lifecycle_hooks", lifecycle_hooks_mod);
    chat_mod.addImport("memory", memory_mod);
    handlers_mod.addImport("fallback", fallback_mod);
    handlers_mod.addImport("parallel", parallel_mod);
    handlers_mod.addImport("worktree", worktree_mod);
    handlers_mod.addImport("skill_import", skill_import_mod);
    handlers_mod.addImport("checkpoint", checkpoint_mod);
    handlers_mod.addImport("ast_grep", ast_grep_mod);
    handlers_mod.addImport("lsp", lsp_mod);

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
    agent_loop_mod.addImport("ai_types", ai_types_mod);

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

    // MCP (Model Context Protocol) client modules
    const mcp_client_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp_discovery_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp/discovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_discovery_mod.addImport("mcp_client", mcp_client_mod);

    const mcp_bridge_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_bridge_mod.addImport("mcp_client", mcp_client_mod);
    mcp_bridge_mod.addImport("discovery", mcp_discovery_mod);
    mcp_bridge_mod.addImport("client", client_mod);

    // Register Phase 23-27 modules on main
    main_mod.addImport("graph", graph_mod);
    main_mod.addImport("agent_loop", agent_loop_mod);
    main_mod.addImport("workflow", workflow_mod);
    main_mod.addImport("compaction", compaction_mod);
    main_mod.addImport("scaffold", scaffold_mod);
    main_mod.addImport("mcp_client", mcp_client_mod);
    main_mod.addImport("mcp_discovery", mcp_discovery_mod);
    main_mod.addImport("mcp_bridge", mcp_bridge_mod);

    // Wire Phase 23-27 into handlers
    handlers_mod.addImport("graph", graph_mod);
    handlers_mod.addImport("agent_loop", agent_loop_mod);
    handlers_mod.addImport("workflow", workflow_mod);
    handlers_mod.addImport("compaction", compaction_mod);
    handlers_mod.addImport("scaffold", scaffold_mod);
    handlers_mod.addImport("mcp_bridge", mcp_bridge_mod);

    // Wire compaction into chat for auto-compaction
    chat_mod.addImport("compaction", compaction_mod);
    chat_mod.addImport("graph", graph_mod);
    chat_mod.addImport("mcp_bridge", mcp_bridge_mod);
    chat_mod.addImport("agent_loop", agent_loop_mod);
    chat_mod.addImport("tools", tools_mod);
    chat_mod.addImport("skills_loader", skills_loader_mod);
    chat_mod.addImport("streaming_types", streaming_types_mod);

    for (&[_]*std.Build.Module{
        cli_mod,
        registry_mod,
        ai_types_mod,
        tool_types_mod,
        tool_loader_mod,
        client_mod,
        config_mod,
        provider_config_mod,
        toml_mod,
        fileops_mod,
        plugin_mod,
        read_mod,
        chat_mod,
        plugin_command_mod,
        default_commands_mod,
        shell_mod,
        write_mod,
        git_mod,
        skills_mod,
        tui_mod,
        install_mod,
        jobs_mod,
        quantization_mod,
        bitpack_mod,
        value_quant_mod,
        key_quant_mod,
        skills_loader_mod,
        tools_mod,
        streaming_types_mod,
        streaming_buffer_mod,
        streaming_display_mod,
        ndjson_mod,
        sse_mod,
        streaming_session_mod,
        core_api_mod,
        usage_tracker_mod,
        usage_pricing_mod,
        usage_budget_mod,
        usage_report_mod,
        hashline_mod,
        hash_index_mod,
        conflict_mod,
        validated_edit_mod,
        ast_grep_mod,
        handlers_mod,
        main_mod,
        fallback_mod,
        parallel_mod,
        skill_import_mod,
        worktree_mod,
        lifecycle_hooks_mod,
        intent_gate_mod,
        graph_types_mod,
        graph_parser_mod,
        graph_mod,
        agent_loop_mod,
        workflow_mod,
        compaction_mod,
        scaffold_mod,
        mcp_client_mod,
        mcp_discovery_mod,
        mcp_bridge_mod,
        auth_mod,
        profile_mod,
        connect_mod,
        json_output_mod,
        permission_evaluate_mod,
        theme_mod,
        checkpoint_mod,
        memory_mod,
        lsp_mod,
    }) |module| {
        module.addImport("array_list_compat", compat_array_list_mod);
        module.addImport("file_compat", compat_file_mod);
    }

    // Executable
    const exe = b.addExecutable(.{
        .name = "crushcode",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // Tests
    const mcp_client_tests = b.addTest(.{
        .root_module = mcp_client_mod,
    });

    const graph_parser_tests = b.addTest(.{
        .root_module = graph_parser_mod,
    });

    const graph_tests = b.addTest(.{
        .root_module = graph_mod,
    });

    const agent_loop_tests = b.addTest(.{
        .root_module = agent_loop_mod,
    });

    const workflow_tests = b.addTest(.{
        .root_module = workflow_mod,
    });

    const compaction_tests = b.addTest(.{
        .root_module = compaction_mod,
    });

    const scaffold_tests = b.addTest(.{
        .root_module = scaffold_mod,
    });

    const toml_tests = b.addTest(.{
        .root_module = toml_mod,
    });

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&mcp_client_tests.step);
    test_step.dependOn(&graph_parser_tests.step);
    test_step.dependOn(&graph_tests.step);
    test_step.dependOn(&agent_loop_tests.step);
    test_step.dependOn(&workflow_tests.step);
    test_step.dependOn(&compaction_tests.step);
    test_step.dependOn(&scaffold_tests.step);
    test_step.dependOn(&toml_tests.step);
    test_step.dependOn(&tui_tests.step);

    // E2E test step (requires RUN_MCP_E2E_TESTS=1 env var)
    const mcp_e2e_tests = b.addTest(.{
        .root_module = mcp_client_mod,
    });
    const e2e_step = b.step("test-e2e", "Run E2E tests with MCP server (requires RUN_MCP_E2E_TESTS=1)");
    e2e_step.dependOn(&mcp_e2e_tests.step);
}
