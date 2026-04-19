const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A trigger rule mapping file patterns to skill names
pub const TriggerRule = struct {
    pattern: []const u8,
    skill_name: []const u8,
    auto_load: bool,
};

/// Parsed configuration from an AGENTS.md file
pub const AgentsConfig = struct {
    allocator: Allocator,
    skill_paths: [][]const u8,
    enabled_skills: [][]const u8,
    trigger_rules: []TriggerRule,

    pub fn deinit(self: *AgentsConfig) void {
        for (self.skill_paths) |p| self.allocator.free(p);
        self.allocator.free(self.skill_paths);
        for (self.enabled_skills) |s| self.allocator.free(s);
        self.allocator.free(self.enabled_skills);
        for (self.trigger_rules) |*r| {
            self.allocator.free(r.pattern);
            self.allocator.free(r.skill_name);
        }
        self.allocator.free(self.trigger_rules);
    }
};

/// Parse an AGENTS.md file for skill references, trigger rules, and enabled skills.
/// Returns null if the file does not exist.
///
/// Supported format:
/// ```markdown
/// ## Skills
/// - ./skills/typescript/
/// - ./skills/react/
///
/// ## Triggers
/// - *.tsx → react-skills (auto)
/// - *.zig → zig-skills
/// ```
pub fn parseAgentsMd(allocator: Allocator, file_path: []const u8) !?AgentsConfig {
    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    return try parseAgentsContent(allocator, content);
}

/// Parse AGENTS.md content from a string buffer
pub fn parseAgentsContent(allocator: Allocator, content: []const u8) !AgentsConfig {
    var skill_paths = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (skill_paths.items) |p| allocator.free(p);
        skill_paths.deinit();
    }
    var enabled_skills = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (enabled_skills.items) |s| allocator.free(s);
        enabled_skills.deinit();
    }
    var trigger_rules = array_list_compat.ArrayList(TriggerRule).init(allocator);
    errdefer {
        for (trigger_rules.items) |*r| {
            allocator.free(r.pattern);
            allocator.free(r.skill_name);
        }
        trigger_rules.deinit();
    }

    var current_section: enum { none, skills, triggers } = .none;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Detect section headers
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const header = std.mem.trim(u8, trimmed[3..], " \t");
            if (std.mem.eql(u8, header, "Skills")) {
                current_section = .skills;
            } else if (std.mem.eql(u8, header, "Triggers")) {
                current_section = .triggers;
            } else {
                current_section = .none;
            }
            continue;
        }

        // Skip non-list items
        if (trimmed[0] != '-') continue;

        const item = std.mem.trimLeft(u8, trimmed[1..], " \t");
        if (item.len == 0) continue;

        switch (current_section) {
            .skills => {
                // Skill path: ./skills/typescript/ or just a name
                if (std.mem.startsWith(u8, item, "./") or std.mem.startsWith(u8, item, "/") or std.mem.endsWith(u8, item, "/")) {
                    try skill_paths.append(try allocator.dupe(u8, item));
                } else {
                    try enabled_skills.append(try allocator.dupe(u8, item));
                }
            },
            .triggers => {
                // Trigger rule: *.tsx → react-skills (auto)
                // Also supports: - pattern: *.tsx → react-skills
                const trigger_line = if (std.mem.startsWith(u8, item, "pattern:"))
                    std.mem.trimLeft(u8, item["pattern:".len..], " \t")
                else
                    item;

                // Find arrow separator: → or ->
                const arrow_utf8_pos = std.mem.indexOf(u8, trigger_line, "→");
                const arrow_ascii_pos = std.mem.indexOf(u8, trigger_line, "->");
                const arrow_pos = arrow_utf8_pos orelse arrow_ascii_pos orelse continue;
                const arrow_len: usize = if (arrow_utf8_pos != null) 3 else 2;

                const pattern = std.mem.trim(u8, trigger_line[0..arrow_pos], " \t");
                const rest = std.mem.trim(u8, trigger_line[arrow_pos + arrow_len ..], " \t");

                if (pattern.len == 0 or rest.len == 0) continue;

                // Check for (auto) suffix
                const auto_marker = std.mem.indexOf(u8, rest, "(auto)");
                var skill_name_end: usize = rest.len;
                if (auto_marker) |pos| {
                    skill_name_end = pos;
                } else {
                    // Also check for (manual) or parenthetical at end
                    if (std.mem.indexOfScalar(u8, rest, '(')) |paren_pos| {
                        skill_name_end = paren_pos;
                    }
                }

                const skill_name = std.mem.trim(u8, rest[0..skill_name_end], " \t");
                if (skill_name.len == 0) continue;

                try trigger_rules.append(.{
                    .pattern = try allocator.dupe(u8, pattern),
                    .skill_name = try allocator.dupe(u8, skill_name),
                    .auto_load = auto_marker != null,
                });
            },
            .none => {},
        }
    }

    return AgentsConfig{
        .allocator = allocator,
        .skill_paths = try skill_paths.toOwnedSlice(),
        .enabled_skills = try enabled_skills.toOwnedSlice(),
        .trigger_rules = try trigger_rules.toOwnedSlice(),
    };
}

// --- Tests ---

test "parseAgentsContent - basic Skills and Triggers sections" {
    const allocator = std.testing.allocator;
    const content =
        \\## Skills
        \\- ./skills/typescript/
        \\- ./skills/react/
        \\
        \\## Triggers
        \\- *.tsx → react-skills (auto)
        \\- *.zig → zig-skills
    ;

    var config = try parseAgentsContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), config.enabled_skills.len);
    try std.testing.expectEqual(@as(usize, 2), config.trigger_rules.len);

    try std.testing.expect(std.mem.eql(u8, config.skill_paths[0], "./skills/typescript/"));
    try std.testing.expect(std.mem.eql(u8, config.skill_paths[1], "./skills/react/"));

    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[0].pattern, "*.tsx"));
    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[0].skill_name, "react-skills"));
    try std.testing.expect(config.trigger_rules[0].auto_load);

    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[1].pattern, "*.zig"));
    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[1].skill_name, "zig-skills"));
    try std.testing.expect(!config.trigger_rules[1].auto_load);
}

test "parseAgentsContent - enabled skills list" {
    const allocator = std.testing.allocator;
    const content =
        \\## Skills
        \\- typescript-language
        \\- react-hooks
        \\- ./skills/custom/
    ;

    var config = try parseAgentsContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 2), config.enabled_skills.len);
    try std.testing.expect(std.mem.eql(u8, config.enabled_skills[0], "typescript-language"));
    try std.testing.expect(std.mem.eql(u8, config.enabled_skills[1], "react-hooks"));
}

test "parseAgentsContent - arrow separator -> " {
    const allocator = std.testing.allocator;
    const content =
        \\## Triggers
        \\- *.go -> golang-skills (auto)
    ;

    var config = try parseAgentsContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.trigger_rules.len);
    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[0].pattern, "*.go"));
    try std.testing.expect(std.mem.eql(u8, config.trigger_rules[0].skill_name, "golang-skills"));
    try std.testing.expect(config.trigger_rules[0].auto_load);
}

test "parseAgentsContent - empty content returns empty config" {
    const allocator = std.testing.allocator;
    const content = "";

    var config = try parseAgentsContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), config.enabled_skills.len);
    try std.testing.expectEqual(@as(usize, 0), config.trigger_rules.len);
}

test "parseAgentsContent - irrelevant sections ignored" {
    const allocator = std.testing.allocator;
    const content =
        \\## Description
        \\This is a project description.
        \\
        \\## Skills
        \\- ./skills/typescript/
        \\
        \\## Other
        \\- ignored item
    ;

    var config = try parseAgentsContent(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), config.trigger_rules.len);
}
