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

    // Patch vaxis tty.zig to fallback to stdin when /dev/tty is unavailable (WSL fix)
    // The patch replaces the hardcoded `try posix.open("/dev/tty", ...)` with a
    // raw openat syscall that silently falls back to STDIN_FILENO on failure,
    // avoiding the stack-trace dump that Zig's posix.open triggers on ENXIO.
    // Only the tty patch is Linux-specific; the App.zig division-by-zero guard applies to all targets.
    patchVaxisTty(b, vaxis_dep, target);

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
    addImports(registry_mod, &.{imp("array_list_compat", compat_array_list_mod), imp("file_compat", compat_file_mod)});

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
    // db modules (declared early — referenced by session_mod and others)
    const sqlite_mod = simpleMod(b, "src/db/sqlite.zig", target, optimize);
    sqlite_mod.addIncludePath(b.path("vendor/sqlite3"));
    const safety_checkpoint_mod = simpleMod(b, "src/safety/checkpoint.zig", target, optimize);
    const session_db_mod = createMod(b, "src/db/session_db.zig", target, optimize, &.{imp("sqlite", sqlite_mod), imp("safety_checkpoint", safety_checkpoint_mod)});
    const cost_dashboard_mod = createMod(b, "src/analytics/cost_dashboard.zig", target, optimize, &.{
        imp("sqlite", sqlite_mod),
        imp("session_db", session_db_mod),
    });
    const db_migration_mod = createMod(b, "src/db/migration.zig", target, optimize, &.{imp("sqlite", sqlite_mod), imp("session_db", session_db_mod)});
    const session_mod = simpleMod(b, "src/session.zig", target, optimize);
    const tui_markdown_mod = createMod(b, "src/tui/markdown.zig", target, optimize, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    const diff_mod = simpleMod(b, "src/tui/diff.zig", target, optimize);
    addImports(diff_mod, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    const overlay_mod = simpleMod(b, "src/tui/overlay.zig", target, optimize);
    const theme_mod = simpleMod(b, "src/tui/theme.zig", target, optimize);
    addImports(theme_mod, &.{imp("vaxis", vaxis_dep.module("vaxis"))});
    // Allow markdown.zig and diff.zig to access theme.zig for theme-aware styling
    addImports(tui_markdown_mod, &.{imp("theme", theme_mod)});
    addImports(diff_mod, &.{imp("theme", theme_mod)});
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
    const skills_agents_parser_mod = simpleMod(b, "src/skills/agents_parser.zig", target, optimize);
    const skills_resolver_mod = createMod(b, "src/skills/resolver.zig", target, optimize, &.{
        imp("skills_agents_parser", skills_agents_parser_mod),
    });
    const skills_loader_mod = createMod(b, "src/skills/loader.zig", target, optimize, &.{
        imp("skills_resolver", skills_resolver_mod),
    });
    const collections_mod = simpleMod(b, "src/core/collections.zig", target, optimize);
    const skill_pipeline_mod = simpleMod(b, "src/skills/pipeline.zig", target, optimize);
    addImports(skill_pipeline_mod, &.{imp("collections", collections_mod)});
    const skill_sync_mod = simpleMod(b, "src/skills/sync.zig", target, optimize);
    const tools_mod = simpleMod(b, "src/tools/registry.zig", target, optimize);
    const json_helpers_mod = simpleMod(b, "src/core/json_helpers.zig", target, optimize);
    const string_utils_mod = simpleMod(b, "src/core/string_utils.zig", target, optimize);
    const process_mod = simpleMod(b, "src/core/process.zig", target, optimize);
    addImports(shell_mod, &.{imp("string_utils", string_utils_mod)});
    const web_fetch_mod = simpleMod(b, "src/tools/web_fetch.zig", target, optimize);
    const web_search_mod = createMod(b, "src/tools/web_search.zig", target, optimize, &.{
        imp("web_fetch", web_fetch_mod),
    });
    const image_display_mod = simpleMod(b, "src/tools/image_display.zig", target, optimize);
    const edit_batch_mod = simpleMod(b, "src/tools/edit_batch.zig", target, optimize);
    addImports(edit_batch_mod, &.{imp("json_helpers", json_helpers_mod), imp("string_utils", string_utils_mod)});
    const lsp_tools_mod = simpleMod(b, "src/tools/lsp_tools.zig", target, optimize);
    addImports(lsp_tools_mod, &.{imp("json_helpers", json_helpers_mod)});
    const todo_mod = simpleMod(b, "src/tools/todo.zig", target, optimize);
    const apply_patch_mod = simpleMod(b, "src/tools/apply_patch.zig", target, optimize);
    const question_mod = simpleMod(b, "src/tools/question.zig", target, optimize);
    const subagent_mod = simpleMod(b, "src/tools/subagent.zig", target, optimize);
    const fork_mod = createMod(b, "src/session/fork.zig", target, optimize, &.{
        imp("session", session_mod),
    });

    const streaming_types_mod = simpleMod(b, "src/streaming/types.zig", target, optimize);
    const streaming_buffer_mod = createMod(b, "src/streaming/buffer.zig", target, optimize, &.{imp("types", streaming_types_mod)});
    const streaming_display_mod = createMod(b, "src/streaming/display.zig", target, optimize, &.{imp("types", streaming_types_mod)});
    const ndjson_mod = simpleMod(b, "src/streaming/parsers/ndjson.zig", target, optimize);

    const intensity_mod = simpleMod(b, "src/core/intensity.zig", target, optimize);
    const tiered_loader_mod = simpleMod(b, "src/core/tiered_loader.zig", target, optimize);
    const convergence_mod = simpleMod(b, "src/core/convergence.zig", target, optimize);
    const color_mod = simpleMod(b, "src/core/color.zig", target, optimize);
    addImports(git_mod, &.{imp("color", color_mod)});
    const source_tracker_mod = simpleMod(b, "src/core/source_tracker.zig", target, optimize);
    const knowledge_lint_mod = simpleMod(b, "src/core/knowledge_lint.zig", target, optimize);
    const slash_commands_mod = simpleMod(b, "src/core/slash_commands.zig", target, optimize);
    const dynamic_commands_mod = simpleMod(b, "src/skills/dynamic_commands.zig", target, optimize);
    addImports(slash_commands_mod, &.{imp("dynamic_commands", dynamic_commands_mod)});
    const revision_loop_mod = createMod(b, "src/core/revision_loop.zig", target, optimize, &.{
        imp("convergence", convergence_mod),
    });
    const file_tracker_mod = simpleMod(b, "src/core/file_tracker.zig", target, optimize);

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
    addImports(session_mod, &.{imp("core_api", core_api_mod), imp("sqlite", sqlite_mod), imp("session_db", session_db_mod), imp("db_migration", db_migration_mod), imp("file_compat", compat_file_mod)});
    const session_summarizer_mod = simpleMod(b, "src/core/session_summarizer.zig", target, optimize);
    const model_hotswap_mod = simpleMod(b, "src/core/model_hotswap.zig", target, optimize);
    addImports(chat_mod, &.{
        imp("intensity", intensity_mod),           imp("tiered_loader", tiered_loader_mod),   imp("convergence", convergence_mod),
        imp("color", color_mod),                   imp("source_tracker", source_tracker_mod), imp("knowledge_lint", knowledge_lint_mod),
        imp("slash_commands", slash_commands_mod), imp("revision_loop", revision_loop_mod),
        imp("session_summarizer", session_summarizer_mod), imp("model_hotswap", model_hotswap_mod),
    });
    addImports(chat_helpers_mod, &.{
        imp("core_api", core_api_mod),
        imp("ai_types", ai_types_mod),
        imp("color", color_mod),
        imp("session_summarizer", session_summarizer_mod),
    });

    const adversarial_review_mod = simpleMod(b, "src/core/adversarial_review.zig", target, optimize);
    const structured_log_mod = createMod(b, "src/core/structured_log.zig", target, optimize, &.{imp("env", env_mod)});
    const perf_mod = simpleMod(b, "src/core/perf.zig", target, optimize);
    
    const spinner_mod = createMod(b, "src/core/spinner.zig", target, optimize, &.{imp("color", color_mod)});
    const markdown_renderer_mod = createMod(b, "src/core/markdown_renderer.zig", target, optimize, &.{imp("color", color_mod)});
    const error_display_mod = createMod(b, "src/core/error_display.zig", target, optimize, &.{imp("color", color_mod)});
    
    addImports(chat_mod, &.{
        imp("spinner", spinner_mod), imp("markdown_renderer", markdown_renderer_mod), imp("error_display", error_display_mod),
        imp("structured_log", structured_log_mod), imp("perf", perf_mod), imp("streaming", streaming_session_mod), imp("core_api", core_api_mod),
    });
    addImports(tui_mod, &.{
        imp("core_api", core_api_mod), imp("markdown_renderer", markdown_renderer_mod), imp("color", color_mod), imp("registry", registry_mod),
        imp("config", config_mod),
    });

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
    const multiline_input_mod = createMod(b, "src/tui/widgets/multiline_input.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("file_compat", compat_file_mod),
    });
    const widget_input_mod = createMod(b, "src/tui/widgets/input.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("multiline_input", multiline_input_mod),
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
    addImports(widget_permission_mod, &.{imp("diff", diff_mod)});
    const widget_setup_mod = createMod(b, "src/tui/widgets/setup.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_types", widget_types_mod),
        imp("widget_helpers", widget_helpers_mod),
        imp("slash_commands", slash_commands_mod),
        imp("file_compat", compat_file_mod),
    });
    const widget_spinner_mod = createMod(b, "src/tui/widgets/spinner.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_gradient_mod = createMod(b, "src/tui/widgets/gradient.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_toast_mod = createMod(b, "src/tui/widgets/toast.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_typewriter_mod = createMod(b, "src/tui/widgets/typewriter.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
    });
    const widget_diff_preview_mod = createMod(b, "src/tui/widgets/diff_preview.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
        imp("widget_helpers", widget_helpers_mod),
        imp("diff", diff_mod),
    });
    const session_tree_mod = simpleMod(b, "src/tui/widgets/session_tree.zig", target, optimize);
    addImports(widget_messages_mod, &.{imp("typewriter", widget_typewriter_mod)});
    const widget_code_view_mod = createMod(b, "src/tui/widgets/code_view.zig", target, optimize, &.{
        imp("vaxis", vaxis_dep.module("vaxis")),
        imp("theme", theme_mod),
    });
    const code_preview_mod = simpleMod(b, "src/tui/code_preview.zig", target, optimize);
    addImports(code_preview_mod, &.{imp("string_utils", string_utils_mod)});
    const image_mod = simpleMod(b, "src/tui/image.zig", target, optimize);
    addImports(image_mod, &.{imp("file_compat", compat_file_mod)});
    const widget_data_table_mod = simpleMod(b, "src/tui/widgets/data_table.zig", target, optimize);
    const widget_scroll_panel_mod = simpleMod(b, "src/tui/widgets/scroll_panel.zig", target, optimize);
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
        imp("widget_code_view", widget_code_view_mod),
        imp("widget_data_table", widget_data_table_mod),
        imp("widget_scroll_panel", widget_scroll_panel_mod),
        imp("widget_diff_preview", widget_diff_preview_mod),
        imp("image", image_mod),
        imp("file_compat", compat_file_mod),
        imp("overlay", overlay_mod),
    });
    const json_output_mod = simpleMod(b, "src/streaming/json_output.zig", target, optimize);
    const auto_classifier_mod = createMod(b, "src/permission/auto_classifier.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod),
    });
    const permission_evaluate_mod = simpleMod(b, "src/permission/evaluate.zig", target, optimize);
    addImports(permission_evaluate_mod, &.{imp("auto_classifier", auto_classifier_mod)});
    const permission_audit_mod = createMod(b, "src/permission/audit.zig", target, optimize, &.{
        imp("permission_evaluate", permission_evaluate_mod),
    });
    const shell_state_mod = simpleMod(b, "src/shell/state.zig", target, optimize);
    const shell_history_mod = simpleMod(b, "src/shell/history.zig", target, optimize);
    const permission_lists_mod = simpleMod(b, "src/permission/lists.zig", target, optimize);
    const governance_mod = simpleMod(b, "src/permission/governance.zig", target, optimize);
    const app_theme_mod = simpleMod(b, "src/theme/mod.zig", target, optimize);
    addImports(chat_mod, &.{
        imp("json_output", json_output_mod), imp("permission_evaluate", permission_evaluate_mod),
        imp("permission_audit", permission_audit_mod), imp("theme", app_theme_mod), imp("env", env_mod),
        imp("shell_state", shell_state_mod), imp("shell_history", shell_history_mod),
        imp("permission_blocklist", permission_lists_mod), imp("permission_safelist", permission_lists_mod),
        imp("file_tracker", file_tracker_mod),
    });

    const usage_tracker_mod = createMod(b, "src/usage/tracker.zig", target, optimize, &.{imp("streaming_types", streaming_types_mod)});
    const usage_budget_mod = simpleMod(b, "src/usage/budget.zig", target, optimize);
    const usage_report_mod = createMod(b, "src/usage/report.zig", target, optimize, &.{
        imp("usage_tracker", usage_tracker_mod),         imp("usage_budget", usage_budget_mod),
    });

    // TUI test harness — must be after widget_typewriter_mod, theme_mod, usage_budget_mod, usage_pricing_mod
    const tui_test_harness_mod = createMod(b, "src/tui/test_harness.zig", target, optimize, &.{
        imp("widget_typewriter", widget_typewriter_mod),
        imp("theme", theme_mod),
        imp("usage_budget", usage_budget_mod),
        imp("usage_pricing", usage_pricing_mod),
    });

    const hashline_mod = simpleMod(b, "src/edit/hashline.zig", target, optimize);
    const pattern_search_mod = simpleMod(b, "src/edit/pattern_search.zig", target, optimize);
    const hash_index_mod = createMod(b, "src/edit/hash_index.zig", target, optimize, &.{imp("hashline", hashline_mod)});
    const conflict_mod = simpleMod(b, "src/edit/conflict.zig", target, optimize);
    const hashline_edit_mod = simpleMod(b, "src/edit/hashline_edit.zig", target, optimize);
    const validated_edit_mod = createMod(b, "src/edit/validated_edit.zig", target, optimize, &.{
        imp("hashline", hashline_mod), imp("hash_index", hash_index_mod), imp("conflict", conflict_mod),
    });
    addImports(write_mod, &.{
        imp("hashline", hashline_mod), imp("hash_index", hash_index_mod), imp("validated_edit", validated_edit_mod),
    });
    const lsp_handler_mod = simpleMod(b, "src/commands/lsp_handler.zig", target, optimize);
    const mcp_handler_mod = simpleMod(b, "src/commands/mcp_handler.zig", target, optimize);
    const run_mod = createMod(b, "src/commands/run.zig", target, optimize, &.{
        imp("args", cli_mod),        imp("registry", registry_mod), imp("config", config_mod),
        imp("profile", profile_mod), imp("core_api", core_api_mod), imp("json_output", json_output_mod),
        imp("env", env_mod),
    });
    const batch_mod = createMod(b, "src/commands/batch.zig", target, optimize, &.{
        imp("args", cli_mod),        imp("registry", registry_mod), imp("config", config_mod),
        imp("profile", profile_mod), imp("core_api", core_api_mod), imp("env", env_mod),
    });

    const ai_handlers_mod = simpleMod(b, "src/commands/handlers/ai.zig", target, optimize);
    const tool_handlers_mod = simpleMod(b, "src/commands/handlers/tools.zig", target, optimize);
    const system_handlers_mod = simpleMod(b, "src/commands/handlers/system.zig", target, optimize);
    const experimental_handlers_mod = simpleMod(b, "src/commands/handlers/experimental.zig", target, optimize);
    const agent_loop_handler_mod = simpleMod(b, "src/commands/handlers/agent_loop_handler.zig", target, optimize);
    const workflow_handler_mod = simpleMod(b, "src/commands/handlers/workflow_handler.zig", target, optimize);
    const knowledge_handler_mod = simpleMod(b, "src/commands/handlers/knowledge_handler.zig", target, optimize);
    const team_handler_mod = simpleMod(b, "src/commands/handlers/team_handler.zig", target, optimize);
    const memory_handler_mod = simpleMod(b, "src/commands/handlers/memory_handler.zig", target, optimize);
    const plan_handler_mod = simpleMod(b, "src/commands/handlers/plan_handler.zig", target, optimize);
    addImports(plan_handler_mod, &.{imp("json_helpers", json_helpers_mod)});
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
    // experimental_handlers_mod imports deferred to after all dependency modules are declared

    const logs_mod = createMod(b, "src/commands/logs.zig", target, optimize, &.{
        imp("args", cli_mod), imp("env", env_mod), imp("structured_log", structured_log_mod), imp("color", color_mod),
    });

    const session_cmd_mod = createMod(b, "src/commands/session_cmd.zig", target, optimize, &.{
        imp("args", cli_mod), imp("session", session_mod), imp("file_compat", compat_file_mod),
    });

    const completion_mod = createMod(b, "src/commands/completion.zig", target, optimize, &.{
        imp("args", cli_mod),
        imp("file_compat", compat_file_mod),
    });
    const handlers_mod = createMod(b, "src/commands/handlers.zig", target, optimize, &.{
        imp("args", cli_mod),                        imp("config", config_mod),                               imp("chat", chat_mod),               imp("read", read_mod),
        imp("shell", shell_mod),                     imp("write", write_mod),                                 imp("git", git_mod),                 imp("skills", skills_mod),
        imp("install", install_mod),                 imp("update", update_mod),                               imp("jobs", jobs_mod),               imp("plugin_command", plugin_command_mod),
        imp("lsp_handler", lsp_handler_mod),         imp("mcp_handler", mcp_handler_mod),                     imp("ai_handlers", ai_handlers_mod), imp("tool_handlers", tool_handlers_mod),
        imp("system_handlers", system_handlers_mod), imp("experimental_handlers", experimental_handlers_mod), imp("auth_cmd", auth_cmd_mod),       imp("run", run_mod),
        imp("batch", batch_mod),                     imp("logs", logs_mod),                                   imp("session_cmd", session_cmd_mod),
        imp("completion", completion_mod),
    });

    const cli_registry_mod = createMod(b, "src/cli/registry.zig", target, optimize, &.{
        imp("args", cli_mod), imp("config", config_mod), imp("handlers", handlers_mod),
    });

    const diff_visualizer_mod = simpleMod(b, "src/diff/visualizer.zig", target, optimize);
    const myers_mod = simpleMod(b, "src/diff/myers.zig", target, optimize);
    addImports(diff_visualizer_mod, &.{imp("myers", myers_mod)});
    addImports(widget_diff_preview_mod, &.{imp("myers", myers_mod)});
    addImports(system_handlers_mod, &.{imp("diff", diff_visualizer_mod)});
    const custom_commands_mod = simpleMod(b, "src/commands/custom_commands.zig", target, optimize);

    const backup_mod = simpleMod(b, "src/config/backup.zig", target, optimize);
    addImports(config_mod, &.{imp("backup", backup_mod)});
    addImports(config_mod, &.{imp("migrate", migrate_mod)});

    const project_mod = simpleMod(b, "src/config/project.zig", target, optimize);
    addImports(tui_mod, &.{imp("project", project_mod)});
    addImports(config_mod, &.{imp("project", project_mod)});

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
    addImports(parallel_mod, &.{ imp("task", task_mod), imp("core_api", core_api_mod), imp("registry", registry_mod), imp("collections", collections_mod) });
    const memory_mod = simpleMod(b, "src/agent/memory.zig", target, optimize);
    const skill_import_mod = simpleMod(b, "src/skills/import.zig", target, optimize);
    const worktree_mod = createMod(b, "src/agent/worktree.zig", target, optimize, &.{imp("shell", shell_mod)});
    const lifecycle_hooks_mod = simpleMod(b, "src/hooks/lifecycle.zig", target, optimize);
    const hooks_registry_mod = simpleMod(b, "src/hooks/registry.zig", target, optimize);
    const hooks_config_mod = createMod(b, "src/hooks/config.zig", target, optimize, &.{
        imp("hooks", hooks_registry_mod),
        imp("env", env_mod),
    });
    const hooks_executor_mod = createMod(b, "src/hooks/executor.zig", target, optimize, &.{
        imp("lifecycle_hooks", lifecycle_hooks_mod),
    });
    const guardian_mod = createMod(b, "src/permission/guardian.zig", target, optimize, &.{
        imp("hooks_executor", hooks_executor_mod),
        imp("lifecycle_hooks", lifecycle_hooks_mod),
        imp("governance", governance_mod),
        imp("sensitive_paths", permission_lists_mod),
    });
    const intent_gate_mod = simpleMod(b, "src/cli/intent_gate.zig", target, optimize);
    const checkpoint_mod = simpleMod(b, "src/agent/checkpoint.zig", target, optimize);
    const lsp_mod = simpleMod(b, "src/lsp/client.zig", target, optimize);
    const lsp_manager_mod = createMod(b, "src/tui/lsp_manager.zig", target, optimize, &.{imp("lsp", lsp_mod)});

    // main_mod deferred imports merged into single call below (near hybrid_bridge_mod)
    addImports(chat_mod, &.{ imp("intent_gate", intent_gate_mod), imp("lifecycle_hooks", lifecycle_hooks_mod), imp("memory", memory_mod), imp("guardian", guardian_mod) });
    addImports(lsp_handler_mod, &.{ imp("args", cli_mod), imp("lsp", lsp_mod) });
    addImports(ai_handlers_mod, &.{ imp("fallback", fallback_mod), imp("parallel", parallel_mod) });
    addImports(tool_handlers_mod, &.{ imp("skill_import", skill_import_mod), imp("pattern_search", pattern_search_mod) });
    addImports(system_handlers_mod, &.{ imp("worktree", worktree_mod), imp("checkpoint", checkpoint_mod), imp("shell", shell_mod) });

    const graph_types_mod = simpleMod(b, "src/graph/types.zig", target, optimize);
    const graph_parser_mod = createMod(b, "src/graph/parser.zig", target, optimize, &.{imp("types", graph_types_mod)});
    addImports(graph_parser_mod, &.{imp("string_utils", string_utils_mod)});
    const graph_algorithms_mod = createMod(b, "src/graph/algorithms.zig", target, optimize, &.{imp("types", graph_types_mod)});
    const graph_mod = createMod(b, "src/graph/graph.zig", target, optimize, &.{ imp("types", graph_types_mod), imp("parser", graph_parser_mod), imp("algorithms", graph_algorithms_mod) });
    addImports(graph_mod, &.{imp("string_utils", string_utils_mod)});

    // Knowledge modules (Phase 48)
    const knowledge_schema_mod = simpleMod(b, "src/knowledge/schema.zig", target, optimize);
    const knowledge_persistence_mod = createMod(b, "src/knowledge/persistence.zig", target, optimize, &.{
        imp("knowledge_schema", knowledge_schema_mod),
    });
    const knowledge_vault_mod = createMod(b, "src/knowledge/vault.zig", target, optimize, &.{
        imp("knowledge_schema", knowledge_schema_mod),
        imp("knowledge_persistence", knowledge_persistence_mod),
    });
    const knowledge_ops_mod = createMod(b, "src/knowledge/ops.zig", target, optimize, &.{
        imp("knowledge_schema", knowledge_schema_mod),
    });
    const knowledge_knowledge_lint_mod = createMod(b, "src/knowledge/lint.zig", target, optimize, &.{
        imp("knowledge_schema", knowledge_schema_mod),
    });
    const agent_loop_mod = createMod(b, "src/agent/loop.zig", target, optimize, &.{imp("ai_types", ai_types_mod)});
    const workflow_mod = createMod(b, "src/workflow/phase.zig", target, optimize, &.{ imp("task", task_mod), imp("adversarial_review", adversarial_review_mod), imp("git", git_mod) });
    const compaction_mod = simpleMod(b, "src/agent/compaction.zig", target, optimize);
    const context_budget_mod = simpleMod(b, "src/agent/context_budget.zig", target, optimize);
    const context_optimizer_mod = simpleMod(b, "src/ai/context_optimizer.zig", target, optimize);
    const context_limits_mod = simpleMod(b, "src/ai/context_limits.zig", target, optimize);
    const project_memory_mod = simpleMod(b, "src/agent/project_memory.zig", target, optimize);
    const smart_context_mod = simpleMod(b, "src/agent/smart_context.zig", target, optimize);
    const semantic_compressor_mod = simpleMod(b, "src/agent/semantic_compressor.zig", target, optimize);
    addImports(semantic_compressor_mod, &.{imp("string_utils", string_utils_mod)});
    const doctor_mod = createMod(b, "src/commands/doctor.zig", target, optimize, &.{imp("shell", shell_mod), imp("file_compat", compat_file_mod)});
    const review_mod = createMod(b, "src/commands/review.zig", target, optimize, &.{imp("shell", shell_mod)});
    const commit_mod = createMod(b, "src/commands/commit.zig", target, optimize, &.{imp("shell", shell_mod)});
    const recipe_mod = createMod(b, "src/recipes/recipe.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod),
    });
    const recipe_loader_mod = createMod(b, "src/recipes/loader.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod),
        imp("recipe", recipe_mod),
        imp("file_compat", compat_file_mod),
    });
    const recipe_runner_mod = createMod(b, "src/recipes/runner.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod),
        imp("recipe", recipe_mod),
        imp("loader", recipe_loader_mod),
    });
    const worker_mod = simpleMod(b, "src/agent/worker.zig", target, optimize);
    addImports(worker_mod, &.{imp("collections", collections_mod)});
    const worker_runner_mod = createMod(b, "src/agent/worker_runner.zig", target, optimize, &.{
        imp("worker", worker_mod),
    });
    const coordinator_mod = createMod(b, "src/agent/coordinator.zig", target, optimize, &.{
        imp("worker", worker_mod),
    });
    const background_agent_mod = simpleMod(b, "src/agent/background.zig", target, optimize);
    const adversarial_mod = simpleMod(b, "src/agent/adversarial.zig", target, optimize);
    const user_model_mod = simpleMod(b, "src/agent/user_model.zig", target, optimize);
    const feedback_mod = simpleMod(b, "src/agent/feedback.zig", target, optimize);
    addImports(feedback_mod, &.{imp("file_compat", compat_file_mod)});
    const delegate_mod = simpleMod(b, "src/agent/delegate.zig", target, optimize);
    addImports(subagent_mod, &.{imp("delegate", delegate_mod)});
    const moa_mod = simpleMod(b, "src/agent/moa.zig", target, optimize);
    const team_coordinator_mod = createMod(b, "src/agent/team_coordinator.zig", target, optimize, &.{
        imp("registry", registry_mod),
        imp("core_api", core_api_mod),
    });
    addImports(team_coordinator_mod, &.{imp("collections", collections_mod)});
    const auto_gen_mod = simpleMod(b, "src/skills/auto_gen.zig", target, optimize);
    const phase_runner_mod = createMod(b, "src/execution/phase_runner.zig", target, optimize, &.{
        imp("workflow", workflow_mod),
        imp("skill_pipeline", skill_pipeline_mod),
        imp("adversarial", adversarial_mod),
    });
    const template_mod = simpleMod(b, "src/marketplace/template.zig", target, optimize);
    const file_type_mod = simpleMod(b, "src/detection/file_type.zig", target, optimize);
    const cognition_mod = createMod(b, "src/agent/context_builder.zig", target, optimize, &.{
        imp("file_type", file_type_mod),
        imp("graph", graph_mod),
        imp("knowledge_schema", knowledge_schema_mod),
        imp("knowledge_ingest_mod", knowledge_ops_mod),
        imp("knowledge_query_mod", knowledge_ops_mod),
        imp("source_tracker", source_tracker_mod),
    });
    const layered_memory_mod = simpleMod(b, "src/agent/layered_memory.zig", target, optimize);
    addImports(cognition_mod, &.{imp("layered_memory", layered_memory_mod), imp("user_model", user_model_mod)});
    addImports(cognition_mod, &.{
        imp("tiered_loader", tiered_loader_mod),
        imp("intensity", intensity_mod),
        imp("context_optimizer", context_optimizer_mod),
    });
    const autopilot_mod = createMod(b, "src/execution/autopilot.zig", target, optimize, &.{
        imp("background_agent", background_agent_mod),
        imp("cognition", cognition_mod),
        imp("guardian", guardian_mod),
    });
    const crush_mode_mod = simpleMod(b, "src/execution/crush_mode.zig", target, optimize);
    const circuit_breaker_mod = simpleMod(b, "src/agent/circuit_breaker.zig", target, optimize);
    const router_mod = simpleMod(b, "src/agent/router.zig", target, optimize);

    // Harness Engineering: Trace + Retry modules (P0)
    const trace_span_mod = createMod(b, "src/trace/span.zig", target, optimize, &.{
        imp("array_list_compat", compat_array_list_mod),
    });
    const trace_context_mod = createMod(b, "src/trace/context.zig", target, optimize, &.{
        imp("span", trace_span_mod),
    });
    const trace_writer_mod = createMod(b, "src/trace/writer.zig", target, optimize, &.{
        imp("span", trace_span_mod),
    });
    const retry_policy_mod = simpleMod(b, "src/retry/policy.zig", target, optimize);
    const retry_self_heal_mod = simpleMod(b, "src/retry/self_heal.zig", target, optimize);

    // Harness Engineering: Guardrail modules (P1)
    const guardrail_pipeline_mod = simpleMod(b, "src/guardrail/pipeline.zig", target, optimize);

    // Tool inspection pipeline
    const tool_inspection_mod = simpleMod(b, "src/tool/inspection.zig", target, optimize);
    const tool_parallel_mod = simpleMod(b, "src/tool/parallel.zig", target, optimize);

    // Harness Engineering: Observability Metrics (P2)
    const metrics_collector_mod = simpleMod(b, "src/metrics/collector.zig", target, optimize);

    // Wire trace + retry into agent loop
    addImports(agent_loop_mod, &.{
        imp("trace_span", trace_span_mod),
        imp("self_heal", retry_self_heal_mod),
    });

    // Wire metrics, tool inspection, parallel execution, compaction, loop detection, and notifications into agent loop
    addImports(agent_loop_mod, &.{
        imp("metrics_collector", metrics_collector_mod),
        imp("tool_inspection", tool_inspection_mod),
        imp("tool_parallel", tool_parallel_mod),
        imp("compaction", compaction_mod),
        imp("loop_detector", simpleMod(b, "src/agent/loop_detector.zig", target, optimize)),
        imp("notifier", simpleMod(b, "src/notification/notifier.zig", target, optimize)),
    });

    // Wire trace, retry, guardrail, metrics into AI client
    addImports(client_mod, &.{
        imp("trace_span", trace_span_mod), imp("retry_policy", retry_policy_mod),
        imp("guardrail_pipeline", guardrail_pipeline_mod), imp("metrics_collector", metrics_collector_mod),
        imp("circuit_breaker", circuit_breaker_mod),
    });

    // Wire guardrail + metrics into AI client
    addImports(client_mod, &.{
        imp("guardrail_pipeline", guardrail_pipeline_mod),
        imp("metrics_collector", metrics_collector_mod),
        imp("circuit_breaker", circuit_breaker_mod),
    });

    const capability_mod = simpleMod(b, "src/agent/capability.zig", target, optimize);
    addImports(router_mod, &.{imp("circuit_breaker", circuit_breaker_mod)});
    const orchestration_mod = createMod(b, "src/agent/orchestrator.zig", target, optimize, &.{
        imp("worker", worker_mod),
        imp("coordinator", coordinator_mod),
        imp("router", router_mod),
        imp("capability", capability_mod),
        imp("worker_runner", worker_runner_mod),
        imp("checkpoint", checkpoint_mod),
        imp("core_api", core_api_mod),
        imp("registry", registry_mod),
    });
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
    const tool_exposition_mod = simpleMod(b, "src/mcp/tool_exposition.zig", target, optimize);
    const mcp_server_mod = createMod(b, "src/mcp/server.zig", target, optimize, &.{
        imp("tool_exposition", tool_exposition_mod),
    });
    addImports(mcp_handler_mod, &.{ imp("args", cli_mod), imp("mcp_client", mcp_client_mod), imp("mcp_discovery", mcp_discovery_mod), imp("mcp_server", mcp_server_mod) });

    const mcp_bridge_mod = createMod(b, "src/mcp/bridge.zig", target, optimize, &.{
        imp("mcp_client", mcp_client_mod), imp("discovery", mcp_discovery_mod), imp("client", client_mod),
    });

    const hybrid_bridge_mod = createMod(b, "src/hybrid_bridge.zig", target, optimize, &.{
        imp("core_api", core_api_mod),
        imp("chat_tool_executors", chat_tool_executors_mod),
        imp("mcp_bridge", mcp_bridge_mod),
        imp("widget_types", widget_types_mod),
        imp("plugin_manager", plugin_manager_mod),
    });

    addImports(main_mod, &.{
        imp("fallback", fallback_mod), imp("parallel", parallel_mod), imp("skill_import", skill_import_mod),
        imp("worktree", worktree_mod), imp("lifecycle_hooks", lifecycle_hooks_mod), imp("intent_gate", intent_gate_mod),
        imp("checkpoint", checkpoint_mod), imp("memory", memory_mod), imp("lsp", lsp_mod),
        imp("capability_catalog", capability_catalog_mod), imp("graph", graph_mod), imp("agent_loop", agent_loop_mod),
        imp("workflow", workflow_mod), imp("compaction", compaction_mod), imp("scaffold", scaffold_mod),
        imp("mcp_client", mcp_client_mod), imp("mcp_discovery", mcp_discovery_mod), imp("mcp_bridge", mcp_bridge_mod),
        imp("hybrid_bridge", hybrid_bridge_mod), imp("update", update_mod),
        imp("user_model", user_model_mod), imp("auto_gen", auto_gen_mod), imp("feedback", feedback_mod),
    });
    addImports(tool_handlers_mod, &.{imp("capability_catalog", capability_catalog_mod)});
    // experimental_handlers_mod is now a re-export shim — imports 5 sub-modules
    addImports(experimental_handlers_mod, &.{
        imp("agent_loop_handler", agent_loop_handler_mod),
        imp("workflow_handler", workflow_handler_mod),
        imp("knowledge_handler", knowledge_handler_mod),
        imp("team_handler", team_handler_mod),
        imp("memory_handler", memory_handler_mod),
    });
    // agent_loop_handler: handleGraph, handleAutopilot, handleAgentLoop + AI helpers
    addImports(agent_loop_handler_mod, &.{
        imp("args", cli_mod), imp("ai_types", ai_types_mod), imp("graph", graph_mod),
        imp("agent_loop", agent_loop_mod), imp("autopilot", autopilot_mod),
        imp("crush_mode", crush_mode_mod),
        imp("cognition", cognition_mod), imp("guardian", guardian_mod),
        imp("orchestration", orchestration_mod), imp("file_compat", compat_file_mod),
        imp("array_list_compat", compat_array_list_mod),
    });
    // workflow_handler: handleWorkflow, handlePhaseRun, handleCompact, handleScaffold
    addImports(workflow_handler_mod, &.{
        imp("args", cli_mod), imp("workflow", workflow_mod), imp("compaction", compaction_mod),
        imp("scaffold", scaffold_mod), imp("phase_runner", phase_runner_mod),
        imp("adversarial", adversarial_mod), imp("cognition", cognition_mod),
        imp("guardian", guardian_mod), imp("file_compat", compat_file_mod),
        imp("array_list_compat", compat_array_list_mod),
    });
    // knowledge_handler: handleKnowledge, handleWorker, handleHooks
    addImports(knowledge_handler_mod, &.{
        imp("args", cli_mod),
        imp("knowledge_schema", knowledge_schema_mod), imp("knowledge_vault_mod", knowledge_vault_mod),
        imp("knowledge_ingest_mod", knowledge_ops_mod), imp("knowledge_query_mod", knowledge_ops_mod),
        imp("knowledge_lint_mod", knowledge_knowledge_lint_mod), imp("knowledge_persistence_mod", knowledge_persistence_mod),
        imp("worker", worker_mod), imp("hooks_executor", hooks_executor_mod),
        imp("lifecycle_hooks", lifecycle_hooks_mod), imp("file_compat", compat_file_mod),
    });
    // team_handler: handleSkillsResolve, handleSkillsScan, handleTeam, handleBackground
    addImports(team_handler_mod, &.{
        imp("args", cli_mod), imp("file_compat", compat_file_mod),
        imp("array_list_compat", compat_array_list_mod), imp("skills_resolver", skills_resolver_mod),
        imp("skills_agents_parser", skills_agents_parser_mod), imp("skills_loader", skills_loader_mod),
        imp("worker", worker_mod), imp("coordinator", coordinator_mod),
        imp("orchestration", orchestration_mod), imp("background_agent", background_agent_mod),
    });
    // memory_handler: handleMemory, handlePipeline, handleThink, handleSkillSync, handleTemplate, handlePreview, handleDetect
    addImports(memory_handler_mod, &.{
        imp("args", cli_mod), imp("file_compat", compat_file_mod),
        imp("array_list_compat", compat_array_list_mod), imp("layered_memory", layered_memory_mod),
        imp("skill_pipeline", skill_pipeline_mod), imp("adversarial", adversarial_mod),
        imp("skill_sync", skill_sync_mod), imp("template", template_mod),
        imp("file_type", file_type_mod), imp("code_preview", code_preview_mod),
    });
    addImports(chat_mod, &.{
        imp("compaction", compaction_mod), imp("context_budget", context_budget_mod), imp("project_memory", project_memory_mod),
        imp("usage_pricing", usage_pricing_mod), imp("graph", graph_mod), imp("mcp_bridge", mcp_bridge_mod),
        imp("agent_loop", agent_loop_mod), imp("tools", tools_mod), imp("skills_loader", skills_loader_mod),
        imp("streaming_types", streaming_types_mod), imp("session", session_mod), imp("cognition", cognition_mod),
        imp("autopilot", autopilot_mod), imp("phase_runner", phase_runner_mod), imp("orchestration", orchestration_mod),
        imp("chat_helpers", chat_helpers_mod), imp("chat_bridge", chat_bridge_mod), imp("shell", shell_mod),
        imp("http_client", http_client_mod), imp("moa", moa_mod),
    });
    addImports(tui_mod, &.{
        imp("fallback", fallback_mod), imp("graph", graph_mod), imp("lsp_manager", lsp_manager_mod),
        imp("parallel", parallel_mod), imp("memory", memory_mod), imp("usage_budget", usage_budget_mod),
        imp("chat_tool_executors", chat_tool_executors_mod), imp("mcp_bridge", mcp_bridge_mod),
        imp("mcp_client", mcp_client_mod), imp("compaction", compaction_mod),
        imp("lifecycle_hooks", lifecycle_hooks_mod), imp("hybrid_bridge", hybrid_bridge_mod),
        imp("plugin_manager", plugin_manager_mod), imp("guardian", guardian_mod),
        imp("cognition", cognition_mod), imp("autopilot", autopilot_mod), imp("crush_mode", crush_mode_mod),
        imp("phase_runner", phase_runner_mod), imp("orchestration", orchestration_mod),
        imp("slash_commands", slash_commands_mod), imp("user_model", user_model_mod),
        imp("auto_gen", auto_gen_mod), imp("feedback", feedback_mod), imp("plan_handler", plan_handler_mod),
        imp("delegate", delegate_mod), imp("session_db", session_db_mod), imp("cost_dashboard", cost_dashboard_mod),
        imp("fork", fork_mod), imp("myers", myers_mod), imp("session_tree", session_tree_mod),
        imp("team_coordinator", team_coordinator_mod), imp("semantic_compressor", semantic_compressor_mod),
        imp("doctor", doctor_mod), imp("review", review_mod), imp("commit", commit_mod),
        imp("recipe", recipe_mod), imp("loader", recipe_loader_mod), imp("runner", recipe_runner_mod),
        imp("safety_checkpoint", safety_checkpoint_mod), imp("hooks_registry", hooks_registry_mod),
        imp("hooks_config", hooks_config_mod), imp("context_limits", context_limits_mod),
        imp("http_client", http_client_mod),
    });
    addImports(chat_tool_executors_mod, &.{
        imp("core_api", core_api_mod), imp("agent_loop", agent_loop_mod), imp("json_output", json_output_mod),
        imp("permission_evaluate", permission_evaluate_mod), imp("permission_audit", permission_audit_mod),
        imp("shell_state", shell_state_mod), imp("permission_blocklist", permission_lists_mod),
        imp("permission_safelist", permission_lists_mod), imp("json_helpers", json_helpers_mod),
        imp("string_utils", string_utils_mod), imp("process", process_mod), imp("myers", myers_mod),
        imp("file_tracker", file_tracker_mod), imp("web_fetch", web_fetch_mod), imp("web_search", web_search_mod),
        imp("image_display", image_display_mod), imp("edit_batch", edit_batch_mod), imp("lsp_tools", lsp_tools_mod),
        imp("todo", todo_mod), imp("apply_patch", apply_patch_mod), imp("question", question_mod),
        imp("subagent", subagent_mod), imp("safety_checkpoint", safety_checkpoint_mod),
        imp("session_db", session_db_mod), imp("hooks_registry", hooks_registry_mod),
        imp("hashline_edit", hashline_edit_mod),
    });
    addImports(todo_mod, &.{imp("core_api", core_api_mod), imp("json_helpers", json_helpers_mod)});
    addImports(apply_patch_mod, &.{imp("core_api", core_api_mod), imp("json_helpers", json_helpers_mod)});
    addImports(question_mod, &.{imp("core_api", core_api_mod), imp("file_compat", compat_file_mod), imp("json_helpers", json_helpers_mod)});
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

    for (&[_]*std.Build.Module{
        cli_mod, env_mod, http_client_mod, registry_mod, ai_types_mod, tool_types_mod,
        tool_loader_mod, client_mod, config_mod, provider_config_mod, toml_mod, fileops_mod,
        pty_plugin_mod, table_formatter_plugin_mod, notifier_plugin_mod, shell_strategy_plugin_mod,
        plugin_mod, read_mod, chat_tool_executors_mod, chat_helpers_mod, chat_bridge_mod, chat_mod,
        plugin_command_mod, default_commands_mod, shell_mod, write_mod, git_mod, skills_mod,
        tui_mod, install_mod, jobs_mod, skills_loader_mod, tools_mod, diff_mod, diff_visualizer_mod,
        myers_mod, backup_mod, streaming_types_mod, streaming_buffer_mod, streaming_display_mod,
        ndjson_mod, sse_mod, streaming_session_mod, core_api_mod, usage_tracker_mod,
        usage_pricing_mod, usage_budget_mod, usage_report_mod, hashline_mod, hash_index_mod,
        conflict_mod, validated_edit_mod, hashline_edit_mod, pattern_search_mod, lsp_handler_mod,
        mcp_handler_mod, ai_handlers_mod, tool_handlers_mod, system_handlers_mod,
        experimental_handlers_mod, handlers_mod, main_mod, fallback_mod, parallel_mod,
        skill_import_mod, worktree_mod, lifecycle_hooks_mod, intent_gate_mod, graph_types_mod,
        graph_parser_mod, graph_algorithms_mod, graph_mod, agent_loop_mod, workflow_mod,
        compaction_mod, context_budget_mod, project_memory_mod, smart_context_mod,
        semantic_compressor_mod, capability_catalog_mod, intensity_mod, tiered_loader_mod,
        revision_loop_mod, session_summarizer_mod, model_hotswap_mod, adversarial_review_mod,
        spinner_mod, markdown_renderer_mod, error_display_mod, convergence_mod, color_mod,
        source_tracker_mod, knowledge_lint_mod, slash_commands_mod, scaffold_mod,
        mcp_transport_mod, mcp_oauth_mod, mcp_client_mod, mcp_discovery_mod, mcp_bridge_mod,
        auth_mod, profile_mod, connect_mod, json_output_mod, permission_evaluate_mod,
        app_theme_mod, theme_mod, checkpoint_mod, memory_mod, lsp_mod, json_extract_mod,
        ai_streaming_parsers_mod, session_mod, cli_registry_mod, provider_oauth_mod,
        auth_cmd_mod, lsp_manager_mod, widget_types_mod, widget_helpers_mod, widget_messages_mod,
        widget_header_mod, widget_input_mod, widget_sidebar_mod, widget_palette_mod,
        widget_permission_mod, widget_setup_mod, widget_spinner_mod, widget_gradient_mod,
        widget_toast_mod, widget_typewriter_mod, multiline_input_mod, migrate_mod, update_mod,
        custom_commands_mod, project_mod, permission_audit_mod, shell_state_mod, shell_history_mod,
        permission_lists_mod, run_mod, batch_mod, file_tracker_mod, structured_log_mod, logs_mod,
        tool_exposition_mod, mcp_server_mod, governance_mod, context_optimizer_mod,
        context_limits_mod, worker_mod, router_mod, circuit_breaker_mod, capability_mod,
        knowledge_schema_mod, knowledge_vault_mod, knowledge_ops_mod, knowledge_knowledge_lint_mod,
        widget_code_view_mod, widget_data_table_mod, widget_scroll_panel_mod, widget_diff_preview_mod,
        worker_runner_mod, skills_agents_parser_mod, skills_resolver_mod, knowledge_persistence_mod,
        hooks_executor_mod, coordinator_mod, background_agent_mod, skill_pipeline_mod,
        layered_memory_mod, adversarial_mod, skill_sync_mod, template_mod, code_preview_mod,
        file_type_mod, cognition_mod, guardian_mod, phase_runner_mod, autopilot_mod, crush_mode_mod,
        orchestration_mod, hybrid_bridge_mod, user_model_mod, auto_gen_mod, feedback_mod,
        plan_handler_mod, delegate_mod, moa_mod, team_coordinator_mod, sqlite_mod, session_db_mod,
        db_migration_mod, web_fetch_mod, web_search_mod, image_display_mod, edit_batch_mod,
        lsp_tools_mod, fork_mod, image_mod, cost_dashboard_mod, session_tree_mod,
        safety_checkpoint_mod, dynamic_commands_mod, todo_mod, apply_patch_mod, question_mod,
        subagent_mod, auto_classifier_mod, hooks_registry_mod, hooks_config_mod, doctor_mod,
        review_mod, commit_mod, recipe_mod, recipe_loader_mod, recipe_runner_mod,
        trace_span_mod, trace_context_mod, trace_writer_mod, retry_policy_mod, retry_self_heal_mod,
        guardrail_pipeline_mod, metrics_collector_mod, tool_parallel_mod,
    }) |module| {
        module.addImport("array_list_compat", compat_array_list_mod);
        module.addImport("file_compat", compat_file_mod);
    }

    // --- SQLite3 amalgamation (vendored C) ---
    const sqlite_c_flags = [_][]const u8{
        "-std=c99",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_DQS=0",
    };

    const exe = b.addExecutable(.{ .name = "crushcode", .root_module = main_mod });
    exe.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &sqlite_c_flags,
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/zig_helpers.c"),
        .flags = &.{},
    });
    exe.addIncludePath(b.path("vendor/sqlite3"));
    exe.linkLibC();
    b.installArtifact(exe);

    const test_modules = [_]*std.Build.Module{
        myers_mod, mcp_client_mod, mcp_transport_mod, mcp_oauth_mod, graph_parser_mod,
        graph_algorithms_mod, graph_mod, agent_loop_mod, memory_mod, compaction_mod,
        context_budget_mod, project_memory_mod, smart_context_mod, semantic_compressor_mod,
        user_model_mod, feedback_mod, checkpoint_mod, workflow_mod, scaffold_mod, toml_mod,
        tui_mod, config_mod, provider_config_mod, backup_mod, auth_mod, tools_mod,
        skills_loader_mod, custom_commands_mod, color_mod, source_tracker_mod, provider_oauth_mod,
        tool_exposition_mod, mcp_server_mod, governance_mod, permission_lists_mod,
        context_optimizer_mod, context_limits_mod, worker_mod, router_mod, circuit_breaker_mod,
        guardrail_pipeline_mod, metrics_collector_mod, knowledge_schema_mod, knowledge_ops_mod,
        knowledge_knowledge_lint_mod, widget_data_table_mod, widget_scroll_panel_mod,
        widget_code_view_mod, worker_runner_mod, skills_agents_parser_mod, skills_resolver_mod,
        knowledge_persistence_mod, hooks_executor_mod, coordinator_mod, background_agent_mod,
        skill_pipeline_mod, layered_memory_mod, adversarial_mod, skill_sync_mod, template_mod,
        code_preview_mod, file_type_mod, cognition_mod, guardian_mod, phase_runner_mod,
        autopilot_mod, crush_mode_mod, orchestration_mod, hybrid_bridge_mod,
        chat_tool_executors_mod, auto_gen_mod, plan_handler_mod, delegate_mod, moa_mod,
        team_coordinator_mod, sqlite_mod, session_db_mod, db_migration_mod, image_display_mod,
        edit_batch_mod, lsp_tools_mod, fork_mod, cost_dashboard_mod, dynamic_commands_mod,
        auto_classifier_mod, todo_mod, apply_patch_mod, question_mod, subagent_mod,
        hooks_registry_mod, hooks_config_mod, doctor_mod, review_mod, commit_mod, recipe_mod,
        recipe_loader_mod, recipe_runner_mod, tool_inspection_mod, tool_parallel_mod,
        trace_span_mod, trace_context_mod, trace_writer_mod, retry_policy_mod, retry_self_heal_mod,
        tui_test_harness_mod, registry_mod, fileops_mod, hashline_edit_mod,
    };
    const test_step = b.step("test", "Run tests");
    for (&test_modules) |mod| test_step.dependOn(&b.addTest(.{ .root_module = mod }).step);

    // SQ-1: Dedicated sqlite test step with C linkage (-lc + sqlite3 amalgamation)
    // Uses a separate module instance to avoid duplicate symbol conflicts with the main exe.
    const sqlite_test_mod = simpleMod(b, "src/db/sqlite.zig", target, optimize);
    sqlite_test_mod.addIncludePath(b.path("vendor/sqlite3"));
    const sqlite_tests = b.addTest(.{ .root_module = sqlite_test_mod });
    sqlite_tests.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &sqlite_c_flags,
    });
    sqlite_tests.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/zig_helpers.c"),
        .flags = &.{},
    });
    sqlite_tests.addIncludePath(b.path("vendor/sqlite3"));
    sqlite_tests.linkLibC();
    const test_sqlite_step = b.step("test-sqlite", "Run sqlite unit tests (with C linkage)");
    test_sqlite_step.dependOn(&sqlite_tests.step);

    // Dedicated registry test step
    const registry_tests = b.addTest(.{ .root_module = registry_mod });
    const test_registry_step = b.step("test-registry", "Run registry unit tests");
    test_registry_step.dependOn(&registry_tests.step);

    // Dedicated protocol test step
    const protocol_tests = b.addTest(.{ .root_module = plugin_mod });
    const test_protocol_step = b.step("test-protocol", "Run plugin protocol unit tests");
    test_protocol_step.dependOn(&protocol_tests.step);

    const mcp_e2e_tests = b.addTest(.{ .root_module = mcp_client_mod });
    const e2e_step = b.step("test-e2e", "Run E2E tests with MCP server (requires RUN_MCP_E2E_TESTS=1)");
    e2e_step.dependOn(&mcp_e2e_tests.step);
}

/// Patch vaxis tty.zig to gracefully handle /dev/tty unavailable on WSL.
/// Replaces the raw `try posix.open("/dev/tty")` with a syscall that falls
/// back to STDIN_FILENO without dumping a stack trace.
/// Also patches App.zig doLayout to guard against division-by-zero when
/// screen dimensions are zero (e.g. before queryTerminal responds).
fn patchVaxisTty(b: *std.Build, vaxis_dep: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    // Patch 1: tty.zig — /dev/tty fallback (Linux only — uses std.os.linux.openat)
    if (target.result.os.tag == .linux) {
        const tty_src = vaxis_dep.path("src/tty.zig").getPath3(b, null);
        const tty_path = tty_src.root_dir.path orelse return;

        const file = std.fs.cwd().openFile(tty_path, .{ .mode = .read_write }) catch return;
        defer file.close();

        const contents = file.readToEndAlloc(b.allocator, 128 * 1024) catch return;
        defer b.allocator.free(contents);

        const needle = "const fd = try posix.open(\"/dev/tty\", .{ .ACCMODE = .RDWR }, 0);";
        if (std.mem.indexOf(u8, contents, needle)) |_| {
            const patch =
                \\        const fd: posix.fd_t = blk: {
                \\            const rc = std.os.linux.openat(std.os.linux.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
                \\            const signed: isize = @bitCast(rc);
                \\            if (signed < 0) break :blk posix.STDIN_FILENO;
                \\            break :blk @intCast(rc);
                \\        };
            ;
            const new_contents = std.mem.replaceOwned(u8, b.allocator, contents, needle, patch) catch return;
            file.seekTo(0) catch return;
            file.setEndPos(0) catch return;
            file.writeAll(new_contents) catch return;
        }
    } // end Linux-only tty patch

    // Patch 2: App.zig doLayout — guard division-by-zero (all platforms)
    {
        const app_src = vaxis_dep.path("src/vxfw/App.zig").getPath3(b, null);
        const app_root = app_src.root_dir.path orelse return;

        // Build full path: root_dir + sub_path components
        var app_path_buf: [512]u8 = undefined;
        const app_path = std.fmt.bufPrint(&app_path_buf, "{s}/src/vxfw/App.zig", .{app_root}) catch return;

        const file = std.fs.cwd().openFile(app_path, .{ .mode = .read_write }) catch return;
        defer file.close();

        const contents = file.readToEndAlloc(b.allocator, 128 * 1024) catch return;
        defer b.allocator.free(contents);

        const needle = ".width = vx.screen.width_pix / vx.screen.width,";
        if (std.mem.indexOf(u8, contents, needle)) |_| {
            const patch = ".width = if (vx.screen.width > 0) vx.screen.width_pix / vx.screen.width else 8,";
            const new_contents = std.mem.replaceOwned(u8, b.allocator, contents, needle, patch) catch return;
            file.seekTo(0) catch return;
            file.setEndPos(0) catch return;
            file.writeAll(new_contents) catch return;
        }
    }
}
