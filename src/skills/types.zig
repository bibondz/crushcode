const std = @import("std");
const array_list_compat = @import("array_list_compat");

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
                std.mem.endsWith(u8, basename, ".skill.md");

            if (!is_skill_file) continue;

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
            errdefer self.allocator.free(full_path);

            const skill = self.parseSkillFile(full_path) catch |err| {
                std.debug.print("Warning: Failed to parse skill {s}: {}\n", .{ full_path, err });
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
            } else if (std.mem.eql(u8, basename, "SKILL.md")) {
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
        std.debug.print("Loaded {} skills:\n", .{self.skills.items.len});
        for (self.skills.items) |skill| {
            std.debug.print("  - {s}: {s}\n", .{ skill.name, skill.description });
        }
    }
};

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
