const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;
const ArrayListMeta = array_list_compat.ArrayList;

// ── TemplateCategory ──────────────────────────────────────────────────────────

pub const TemplateCategory = enum {
    agent,
    skill,
    command,
    hook,
    config,
    pipeline,

    pub fn toString(self: TemplateCategory) []const u8 {
        return switch (self) {
            .agent => "agent",
            .skill => "skill",
            .command => "command",
            .hook => "hook",
            .config => "config",
            .pipeline => "pipeline",
        };
    }

    pub fn fromString(str: []const u8) ?TemplateCategory {
        if (std.mem.eql(u8, str, "agent")) return .agent;
        if (std.mem.eql(u8, str, "skill")) return .skill;
        if (std.mem.eql(u8, str, "command")) return .command;
        if (std.mem.eql(u8, str, "hook")) return .hook;
        if (std.mem.eql(u8, str, "config")) return .config;
        if (std.mem.eql(u8, str, "pipeline")) return .pipeline;
        return null;
    }
};

// ── TemplateMetadata ──────────────────────────────────────────────────────────

pub const TemplateMetadata = struct {
    allocator: Allocator,
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    category: TemplateCategory,
    version: []const u8,
    author: []const u8,
    tags: [][]const u8,
    model_preference: []const u8,
    tools_required: [][]const u8,
    file_path: []const u8,
    is_installed: bool,

    pub fn init(
        allocator: Allocator,
        name: []const u8,
        display_name: []const u8,
        description: []const u8,
        category: TemplateCategory,
        version: []const u8,
        author: []const u8,
        tags: []const []const u8,
        model_preference: []const u8,
        tools_required: []const []const u8,
        file_path: []const u8,
    ) !TemplateMetadata {
        var owned_tags = try ArrayListMeta([]const u8).initCapacity(allocator, tags.len);
        errdefer owned_tags.deinit();
        for (tags) |tag| {
            try owned_tags.append(try allocator.dupe(u8, tag));
        }
        const tags_slice = try owned_tags.toOwnedSlice();

        var owned_tools = try ArrayListMeta([]const u8).initCapacity(allocator, tools_required.len);
        errdefer owned_tools.deinit();
        for (tools_required) |tool| {
            try owned_tools.append(try allocator.dupe(u8, tool));
        }
        const tools_slice = try owned_tools.toOwnedSlice();

        return TemplateMetadata{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .display_name = try allocator.dupe(u8, display_name),
            .description = try allocator.dupe(u8, description),
            .category = category,
            .version = try allocator.dupe(u8, version),
            .author = try allocator.dupe(u8, author),
            .tags = tags_slice,
            .model_preference = try allocator.dupe(u8, model_preference),
            .tools_required = tools_slice,
            .file_path = try allocator.dupe(u8, file_path),
            .is_installed = false,
        };
    }

    pub fn deinit(self: *const TemplateMetadata) void {
        const alloc = self.allocator;
        alloc.free(self.name);
        alloc.free(self.display_name);
        alloc.free(self.description);
        alloc.free(self.version);
        alloc.free(self.author);
        for (self.tags) |tag| alloc.free(tag);
        alloc.free(self.tags);
        alloc.free(self.model_preference);
        for (self.tools_required) |tool| alloc.free(tool);
        alloc.free(self.tools_required);
        alloc.free(self.file_path);
    }

    /// Check if this template matches a search query (substring match on name, description, tags).
    pub fn matchesQuery(self: *const TemplateMetadata, query: []const u8) bool {
        const lower_query = std.ascii.allocLowerString(self.allocator, query) catch return false;
        defer self.allocator.free(lower_query);
        const lower_name = std.ascii.allocLowerString(self.allocator, self.name) catch return false;
        defer self.allocator.free(lower_name);
        const lower_desc = std.ascii.allocLowerString(self.allocator, self.description) catch return false;
        defer self.allocator.free(lower_desc);

        if (std.mem.indexOf(u8, lower_name, lower_query) != null) return true;
        if (std.mem.indexOf(u8, lower_desc, lower_query) != null) return true;
        for (self.tags) |tag| {
            const lower_tag = std.ascii.allocLowerString(self.allocator, tag) catch continue;
            defer self.allocator.free(lower_tag);
            if (std.mem.indexOf(u8, lower_tag, lower_query) != null) return true;
        }
        return false;
    }
};

// ── TemplateRegistry ──────────────────────────────────────────────────────────

pub const TemplateRegistry = struct {
    allocator: Allocator,
    templates: ArrayListMeta(*TemplateMetadata),
    installed_dir: []const u8,
    builtin_dir: []const u8,

    pub fn init(allocator: Allocator, installed_dir: []const u8) !TemplateRegistry {
        return TemplateRegistry{
            .allocator = allocator,
            .templates = ArrayListMeta(*TemplateMetadata).init(allocator),
            .installed_dir = try allocator.dupe(u8, installed_dir),
            .builtin_dir = try allocator.dupe(u8, ".crushcode/builtin/"),
        };
    }

    pub fn deinit(self: *TemplateRegistry) void {
        for (self.templates.items) |tmpl| {
            tmpl.deinit();
            self.allocator.destroy(tmpl);
        }
        self.templates.deinit();
        self.allocator.free(self.installed_dir);
        self.allocator.free(self.builtin_dir);
    }

    /// Register all 8 built-in templates.
    pub fn registerDefaults(self: *TemplateRegistry) !void {
        // 1. code-review — agent template for code review
        try self.registerTemplate(
            "code-review",
            "Code Review Agent",
            "AI agent template for automated code review with security and quality checks",
            .agent,
            "1.0.0",
            "crushcode",
            &.{ "review", "quality", "security", "code-review" },
            "opus",
            &.{ "read", "grep" },
            "agents/code-review.md",
        );

        // 2. test-writer — agent template for writing tests
        try self.registerTemplate(
            "test-writer",
            "Test Writer Agent",
            "AI agent template for generating comprehensive unit and integration tests",
            .agent,
            "1.0.0",
            "crushcode",
            &.{ "testing", "tdd", "unit-test", "integration" },
            "sonnet",
            &.{ "read", "write", "edit" },
            "agents/test-writer.md",
        );

        // 3. refactor — pipeline template for refactoring
        try self.registerTemplate(
            "refactor",
            "Refactoring Pipeline",
            "Multi-phase pipeline template for safe code refactoring with validation",
            .pipeline,
            "1.0.0",
            "crushcode",
            &.{ "refactor", "cleanup", "architecture", "pipeline" },
            "sonnet",
            &.{ "read", "write", "edit", "grep" },
            "pipelines/refactor.md",
        );

        // 4. security-scan — hook template for pre-edit security checks
        try self.registerTemplate(
            "security-scan",
            "Security Scan Hook",
            "Pre-edit hook template that scans for security vulnerabilities before changes",
            .hook,
            "1.0.0",
            "crushcode",
            &.{ "security", "vulnerability", "audit", "hook" },
            "",
            &.{ "read", "grep" },
            "hooks/security-scan.md",
        );

        // 5. commit-helper — command template for generating commit messages
        try self.registerTemplate(
            "commit-helper",
            "Commit Helper Command",
            "Command template for generating conventional commit messages from staged changes",
            .command,
            "1.0.0",
            "crushcode",
            &.{ "commit", "git", "conventional", "message" },
            "sonnet",
            &.{ "shell", "read" },
            "commands/commit-helper.md",
        );

        // 6. project-setup — config template for new project initialization
        try self.registerTemplate(
            "project-setup",
            "Project Setup Config",
            "Configuration template for initializing new project with best practices",
            .config,
            "1.0.0",
            "crushcode",
            &.{ "setup", "init", "project", "config" },
            "",
            &.{ "write", "shell" },
            "configs/project-setup.md",
        );

        // 7. knowledge-ingest — skill template for knowledge base ingestion
        try self.registerTemplate(
            "knowledge-ingest",
            "Knowledge Ingest Skill",
            "Skill template for ingesting documentation into the knowledge base",
            .skill,
            "1.0.0",
            "crushcode",
            &.{ "knowledge", "ingest", "documentation", "skill" },
            "sonnet",
            &.{ "read", "grep" },
            "skills/knowledge-ingest.md",
        );

        // 8. doc-writer — agent template for documentation generation
        try self.registerTemplate(
            "doc-writer",
            "Documentation Writer Agent",
            "AI agent template for generating and updating project documentation",
            .agent,
            "1.0.0",
            "crushcode",
            &.{ "documentation", "docs", "readme", "api-docs" },
            "sonnet",
            &.{ "read", "write" },
            "agents/doc-writer.md",
        );
    }

    /// Register a single template by creating its metadata and adding to the list.
    pub fn registerTemplate(
        self: *TemplateRegistry,
        name: []const u8,
        display_name: []const u8,
        description: []const u8,
        category: TemplateCategory,
        version: []const u8,
        author: []const u8,
        tags: []const []const u8,
        model_preference: []const u8,
        tools_required: []const []const u8,
        file_path: []const u8,
    ) !void {
        const meta = try self.allocator.create(TemplateMetadata);
        errdefer self.allocator.destroy(meta);
        meta.* = try TemplateMetadata.init(
            self.allocator,
            name,
            display_name,
            description,
            category,
            version,
            author,
            tags,
            model_preference,
            tools_required,
            file_path,
        );
        try self.templates.append(meta);
    }

    /// Find a template by exact name match.
    pub fn findByName(self: *TemplateRegistry, name: []const u8) ?*TemplateMetadata {
        for (self.templates.items) |tmpl| {
            if (std.mem.eql(u8, tmpl.name, name)) return tmpl;
        }
        return null;
    }

    /// Search templates by keyword — matches against name, description, and tags.
    pub fn search(self: *TemplateRegistry, query: []const u8) ![]*TemplateMetadata {
        var results = ArrayListMeta(*TemplateMetadata).init(self.allocator);
        for (self.templates.items) |tmpl| {
            if (tmpl.matchesQuery(query)) {
                try results.append(tmpl);
            }
        }
        return results.toOwnedSlice();
    }

    /// Find templates by category.
    pub fn findByCategory(self: *TemplateRegistry, category: TemplateCategory) ![]*TemplateMetadata {
        var results = ArrayListMeta(*TemplateMetadata).init(self.allocator);
        for (self.templates.items) |tmpl| {
            if (tmpl.category == category) {
                try results.append(tmpl);
            }
        }
        return results.toOwnedSlice();
    }

    /// Install a template by copying its content to the installed_dir.
    pub fn install(self: *TemplateRegistry, name: []const u8) !void {
        const tmpl = self.findByName(name) orelse return error.TemplateNotFound;

        // Create installed directory if needed
        std.fs.cwd().makePath(self.installed_dir) catch {};

        // Build installed file path
        const installed_file = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}.md",
            .{ self.installed_dir, tmpl.name },
        );
        defer self.allocator.free(installed_file);

        // Write template content placeholder
        const content = try std.fmt.allocPrint(
            self.allocator,
            \\# {s}
            \\
            \\Category: {s}
            \\Version: {s}
            \\Author: {s}
            \\Model: {s}
            \\
            \\{s}
            \\
        ,
            .{
                tmpl.display_name,
                tmpl.category.toString(),
                tmpl.version,
                tmpl.author,
                tmpl.model_preference,
                tmpl.description,
            },
        );
        defer self.allocator.free(content);

        const file = std.fs.cwd().createFile(installed_file, .{}) catch |err| {
            return err;
        };
        defer file.close();
        try file.writeAll(content);

        // Write metadata JSON alongside
        const meta_file = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}.json",
            .{ self.installed_dir, tmpl.name },
        );
        defer self.allocator.free(meta_file);

        var tags_str = ArrayListMeta(u8).init(self.allocator);
        defer tags_str.deinit();
        try tags_str.appendSlice("[");
        for (tmpl.tags, 0..) |tag, i| {
            if (i > 0) try tags_str.appendSlice(", ");
            try tags_str.appendSlice("\"");
            try tags_str.appendSlice(tag);
            try tags_str.appendSlice("\"");
        }
        try tags_str.appendSlice("]");

        var tools_str = ArrayListMeta(u8).init(self.allocator);
        defer tools_str.deinit();
        try tools_str.appendSlice("[");
        for (tmpl.tools_required, 0..) |tool, i| {
            if (i > 0) try tools_str.appendSlice(", ");
            try tools_str.appendSlice("\"");
            try tools_str.appendSlice(tool);
            try tools_str.appendSlice("\"");
        }
        try tools_str.appendSlice("]");

        const meta_content = try std.fmt.allocPrint(
            self.allocator,
            \\{{"name":"{s}","display_name":"{s}","description":"{s}","category":"{s}","version":"{s}","author":"{s}","tags":{s},"model_preference":"{s}","tools_required":{s}}}
        ,
            .{
                tmpl.name,
                tmpl.display_name,
                tmpl.description,
                tmpl.category.toString(),
                tmpl.version,
                tmpl.author,
                tags_str.items,
                tmpl.model_preference,
                tools_str.items,
            },
        );
        defer self.allocator.free(meta_content);

        const mfile = std.fs.cwd().createFile(meta_file, .{}) catch |err| {
            return err;
        };
        defer mfile.close();
        try mfile.writeAll(meta_content);

        tmpl.is_installed = true;
    }

    /// Uninstall a template by removing its files from installed_dir.
    pub fn uninstall(self: *TemplateRegistry, name: []const u8) !void {
        const tmpl = self.findByName(name) orelse return error.TemplateNotFound;

        const installed_file = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}.md",
            .{ self.installed_dir, tmpl.name },
        );
        defer self.allocator.free(installed_file);

        std.fs.cwd().deleteFile(installed_file) catch {};

        const meta_file = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}.json",
            .{ self.installed_dir, tmpl.name },
        );
        defer self.allocator.free(meta_file);

        std.fs.cwd().deleteFile(meta_file) catch {};

        tmpl.is_installed = false;
    }

    /// Check if a template is installed by name.
    pub fn isInstalled(self: *TemplateRegistry, name: []const u8) bool {
        const tmpl = self.findByName(name) orelse return false;
        return tmpl.is_installed;
    }

    /// List all installed templates.
    pub fn listInstalled(self: *TemplateRegistry) ![]*TemplateMetadata {
        var results = ArrayListMeta(*TemplateMetadata).init(self.allocator);
        for (self.templates.items) |tmpl| {
            if (tmpl.is_installed) {
                try results.append(tmpl);
            }
        }
        return results.toOwnedSlice();
    }

    /// List all registered templates.
    pub fn listAll(self: *TemplateRegistry) []*TemplateMetadata {
        return self.templates.items;
    }

    /// Get formatted info string for a template.
    pub fn getInfo(self: *TemplateRegistry, name: []const u8) ![]const u8 {
        const tmpl = self.findByName(name) orelse return error.TemplateNotFound;

        // Build tags string
        var tags_buf = ArrayListMeta(u8).init(self.allocator);
        defer tags_buf.deinit();
        for (tmpl.tags, 0..) |tag, i| {
            if (i > 0) try tags_buf.appendSlice(", ");
            try tags_buf.appendSlice(tag);
        }

        // Build tools string
        var tools_buf = ArrayListMeta(u8).init(self.allocator);
        defer tools_buf.deinit();
        for (tmpl.tools_required, 0..) |tool, i| {
            if (i > 0) try tools_buf.appendSlice(", ");
            try tools_buf.appendSlice(tool);
        }

        const installed_str: []const u8 = if (tmpl.is_installed) "yes" else "no";

        return std.fmt.allocPrint(self.allocator,
            \\Name:     {s}
            \\Title:    {s}
            \\Desc:     {s}
            \\Category: {s}
            \\Version:  {s}
            \\Author:   {s}
            \\Model:    {s}
            \\Tags:     {s}
            \\Tools:    {s}
            \\File:     {s}
            \\Installed: {s}
        , .{
            tmpl.name,
            tmpl.display_name,
            tmpl.description,
            tmpl.category.toString(),
            tmpl.version,
            tmpl.author,
            tmpl.model_preference,
            tags_buf.items,
            tools_buf.items,
            tmpl.file_path,
            installed_str,
        });
    }

    /// Export a template to a specified output path.
    pub fn exportTemplate(self: *TemplateRegistry, name: []const u8, output_path: []const u8) !void {
        // Verify template exists
        _ = self.findByName(name) orelse return error.TemplateNotFound;

        const info_str = try self.getInfo(name);
        defer self.allocator.free(info_str);

        const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
            return err;
        };
        defer file.close();
        try file.writeAll(info_str);
    }
};

// ── CLI Handler ───────────────────────────────────────────────────────────────

pub fn handleTemplate(args: []const []const u8) !void {
    const allocator = std.heap.page_allocator;
    const stdout = file_compat.File.stdout().writer();

    if (args.len == 0) {
        stdout.print("Usage: crushcode template <list|info|install|uninstall|search> [args]\n\n", .{}) catch {};
        stdout.print("Commands:\n", .{}) catch {};
        stdout.print("  list [--category <cat>]   List all templates\n", .{}) catch {};
        stdout.print("  info <name>               Show template details\n", .{}) catch {};
        stdout.print("  install <name>            Install a template\n", .{}) catch {};
        stdout.print("  uninstall <name>          Remove installed template\n", .{}) catch {};
        stdout.print("  search <query>            Search templates by keyword\n", .{}) catch {};
        return;
    }

    const subcmd = args[0];

    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    if (std.mem.eql(u8, subcmd, "list")) {
        // Check for --category filter
        var category_filter: ?TemplateCategory = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--category") or std.mem.eql(u8, args[i], "-c")) {
                if (i + 1 < args.len) {
                    category_filter = TemplateCategory.fromString(args[i + 1]);
                    i += 1;
                }
            }
        }

        const templates = registry.listAll();
        stdout.print("\nAvailable Templates ({d} total):\n", .{templates.len}) catch {};
        stdout.print("{s}\n", .{"────────────────────────────────────────────────────────────"}) catch {};

        for (templates) |tmpl| {
            if (category_filter) |cf| {
                if (tmpl.category != cf) continue;
            }
            const installed_marker = if (tmpl.is_installed) " [installed]" else "";
            stdout.print("  {s} - {s} ({s}){s}\n", .{
                tmpl.name,
                tmpl.display_name,
                tmpl.category.toString(),
                installed_marker,
            }) catch {};
        }
        stdout.print("\n", .{}) catch {};
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (args.len < 2) {
            stdout.print("Usage: crushcode template info <name>\n", .{}) catch {};
            return;
        }
        const info_str = registry.getInfo(args[1]) catch |err| {
            stdout.print("Template '{s}' not found: {}\n", .{ args[1], err }) catch {};
            return;
        };
        defer allocator.free(info_str);
        stdout.print("\n{s}\n\n", .{info_str}) catch {};
    } else if (std.mem.eql(u8, subcmd, "install")) {
        if (args.len < 2) {
            stdout.print("Usage: crushcode template install <name>\n", .{}) catch {};
            return;
        }
        registry.install(args[1]) catch |err| {
            stdout.print("Failed to install template '{s}': {}\n", .{ args[1], err }) catch {};
            return;
        };
        stdout.print("Template '{s}' installed successfully.\n", .{args[1]}) catch {};
    } else if (std.mem.eql(u8, subcmd, "uninstall")) {
        if (args.len < 2) {
            stdout.print("Usage: crushcode template uninstall <name>\n", .{}) catch {};
            return;
        }
        registry.uninstall(args[1]) catch |err| {
            stdout.print("Failed to uninstall template '{s}': {}\n", .{ args[1], err }) catch {};
            return;
        };
        stdout.print("Template '{s}' uninstalled successfully.\n", .{args[1]}) catch {};
    } else if (std.mem.eql(u8, subcmd, "search")) {
        if (args.len < 2) {
            stdout.print("Usage: crushcode template search <query>\n", .{}) catch {};
            return;
        }
        const results = registry.search(args[1]) catch |err| {
            stdout.print("Search failed: {}\n", .{err}) catch {};
            return;
        };
        defer allocator.free(results);

        stdout.print("\nSearch results for '{s}' ({d} found):\n", .{ args[1], results.len }) catch {};
        stdout.print("{s}\n", .{"────────────────────────────────────────────────────────────"}) catch {};
        for (results) |tmpl| {
            stdout.print("  {s} - {s} ({s})\n", .{
                tmpl.name,
                tmpl.description,
                tmpl.category.toString(),
            }) catch {};
        }
        stdout.print("\n", .{}) catch {};
    } else {
        stdout.print("Unknown subcommand: {s}\n", .{subcmd}) catch {};
        stdout.print("Use: crushcode template <list|info|install|uninstall|search>\n", .{}) catch {};
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TemplateMetadata creation and deinit" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{ "review", "quality" };
    const tools = [_][]const u8{ "read", "grep" };

    var meta = try TemplateMetadata.init(
        allocator,
        "test-template",
        "Test Template",
        "A test template for unit tests",
        .agent,
        "1.0.0",
        "tester",
        &tags,
        "sonnet",
        &tools,
        "test/path.md",
    );
    defer meta.deinit();

    try std.testing.expectEqualStrings("test-template", meta.name);
    try std.testing.expectEqualStrings("Test Template", meta.display_name);
    try std.testing.expectEqualStrings("A test template for unit tests", meta.description);
    try std.testing.expect(meta.category == .agent);
    try std.testing.expectEqualStrings("1.0.0", meta.version);
    try std.testing.expectEqualStrings("tester", meta.author);
    try std.testing.expectEqualStrings("sonnet", meta.model_preference);
    try std.testing.expectEqualStrings("test/path.md", meta.file_path);
    try std.testing.expect(!meta.is_installed);
    try std.testing.expectEqual(@as(usize, 2), meta.tags.len);
    try std.testing.expectEqual(@as(usize, 2), meta.tools_required.len);
}

test "Registry with defaults (8 templates)" {
    const allocator = std.testing.allocator;
    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    const all = registry.listAll();
    try std.testing.expectEqual(@as(usize, 8), all.len);
}

test "Find by name" {
    const allocator = std.testing.allocator;
    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    const found = registry.findByName("code-review");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Code Review Agent", found.?.display_name);
    try std.testing.expect(found.?.category == .agent);

    const not_found = registry.findByName("nonexistent");
    try std.testing.expect(not_found == null);
}

test "Search by keyword" {
    const allocator = std.testing.allocator;
    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    // Search for "review" — should match code-review
    const results = try registry.search("review");
    defer allocator.free(results);
    try std.testing.expect(results.len >= 1);

    var found_code_review = false;
    for (results) |tmpl| {
        if (std.mem.eql(u8, tmpl.name, "code-review")) found_code_review = true;
    }
    try std.testing.expect(found_code_review);
}

test "Filter by category" {
    const allocator = std.testing.allocator;
    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    const agents = try registry.findByCategory(.agent);
    defer allocator.free(agents);
    // code-review, test-writer, doc-writer = 3 agents
    try std.testing.expectEqual(@as(usize, 3), agents.len);

    const hooks = try registry.findByCategory(.hook);
    defer allocator.free(hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.len);

    const pipelines = try registry.findByCategory(.pipeline);
    defer allocator.free(pipelines);
    try std.testing.expectEqual(@as(usize, 1), pipelines.len);
}

test "Install and isInstalled" {
    const allocator = std.testing.allocator;
    const test_dir = ".crushcode/test-templates-install/";

    var registry = try TemplateRegistry.init(allocator, test_dir);
    defer registry.deinit();
    try registry.registerDefaults();

    // Before install
    try std.testing.expect(!registry.isInstalled("commit-helper"));

    // Install
    try registry.install("commit-helper");
    try std.testing.expect(registry.isInstalled("commit-helper"));

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "Uninstall" {
    const allocator = std.testing.allocator;
    const test_dir = ".crushcode/test-templates-uninstall/";

    var registry = try TemplateRegistry.init(allocator, test_dir);
    defer registry.deinit();
    try registry.registerDefaults();

    // Install then uninstall
    try registry.install("commit-helper");
    try std.testing.expect(registry.isInstalled("commit-helper"));

    try registry.uninstall("commit-helper");
    try std.testing.expect(!registry.isInstalled("commit-helper"));

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "List installed" {
    const allocator = std.testing.allocator;
    const test_dir = ".crushcode/test-templates-list/";

    var registry = try TemplateRegistry.init(allocator, test_dir);
    defer registry.deinit();
    try registry.registerDefaults();

    // Nothing installed initially
    var installed = try registry.listInstalled();
    allocator.free(installed);
    try std.testing.expectEqual(@as(usize, 0), installed.len);

    // Install two templates
    try registry.install("code-review");
    try registry.install("doc-writer");

    installed = try registry.listInstalled();
    defer allocator.free(installed);
    try std.testing.expectEqual(@as(usize, 2), installed.len);

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}

test "Get info formatting" {
    const allocator = std.testing.allocator;
    var registry = try TemplateRegistry.init(allocator, ".crushcode/templates/");
    defer registry.deinit();
    try registry.registerDefaults();

    const info = try registry.getInfo("code-review");
    defer allocator.free(info);

    // Verify key fields appear in output
    try std.testing.expect(std.mem.indexOf(u8, info, "code-review") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Code Review Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "opus") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "crushcode") != null);
}

test "TemplateCategory toString and fromString" {
    try std.testing.expectEqualStrings("agent", TemplateCategory.agent.toString());
    try std.testing.expectEqualStrings("skill", TemplateCategory.skill.toString());
    try std.testing.expectEqualStrings("pipeline", TemplateCategory.pipeline.toString());

    try std.testing.expect(TemplateCategory.fromString("agent") == .agent);
    try std.testing.expect(TemplateCategory.fromString("hook") == .hook);
    try std.testing.expect(TemplateCategory.fromString("nonexistent") == null);
}

test "matchesQuery on metadata" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{ "review", "quality", "security" };
    const tools = [_][]const u8{"read"};

    var meta = try TemplateMetadata.init(
        allocator,
        "code-review",
        "Code Review",
        "Automated code review agent",
        .agent,
        "1.0.0",
        "tester",
        &tags,
        "opus",
        &tools,
        "test.md",
    );
    defer meta.deinit();

    try std.testing.expect(meta.matchesQuery("code-review"));
    try std.testing.expect(meta.matchesQuery("CODE-REVIEW"));
    try std.testing.expect(meta.matchesQuery("review"));
    try std.testing.expect(meta.matchesQuery("security"));
    try std.testing.expect(meta.matchesQuery("automated"));
    try std.testing.expect(!meta.matchesQuery("nonexistent-xyz"));
}
