const std = @import("std");
const args_mod = @import("args");
const capability_catalog = @import("capability_catalog");
const tools_mod = @import("tools");
const plugin_manager_mod = @import("plugin_manager");
const skills_loader_mod = @import("skills_loader");
const skill_import_mod = @import("skill_import");
const pattern_search_mod = @import("pattern_search");
const file_compat = @import("file_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

fn capabilityKindLabel(kind: capability_catalog.CapabilityKind) []const u8 {
    return switch (kind) {
        .tool => "Tools",
        .plugin => "Plugins",
        .skill => "Skills",
        .mcp_tool => "MCP Tools",
        .builtin => "Built-ins",
    };
}

pub fn handleCapabilities(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var catalog = capability_catalog.CapabilityCatalog.init(allocator);
    defer catalog.deinit();

    var tool_registry = tools_mod.ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.registerBuiltinTools();

    const available_tools = try tool_registry.getAvailableTools(allocator);
    defer allocator.free(available_tools);
    for (available_tools) |tool_name| {
        if (tool_registry.get(tool_name)) |tool| {
            try catalog.register(.{
                .name = tool.name,
                .kind = .tool,
                .enabled = tool.enabled,
                .description = tool.description,
            });
        }
    }

    var plugin_manager = plugin_manager_mod.PluginManager.init(allocator);
    defer plugin_manager.deinit();
    try plugin_manager.initializeBuiltIns();

    const plugins = try plugin_manager.listPlugins();
    defer allocator.free(plugins);
    for (plugins) |plugin| {
        const status = plugin_manager.getPluginStatus(plugin.name) catch continue;
        try catalog.register(.{
            .name = status.name,
            .kind = if (status.type == .builtin) .builtin else .plugin,
            .enabled = status.enabled,
            .description = status.description,
        });
    }

    var skill_loader = skills_loader_mod.SkillLoader.init(allocator);
    defer skill_loader.deinit();
    skill_loader.loadFromDirectory("skills") catch {};
    for (skill_loader.getSkills()) |skill| {
        try catalog.register(.{
            .name = skill.name,
            .kind = .skill,
            .enabled = true,
            .description = skill.description,
            .source = skill.file_path,
        });
    }

    const kinds = [_]capability_catalog.CapabilityKind{ .tool, .plugin, .builtin, .skill, .mcp_tool };
    catalog.printSummary();
    stdout_print("\n", .{});
    for (kinds) |kind| {
        const entries = try catalog.listByKind(allocator, kind);
        defer allocator.free(entries);

        if (entries.len == 0) continue;

        stdout_print("{s}:\n", .{capabilityKindLabel(kind)});
        for (entries) |entry| {
            const status = if (entry.enabled) "enabled" else "disabled";
            if (entry.source) |source| {
                stdout_print("  - {s} [{s}] — {s} ({s})\n", .{ entry.name, status, entry.description, source });
            } else {
                stdout_print("  - {s} [{s}] — {s}\n", .{ entry.name, status, entry.description });
            }
        }
        stdout_print("\n", .{});
    }
}

pub fn handlePlugin(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var manager = plugin_manager_mod.PluginManager.init(allocator);
    defer manager.deinit();

    try manager.initializeBuiltIns();

    const stdout = file_compat.File.stdout().writer();

    if (args.remaining.len == 0) {
        try stdout.print("Usage: crushcode plugin <list|enable|disable|status> [name]\n", .{});
        return;
    }

    const subcmd = args.remaining[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const plugins = try manager.listPlugins();
        defer allocator.free(plugins);

        if (plugins.len == 0) {
            try stdout.writeAll("No plugins registered\n");
            return;
        }

        for (plugins) |plugin| {
            try stdout.print("{s} - {s} ({s})\n", .{ plugin.name, plugin.description, @tagName(plugin.type) });
        }
        return;
    }

    if (std.mem.eql(u8, subcmd, "enable") or std.mem.eql(u8, subcmd, "disable")) {
        if (args.remaining.len < 2) {
            try stdout.print("Usage: crushcode plugin {s} <name>\n", .{subcmd});
            return;
        }

        const enabled = std.mem.eql(u8, subcmd, "enable");
        const plugin_name = args.remaining[1];
        try manager.setPluginEnabled(plugin_name, enabled);
        try stdout.print("{s} plugin: {s}\n", .{ if (enabled) "Enabled" else "Disabled", plugin_name });
        return;
    }

    if (std.mem.eql(u8, subcmd, "status")) {
        if (args.remaining.len > 1) {
            const plugin_name = args.remaining[1];
            const status = try manager.getPluginStatus(plugin_name);
            try stdout.print("{s}: {s} ({s}) - {s}\n", .{
                status.name,
                if (status.enabled) "enabled" else "disabled",
                @tagName(status.type),
                status.description,
            });
            return;
        }

        const plugins = try manager.listPlugins();
        defer allocator.free(plugins);
        for (plugins) |plugin| {
            const status = try manager.getPluginStatus(plugin.name);
            try stdout.print("{s}: {s}\n", .{ status.name, if (status.enabled) "enabled" else "disabled" });
        }
        return;
    }

    try stdout.print("Unknown plugin subcommand: {s}\n", .{subcmd});
}

fn isRemoteSkillSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "clawhub:") or
        std.mem.startsWith(u8, source, "skills.sh:") or
        std.mem.startsWith(u8, source, "https://github.com/");
}

pub fn handleSkillsLoad(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const source = if (args.remaining.len > 0) args.remaining[0] else "skills";

    if (isRemoteSkillSource(source)) {
        var importer = skill_import_mod.SkillImporter.init(allocator, "skills");
        defer importer.deinit();

        const result = try importer.importSkill(source);
        defer {
            allocator.free(result.name);
            allocator.free(result.install_path);
        }

        skill_import_mod.SkillImporter.printResult(&result);
        return;
    }

    const skills_dir = source;

    var loader = skills_loader_mod.SkillLoader.init(allocator);
    defer loader.deinit();

    loader.loadFromDirectory(skills_dir) catch |err| {
        stdout_print("Error loading skills from '{s}': {}\n", .{ skills_dir, err });
        return;
    };

    const skills = loader.getSkills();

    if (skills.len == 0) {
        stdout_print("No skills found in '{s}'\n", .{skills_dir});
        stdout_print("Create SKILL.md files in subdirectories.\n", .{});
        return;
    }

    stdout_print("Loaded {} skills from '{s}':\n\n", .{ skills.len, skills_dir });

    for (skills) |skill| {
        stdout_print("  {s}", .{skill.name});
        if (skill.description.len > 0) {
            stdout_print(" - {s}", .{skill.description});
        }
        stdout_print("\n", .{});

        if (skill.triggers.len > 0) {
            stdout_print("    Triggers: ", .{});
            for (skill.triggers, 0..) |trigger, i| {
                if (i > 0) stdout_print(", ", .{});
                stdout_print("{s}", .{trigger});
            }
            stdout_print("\n", .{});
        }

        if (skill.tools.len > 0) {
            stdout_print("    Tools: ", .{});
            for (skill.tools, 0..) |tool, i| {
                if (i > 0) stdout_print(", ", .{});
                stdout_print("{s}", .{tool});
            }
            stdout_print("\n", .{});
        }
    }

    stdout_print("\n--- AI Prompt XML Preview ---\n", .{});
    const xml = loader.toPromptXml(std.heap.page_allocator) catch |err| {
        stdout_print("Error generating XML: {}\n", .{err});
        return;
    };
    defer allocator.free(xml);
    stdout_print("{s}\n", .{xml});
}

pub fn handleTools(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var registry = tools_mod.ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerBuiltinTools();

    if (args.remaining.len > 0) {
        const subcmd = args.remaining[0];

        if (std.mem.eql(u8, subcmd, "enable") and args.remaining.len > 1) {
            registry.enable(args.remaining[1]);
            stdout_print("Enabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "disable") and args.remaining.len > 1) {
            registry.disable(args.remaining[1]);
            stdout_print("Disabled tool: {s}\n", .{args.remaining[1]});
            return;
        } else if (std.mem.eql(u8, subcmd, "check") and args.remaining.len > 1) {
            const tool_name = args.remaining[1];
            if (registry.isAvailable(tool_name)) {
                stdout_print("Tool '{s}' is available ✓\n", .{tool_name});
            } else if (registry.get(tool_name) != null) {
                stdout_print("Tool '{s}' is registered but disabled ✗\n", .{tool_name});
            } else {
                stdout_print("Tool '{s}' not found\n", .{tool_name});
            }
            return;
        } else if (std.mem.eql(u8, subcmd, "category") and args.remaining.len > 1) {
            const cat_name = args.remaining[1];
            const category = parseCategory(cat_name) orelse {
                stdout_print("Unknown category: {s}\n", .{cat_name});
                stdout_print("Categories: file_ops, shell, git, network, ai, mcp, system, custom\n", .{});
                return;
            };
            const tools_in_cat = registry.getByCategory(allocator, category) catch return;
            defer allocator.free(tools_in_cat);
            stdout_print("Tools in {s}:\n", .{cat_name});
            for (tools_in_cat) |t| {
                stdout_print("  - {s}\n", .{t});
            }
            return;
        }
    }

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

pub fn handleGrep(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    if (args.remaining.len < 2) {
        stdout_print("Usage: crushcode grep <pattern> <file-or-dir> [--lang <language>]\n", .{});
        stdout_print("\nAST-grep pattern examples:\n", .{});
        stdout_print("  crushcode grep 'console.log($MSG)' src/\n", .{});
        stdout_print("  crushcode grep 'function $NAME(...) {{ ... }}' --lang javascript\n", .{});
        stdout_print("  crushcode grep 'await $FETCH(...)' --lang ts\n", .{});
        return;
    }

    const pattern = args.remaining[0];
    const target = args.remaining[1];

    var language = pattern_search_mod.AstGrep.Language.unknown;
    for (args.remaining, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.remaining.len) {
                language = pattern_search_mod.parseLanguage(args.remaining[i + 1]);
            }
        }
    }

    // Tier 1: Try ast-grep (sg) binary for true AST-aware structural search
    if (trySgCli(allocator, pattern, target, language)) {
        return; // sg succeeded, results already printed
    }

    // Tier 2: Fall back to built-in AstGrep (line-based substring matching)
    var grep = pattern_search_mod.AstGrep.init(allocator, pattern, language);
    const file_exists = std.fs.cwd().statFile(target) catch null;

    if (file_exists != null) {
        const matches = grep.search(target) catch |err| {
            stdout_print("Error searching '{s}': {}\n", .{ target, err });
            return;
        };
        defer {
            for (matches) |m| {
                allocator.free(m.file);
                allocator.free(m.matched_text);
                allocator.free(m.context);
            }
            allocator.free(matches);
        }
        pattern_search_mod.AstGrep.printMatches(matches);
    } else {
        stdout_print("Searching in directory: {s}\n", .{target});
        const matches = grep.searchGlob(target, pattern) catch |err| {
            stdout_print("Error searching directory '{s}': {}\n", .{ target, err });
            return;
        };
        defer {
            for (matches) |m| {
                allocator.free(m.file);
                allocator.free(m.matched_text);
                allocator.free(m.context);
            }
            allocator.free(matches);
        }
        pattern_search_mod.AstGrep.printMatches(matches);
    }
}

/// Try spawning the ast-grep (sg) binary for structural code search.
/// Returns true if sg ran successfully and printed results.
/// Returns false if sg is not installed or failed (caller should fall back).
fn trySgCli(allocator: std.mem.Allocator, pattern: []const u8, target: []const u8, language: pattern_search_mod.AstGrep.Language) bool {
    // Build argv: sg run -p <pattern> --json [-l <lang>] <target>
    // Max 7 args: sg, run, -p<pattern>, --json, -l<lang>, <target>
    var argv_buf: [7][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "sg";
    argc += 1;
    argv_buf[argc] = "run";
    argc += 1;

    const pattern_arg = std.fmt.allocPrint(allocator, "-p{s}", .{pattern}) catch return false;
    argv_buf[argc] = pattern_arg;
    argc += 1;

    argv_buf[argc] = "--json";
    argc += 1;

    // Map AstGrep.Language to sg language names
    if (language != .unknown) {
        const lang_name: []const u8 = switch (language) {
            .javascript => "JavaScript",
            .typescript => "TypeScript",
            .tsx => "Tsx",
            .python => "Python",
            .go => "Go",
            .rust => "Rust",
            .c => "C",
            .cpp => "Cpp",
            .java => "Java",
            .json => "Json",
            .yaml => "Yaml",
            .bash => "Bash",
            .ruby => "Ruby",
            .php => "Php",
            .swift => "Swift",
            .kotlin => "Kotlin",
            .scala => "Scala",
            .solidity => "Solidity",
            .html => "Html",
            .css => "Css",
            .unknown => unreachable,
        };
        const lang_arg = std.fmt.allocPrint(allocator, "-l{s}", .{lang_name}) catch return false;
        argv_buf[argc] = lang_arg;
        argc += 1;
    }

    argv_buf[argc] = target;
    argc += 1;

    const argv = argv_buf[0..argc];

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return false;

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};

    child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024) catch return false;

    const term = child.wait() catch return false;
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |code| @intCast(code),
        else => 99,
    };

    // sg exit 1 = no matches (not error), 2+ = error, 127 = not found
    if (exit_code >= 127) return false;
    if (stdout.items.len == 0) return false;

    // Parse JSON output: array of { "text", "file", "range": { "start": { "line", "column" } } }
    const trimmed = std.mem.trimLeft(u8, stdout.items, " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '[') return false;

    const SgMatch = struct {
        text: []const u8,
        file: []const u8,
        range: struct {
            start: struct {
                line: u32,
                column: u32,
            },
            end: struct {
                line: u32,
                column: u32,
            },
        },
    };

    const parsed = std.json.parseFromSlice([]SgMatch, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    if (parsed.value.len == 0) return false;

    stdout_print("Found {d} AST matches (ast-grep):\n", .{parsed.value.len});
    for (parsed.value) |match_item| {
        const clean_text = std.mem.trim(u8, match_item.text, " \t\n\r");
        // Truncate long lines for readability
        const display_text: []const u8 = if (clean_text.len > 120) clean_text[0..120] else clean_text;
        stdout_print("{s}:{d}:{d}: {s}\n", .{
            match_item.file,
            match_item.range.start.line + 1, // sg uses 0-indexed
            match_item.range.start.column,
            display_text,
        });
    }

    return true;
}
