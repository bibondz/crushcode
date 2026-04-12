const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

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
    depends_on: array_list_compat.ArrayList([]const u8),
    output: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, description: []const u8) !PhaseTask {
        return PhaseTask{
            .id = try allocator.dupe(u8, id),
            .description = try allocator.dupe(u8, description),
            .status = .pending,
            .depends_on = array_list_compat.ArrayList([]const u8).init(allocator),
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
    depends_on: array_list_compat.ArrayList(u32),
    tasks: array_list_compat.ArrayList(*PhaseTask),
    criteria: array_list_compat.ArrayList(*VerificationCriterion),
    allocator: Allocator,

    pub fn init(allocator: Allocator, number: u32, name: []const u8, goal: []const u8) !WorkflowPhase {
        return WorkflowPhase{
            .number = number,
            .name = try allocator.dupe(u8, name),
            .goal = try allocator.dupe(u8, goal),
            .status = .pending,
            .depends_on = array_list_compat.ArrayList(u32).init(allocator),
            .tasks = array_list_compat.ArrayList(*PhaseTask).init(allocator),
            .criteria = array_list_compat.ArrayList(*VerificationCriterion).init(allocator),
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
    pub fn dependenciesMet(self: *WorkflowPhase, phases: *const array_list_compat.ArrayList(*WorkflowPhase)) bool {
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
    phases: array_list_compat.ArrayList(*WorkflowPhase),
    current_phase: ?u32,
    wave_mode: WaveMode,
    created_at: i64,

    pub fn init(allocator: Allocator, name: []const u8) !PhaseWorkflow {
        return PhaseWorkflow{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .phases = array_list_compat.ArrayList(*WorkflowPhase).init(allocator),
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
        var buf = array_list_compat.ArrayList(u8).init(allocator);
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
        const stdout = file_compat.File.stdout().writer();
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "PhaseStatus - is enum" {
    const status: PhaseStatus = .pending;
    try testing.expectEqual(PhaseStatus.pending, status);
}

test "WaveMode - enum values" {
    try testing.expectEqual(WaveMode.sequential, WaveMode.sequential);
    try testing.expectEqual(WaveMode.parallel, WaveMode.parallel);
    try testing.expectEqual(WaveMode.adaptive, WaveMode.adaptive);
}

test "VerificationCriterion - init and deinit" {
    const c = try VerificationCriterion.init(testing.allocator, "Build passes");
    defer {
        var mutable = c;
        mutable.deinit();
    }
    try testing.expectEqualStrings("Build passes", c.description);
    try testing.expect(!c.passed);
}

test "PhaseTask - init and deinit" {
    const task = try PhaseTask.init(testing.allocator, "T1", "Write module");
    defer {
        var mutable = task;
        mutable.deinit();
    }
    try testing.expectEqualStrings("T1", task.id);
    try testing.expectEqualStrings("Write module", task.description);
    try testing.expectEqual(PhaseStatus.pending, task.status);
    try testing.expectEqual(@as(usize, 0), task.depends_on.items.len);
}

test "PhaseTask - addDependency" {
    var task = try PhaseTask.init(testing.allocator, "T1", "Write module");
    defer task.deinit();
    try task.addDependency("T0");
    try testing.expectEqual(@as(usize, 1), task.depends_on.items.len);
    try testing.expectEqualStrings("T0", task.depends_on.items[0]);
}

test "WorkflowPhase - init and deinit" {
    const phase = try WorkflowPhase.init(testing.allocator, 1, "Setup", "Initialize project");
    defer {
        var mutable = phase;
        mutable.deinit();
    }
    try testing.expectEqual(@as(u32, 1), phase.number);
    try testing.expectEqualStrings("Setup", phase.name);
    try testing.expectEqualStrings("Initialize project", phase.goal);
    try testing.expectEqual(PhaseStatus.pending, phase.status);
}

test "WorkflowPhase - addDependency" {
    var phase = try WorkflowPhase.init(testing.allocator, 2, "Build", "Build the thing");
    defer phase.deinit();
    try phase.addDependency(1);
    try testing.expectEqual(@as(usize, 1), phase.depends_on.items.len);
    try testing.expectEqual(@as(u32, 1), phase.depends_on.items[0]);
}

test "WorkflowPhase - isVerified with no criteria" {
    const phase = try WorkflowPhase.init(testing.allocator, 1, "Test", "Goal");
    defer {
        var mutable = phase;
        mutable.deinit();
    }
    // No criteria → not verified (returns false when empty)
    try testing.expect(!phase.isVerified());
}

test "WorkflowPhase - isVerified with passing criteria" {
    var phase = try WorkflowPhase.init(testing.allocator, 1, "Test", "Goal");
    defer phase.deinit();

    const c1 = try testing.allocator.create(VerificationCriterion);
    c1.* = try VerificationCriterion.init(testing.allocator, "Test passes");
    c1.passed = true;
    try phase.addCriterion(c1);

    const c2 = try testing.allocator.create(VerificationCriterion);
    c2.* = try VerificationCriterion.init(testing.allocator, "Build passes");
    c2.passed = true;
    try phase.addCriterion(c2);

    try testing.expect(phase.isVerified());
}

test "WorkflowPhase - isVerified with failing criteria" {
    var phase = try WorkflowPhase.init(testing.allocator, 1, "Test", "Goal");
    defer phase.deinit();

    const c1 = try testing.allocator.create(VerificationCriterion);
    c1.* = try VerificationCriterion.init(testing.allocator, "Test passes");
    c1.passed = true;
    try phase.addCriterion(c1);

    const c2 = try testing.allocator.create(VerificationCriterion);
    c2.* = try VerificationCriterion.init(testing.allocator, "Build passes");
    c2.passed = false;
    try phase.addCriterion(c2);

    try testing.expect(!phase.isVerified());
}

test "WorkflowPhase - dependenciesMet with completed deps" {
    var p1 = try WorkflowPhase.init(testing.allocator, 1, "Phase 1", "Goal 1");
    defer p1.deinit();
    p1.status = .completed;

    var p2 = try WorkflowPhase.init(testing.allocator, 2, "Phase 2", "Goal 2");
    defer p2.deinit();
    try p2.addDependency(1);

    var phases = array_list_compat.ArrayList(*WorkflowPhase).init(testing.allocator);
    defer phases.deinit();
    try phases.append(&p1);
    try phases.append(&p2);

    try testing.expect(p2.dependenciesMet(&phases));
}

test "WorkflowPhase - dependenciesMet with pending deps" {
    var p1 = try WorkflowPhase.init(testing.allocator, 1, "Phase 1", "Goal 1");
    defer p1.deinit();
    p1.status = .pending;

    var p2 = try WorkflowPhase.init(testing.allocator, 2, "Phase 2", "Goal 2");
    defer p2.deinit();
    try p2.addDependency(1);

    var phases = array_list_compat.ArrayList(*WorkflowPhase).init(testing.allocator);
    defer phases.deinit();
    try phases.append(&p1);
    try phases.append(&p2);

    try testing.expect(!p2.dependenciesMet(&phases));
}

test "PhaseWorkflow - init and deinit" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test-project");
    defer wf.deinit();
    try testing.expectEqualStrings("test-project", wf.name);
    try testing.expectEqual(@as(usize, 0), wf.phases.items.len);
    try testing.expect(wf.current_phase == null);
    try testing.expectEqual(WaveMode.adaptive, wf.wave_mode);
}

test "PhaseWorkflow - addPhase and getPhase" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Second", "Goal 2");
    try wf.addPhase(p2);

    try testing.expectEqual(@as(usize, 2), wf.phases.items.len);
    const found = wf.getPhase(1);
    try testing.expect(found != null);
    try testing.expectEqualStrings("First", found.?.name);

    const not_found = wf.getPhase(99);
    try testing.expect(not_found == null);
}

test "PhaseWorkflow - startPhase and completePhase" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    try wf.addPhase(p1);

    try wf.startPhase(1);
    try testing.expectEqual(PhaseStatus.in_progress, p1.status);
    try testing.expect(wf.current_phase == 1);

    try wf.completePhase(1);
    try testing.expectEqual(PhaseStatus.completed, p1.status);
    try testing.expect(wf.current_phase == null);
}

test "PhaseWorkflow - verifyPhase" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    try wf.addPhase(p1);

    try wf.startPhase(1);
    try wf.verifyPhase(1);
    try testing.expectEqual(PhaseStatus.verified, p1.status);
}

test "PhaseWorkflow - nextPhase returns first pending with met deps" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    p1.status = .completed;
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Second", "Goal 2");
    try p2.addDependency(1);
    try wf.addPhase(p2);

    const next = wf.nextPhase();
    try testing.expect(next != null);
    try testing.expectEqual(@as(u32, 2), next.?.number);
}

test "PhaseWorkflow - nextPhase returns null when deps not met" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    p1.status = .pending;
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Second", "Goal 2");
    try p2.addDependency(1);
    try wf.addPhase(p2);

    // p2 depends on p1 which is pending, but p1 has no deps so it's next
    const next = wf.nextPhase();
    try testing.expect(next != null);
    try testing.expectEqual(@as(u32, 1), next.?.number);
}

test "PhaseWorkflow - progress calculation" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test");
    defer wf.deinit();

    // No phases → 0%
    try testing.expectEqual(@as(f64, 0.0), wf.progress());

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "First", "Goal 1");
    p1.status = .completed;
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Second", "Goal 2");
    p2.status = .in_progress;
    try wf.addPhase(p2);

    const p3 = try testing.allocator.create(WorkflowPhase);
    p3.* = try WorkflowPhase.init(testing.allocator, 3, "Third", "Goal 3");
    p3.status = .pending;
    try wf.addPhase(p3);

    // completed(1.0) + in_progress(0.5) + pending(0) = 1.5/3 = 50%
    const pct = wf.progress();
    try testing.expect(pct > 49.0 and pct < 51.0);
}

test "PhaseWorkflow - toXml generates valid XML" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test-wf");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Setup", "Init project");
    p1.status = .completed;
    try wf.addPhase(p1);

    const xml = try wf.toXml(testing.allocator);
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<?xml") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<workflow name=\"test-wf\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "completed") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</workflow>") != null);
}

test "PhaseWorkflow - full lifecycle: add → start → complete → verify" {
    var wf = try PhaseWorkflow.init(testing.allocator, "lifecycle-test");
    defer wf.deinit();

    // Add phases with dependencies
    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Design", "Design phase");
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Implement", "Implementation phase");
    try p2.addDependency(1);
    try wf.addPhase(p2);

    const p3 = try testing.allocator.create(WorkflowPhase);
    p3.* = try WorkflowPhase.init(testing.allocator, 3, "Test", "Testing phase");
    try p3.addDependency(2);
    try wf.addPhase(p3);

    // Phase 1
    try wf.startPhase(1);
    try testing.expectEqual(PhaseStatus.in_progress, p1.status);
    try wf.completePhase(1);
    try testing.expectEqual(PhaseStatus.completed, p1.status);

    // Phase 2
    const next = wf.nextPhase();
    try testing.expect(next != null);
    try testing.expectEqual(@as(u32, 2), next.?.number);
    try wf.startPhase(2);
    try wf.completePhase(2);

    // Phase 3
    const next2 = wf.nextPhase();
    try testing.expect(next2 != null);
    try testing.expectEqual(@as(u32, 3), next2.?.number);
    try wf.startPhase(3);
    try wf.verifyPhase(3);

    // All done
    try testing.expect(wf.nextPhase() == null);
    const pct = wf.progress();
    try testing.expect(pct > 99.0);
}
