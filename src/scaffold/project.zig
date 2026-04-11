const std = @import("std");

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
    acceptance_criteria: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, title: []const u8, priority: Priority) !Requirement {
        return Requirement{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, title),
            .description = try allocator.dupe(u8, ""),
            .priority = priority,
            .category = try allocator.dupe(u8, "general"),
            .acceptance_criteria = std.ArrayList([]const u8).init(allocator),
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
    requirement_ids: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, number: u32, name: []const u8) !ScaffoldPhase {
        return ScaffoldPhase{
            .number = number,
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, ""),
            .requirement_ids = std.ArrayList([]const u8).init(allocator),
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
    tech_stack: std.ArrayList([]const u8),
    requirements: std.ArrayList(*Requirement),
    phases: std.ArrayList(*ScaffoldPhase),

    pub fn init(allocator: Allocator, name: []const u8, description: []const u8) !ProjectScaffolder {
        return ProjectScaffolder{
            .allocator = allocator,
            .project_name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .tech_stack = std.ArrayList([]const u8).init(allocator),
            .requirements = std.ArrayList(*Requirement).init(allocator),
            .phases = std.ArrayList(*ScaffoldPhase).init(allocator),
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
        var buf = std.ArrayList(u8).init(self.allocator);
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
        var buf = std.ArrayList(u8).init(self.allocator);
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
        var buf = std.ArrayList(u8).init(self.allocator);
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
        var buf = std.ArrayList(u8).init(self.allocator);
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
        const stdout = std.io.getStdOut().writer();

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
