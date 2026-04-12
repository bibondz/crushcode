const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Priority level for requirements
pub const Priority = enum {
    critical, // Must have — project fails without it
    high, // Should have — core functionality
    medium, // Nice to have — enhancement
    low, // Optional — future consideration
};

/// A project requirement with acceptance criteria
pub const Requirement = struct {
    id: []const u8, // e.g., "REQ-01"
    title: []const u8,
    description: []const u8,
    priority: Priority,
    category: []const u8, // e.g., "AI", "CLI", "Build"
    acceptance_criteria: array_list_compat.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, title: []const u8, priority: Priority) !Requirement {
        return Requirement{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, ""),
            .priority = priority,
            .category = try allocator.dupe(u8, "general"),
            .acceptance_criteria = array_list_compat.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn setDescription(self: *Requirement, desc: []const u8) !void {
        self.allocator.free(self.description);
        self.description = try self.allocator.dupe(u8, desc);
    }

    pub fn setCategory(self: *Requirement, cat: []const u8) !void {
        self.allocator.free(self.category);
        self.category = try self.allocator.dupe(u8, cat);
    }

    pub fn addCriterion(self: *Requirement, criterion: []const u8) !void {
        try self.acceptance_criteria.append(try self.allocator.dupe(u8, criterion));
    }

    pub fn deinit(self: *Requirement) void {
        self.allocator.free(self.id);
        self.allocator.free(self.title);
        self.allocator.free(self.description);
        self.allocator.free(self.category);
        for (self.acceptance_criteria.items) |c| self.allocator.free(c);
        self.acceptance_criteria.deinit();
    }
};

/// Scaffolding phase definition
pub const ScaffoldPhase = struct {
    number: u32,
    name: []const u8,
    description: []const u8,
    requirement_ids: array_list_compat.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, number: u32, name: []const u8) !ScaffoldPhase {
        return ScaffoldPhase{
            .number = number,
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, ""),
            .requirement_ids = array_list_compat.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn setDescription(self: *ScaffoldPhase, desc: []const u8) !void {
        self.allocator.free(self.description);
        self.description = try self.allocator.dupe(u8, desc);
    }

    pub fn addRequirement(self: *ScaffoldPhase, req_id: []const u8) !void {
        try self.requirement_ids.append(try self.allocator.dupe(u8, req_id));
    }

    pub fn deinit(self: *ScaffoldPhase) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        for (self.requirement_ids.items) |id| self.allocator.free(id);
        self.requirement_ids.deinit();
    }
};

/// Project Scaffolding — generates project structure from description
///
/// Reference: Get-Shit-Done project scaffolding from requirements→roadmap
/// Generates PROJECT.md, REQUIREMENTS.md, ROADMAP.md, and directory structure
pub const ProjectScaffolder = struct {
    allocator: Allocator,
    project_name: []const u8,
    description: []const u8,
    tech_stack: array_list_compat.ArrayList([]const u8),
    requirements: array_list_compat.ArrayList(*Requirement),
    phases: array_list_compat.ArrayList(*ScaffoldPhase),

    pub fn init(allocator: Allocator, name: []const u8, description: []const u8) !ProjectScaffolder {
        return ProjectScaffolder{
            .allocator = allocator,
            .project_name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .tech_stack = array_list_compat.ArrayList([]const u8).init(allocator),
            .requirements = array_list_compat.ArrayList(*Requirement).init(allocator),
            .phases = array_list_compat.ArrayList(*ScaffoldPhase).init(allocator),
        };
    }

    /// Add a technology to the stack
    pub fn addTech(self: *ProjectScaffolder, tech: []const u8) !void {
        try self.tech_stack.append(try self.allocator.dupe(u8, tech));
    }

    /// Add a requirement
    pub fn addRequirement(self: *ProjectScaffolder, req: *Requirement) !void {
        try self.requirements.append(req);
    }

    /// Add a phase
    pub fn addPhase(self: *ProjectScaffolder, phase: *ScaffoldPhase) !void {
        try self.phases.append(phase);
    }

    /// Generate PROJECT.md content
    pub fn generateProjectMd(self: *ProjectScaffolder) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.print("# {s}\n\n", .{self.project_name});
        try writer.print("{s}\n\n", .{self.description});

        try writer.print("## Tech Stack\n\n", .{});
        for (self.tech_stack.items) |tech| {
            try writer.print("- {s}\n", .{tech});
        }
        try writer.print("\n## Requirements\n\n", .{});
        try writer.print("See REQUIREMENTS.md for detailed requirements.\n\n", .{});
        try writer.print("## Roadmap\n\n", .{});
        try writer.print("See ROADMAP.md for phased development plan.\n", .{});

        return buf.toOwnedSlice();
    }

    /// Generate REQUIREMENTS.md content
    pub fn generateRequirementsMd(self: *ProjectScaffolder) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.print("# Requirements: {s}\n\n", .{self.project_name});

        // Group by priority
        const priorities = [_]Priority{ .critical, .high, .medium, .low };
        const labels = [_][]const u8{ "Critical", "High", "Medium", "Low" };

        for (priorities, labels) |priority, label| {
            var has_any = false;
            for (self.requirements.items) |req| {
                if (req.priority == priority) {
                    if (!has_any) {
                        try writer.print("## {s} Priority\n\n", .{label});
                        has_any = true;
                    }
                    try writer.print("### {s}: {s}\n", .{ req.id, req.title });
                    if (req.description.len > 0) {
                        try writer.print("{s}\n\n", .{req.description});
                    }
                    try writer.print("**Category:** {s}\n\n", .{req.category});
                    if (req.acceptance_criteria.items.len > 0) {
                        try writer.print("**Acceptance Criteria:**\n", .{});
                        for (req.acceptance_criteria.items) |c| {
                            try writer.print("- [ ] {s}\n", .{c});
                        }
                        try writer.print("\n", .{});
                    }
                }
            }
        }

        return buf.toOwnedSlice();
    }

    /// Generate ROADMAP.md content
    pub fn generateRoadmapMd(self: *ProjectScaffolder) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.print("# Roadmap: {s}\n\n", .{self.project_name});
        try writer.print("**Created:** {s}\n\n", .{"auto-generated"});

        try writer.print("## Phases\n\n", .{});

        for (self.phases.items) |phase| {
            try writer.print("### Phase {d}: {s}\n\n", .{ phase.number, phase.name });
            if (phase.description.len > 0) {
                try writer.print("**Goal:** {s}\n\n", .{phase.description});
            }

            if (phase.requirement_ids.items.len > 0) {
                try writer.print("**Requirements:** ", .{});
                for (phase.requirement_ids.items, 0..) |id, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{id});
                }
                try writer.print("\n\n", .{});
            }

            try writer.print("**Success Criteria:**\n", .{});
            try writer.print("1. All requirements in this phase are met\n", .{});
            try writer.print("2. Build passes with no errors\n", .{});
            try writer.print("3. Manual testing confirms functionality\n\n", .{});
        }

        // Progress table
        try writer.print("## Progress\n\n", .{});
        try writer.print("| Phase | Status | Completed |\n", .{});
        try writer.print("|-------|--------|----------|\n", .{});
        for (self.phases.items) |phase| {
            try writer.print("| {d}. {s} | Pending | ⬜ |\n", .{ phase.number, phase.name });
        }

        return buf.toOwnedSlice();
    }

    /// Generate suggested directory structure
    pub fn generateStructure(self: *ProjectScaffolder) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.print("Suggested directory structure for {s}:\n\n", .{self.project_name});
        try writer.print("{s}/\n", .{self.project_name});
        try writer.print("├── src/\n", .{});
        try writer.print("│   ├── main.zig\n", .{});
        try writer.print("│   ├── cli/\n", .{});
        try writer.print("│   │   └── args.zig\n", .{});
        try writer.print("│   ├── ai/\n", .{});
        try writer.print("│   │   ├── client.zig\n", .{});
        try writer.print("│   │   └── registry.zig\n", .{});
        try writer.print("│   ├── config/\n", .{});
        try writer.print("│   │   └── config.zig\n", .{});
        try writer.print("│   ├── commands/\n", .{});
        try writer.print("│   │   └── handlers.zig\n", .{});
        try writer.print("│   └── utils/\n", .{});
        try writer.print("│       └── string.zig\n", .{});
        try writer.print("├── build.zig\n", .{});
        try writer.print("├── PROJECT.md\n", .{});
        try writer.print("├── REQUIREMENTS.md\n", .{});
        try writer.print("└── ROADMAP.md\n", .{});

        // Structure is static suggestion based on project type
        _ = self.tech_stack.items.len;
        return buf.toOwnedSlice();
    }

    /// Print scaffolding summary
    pub fn printSummary(self: *ProjectScaffolder) void {
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Project Scaffolding: {s} ===\n\n", .{self.project_name}) catch {};
        stdout.print("Description: {s}\n\n", .{self.description}) catch {};

        if (self.tech_stack.items.len > 0) {
            stdout.print("Tech Stack:\n", .{}) catch {};
            for (self.tech_stack.items) |tech| {
                stdout.print("  - {s}\n", .{tech}) catch {};
            }
            stdout.print("\n", .{}) catch {};
        }

        stdout.print("Requirements: {d}\n", .{self.requirements.items.len}) catch {};
        var crit_count: u32 = 0;
        var high_count: u32 = 0;
        var med_count: u32 = 0;
        var low_count: u32 = 0;
        for (self.requirements.items) |req| {
            switch (req.priority) {
                .critical => crit_count += 1,
                .high => high_count += 1,
                .medium => med_count += 1,
                .low => low_count += 1,
            }
        }
        stdout.print("  Critical: {d} | High: {d} | Medium: {d} | Low: {d}\n\n", .{ crit_count, high_count, med_count, low_count }) catch {};

        stdout.print("Phases: {d}\n", .{self.phases.items.len}) catch {};
        for (self.phases.items) |phase| {
            stdout.print("  {d}. {s} ({d} requirements)\n", .{
                phase.number,
                phase.name,
                phase.requirement_ids.items.len,
            }) catch {};
        }
    }

    pub fn deinit(self: *ProjectScaffolder) void {
        self.allocator.free(self.project_name);
        self.allocator.free(self.description);
        for (self.tech_stack.items) |tech| self.allocator.free(tech);
        self.tech_stack.deinit();
        for (self.requirements.items) |req| {
            req.deinit();
            self.allocator.destroy(req);
        }
        self.requirements.deinit();
        for (self.phases.items) |phase| {
            phase.deinit();
            self.allocator.destroy(phase);
        }
        self.phases.deinit();
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Priority - enum values" {
    try testing.expectEqual(Priority.critical, Priority.critical);
    try testing.expectEqual(Priority.high, Priority.high);
    try testing.expectEqual(Priority.medium, Priority.medium);
    try testing.expectEqual(Priority.low, Priority.low);
}

test "Requirement - init and deinit" {
    const req = try Requirement.init(testing.allocator, "REQ-01", "Core feature", .critical);
    defer {
        var mutable = req;
        mutable.deinit();
    }
    try testing.expectEqualStrings("REQ-01", req.id);
    try testing.expectEqualStrings("Core feature", req.title);
    try testing.expectEqualStrings("", req.description);
    try testing.expectEqual(Priority.critical, req.priority);
    try testing.expectEqualStrings("general", req.category);
    try testing.expectEqual(@as(usize, 0), req.acceptance_criteria.items.len);
}

test "Requirement - setDescription" {
    var req = try Requirement.init(testing.allocator, "REQ-01", "Test", .high);
    defer req.deinit();
    try req.setDescription("A detailed description");
    try testing.expectEqualStrings("A detailed description", req.description);
}

test "Requirement - setCategory" {
    var req = try Requirement.init(testing.allocator, "REQ-01", "Test", .high);
    defer req.deinit();
    try req.setCategory("AI");
    try testing.expectEqualStrings("AI", req.category);
}

test "Requirement - addCriterion" {
    var req = try Requirement.init(testing.allocator, "REQ-01", "Test", .high);
    defer req.deinit();
    try req.addCriterion("CLI starts successfully");
    try req.addCriterion("Shows help output");
    try testing.expectEqual(@as(usize, 2), req.acceptance_criteria.items.len);
    try testing.expectEqualStrings("CLI starts successfully", req.acceptance_criteria.items[0]);
    try testing.expectEqualStrings("Shows help output", req.acceptance_criteria.items[1]);
}

test "ScaffoldPhase - init and deinit" {
    const phase = try ScaffoldPhase.init(testing.allocator, 1, "Core Setup");
    defer {
        var mutable = phase;
        mutable.deinit();
    }
    try testing.expectEqual(@as(u32, 1), phase.number);
    try testing.expectEqualStrings("Core Setup", phase.name);
    try testing.expectEqualStrings("", phase.description);
    try testing.expectEqual(@as(usize, 0), phase.requirement_ids.items.len);
}

test "ScaffoldPhase - setDescription" {
    var phase = try ScaffoldPhase.init(testing.allocator, 1, "Test");
    defer phase.deinit();
    try phase.setDescription("Set up the project foundation");
    try testing.expectEqualStrings("Set up the project foundation", phase.description);
}

test "ScaffoldPhase - addRequirement" {
    var phase = try ScaffoldPhase.init(testing.allocator, 1, "Test");
    defer phase.deinit();
    try phase.addRequirement("REQ-01");
    try phase.addRequirement("REQ-02");
    try testing.expectEqual(@as(usize, 2), phase.requirement_ids.items.len);
    try testing.expectEqualStrings("REQ-01", phase.requirement_ids.items[0]);
    try testing.expectEqualStrings("REQ-02", phase.requirement_ids.items[1]);
}

test "ProjectScaffolder - init and deinit" {
    var s = try ProjectScaffolder.init(testing.allocator, "my-app", "A cool app");
    defer s.deinit();
    try testing.expectEqualStrings("my-app", s.project_name);
    try testing.expectEqualStrings("A cool app", s.description);
    try testing.expectEqual(@as(usize, 0), s.tech_stack.items.len);
    try testing.expectEqual(@as(usize, 0), s.requirements.items.len);
    try testing.expectEqual(@as(usize, 0), s.phases.items.len);
}

test "ProjectScaffolder - addTech" {
    var s = try ProjectScaffolder.init(testing.allocator, "test", "desc");
    defer s.deinit();
    try s.addTech("Zig");
    try s.addTech("PostgreSQL");
    try testing.expectEqual(@as(usize, 2), s.tech_stack.items.len);
    try testing.expectEqualStrings("Zig", s.tech_stack.items[0]);
    try testing.expectEqualStrings("PostgreSQL", s.tech_stack.items[1]);
}

test "ProjectScaffolder - addRequirement and addPhase" {
    var s = try ProjectScaffolder.init(testing.allocator, "test", "desc");
    defer s.deinit();

    const req = try testing.allocator.create(Requirement);
    req.* = try Requirement.init(testing.allocator, "REQ-01", "Feature", .critical);
    try s.addRequirement(req);

    const phase = try testing.allocator.create(ScaffoldPhase);
    phase.* = try ScaffoldPhase.init(testing.allocator, 1, "Setup");
    try s.addPhase(phase);

    try testing.expectEqual(@as(usize, 1), s.requirements.items.len);
    try testing.expectEqual(@as(usize, 1), s.phases.items.len);
}

test "ProjectScaffolder - generateProjectMd" {
    var s = try ProjectScaffolder.init(testing.allocator, "my-project", "A test project");
    defer s.deinit();
    try s.addTech("Zig");

    const md = try s.generateProjectMd();
    defer testing.allocator.free(md);

    try testing.expect(std.mem.indexOf(u8, md, "# my-project") != null);
    try testing.expect(std.mem.indexOf(u8, md, "A test project") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Zig") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Roadmap") != null);
}

test "ProjectScaffolder - generateRequirementsMd" {
    var s = try ProjectScaffolder.init(testing.allocator, "test-project", "desc");
    defer s.deinit();

    const req = try testing.allocator.create(Requirement);
    req.* = try Requirement.init(testing.allocator, "REQ-01", "Auth system", .critical);
    try req.setDescription("Implement OAuth 2.0");
    try req.setCategory("Security");
    try req.addCriterion("Login works");
    try req.addCriterion("Token refresh works");
    try s.addRequirement(req);

    const md = try s.generateRequirementsMd();
    defer testing.allocator.free(md);

    try testing.expect(std.mem.indexOf(u8, md, "REQ-01") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Auth system") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Critical") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Security") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Login works") != null);
}

test "ProjectScaffolder - generateRequirementsMd groups by priority" {
    var s = try ProjectScaffolder.init(testing.allocator, "test", "desc");
    defer s.deinit();

    const req1 = try testing.allocator.create(Requirement);
    req1.* = try Requirement.init(testing.allocator, "REQ-01", "Low priority", .low);
    try s.addRequirement(req1);

    const req2 = try testing.allocator.create(Requirement);
    req2.* = try Requirement.init(testing.allocator, "REQ-02", "Critical", .critical);
    try s.addRequirement(req2);

    const md = try s.generateRequirementsMd();
    defer testing.allocator.free(md);

    // Critical should appear before Low
    const crit_pos = std.mem.indexOf(u8, md, "Critical Priority").?;
    const low_pos = std.mem.indexOf(u8, md, "Low Priority").?;
    try testing.expect(crit_pos < low_pos);
}

test "ProjectScaffolder - generateRoadmapMd" {
    var s = try ProjectScaffolder.init(testing.allocator, "roadmap-test", "desc");
    defer s.deinit();

    const ph = try testing.allocator.create(ScaffoldPhase);
    ph.* = try ScaffoldPhase.init(testing.allocator, 1, "Foundation");
    try ph.setDescription("Set up project structure");
    try ph.addRequirement("REQ-01");
    try s.addPhase(ph);

    const md = try s.generateRoadmapMd();
    defer testing.allocator.free(md);

    try testing.expect(std.mem.indexOf(u8, md, "Phase 1") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Foundation") != null);
    try testing.expect(std.mem.indexOf(u8, md, "REQ-01") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Progress") != null);
}

test "ProjectScaffolder - generateStructure" {
    var s = try ProjectScaffolder.init(testing.allocator, "my-app", "desc");
    defer s.deinit();

    const structure = try s.generateStructure();
    defer testing.allocator.free(structure);

    try testing.expect(std.mem.indexOf(u8, structure, "my-app") != null);
    try testing.expect(std.mem.indexOf(u8, structure, "src/") != null);
    try testing.expect(std.mem.indexOf(u8, structure, "build.zig") != null);
    try testing.expect(std.mem.indexOf(u8, structure, "PROJECT.md") != null);
}

test "ProjectScaffolder - full scaffold with multiple requirements and phases" {
    var s = try ProjectScaffolder.init(testing.allocator, "full-test", "Complete test project");
    defer s.deinit();

    try s.addTech("Zig");
    try s.addTech("SQLite");

    // Requirements across priorities
    const req1 = try testing.allocator.create(Requirement);
    req1.* = try Requirement.init(testing.allocator, "REQ-01", "CLI", .critical);
    try req1.addCriterion("Builds and runs");
    try s.addRequirement(req1);

    const req2 = try testing.allocator.create(Requirement);
    req2.* = try Requirement.init(testing.allocator, "REQ-02", "Database", .high);
    try s.addRequirement(req2);

    // Phases
    const ph1 = try testing.allocator.create(ScaffoldPhase);
    ph1.* = try ScaffoldPhase.init(testing.allocator, 1, "Setup");
    try ph1.addRequirement("REQ-01");
    try s.addPhase(ph1);

    const ph2 = try testing.allocator.create(ScaffoldPhase);
    ph2.* = try ScaffoldPhase.init(testing.allocator, 2, "Database");
    try ph2.addRequirement("REQ-02");
    try s.addPhase(ph2);

    // Generate all outputs
    const project_md = try s.generateProjectMd();
    defer testing.allocator.free(project_md);
    const reqs_md = try s.generateRequirementsMd();
    defer testing.allocator.free(reqs_md);
    const roadmap_md = try s.generateRoadmapMd();
    defer testing.allocator.free(roadmap_md);
    const structure = try s.generateStructure();
    defer testing.allocator.free(structure);

    // Verify all outputs contain expected content
    try testing.expect(std.mem.indexOf(u8, project_md, "full-test") != null);
    try testing.expect(std.mem.indexOf(u8, reqs_md, "REQ-01") != null);
    try testing.expect(std.mem.indexOf(u8, reqs_md, "REQ-02") != null);
    try testing.expect(std.mem.indexOf(u8, roadmap_md, "Phase 1") != null);
    try testing.expect(std.mem.indexOf(u8, roadmap_md, "Phase 2") != null);
    try testing.expect(std.mem.indexOf(u8, structure, "src/") != null);
}
