const std = @import("std");

const Allocator = std.mem.Allocator;

/// Phase status in the workflow lifecycle
pub const PhaseStatus = enum {
    pending, // Not yet started
    in_progress, // Currently executing
    completed, // Successfully finished
    failed, // Errored out
    skipped, // Skipped (dependency not met or user choice)
    verified, // Completed and verified against criteria
};

/// Wave execution mode for parallel vs sequential tasks
/// Reference: GSD wave execution
pub const WaveMode = enum {
    sequential, // One task at a time, in order
    parallel, // All tasks run concurrently
    adaptive, // Parallel if independent, sequential if dependent
};

/// A verification criterion for a phase
pub const VerificationCriterion = struct {
    description: []const u8,
    passed: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, description: []const u8) !VerificationCriterion {
        return VerificationCriterion{
            .description = try allocator.dupe(u8, description),
            .passed = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VerificationCriterion) void {
        self.allocator.free(self.description);
    }
};

/// A task within a phase
pub const PhaseTask = struct {
    id: []const u8,
    description: []const u8,
    status: PhaseStatus,
    depends_on: std.ArrayList([]const u8),
    output: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, description: []const u8) !PhaseTask {
        return PhaseTask{
            .id = try allocator.dupe(u8, id),
            .description = try allocator.dupe(u8, description),
            .status = .pending,
            .depends_on = std.ArrayList([]const u8).init(allocator),
            .output = null,
            .allocator = allocator,
        };
    }

    pub fn addDependency(self: *PhaseTask, dep_id: []const u8) !void {
        try self.depends_on.append(try self.allocator.dupe(u8, dep_id));
    }

    pub fn deinit(self: *PhaseTask) void {
        self.allocator.free(self.id);
        self.allocator.free(self.description);
        for (self.depends_on.items) |dep| self.allocator.free(dep);
        self.depends_on.deinit();
        if (self.output) |o| self.allocator.free(o);
    }
};

/// A phase in the development workflow
pub const WorkflowPhase = struct {
    number: u32,
    name: []const u8,
    goal: []const u8,
    status: PhaseStatus,
    depends_on: std.ArrayList(u32),
    tasks: std.ArrayList(*PhaseTask),
    criteria: std.ArrayList(*VerificationCriterion),
    allocator: Allocator,

    pub fn init(allocator: Allocator, number: u32, name: []const u8, goal: []const u8) !WorkflowPhase {
        return WorkflowPhase{
            .number = number,
            .name = try allocator.dupe(u8, name),
            .goal = try allocator.dupe(u8, goal),
            .status = .pending,
            .depends_on = std.ArrayList(u32).init(allocator),
            .tasks = std.ArrayList(*PhaseTask).init(allocator),
            .criteria = std.ArrayList(*VerificationCriterion).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addDependency(self: *WorkflowPhase, phase_num: u32) !void {
        try self.depends_on.append(phase_num);
    }

    pub fn addTask(self: *WorkflowPhase, task: *PhaseTask) !void {
        try self.tasks.append(task);
    }

    pub fn addCriterion(self: *WorkflowPhase, criterion: *VerificationCriterion) !void {
        try self.criteria.append(criterion);
    }

    /// Check if all verification criteria pass
    pub fn isVerified(self: *const WorkflowPhase) bool {
        for (self.criteria.items) |c| {
            if (!c.passed) return false;
        }
        return self.criteria.items.len > 0;
    }

    /// Check if dependencies are all completed
    pub fn dependenciesMet(self: *WorkflowPhase, phases: *const std.ArrayList(*WorkflowPhase)) bool {
        for (self.depends_on.items) |dep_num| {
            for (phases.items) |phase| {
                if (phase.number == dep_num) {
                    if (phase.status != .completed and phase.status != .verified) {
                        return false;
                    }
                    break;
                }
            }
        }
        return true;
    }

    pub fn deinit(self: *WorkflowPhase) void {
        self.allocator.free(self.name);
        self.allocator.free(self.goal);
        self.depends_on.deinit();
        for (self.tasks.items) |task| {
            task.deinit();
            self.allocator.destroy(task);
        }
        self.tasks.deinit();
        for (self.criteria.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.criteria.deinit();
    }
};

/// Phase Workflow System — GSD-inspired discuss→plan→execute→verify→ship
///
/// Reference: Get-Shit-Done phase-runner.ts, XML atomic plans, wave execution
pub const PhaseWorkflow = struct {
    allocator: Allocator,
    name: []const u8,
    phases: std.ArrayList(*WorkflowPhase),
    current_phase: ?u32,
    wave_mode: WaveMode,
    created_at: i64,

    pub fn init(allocator: Allocator, name: []const u8) !PhaseWorkflow {
        return PhaseWorkflow{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .phases = std.ArrayList(*WorkflowPhase).init(allocator),
            .current_phase = null,
            .wave_mode = .adaptive,
            .created_at = std.time.timestamp(),
        };
    }

    /// Add a phase to the workflow
    pub fn addPhase(self: *PhaseWorkflow, phase: *WorkflowPhase) !void {
        try self.phases.append(phase);
    }

    /// Get a phase by number
    pub fn getPhase(self: *PhaseWorkflow, number: u32) ?*WorkflowPhase {
        for (self.phases.items) |phase| {
            if (phase.number == number) return phase;
        }
        return null;
    }

    /// Get the next phase to execute (first pending with met dependencies)
    pub fn nextPhase(self: *PhaseWorkflow) ?*WorkflowPhase {
        for (self.phases.items) |phase| {
            if (phase.status == .pending and phase.dependenciesMet(&self.phases)) {
                return phase;
            }
        }
        return null;
    }

    /// Mark a phase as in progress
    pub fn startPhase(self: *PhaseWorkflow, number: u32) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .in_progress;
            self.current_phase = number;
        }
    }

    /// Mark a phase as completed
    pub fn completePhase(self: *PhaseWorkflow, number: u32) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .completed;
            if (self.current_phase == number) self.current_phase = null;
        }
    }

    /// Mark a phase as verified
    pub fn verifyPhase(self: *PhaseWorkflow, number: u32) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .verified;
            if (self.current_phase == number) self.current_phase = null;
        }
    }

    /// Calculate overall progress percentage
    pub fn progress(self: *const PhaseWorkflow) f64 {
        if (self.phases.items.len == 0) return 0.0;
        var completed: f64 = 0.0;
        for (self.phases.items) |phase| {
            if (phase.status == .completed or phase.status == .verified) {
                completed += 1.0;
            } else if (phase.status == .in_progress) {
                completed += 0.5;
            }
        }
        return completed / @as(f64, @floatFromInt(self.phases.items.len)) * 100.0;
    }

    /// Export workflow as XML plan
    pub fn toXml(self: *PhaseWorkflow, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", .{});
        try writer.print("<workflow name=\"{s}\">\n", .{self.name});

        for (self.phases.items) |phase| {
            const status_str = @tagName(phase.status);
            try writer.print("  <phase number=\"{d}\" name=\"{s}\" status=\"{s}\">\n", .{
                phase.number,
                phase.name,
                status_str,
            });
            try writer.print("    <goal>{s}</goal>\n", .{phase.goal});

            // Dependencies
            if (phase.depends_on.items.len > 0) {
                try writer.print("    <depends-on>", .{});
                for (phase.depends_on.items, 0..) |dep, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{d}", .{dep});
                }
                try writer.print("</depends-on>\n", .{});
            }

            // Tasks
            for (phase.tasks.items) |task| {
                try writer.print("    <task id=\"{s}\" status=\"{s}\">\n", .{
                    task.id,
                    @tagName(task.status),
                });
                try writer.print("      <description>{s}</description>\n", .{task.description});
                try writer.print("    </task>\n", .{});
            }

            // Verification criteria
            for (phase.criteria.items) |c| {
                try writer.print("    <criterion passed=\"{s}\">{s}</criterion>\n", .{
                    if (c.passed) "true" else "false",
                    c.description,
                });
            }

            try writer.print("  </phase>\n", .{});
        }

        try writer.print("</workflow>\n", .{});
        return buf.toOwnedSlice();
    }

    /// Print workflow progress
    pub fn printProgress(self: *PhaseWorkflow) void {
        const stdout = std.io.getStdOut().writer();
        const pct = self.progress();

        stdout.print("\n=== Workflow: {s} ({d:.0}% complete) ===\n\n", .{ self.name, pct }) catch {};

        for (self.phases.items) |phase| {
            const status_icon = switch (phase.status) {
                .pending => "⏳",
                .in_progress => "🔄",
                .completed => "✅",
                .failed => "❌",
                .skipped => "⏭️ ",
                .verified => "✓ ",
            };
            stdout.print("  {s} Phase {d}: {s}\n", .{ status_icon, phase.number, phase.name }) catch {};
            stdout.print("     Goal: {s}\n", .{phase.goal}) catch {};

            if (phase.tasks.items.len > 0) {
                var done: u32 = 0;
                for (phase.tasks.items) |task| {
                    if (task.status == .completed or task.status == .verified) done += 1;
                }
                stdout.print("     Tasks: {d}/{d}\n", .{ done, phase.tasks.items.len }) catch {};
            }

            if (phase.criteria.items.len > 0) {
                var passed: u32 = 0;
                for (phase.criteria.items) |c| {
                    if (c.passed) passed += 1;
                }
                stdout.print("     Criteria: {d}/{d}\n", .{ passed, phase.criteria.items.len }) catch {};
            }
            stdout.print("\n", .{}) catch {};
        }

        if (self.current_phase) |cp| {
            stdout.print("  ▶ Current: Phase {d}\n", .{cp}) catch {};
        } else if (self.nextPhase()) |np| {
            stdout.print("  ▶ Next: Phase {d} ({s})\n", .{ np.number, np.name }) catch {};
        }
    }

    pub fn deinit(self: *PhaseWorkflow) void {
        self.allocator.free(self.name);
        for (self.phases.items) |phase| {
            phase.deinit();
            self.allocator.destroy(phase);
        }
        self.phases.deinit();
    }
};
