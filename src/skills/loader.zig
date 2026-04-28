const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const skills_resolver = @import("skills_resolver");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

const Allocator = std.mem.Allocator;

/// Skill definition loaded from SKILL.md
pub const Skill = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    triggers: [][]const u8,
    tools: [][]const u8,
    prompt: []const u8,
    file_path: []const u8,

    pub fn deinit(self: *Skill) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.prompt);
        self.allocator.free(self.file_path);
        for (self.triggers) |t| self.allocator.free(t);
        self.allocator.free(self.triggers);
        for (self.tools) |t| self.allocator.free(t);
        self.allocator.free(self.tools);
    }
};

/// Skill loader that discovers and parses SKILL.md files
pub const SkillLoader = struct {
    allocator: Allocator,
    skills: array_list_compat.ArrayList(Skill),

    pub fn init(allocator: Allocator) SkillLoader {
        return SkillLoader{
            .allocator = allocator,
            .skills = array_list_compat.ArrayList(Skill).init(allocator),
        };
    }

    pub fn deinit(self: *SkillLoader) void {
        for (self.skills.items) |*skill| {
            skill.deinit();
        }
        self.skills.deinit();
    }

    /// Discover and load all SKILL.md files from a directory
    pub fn loadFromDirectory(self: *SkillLoader, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const basename = entry.basename;
            const is_skill_file = std.mem.eql(u8, basename, "SKILL.md") or
                std.mem.endsWith(u8, basename, ".skill.md") or
                std.mem.eql(u8, basename, "Alloy.md") or
                std.mem.endsWith(u8, basename, ".alloy.md");

            if (!is_skill_file) continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
            errdefer self.allocator.free(full_path);

            const skill = self.parseSkillFile(full_path) catch |err| {
                out("Warning: Failed to parse skill {s}: {}\n", .{ full_path, err });
                self.allocator.free(full_path);
                continue;
            };

            try self.skills.append(skill);
        }
    }

    /// Parse a single SKILL.md file
    fn parseSkillFile(self: *SkillLoader, path: []const u8) !Skill {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return error.EmptyFile;

        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read == 0) return error.EmptyFile;

        const content = buffer[0..bytes_read];

        const split = splitFrontmatter(content);

        var skill = Skill{
            .allocator = self.allocator,
            .name = "",
            .description = "",
            .triggers = &[_][]const u8{},
            .tools = &[_][]const u8{},
            .prompt = "",
            .file_path = try self.allocator.dupe(u8, path),
        };

        if (split.yaml.len > 0) {
            try self.parseYamlFields(split.yaml, &skill);
        }

        if (skill.prompt.len == 0 and split.body.len > 0) {
            skill.prompt = try self.allocator.dupe(u8, std.mem.trim(u8, split.body, " \t\r\n"));
        }

        if (skill.name.len == 0) {
            const basename = std.fs.path.basename(path);
            if (std.mem.endsWith(u8, basename, ".skill.md")) {
                skill.name = try self.allocator.dupe(u8, basename[0 .. basename.len - ".skill.md".len]);
            } else if (std.mem.endsWith(u8, basename, ".alloy.md")) {
                skill.name = try self.allocator.dupe(u8, basename[0 .. basename.len - ".alloy.md".len]);
            } else if (std.mem.eql(u8, basename, "SKILL.md") or std.mem.eql(u8, basename, "Alloy.md")) {
                const parent = std.fs.path.dirname(path) orelse ".";
                skill.name = try self.allocator.dupe(u8, std.fs.path.basename(parent));
            } else {
                skill.name = try self.allocator.dupe(u8, basename);
            }
        }

        return skill;
    }

    /// Parse simple YAML key: value pairs
    fn parseYamlFields(self: *SkillLoader, yaml: []const u8, skill: *Skill) !void {
        var line_iter = std.mem.splitScalar(u8, yaml, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\"'");

                if (value.len == 0) continue;

                if (std.mem.eql(u8, key, "name")) {
                    skill.name = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    skill.description = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "prompt")) {
                    skill.prompt = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "triggers")) {
                    skill.triggers = try self.parseCommaList(value);
                } else if (std.mem.eql(u8, key, "tools")) {
                    skill.tools = try self.parseCommaList(value);
                }
            }
        }
    }

    /// Parse comma-separated list
    fn parseCommaList(self: *SkillLoader, value: []const u8) ![][]const u8 {
        var items = array_list_compat.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (items.items) |item| self.allocator.free(item);
            items.deinit();
        }

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t\"'[]");
            if (trimmed.len == 0) continue;
            try items.append(try self.allocator.dupe(u8, trimmed));
        }

        return items.toOwnedSlice();
    }

    /// Get loaded skills
    pub fn getSkills(self: *SkillLoader) []const Skill {
        return self.skills.items;
    }

    /// Find skill by name
    pub fn findSkill(self: *SkillLoader, name: []const u8) ?*const Skill {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) {
                return skill;
            }
        }
        return null;
    }

    /// Find skill by trigger
    pub fn findSkillByTrigger(self: *SkillLoader, trigger: []const u8) ?*const Skill {
        for (self.skills.items) |*skill| {
            for (skill.triggers) |t| {
                if (std.mem.eql(u8, t, trigger)) {
                    return skill;
                }
            }
        }
        return null;
    }

    /// Generate XML for AI prompts
    pub fn toPromptXml(self: *SkillLoader, allocator: Allocator) ![]u8 {
        var output = array_list_compat.ArrayList(u8).init(allocator);
        const writer = output.writer();

        try writer.writeAll("<available_skills>\n");

        for (self.skills.items) |skill| {
            try writer.print("  <skill name=\"{s}\">\n", .{skill.name});
            if (skill.description.len > 0) {
                try writer.print("    <description>{s}</description>\n", .{skill.description});
            }
            if (skill.triggers.len > 0) {
                try writer.writeAll("    <triggers>");
                for (skill.triggers, 0..) |trigger, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(trigger);
                }
                try writer.writeAll("</triggers>\n");
            }
            if (skill.tools.len > 0) {
                try writer.writeAll("    <tools>");
                for (skill.tools, 0..) |tool, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(tool);
                }
                try writer.writeAll("</tools>\n");
            }
            if (skill.prompt.len > 0) {
                try writer.print("    <prompt>{s}</prompt>\n", .{skill.prompt});
            }
            try writer.writeAll("  </skill>\n");
        }

        try writer.writeAll("</available_skills>");

        return output.toOwnedSlice();
    }

    /// Print loaded skills summary
    pub fn printSummary(self: *SkillLoader) void {
        out("Loaded {} skills:\n", .{self.skills.items.len});
        for (self.skills.items) |skill| {
            out("  - {s}: {s}\n", .{ skill.name, skill.description });
        }
    }

    /// Load a skill from a resolver resolution (resolved SKILL.md path)
    pub fn loadFromResolver(self: *SkillLoader, resolution: skills_resolver.SkillResolution) !*Skill {
        if (resolution.skill_path.len == 0) return error.SkillPathEmpty;

        const skill = try self.parseSkillFile(resolution.skill_path);
        try self.skills.append(skill);
        return &self.skills.items[self.skills.items.len - 1];
    }

    /// Resolve and load skills matching a file path and/or query context.
    /// Uses the resolver to find relevant skills, then loads matched SKILL.md files.
    pub fn resolveAndLoad(self: *SkillLoader, resolver: *skills_resolver.SkillResolver, file_path: []const u8, query: []const u8) ![]*Skill {
        const resolutions = try resolver.resolveForContext(file_path, query);
        defer {
            for (resolutions) |*r| r.deinit(self.allocator);
            self.allocator.free(resolutions);
        }

        var loaded = array_list_compat.ArrayList(*Skill).init(self.allocator);
        errdefer loaded.deinit();

        for (resolutions) |res| {
            if (res.skill_path.len == 0) continue;

            // Check if already loaded (dedup by path)
            var already_loaded = false;
            for (self.skills.items) |existing| {
                if (std.mem.eql(u8, existing.file_path, res.skill_path)) {
                    already_loaded = true;
                    try loaded.append(&self.skills.items[
                        std.mem.indexOfScalar(Skill, self.skills.items, existing) orelse 0
                    ]);
                    break;
                }
            }
            if (already_loaded) continue;

            const skill = self.parseSkillFile(res.skill_path) catch |err| {
                out("Warning: Failed to load resolved skill {s}: {}\n", .{ res.skill_path, err });
                continue;
            };
            try self.skills.append(skill);
            try loaded.append(&self.skills.items[self.skills.items.len - 1]);
        }

        return loaded.toOwnedSlice();
    }
};

// ============================================================
// Standalone SkillMetadata — lightweight frontmatter-only parsing
// ============================================================

/// Lightweight metadata extracted from SKILL.md frontmatter.
/// Used by skill discovery without loading the full Skill struct.
pub const SkillMetadata = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    triggers: [][]const u8,
    tools: [][]const u8,
    scope: []const u8,
    content: []const u8,

    pub fn deinit(self: *SkillMetadata) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.scope);
        self.allocator.free(self.content);
        for (self.triggers) |t| self.allocator.free(t);
        self.allocator.free(self.triggers);
        for (self.tools) |t| self.allocator.free(t);
        self.allocator.free(self.tools);
    }
};

/// Parse a SKILL.md content string into a SkillMetadata.
/// Returns null if the content does not contain valid frontmatter.
pub fn parseSkillMd(allocator: Allocator, content: []const u8) !?SkillMetadata {
    const split = splitFrontmatter(content);
    if (split.yaml.len == 0) return null;

    var meta = SkillMetadata{
        .allocator = allocator,
        .name = "",
        .description = "",
        .triggers = &[_][]const u8{},
        .tools = &[_][]const u8{},
        .scope = "",
        .content = "",
    };

    // Parse YAML key: value pairs
    var line_iter = std.mem.splitScalar(u8, split.yaml, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\"'");
            if (value.len == 0) continue;

            if (std.mem.eql(u8, key, "name")) {
                meta.name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "description")) {
                meta.description = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "triggers")) {
                meta.triggers = try parseCommaListStandalone(allocator, value);
            } else if (std.mem.eql(u8, key, "tools")) {
                meta.tools = try parseCommaListStandalone(allocator, value);
            } else if (std.mem.eql(u8, key, "scope")) {
                meta.scope = try allocator.dupe(u8, value);
            }
        }
    }

    // Body content after frontmatter
    if (split.body.len > 0) {
        meta.content = try allocator.dupe(u8, split.body);
    }

    return meta;
}

/// Walk a directory for SKILL.md or *.skill.md files and parse them into metadata.
pub fn loadSkillsFromDirectory(allocator: Allocator, dir_path: []const u8) ![]SkillMetadata {
    var results = array_list_compat.ArrayList(SkillMetadata).init(allocator);
    errdefer {
        for (results.items) |*m| m.deinit();
        results.deinit();
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return &[_]SkillMetadata{};
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const basename = entry.basename;
        const is_skill_file = std.mem.eql(u8, basename, "SKILL.md") or
            std.mem.endsWith(u8, basename, ".skill.md") or
            std.mem.eql(u8, basename, "Alloy.md") or
            std.mem.endsWith(u8, basename, ".alloy.md");
        if (!is_skill_file) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
        errdefer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer file.close();

        const file_size = file.getEndPos() catch {
            allocator.free(full_path);
            continue;
        };
        if (file_size == 0) {
            allocator.free(full_path);
            continue;
        }

        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        const bytes_read = file.readAll(buffer) catch {
            allocator.free(full_path);
            continue;
        };

        const meta = try parseSkillMd(allocator, buffer[0..bytes_read]) orelse {
            allocator.free(full_path);
            continue;
        };

        // Use filename as fallback name
        var owned = meta;
        if (owned.name.len == 0) {
            if (std.mem.endsWith(u8, basename, ".skill.md")) {
                owned.name = try allocator.dupe(u8, basename[0 .. basename.len - ".skill.md".len]);
            } else if (std.mem.endsWith(u8, basename, ".alloy.md")) {
                owned.name = try allocator.dupe(u8, basename[0 .. basename.len - ".alloy.md".len]);
            } else {
                owned.name = try allocator.dupe(u8, basename);
            }
        }

        allocator.free(full_path);
        try results.append(owned);
    }

    return results.toOwnedSlice();
}

/// Parse comma-separated list (standalone, no SkillLoader needed).
fn parseCommaListStandalone(allocator: Allocator, value: []const u8) ![][]const u8 {
    var items = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit();
    }

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\"'[]");
        if (trimmed.len == 0) continue;
        try items.append(try allocator.dupe(u8, trimmed));
    }

    return items.toOwnedSlice();
}

/// Split YAML frontmatter from markdown body
fn splitFrontmatter(content: []const u8) struct { yaml: []const u8, body: []const u8 } {
    if (content.len < 4 or !std.mem.startsWith(u8, content, "---")) {
        return .{ .yaml = "", .body = content };
    }

    const after_first = content[3..];
    const closing = std.mem.indexOf(u8, after_first, "\n---") orelse
        return .{ .yaml = "", .body = content };

    const yaml_content = std.mem.trim(u8, after_first[0..closing], " \t\r\n");
    const body_start = closing + 4;
    const body = if (body_start < content.len)
        std.mem.trim(u8, content[body_start..], " \t\r\n")
    else
        "";

    return .{ .yaml = yaml_content, .body = body };
}

test "splitFrontmatter - with YAML" {
    const content =
        \\---
        \\name: code-review
        \\description: Review code
        \\---
        \\This is the prompt body.
    ;

    const result = splitFrontmatter(content);
    try std.testing.expect(result.yaml.len > 0);
    try std.testing.expect(result.body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.yaml, "name: code-review") != null);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "This is the prompt body"));
}

test "splitFrontmatter - no YAML" {
    const content = "Just a body without frontmatter.";

    const result = splitFrontmatter(content);
    try std.testing.expect(result.yaml.len == 0);
    try std.testing.expect(std.mem.eql(u8, result.body, content));
}

test "SkillLoader - parseCommaList" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    const list = try loader.parseCommaList("read, write, edit");
    defer {
        for (list) |item| allocator.free(item);
        allocator.free(list);
    }

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expect(std.mem.eql(u8, list[0], "read"));
    try std.testing.expect(std.mem.eql(u8, list[1], "write"));
    try std.testing.expect(std.mem.eql(u8, list[2], "edit"));
}

test "parseSkillMd - with valid frontmatter" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: code-review
        \\description: Review code for quality
        \\triggers: review, audit
        \\tools: read, grep
        \\scope: builtin
        \\---
        \\You are a code reviewer. Analyze the following code.
    ;

    const result = try parseSkillMd(allocator, content) orelse {
        try std.testing.expect(false);
        return;
    };
    defer {
        var mut = result;
        mut.deinit();
    }

    try std.testing.expectEqualStrings("code-review", result.name);
    try std.testing.expectEqualStrings("Review code for quality", result.description);
    try std.testing.expectEqualStrings("builtin", result.scope);
    try std.testing.expectEqual(@as(usize, 2), result.triggers.len);
    try std.testing.expectEqual(@as(usize, 2), result.tools.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "code reviewer") != null);
}

test "parseSkillMd - no frontmatter returns null" {
    const allocator = std.testing.allocator;
    const content = "Just plain text without frontmatter.";

    const result = try parseSkillMd(allocator, content);
    try std.testing.expect(result == null);
}

test "parseSkillMd - empty frontmatter returns null" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\---
        \\Body content.
    ;

    const result = try parseSkillMd(allocator, content);
    try std.testing.expect(result == null);
}

test "parseCommaListStandalone - parses comma list" {
    const allocator = std.testing.allocator;
    const list = try parseCommaListStandalone(allocator, "bash, read, edit");
    defer {
        for (list) |item| allocator.free(item);
        allocator.free(list);
    }

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("bash", list[0]);
    try std.testing.expectEqualStrings("read", list[1]);
    try std.testing.expectEqualStrings("edit", list[2]);
}

test "SkillLoader - toPromptXml" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    const skill = Skill{
        .allocator = allocator,
        .name = "test-skill",
        .description = "A test skill",
        .triggers = &.{},
        .tools = &.{},
        .prompt = "Do the thing",
        .file_path = "test",
    };
    try loader.skills.append(skill);

    const xml = try loader.toPromptXml(allocator);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "</available_skills>") != null);
}
