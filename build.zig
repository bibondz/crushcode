const std = @import("std");

const ImportSpec = struct {
    name: []const u8,
    module: *std.Build.Module,
};

fn imp(name: []const u8, module: *std.Build.Module) ImportSpec {
    return .{ .name = name, .module = module };
}

fn addImports(mod: *std.Build.Module, imports: []const ImportSpec) void {
    for (imports) |import_spec| mod.addImport(import_spec.name, import_spec.module);
}

fn simpleMod(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

fn createMod(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const ImportSpec,
) *std.Build.Module {
    const mod = simpleMod(b, path, target, optimize);
    addImports(mod, imports);
    return mod;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    const compat_array_list_mod = simpleMod(b, "src/compat/array_list.zig", target, optimize);
    const compat_file_mod = simpleMod(b, "src/compat/file.zig", target, optimize);
    const env_mod = simpleMod(b, "src/config/env.zig", target, optimize);
    const http_client_mod = simpleMod(b, "src/http/client.zig", target, optimize);
    const cli_mod = simpleMod(b, "src/cli/args.zig", target, optimize);
    const registry_mod = createMod(b, "src/ai/registry.zig", target, optimize, &.{imp("http_client", http_client_mod)});
    const ai_types_mod = simpleMod(b, "src/protocol/ai_types.zig", target, optimize);
    const tool_types_mod = simpleMod(b, "src/protocol/tool_types.zig", target, optimize);
    const ai_streaming_parsers_mod = createMod(b, "src/ai/streaming_parsers.zig", target, optimize, &.{
        imp("ai_types", ai_types_mod),
        imp("registry", registry_mod),
    });
    const tool_loader_mod = createMod(b, "src/config/tool_loader.zig", target, optimize, &.{
        imp("tool_types", tool_types_mod),
        imp("env", env_mod),
    });
    const client_mod = createMod(b, "src/ai/client.zig", target, optimize, &.{
        imp("registry", registry_mod),       imp("ai_types", ai_types_mod),                         imp("tool_types", tool_types_mod),
        imp("http_client", http_client_mod), imp("ai_streaming_parsers", ai_streaming_parsers_mod),
    });
    const config_mod = createMod(b, "src/config/config.zig", target, optimize, &.{imp("env", env_mod)});
    const provider_config_mod = simpleMod(b, "src/config/provider_config.zig", target, optimize);
    const providers_file_mod = simpleMod(b, "src/config/providers_file.zig", target, optimize);
    const toml_mod = simpleMod(b, "src/config/toml.zig", target, optimize);

    addImports(config_mod, &.{imp("providers_file", providers_file_mod)});
    addImports(providers_file_mod, &.{
        imp("toml", toml_mod),
        imp("array_list_compat", compat_array_list_mod),
        imp("file_compat", compat_file_mod),
    });
    addImports(registry_mod, &.{imp("providers_file", providers_file_mod)});

    const migrate_mod = createMod(b, "src/config/migrate.zig", target, optimize, &.{imp("env", env_mod)});
    const auth_mod = createMod(b, "src/config/auth.zig", target, optimize, &.{imp("env", env_mod)});
    const profile_mod = createMod(b, "src/config/profile.zig", target, optimize, &.{imp("env", env_mod)});
    const connect_mod = createMod(b, "src/commands/connect.zig", target, optimize, &.{
        imp("auth", auth_mod), imp("registry", registry_mod), imp("config", config_mod),
    });

    addImports(config_mod, &.{imp("toml", toml_mod)});
    addImports(provider_config_mod, &.{imp("toml", toml_mod)});

    const fileops_mod = simpleMod(b, "src/fileops/reader.zig", target, optimize);
    const pty_plugin_mod = simpleMod(b, "src/plugins/pty.zig", target, optimize);
    const table_formatter_plugin_mod = simpleMod(b, "src/plugins/table_formatter.zig", target, optimize);
    const notifier_plugin_mod = simpleMod(b, "src/plugins/notifier.zig", target, optimize);
    const shell_strategy_plugin_mod = simpleMod(b, "src/plugins/shell_strategy.zig", target, optimize);
    const plugin_mod = createMod(b, "src/plugin/mod.zig", target, optimize, &.{
        imp("pty", pty_plugin_mod),           imp("table_formatter", table_formatter_plugin_mod),
        imp("notifier", notifier_plugin_mod), imp("shell_strategy", shell_strategy_plugin_mod),
    });
    const plugin_manager_mod = plugin_mod;

    const read_mod = createMod(b, "src/commands/read.zig", target, optimize, &.{imp("fileops", fileops_mod)});
    const chat_tool_executors_mod = simpleMod(b, "src/chat/tool_executors.zig", target, optimize);
    const chat_helpers_mod = simpleMod(b, "src/commands/chat_helpers.zig", target, optimize);
    const chat_bridge_mod = simpleMod(b, "src/commands/chat_bridge.zig", target, optimize);
    const chat_mod = createMod(b, "src/commands/chat.zig", target, optimize, &.{
        imp("args", cli_mod),                                imp("ai_types", ai_types_mod), imp("registry", registry_mod),
        imp("config", config_mod),                           imp("profile", profile_mod),   imp("client", client_mod),
        imp("provider_config", provider_config_mod),         imp("plugin", plugin_mod),     imp("tool_loader", tool_loader_mod),
        imp("chat_tool_executors", chat_tool_executors_mod),
    });

    const plugin_command_mod = simpleMod(b, "src/commands/plugin_command.zig", target, optimize);
    const default_commands_mod = simpleMod(b, "src/config/default_commands.zig", target, optimize);
    addImports(plugin_command_mod, &.{ imp("default_commands", default_commands_mod), imp("env", env_mod) });

    const shell_mod = simpleMod(b, "src/commands/shell.zig", target, optimize);
    const write_mod = simpleMod(b, "src/commands/write.zig", target, optimize);
    const git_mod = createMod(b, "src/commands/git.zig", target, optimize, &.{imp("shell", shell_mod)});
    const skills_mod = createMod(b, "src/commands/builtins.zig", target, optimize, &.{imp("shell", shell_mod)});
    const usage_pricing_mod = simpleMod(b, "src/usage/pricing.zig", target, optimize);
    const session_mod = simpleMod(b, "src/session.zig", target, optimize);
    const tui_markdown_mod = createMod(b, "src/tui/markdown.zig", target, optimize, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    const diff_mod = simpleMod(b, "src/tui/diff.zig", target, optimize);
    addImports(diff_mod, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    const theme_mod = simpleMod(b, "src/tui/theme.zig", target, optimize);
    addImports(theme_mod, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    const tui_mod = simpleMod(b, "src/tui/mod.zig", target, optimize);
    addImports(tui_mod, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    addImports(tui_mod, &.{ imp("markdown", tui_markdown_mod), imp("diff", diff_mod), imp("usage_pricing", usage_pricing_mod), imp("theme", theme_mod), imp("session", session_mod) });
    addImports(chat_mod, &.{imp("tui", tui_mod)});

    const install_mod = createMod(b, "src/commands/install.zig", target, optimize, &.{
        imp("env", env_mod), imp("http_client", http_client_mod),
    });
    const json_extract_mod = simpleMod(b, "src/json/extract.zig", target, optimize);
    addImports(install_mod, &.{imp("json_extract", json_extract_mod)});
    const update_mod = createMod(b, "src/commands/update.zig", target, optimize, &.{
        imp("env", env_mod), imp("http_client", http_client_mod), imp("json_extract", json_extract_mod),
    });
    const provider_oauth_mod = createMod(b, "src/auth/provider_oauth.zig", target, optimize, &.{
        imp("env", env_mod), imp("http_client", http_client_mod), imp("json_extract", json_extract_mod),
    });
    const auth_cmd_mod = createMod(b, "src/commands/auth_cmd.zig", target, optimize, &.{
        imp("auth", auth_mod), imp("provider_oauth", provider_oauth_mod),
    });

    const jobs_mod = createMod(b, "src/commands/jobs.zig", target, optimize, &.{imp("shell", shell_mod)});
    const skills_loader_mod = simpleMod(b, "src/skills/loader.zig", target, optimize);
    const tools_mod = simpleMod(b, "src/tools/registry.zig", target, optimize);

    const streaming_types_mod = simpleMod(b, "src/streaming/types.zig", target, optimize);
    const streaming_buffer_mod = createMod(b, "src/streaming/buffer.zig", target, optimize, &.{imp("types", streaming_types_mod)});
    const streaming_display_mod = createMod(b, "src/streaming/display.zig", target, optimize, &.{imp("types", streaming_types_mod)});
    const ndjson_mod = simpleMod(b, "src/streaming/parsers/ndjson.zig", target, optimize);

    const intensity_mod = simpleMod(b, "src/core/intensity.zig", target, optimize);
    const tiered_loader_mod = simpleMod(b, "src/core/tiered_loader.zig", target, optimize);
    const convergence_mod = simpleMod(b, "src/core/convergence.zig", target, optimize);
    const color_mod = createMod(b, "src/core/color.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    const source_tracker_mod = createMod(b, "src/core/source_tracker.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    const knowledge_lint_mod = createMod(b, "src/core/knowledge_lint.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    const slash_commands_mod = createMod(b, "src/core/slash_commands.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    const revision_loop_mod = createMod(b, "src/core/revision_loop.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod), imp("convergence", convergence_mod),
    });

    addImports(ndjson_mod, &.{imp("types", streaming_types_mod)});
    const sse_mod = createMod(b, "src/streaming/parsers/sse.zig", target, optimize, &.{imp("types", streaming_types_mod)});
    const streaming_session_mod = createMod(b, "src/streaming/session.zig", target, optimize, &.{
        imp("types", streaming_types_mod), imp("buffer", streaming_buffer_mod), imp("display", streaming_display_mod),
        imp("ndjson_mod", ndjson_mod),     imp("sse_mod", sse_mod),
    });
    const core_api_mod = createMod(b, "src/core/api.zig", target, optimize, &.{
        imp("ai_types", ai_types_mod),                   imp("tool_types", tool_types_mod),       imp("client", client_mod),
        imp("streaming_types", streaming_types_mod),     imp("streaming", streaming_session_mod), imp("streaming_buffer", streaming_buffer_mod),
        imp("streaming_display", streaming_display_mod),
    });
    addImports(session_mod, &.{imp("core_api", core_api_mod)});
    addImports(chat_mod, &.{
        imp("intensity", intensity_mod),           imp("tiered_loader", tiered_loader_mod),   imp("convergence", convergence_mod),
        imp("color", color_mod),                   imp("source_tracker", source_tracker_mod), imp("knowledge_lint", knowledge_lint_mod),
        imp("slash_commands", slash_commands_mod), imp("revision_loop", revision_loop_mod),
    });

    const session_summarizer_mod = simpleMod(b, "src/core/session_summarizer.zig", target, optimize);
    const model_hotswap_mod = createMod(b, "src/core/model_hotswap.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    addImports(chat_mod, &.{ imp("session_summarizer", session_summarizer_mod), imp("model_hotswap", model_hotswap_mod) });
    addImports(chat_helpers_mod, &.{
        imp("core_api", core_api_mod),
        imp("ai_types", ai_types_mod),
        imp("color", color_mod),
        imp("session_summarizer", session_summarizer_mod),
    });

    const adversarial_review_mod = createMod(b, "src/core/adversarial_review.zig", target, optimize, &.{imp("array_list_compat", compat_array_list_mod)});
    addImports(chat_mod, &.{imp("adversarial_review", adversarial_review_mod)});

    const spinner_mod = createMod(b, "src/core/spinner.zig", target, optimize, &.{ imp("file_compat", compat_file_mod), imp("color", color_mod) });
    const markdown_renderer_mod = createMod(b, "src/core/markdown_renderer.zig", target, optimize, &.{ imp("file_compat", compat_file_mod), imp("color", color_mod) });
    const error_display_mod = createMod(b, "src/core/error_display.zig", target, optimize, &.{ imp("file_compat", compat_file_mod), imp("color", color_mod) });
    addImports(chat_mod, &.{
        imp("spinner", spinner_mod), imp("markdown_renderer", markdown_renderer_mod), imp("error_display", error_display_mod),
    });
    addImports(tui_mod, &.{
        imp("core_api", core_api_mod), imp("markdown_renderer", markdown_renderer_mod), imp("color", color_mod), imp("registry", registry_mod),
        imp("config", config_mod),
    });
    addImports(chat_mod, &.{ imp("streaming", streaming_session_mod), imp("core_api", core_api_mod) });

    // Widget modules (Phase 17)
    const widget_types_mod = createMod(b, "src/tui/widgets/types.zig", target, optimize, &.{
        imp("core_api", core_api_mod),
        imp("session", session_mod),
    });
    const widget_helpers_mod = createMod(b, "src/tui/widgets/helpers.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
        imp("core_api", core_api_mod),
    });
    const widget_messages_mod = createMod(b, "src/tui/widgets/messages.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("diff", diff_mod),
        imp("markdown", tui_markdown_mod),
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
        imp("core_api", core_api_mod),
    });
    const widget_header_mod = createMod(b, "src/tui/widgets/header.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_input_mod = createMod(b, "src/tui/widgets/input.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    const widget_sidebar_mod = createMod(b, "src/tui/widgets/sidebar.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_palette_mod = createMod(b, "src/tui/widgets/palette.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
        imp("widget_input", widget_input_mod),
        imp("session", session_mod),
    });
    const widget_permission_mod = createMod(b, "src/tui/widgets/permission.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_setup_mod = createMod(b, "src/tui/widgets/setup.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
    });
    const widget_spinner_mod = createMod(b, "src/tui/widgets/spinner.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    const widget_gradient_mod = createMod(b, "src/tui/widgets/gradient.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    const widget_toast_mod = createMod(b, "src/tui/widgets/toast.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    const widget_typewriter_mod = createMod(b, "src/tui/widgets/typewriter.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    addImports(tui_mod, &.{
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
        imp("widget_messages", widget_messages_mod),
        imp("widget_header", widget_header_mod),
        imp("widget_input", widget_input_mod),
        imp("widget_sidebar", widget_sidebar_mod),
        imp("widget_palette", widget_palette_mod),
        imp("widget_permission", widget_permission_mod),
        imp("widget_setup", widget_setup_mod),
        imp("widget_spinner", widget_spinner_mod),
        imp("widget_gradient", widget_gradient_mod),
        imp("widget_toast", widget_toast_mod),
        imp("widget_typewriter", widget_typewriter_mod),
    });

    const json_output_mod = simpleMod(b, "src/streaming/json_output.zig", target, optimize);
    const permission_evaluate_mod = simpleMod(b, "src/permission/evaluate.zig", target, optimize);
    const app_theme_mod = simpleMod(b, "src/theme/mod.zig", target, optimize);
    addImports(chat_mod, &.{
        imp("json_output", json_output_mod), imp("permission_evaluate", permission_evaluate_mod), imp("theme", app_theme_mod),
    });

    const usage_tracker_mod = createMod(b, "src/usage/tracker.zig", target, optimize, &.{imp("streaming_types", streaming_types_mod)});
    const usage_budget_mod = simpleMod(b, "src/usage/budget.zig", target, optimize);
    const usage_report_mod = createMod(b, "src/usage/report.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod), imp("file_compat", compat_file_mod),
        imp("usage_tracker", usage_tracker_mod),         imp("usage_budget", usage_budget_mod),
    });

    const hashline_mod = simpleMod(b, "src/edit/hashline.zig", target, optimize);
    const ast_grep_mod = simpleMod(b, "src/edit/ast_grep.zig", target, optimize);
    const hash_index_mod = createMod(b, "src/edit/hash_index.zig", target, optimize, &.{imp("hashline", hashline_mod)});
    const conflict_mod = simpleMod(b, "src/edit/conflict.zig", target, optimize);
    const validated_edit_mod = createMod(b, "src/edit/validated_edit.zig", target, optimize, &.{
        imp("hashline", hashline_mod), imp("hash_index", hash_index_mod), imp("conflict", conflict_mod),
    });
    addImports(write_mod, &.{
        imp("hashline", hashline_mod), imp("hash_index", hash_index_mod), imp("validated_edit", validated_edit_mod),
    });
    const lsp_handler_mod = simpleMod(b, "src/commands/lsp_handler.zig", target, optimize);
    const mcp_handler_mod = simpleMod(b, "src/commands/mcp_handler.zig", target, optimize);

    const ai_handlers_mod = simpleMod(b, "src/commands/handlers/ai.zig", target, optimize);
    const tool_handlers_mod = simpleMod(b, "src/commands/handlers/tools.zig", target, optimize);
    const system_handlers_mod = simpleMod(b, "src/commands/handlers/system.zig", target, optimize);
    const experimental_handlers_mod = simpleMod(b, "src/commands/handlers/experimental.zig", target, optimize);
    addImports(ai_handlers_mod, &.{
        imp("args", cli_mod), imp("registry", registry_mod), imp("config", config_mod),   imp("chat", chat_mod),
        imp("tui", tui_mod),  imp("core_api", core_api_mod), imp("connect", connect_mod), imp("profile", profile_mod),
    });
    addImports(tool_handlers_mod, &.{
        imp("args", cli_mod),                    imp("tools", tools_mod),             imp("plugin_manager", plugin_manager_mod),
        imp("skills_loader", skills_loader_mod), imp("lsp_handler", lsp_handler_mod), imp("mcp_handler", mcp_handler_mod),
    });
    addImports(system_handlers_mod, &.{
        imp("args", cli_mod),                    imp("registry", registry_mod),           imp("config", config_mod),
        imp("usage_tracker", usage_tracker_mod), imp("usage_pricing", usage_pricing_mod), imp("usage_report", usage_report_mod),
        imp("usage_budget", usage_budget_mod),   imp("profile", profile_mod),
    });
    addImports(experimental_handlers_mod, &.{
        imp("args", cli_mod), imp("ai_types", ai_types_mod),
    });

    const handlers_mod = createMod(b, "src/commands/handlers.zig", target, optimize, &.{
        imp("args", cli_mod),                        imp("config", config_mod),                               imp("chat", chat_mod),               imp("read", read_mod),
        imp("shell", shell_mod),                     imp("write", write_mod),                                 imp("git", git_mod),                 imp("skills", skills_mod),
        imp("install", install_mod),                 imp("update", update_mod),                               imp("jobs", jobs_mod),               imp("plugin_command", plugin_command_mod),
        imp("lsp_handler", lsp_handler_mod),         imp("mcp_handler", mcp_handler_mod),                     imp("ai_handlers", ai_handlers_mod), imp("tool_handlers", tool_handlers_mod),
        imp("system_handlers", system_handlers_mod), imp("experimental_handlers", experimental_handlers_mod), imp("auth_cmd", auth_cmd_mod),
    });

    const cli_registry_mod = createMod(b, "src/cli/registry.zig", target, optimize, &.{
        imp("args", cli_mod), imp("config", config_mod), imp("handlers", handlers_mod),
    });

    const diff_visualizer_mod = simpleMod(b, "src/diff/visualizer.zig", target, optimize);
    addImports(system_handlers_mod, &.{imp("diff", diff_visualizer_mod)});
    const custom_commands_mod = simpleMod(b, "src/commands/custom_commands.zig", target, optimize);

    const backup_mod = simpleMod(b, "src/config/backup.zig", target, optimize);
    addImports(config_mod, &.{imp("backup", backup_mod)});
    addImports(config_mod, &.{imp("migrate", migrate_mod)});

    const main_mod = createMod(b, "src/main.zig", target, optimize, &.{
        imp("args", cli_mod),                        imp("handlers", handlers_mod), imp("config", config_mod),
        imp("provider_config", provider_config_mod), imp("plugin", plugin_mod),     imp("tui", tui_mod),
    });
    addImports(main_mod, &.{
        imp("streaming", streaming_session_mod),   imp("usage_tracker", usage_tracker_mod),   imp("usage_pricing", usage_pricing_mod),
        imp("usage_budget", usage_budget_mod),     imp("usage_report", usage_report_mod),     imp("validated_edit", validated_edit_mod),
        imp("profile", profile_mod),               imp("json_output", json_output_mod),       imp("custom_commands", custom_commands_mod),
        imp("source_tracker", source_tracker_mod), imp("knowledge_lint", knowledge_lint_mod), imp("slash_commands", slash_commands_mod),
        imp("cli_registry", cli_registry_mod),
    });

    const fallback_mod = simpleMod(b, "src/ai/fallback.zig", target, optimize);
    const parallel_mod = simpleMod(b, "src/agent/parallel.zig", target, optimize);
    const task_mod = simpleMod(b, "src/agent/task.zig", target, optimize);
    addImports(parallel_mod, &.{ imp("task", task_mod), imp("core_api", core_api_mod), imp("registry", registry_mod) });
    const memory_mod = simpleMod(b, "src/agent/memory.zig", target, optimize);
    const skill_import_mod = simpleMod(b, "src/skills/import.zig", target, optimize);
    const worktree_mod = createMod(b, "src/agent/worktree.zig", target, optimize, &.{imp("shell", shell_mod)});
    const lifecycle_hooks_mod = simpleMod(b, "src/hooks/lifecycle.zig", target, optimize);
    const intent_gate_mod = simpleMod(b, "src/cli/intent_gate.zig", target, optimize);
    const checkpoint_mod = simpleMod(b, "src/agent/checkpoint.zig", target, optimize);
    const lsp_mod = simpleMod(b, "src/lsp/client.zig", target, optimize);
    const lsp_manager_mod = createMod(b, "src/tui/lsp_manager.zig", target, optimize, &.{imp("lsp", lsp_mod)});

    addImports(main_mod, &.{
        imp("fallback", fallback_mod),     imp("parallel", parallel_mod),               imp("skill_import", skill_import_mod),
        imp("worktree", worktree_mod),     imp("lifecycle_hooks", lifecycle_hooks_mod), imp("intent_gate", intent_gate_mod),
        imp("checkpoint", checkpoint_mod), imp("memory", memory_mod),                   imp("lsp", lsp_mod),
    });
    addImports(chat_mod, &.{ imp("intent_gate", intent_gate_mod), imp("lifecycle_hooks", lifecycle_hooks_mod), imp("memory", memory_mod) });
    addImports(lsp_handler_mod, &.{ imp("args", cli_mod), imp("lsp", lsp_mod) });
    addImports(ai_handlers_mod, &.{ imp("fallback", fallback_mod), imp("parallel", parallel_mod) });
    addImports(tool_handlers_mod, &.{ imp("skill_import", skill_import_mod), imp("ast_grep", ast_grep_mod) });
    addImports(system_handlers_mod, &.{ imp("worktree", worktree_mod), imp("checkpoint", checkpoint_mod) });

    const graph_types_mod = simpleMod(b, "src/graph/types.zig", target, optimize);
    const graph_parser_mod = createMod(b, "src/graph/parser.zig", target, optimize, &.{imp("types", graph_types_mod)});
    const graph_mod = createMod(b, "src/graph/graph.zig", target, optimize, &.{ imp("types", graph_types_mod), imp("parser", graph_parser_mod) });
    const agent_loop_mod = createMod(b, "src/agent/loop.zig", target, optimize, &.{imp("ai_types", ai_types_mod)});
    const workflow_mod = createMod(b, "src/workflow/phase.zig", target, optimize, &.{imp("task", task_mod)});
    const compaction_mod = simpleMod(b, "src/agent/compaction.zig", target, optimize);
    const scaffold_mod = simpleMod(b, "src/scaffold/project.zig", target, optimize);
    const capability_catalog_mod = simpleMod(b, "src/capability/catalog.zig", target, optimize);

    const mcp_transport_mod = createMod(b, "src/mcp/transport.zig", target, optimize, &.{imp("http_client", http_client_mod)});
    const mcp_oauth_mod = createMod(b, "src/mcp/oauth.zig", target, optimize, &.{
        imp("env", env_mod), imp("http_client", http_client_mod), imp("json_extract", json_extract_mod),
    });
    const mcp_client_mod = createMod(b, "src/mcp/client.zig", target, optimize, &.{ imp("mcp_transport", mcp_transport_mod), imp("mcp_oauth", mcp_oauth_mod) });
    const mcp_discovery_mod = createMod(b, "src/mcp/discovery.zig", target, optimize, &.{
        imp("mcp_client", mcp_client_mod), imp("env", env_mod), imp("http_client", http_client_mod), imp("json_extract", json_extract_mod),
    });
    addImports(mcp_handler_mod, &.{ imp("args", cli_mod), imp("mcp_client", mcp_client_mod), imp("mcp_discovery", mcp_discovery_mod) });

    const mcp_bridge_mod = createMod(b, "src/mcp/bridge.zig", target, optimize, &.{
        imp("mcp_client", mcp_client_mod), imp("discovery", mcp_discovery_mod), imp("client", client_mod),
    });

    addImports(main_mod, &.{
        imp("capability_catalog", capability_catalog_mod), imp("graph", graph_mod),                 imp("agent_loop", agent_loop_mod),
        imp("workflow", workflow_mod),                     imp("compaction", compaction_mod),       imp("scaffold", scaffold_mod),
        imp("mcp_client", mcp_client_mod),                 imp("mcp_discovery", mcp_discovery_mod), imp("mcp_bridge", mcp_bridge_mod),
        imp("update", update_mod),
    });
    addImports(tool_handlers_mod, &.{imp("capability_catalog", capability_catalog_mod)});
    addImports(experimental_handlers_mod, &.{
        imp("graph", graph_mod), imp("agent_loop", agent_loop_mod), imp("workflow", workflow_mod), imp("compaction", compaction_mod), imp("scaffold", scaffold_mod),
    });
    addImports(chat_mod, &.{
        imp("compaction", compaction_mod), imp("graph", graph_mod),                 imp("mcp_bridge", mcp_bridge_mod),           imp("agent_loop", agent_loop_mod),
        imp("tools", tools_mod),           imp("skills_loader", skills_loader_mod), imp("streaming_types", streaming_types_mod),
    });
    addImports(tui_mod, &.{ imp("fallback", fallback_mod), imp("graph", graph_mod), imp("lsp_manager", lsp_manager_mod), imp("parallel", parallel_mod), imp("usage_budget", usage_budget_mod) });
    addImports(chat_tool_executors_mod, &.{
        imp("core_api", core_api_mod), imp("agent_loop", agent_loop_mod), imp("json_output", json_output_mod), imp("permission_evaluate", permission_evaluate_mod),
    });
    addImports(chat_bridge_mod, &.{
        imp("ai_types", ai_types_mod),
        imp("core_api", core_api_mod),
        imp("agent_loop", agent_loop_mod),
        imp("lifecycle_hooks", lifecycle_hooks_mod),
        imp("spinner", spinner_mod),
        imp("markdown_renderer", markdown_renderer_mod),
        imp("error_display", error_display_mod),
        imp("json_output", json_output_mod),
        imp("color", color_mod),
        imp("chat_helpers", chat_helpers_mod),
    });
    addImports(chat_mod, &.{ imp("chat_helpers", chat_helpers_mod), imp("chat_bridge", chat_bridge_mod) });

    for (&[_]*std.Build.Module{
        cli_mod,                 env_mod,              http_client_mod,       registry_mod,              ai_types_mod,               tool_types_mod,           tool_loader_mod,           client_mod,              config_mod,
        provider_config_mod,     toml_mod,             fileops_mod,           pty_plugin_mod,            table_formatter_plugin_mod, notifier_plugin_mod,      shell_strategy_plugin_mod, plugin_mod,              read_mod,
        chat_tool_executors_mod, chat_helpers_mod,     chat_bridge_mod,       chat_mod,                  plugin_command_mod,         default_commands_mod,     shell_mod,                 write_mod,               git_mod,
        skills_mod,              tui_mod,              install_mod,           jobs_mod,                  skills_loader_mod,          tools_mod,                diff_mod,                  diff_visualizer_mod,     backup_mod,
        streaming_types_mod,     streaming_buffer_mod, streaming_display_mod, ndjson_mod,                sse_mod,                    streaming_session_mod,    core_api_mod,              usage_tracker_mod,       usage_pricing_mod,
        usage_budget_mod,        usage_report_mod,     hashline_mod,          hash_index_mod,            conflict_mod,               validated_edit_mod,       ast_grep_mod,              lsp_handler_mod,         mcp_handler_mod,
        ai_handlers_mod,         tool_handlers_mod,    system_handlers_mod,   experimental_handlers_mod, handlers_mod,               main_mod,                 fallback_mod,              parallel_mod,            skill_import_mod,
        worktree_mod,            lifecycle_hooks_mod,  intent_gate_mod,       graph_types_mod,           graph_parser_mod,           graph_mod,                agent_loop_mod,            workflow_mod,            compaction_mod,
        capability_catalog_mod,  intensity_mod,        tiered_loader_mod,     revision_loop_mod,         session_summarizer_mod,     model_hotswap_mod,        adversarial_review_mod,    spinner_mod,             markdown_renderer_mod,
        error_display_mod,       convergence_mod,      color_mod,             source_tracker_mod,        knowledge_lint_mod,         slash_commands_mod,       scaffold_mod,              mcp_transport_mod,       mcp_oauth_mod,
        mcp_client_mod,          mcp_discovery_mod,    mcp_bridge_mod,        auth_mod,                  profile_mod,                connect_mod,              json_output_mod,           permission_evaluate_mod, app_theme_mod,
        theme_mod,               checkpoint_mod,       memory_mod,            lsp_mod,                   json_extract_mod,           ai_streaming_parsers_mod, session_mod,               cli_registry_mod,        provider_oauth_mod,
        auth_cmd_mod,            lsp_manager_mod,      widget_types_mod,      widget_helpers_mod,        widget_messages_mod,        widget_header_mod,        widget_input_mod,          widget_sidebar_mod,      widget_palette_mod,
        widget_permission_mod,   widget_setup_mod,     widget_spinner_mod,    widget_gradient_mod,       widget_toast_mod,           widget_typewriter_mod,    migrate_mod,               update_mod,
    }) |module| {
        module.addImport("array_list_compat", compat_array_list_mod);
        module.addImport("file_compat", compat_file_mod);
    }

    const exe = b.addExecutable(.{ .name = "crushcode", .root_module = main_mod });
    b.installArtifact(exe);

    const test_modules = [_]*std.Build.Module{
        mcp_client_mod,
        mcp_transport_mod,
        mcp_oauth_mod,
        graph_parser_mod,
        graph_mod,
        agent_loop_mod,
        workflow_mod,
        compaction_mod,
        scaffold_mod,
        toml_mod,
        tui_mod,
    };
    const test_step = b.step("test", "Run tests");
    for (&test_modules) |mod| test_step.dependOn(&b.addTest(.{ .root_module = mod }).step);

    const mcp_e2e_tests = b.addTest(.{ .root_module = mcp_client_mod });
    const e2e_step = b.step("test-e2e", "Run E2E tests with MCP server (requires RUN_MCP_E2E_TESTS=1)");
    e2e_step.dependOn(&mcp_e2e_tests.step);
}
