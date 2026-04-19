const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const task = @import("task");
const adversarial_mod = @import("adversarial_review");
const git_mod = @import("git");

const Allocator = std.mem.Allocator;

/// Phase status in the workflow lifecycle
pub const PhaseStatus = task.RunState;

/// Wave execution mode for parallel vs sequential tasks
/// Reference: GSD wave execution
pub const WaveMode = enum {
    sequential, // One task at a time, in order
    parallel, // All tasks run concurrently
    adaptive, // Parallel if independent, sequential if dependent
};

/// Task info used by WaveScheduler for dependency resolution.
/// Maps to PhaseTask data but flattened for topological sort.
pub const TaskInfo = struct {
    id: []const u8,
    depends_on: [][]const u8,
    wave: u32 = 0, // computed by scheduler
};

/// Result of wave-based execution with atomic commits.
pub const WaveResult = struct {
    allocator: Allocator,
    completed_waves: u32 = 0,
    total_waves: u32 = 0,
    failed: bool = false,
    failed_wave: ?u32 = null,

    pub fn deinit(self: *WaveResult) void {
        _ = self;
    }
};

/// Wave scheduler — computes dependency levels using topological sort (Kahn's algorithm).
/// Groups tasks into waves: wave 0 has no deps, wave 1 depends only on wave 0, etc.
pub const WaveScheduler = struct {
    allocator: Allocator,
    tasks: []TaskInfo,

    pub const Error = error{
        CircularDependency,
    };

    /// Compute wave assignments using topological sort (Kahn's algorithm).
    /// Returns grouped tasks: wave 0 (no deps), wave 1 (deps on wave 0), etc.
    /// Caller owns the returned slice and each inner slice (free with allocator).
    pub fn computeWaves(self: *WaveScheduler) ![][]const []const u8 {
        const n = self.tasks.len;
        if (n == 0) {
            return try self.allocator.alloc([]const []const u8, 0);
        }

        // Map task ID → index for O(1) lookup
        var id_map = std.StringHashMap(usize).init(self.allocator);
        defer id_map.deinit();
        for (self.tasks, 0..) |t, i| {
            try id_map.put(t.id, i);
        }

        // Compute in-degree: number of unresolved dependencies per task
        var in_degree = try self.allocator.alloc(u32, n);
        defer self.allocator.free(in_degree);
        for (self.tasks, 0..) |t, i| {
            var count: u32 = 0;
            for (t.depends_on) |dep_id| {
                if (id_map.contains(dep_id)) count += 1;
            }
            in_degree[i] = count;
        }

        // Build reverse adjacency: for each task, which tasks depend on it?
        var dependents = try self.allocator.alloc(std.ArrayList(usize), n);
        defer {
            for (dependents) |*list| list.deinit();
            self.allocator.free(dependents);
        }
        for (dependents) |*list| {
            list.* = std.ArrayList(usize).init(self.allocator);
        }
        for (self.tasks, 0..) |t, i| {
            for (t.depends_on) |dep_id| {
                if (id_map.get(dep_id)) |dep_idx| {
                    try dependents[dep_idx].append(i);
                }
            }
        }

        // Kahn's algorithm — level-by-level BFS
        var current_level = std.ArrayList(usize).init(self.allocator);
        defer current_level.deinit();

        // Seed: tasks with no dependencies → wave 0
        for (in_degree, 0..) |deg, i| {
            if (deg == 0) {
                self.tasks[i].wave = 0;
                try current_level.append(i);
            }
        }

        var current_wave: u32 = 0;
        var processed: u32 = 0;

        while (current_level.items.len > 0) {
            processed += @as(u32, @intCast(current_level.items.len));

            var next_level = std.ArrayList(usize).init(self.allocator);
            defer next_level.deinit();

            for (current_level.items) |idx| {
                for (dependents[idx].items) |dep_idx| {
                    in_degree[dep_idx] -= 1;
                    if (in_degree[dep_idx] == 0) {
                        self.tasks[dep_idx].wave = current_wave + 1;
                        try next_level.append(dep_idx);
                    }
                }
            }

            current_level.clearRetainingCapacity();
            for (next_level.items) |idx| {
                try current_level.append(idx);
            }

            current_wave += 1;
        }

        // Detect circular dependency
        if (processed != @as(u32, @intCast(n))) {
            return Error.CircularDependency;
        }

        // Build result: group task IDs by wave number
        var max_wave: u32 = 0;
        for (self.tasks) |t| {
            if (t.wave > max_wave) max_wave = t.wave;
        }

        const wave_count = max_wave + 1;
        var wave_lists = try self.allocator.alloc(std.ArrayList([]const u8), wave_count);
        defer {
            for (wave_lists) |*list| list.deinit();
            self.allocator.free(wave_lists);
        }
        for (wave_lists) |*list| {
            list.* = std.ArrayList([]const u8).init(self.allocator);
        }
        for (self.tasks) |t| {
            try wave_lists[t.wave].append(t.id);
        }

        var waves = try self.allocator.alloc([]const []const u8, wave_count);
        for (wave_lists, 0..) |*list, i| {
            waves[i] = try list.toOwnedSlice();
        }

        return waves;
    }

    /// Return total number of waves (max wave + 1).
    /// Only valid after computeWaves() has been called.
    pub fn totalWaves(self: *WaveScheduler) u32 {
        if (self.tasks.len == 0) return 0;
        var max_wave: u32 = 0;
        for (self.tasks) |t| {
            if (t.wave > max_wave) max_wave = t.wave;
        }
        return max_wave + 1;
    }
};

/// Gate verdict between phases — determines whether transition is allowed
pub const GateVerdict = enum {
    pass, // Proceed to next phase
    flag, // Show warnings but allow proceed
    block, // Require user approval

    pub fn toString(self: GateVerdict) []const u8 {
        return switch (self) {
            .pass => "✅ PASS",
            .flag => "⚠️ FLAG",
            .block => "🚫 BLOCK",
        };
    }
};

/// Result of a gate check between phases
pub const GateResult = struct {
    verdict: GateVerdict,
    issues: array_list_compat.ArrayList([]const u8),
    summary: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, verdict: GateVerdict, summary: []const u8) GateResult {
        return GateResult{
            .verdict = verdict,
            .issues = array_list_compat.ArrayList([]const u8).init(allocator),
            .summary = summary,
            .allocator = allocator,
        };
    }

    pub fn addIssue(self: *GateResult, issue: []const u8) !void {
        try self.issues.append(try self.allocator.dupe(u8, issue));
    }

    pub fn deinit(self: *GateResult) void {
        for (self.issues.items) |issue| self.allocator.free(issue);
        self.issues.deinit();
    }
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
    status: task.RunState,
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
/// Phase numbers use f64 to support gap/decimal phases (e.g., 1.1, 2.5)
/// Reference: GSD gap closure phases
pub const WorkflowPhase = struct {
    number: f64,
    name: []const u8,
    goal: []const u8,
    status: task.RunState,
    depends_on: array_list_compat.ArrayList(f64),
    tasks: array_list_compat.ArrayList(*PhaseTask),
    criteria: array_list_compat.ArrayList(*VerificationCriterion),
    allocator: Allocator,

    pub fn init(allocator: Allocator, number: f64, name: []const u8, goal: []const u8) !WorkflowPhase {
        return WorkflowPhase{
            .number = number,
            .name = try allocator.dupe(u8, name),
            .goal = try allocator.dupe(u8, goal),
            .status = .pending,
            .depends_on = array_list_compat.ArrayList(f64).init(allocator),
            .tasks = array_list_compat.ArrayList(*PhaseTask).init(allocator),
            .criteria = array_list_compat.ArrayList(*VerificationCriterion).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addDependency(self: *WorkflowPhase, phase_num: f64) !void {
        try self.depends_on.append(phase_num);
    }

    pub fn addTask(self: *WorkflowPhase, phase_task: *PhaseTask) !void {
        try self.tasks.append(phase_task);
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

    /// Check if this is a gap (decimal) phase — e.g., 1.1, 2.5
    pub fn isGapPhase(self: *const WorkflowPhase) bool {
        return self.number != @floor(self.number);
    }

    /// Get the parent phase number (integer part) — e.g., 1.5 → 1.0
    pub fn parentPhaseNumber(self: *const WorkflowPhase) f64 {
        return @floor(self.number);
    }

    pub fn deinit(self: *WorkflowPhase) void {
        self.allocator.free(self.name);
        self.allocator.free(self.goal);
        self.depends_on.deinit();
        for (self.tasks.items) |phase_task| {
            phase_task.deinit();
            self.allocator.destroy(phase_task);
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
    current_phase: ?f64,
    wave_mode: WaveMode,
    created_at: i64,
    last_gate_result: ?GateResult,

    pub fn init(allocator: Allocator, name: []const u8) !PhaseWorkflow {
        return PhaseWorkflow{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .phases = array_list_compat.ArrayList(*WorkflowPhase).init(allocator),
            .current_phase = null,
            .wave_mode = .adaptive,
            .created_at = std.time.timestamp(),
            .last_gate_result = null,
        };
    }

    /// Add a phase to the workflow
    pub fn addPhase(self: *PhaseWorkflow, phase: *WorkflowPhase) !void {
        try self.phases.append(phase);
    }

    /// Get a phase by number
    pub fn getPhase(self: *PhaseWorkflow, number: f64) ?*WorkflowPhase {
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

    /// Mark a phase as running
    pub fn startPhase(self: *PhaseWorkflow, number: f64) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .running;
            self.current_phase = number;
        }
    }

    /// Mark a phase as completed
    pub fn completePhase(self: *PhaseWorkflow, number: f64) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .completed;
            if (self.current_phase == number) self.current_phase = null;
        }
    }

    /// Mark a phase as verified
    pub fn verifyPhase(self: *PhaseWorkflow, number: f64) !void {
        if (self.getPhase(number)) |phase| {
            phase.status = .verified;
            if (self.current_phase == number) self.current_phase = null;
        }
    }

    /// Check the gate between two phases.
    /// Uses heuristic checks for most transitions and adversarial review
    /// for the critical plan→execute gate.
    pub fn checkGate(self: *PhaseWorkflow, from_phase: []const u8, to_phase: []const u8, phase_output: []const u8) GateResult {
        // Clean up previous gate result
        if (self.last_gate_result) |*old| {
            old.deinit();
        }

        var result: GateResult = undefined;

        if (std.mem.eql(u8, from_phase, "discuss") and std.mem.eql(u8, to_phase, "plan")) {
            result = self.checkDiscussToPlanGate(phase_output);
        } else if (std.mem.eql(u8, from_phase, "plan") and std.mem.eql(u8, to_phase, "execute")) {
            result = self.checkPlanToExecuteGate(phase_output);
        } else if (std.mem.eql(u8, from_phase, "execute") and std.mem.eql(u8, to_phase, "verify")) {
            result = self.checkExecuteToVerifyGate(phase_output);
        } else if (std.mem.eql(u8, from_phase, "verify") and std.mem.eql(u8, to_phase, "ship")) {
            result = self.checkVerifyToShipGate(phase_output);
        } else {
            // Unknown gate — pass by default
            result = GateResult.init(self.allocator, .pass, "No gate defined for this transition");
        }

        self.last_gate_result = result;
        return result;
    }

    /// discuss → plan: Check requirements exist, are specific, not ambiguous
    fn checkDiscussToPlanGate(self: *PhaseWorkflow, phase_output: []const u8) GateResult {
        var result = GateResult.init(self.allocator, .pass, "Discuss phase output looks adequate");

        if (phase_output.len == 0) {
            result.verdict = .block;
            result.summary = "Discuss phase produced no output";
            result.addIssue("Empty output — requirements not gathered") catch {};
            return result;
        }

        // Check for requirement/goal keywords
        const keywords = [_][]const u8{ "requirement", "goal", "need", "objective", "feature", "must", "should", "user" };
        var keyword_hits: u32 = 0;
        for (keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                keyword_hits += 1;
            }
        }

        if (keyword_hits == 0) {
            result.verdict = .flag;
            result.summary = "No requirement-like keywords detected";
            result.addIssue("Output lacks recognizable requirement keywords") catch {};
        }

        // Very short output is suspicious
        if (phase_output.len < 50) {
            result.verdict = .flag;
            result.summary = "Discuss output is very short";
            result.addIssue("Output is under 50 chars — may be insufficient") catch {};
        }

        return result;
    }

    /// plan → execute: Check plan has tasks, dependencies, success criteria.
    /// Uses adversarial review for deeper analysis when available.
    fn checkPlanToExecuteGate(self: *PhaseWorkflow, phase_output: []const u8) GateResult {
        var result = GateResult.init(self.allocator, .pass, "Plan phase output looks adequate");

        if (phase_output.len == 0) {
            result.verdict = .block;
            result.summary = "Plan phase produced no output";
            result.addIssue("Empty plan — nothing to execute") catch {};
            return result;
        }

        // Run adversarial review for deeper analysis
        var reviewer = adversarial_mod.AdversarialReviewer.init(self.allocator, .{
            .generator_model = "planner",
            .reviewer_model = "gate-checker",
            .min_severity = .medium,
        });
        defer reviewer.deinit();

        const review = reviewer.startReview() catch {
            // Fall back to heuristic-only if review fails
            return self.checkPlanToExecuteGateHeuristic(phase_output);
        };

        // Heuristic: check for task/action keywords
        const task_keywords = [_][]const u8{ "task", "step", "implement", "build", "create", "write", "add", "fix", "update" };
        var task_hits: u32 = 0;
        for (task_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                task_hits += 1;
            }
        }

        if (task_hits == 0) {
            _ = reviewer.addFinding(review, .high, .architecture, "No task keywords found", "Plan output lacks recognizable task descriptions") catch {};
        }

        // Heuristic: check for success criteria
        const criteria_keywords = [_][]const u8{ "test", "verify", "check", "criteria", "success", "pass", "validate" };
        var criteria_hits: u32 = 0;
        for (criteria_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                criteria_hits += 1;
            }
        }

        if (criteria_hits == 0) {
            _ = reviewer.addFinding(review, .medium, .testing, "No success criteria detected", "Plan should define verification criteria") catch {};
        }

        // Short plan is suspicious
        if (phase_output.len < 100) {
            _ = reviewer.addFinding(review, .high, .documentation, "Plan is very short", "Plan output is under 100 chars — may be insufficient") catch {};
        }

        // Map review verdict to gate verdict
        switch (review.verdict) {
            .approve => {
                result.verdict = .pass;
                result.summary = "Adversarial review approved";
            },
            .approve_with_comments => {
                result.verdict = .flag;
                result.summary = "Adversarial review approved with comments";
            },
            .request_changes => {
                result.verdict = .block;
                result.summary = "Adversarial review requests changes";
            },
            .reject => {
                result.verdict = .block;
                result.summary = "Adversarial review rejected the plan";
            },
        }

        // Collect finding titles as issues
        for (review.findings.items) |finding| {
            result.addIssue(finding.title) catch {};
        }

        return result;
    }

    /// Heuristic-only fallback for plan→execute gate (when adversarial review init fails)
    fn checkPlanToExecuteGateHeuristic(self: *PhaseWorkflow, phase_output: []const u8) GateResult {
        var result = GateResult.init(self.allocator, .pass, "Plan phase passed heuristic checks");

        const task_keywords = [_][]const u8{ "task", "step", "implement", "build", "create", "write", "add", "fix", "update" };
        var task_hits: u32 = 0;
        for (task_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                task_hits += 1;
            }
        }

        if (task_hits == 0) {
            result.verdict = .block;
            result.summary = "No task keywords found in plan";
            result.addIssue("Plan lacks recognizable task descriptions") catch {};
        } else if (task_hits <= 1) {
            result.verdict = .flag;
            result.summary = "Very few task keywords in plan";
            result.addIssue("Plan may not have enough detail for execution") catch {};
        }

        if (phase_output.len < 100) {
            result.verdict = .block;
            result.summary = "Plan output is too short";
            result.addIssue("Plan is under 100 chars") catch {};
        }

        return result;
    }

    /// execute → verify: Check all tasks completed, no failures
    fn checkExecuteToVerifyGate(self: *PhaseWorkflow, phase_output: []const u8) GateResult {
        var result = GateResult.init(self.allocator, .pass, "Execute phase output looks adequate");

        if (phase_output.len == 0) {
            result.verdict = .block;
            result.summary = "Execute phase produced no output";
            result.addIssue("Empty output — nothing to verify") catch {};
            return result;
        }

        // Check for failure/error keywords — high density is concerning
        const fail_keywords = [_][]const u8{ "error", "failed", "failure", "panic", "segfault" };
        var fail_hits: u32 = 0;
        for (fail_keywords) |kw| {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, phase_output, pos, kw)) |idx| {
                fail_hits += 1;
                pos = idx + kw.len;
            }
        }

        // Check for completion/success keywords
        const success_keywords = [_][]const u8{ "done", "complete", "success", "finished", "built", "passed" };
        var success_hits: u32 = 0;
        for (success_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                success_hits += 1;
            }
        }

        // If failures dominate, block
        if (fail_hits > 3 and fail_hits > success_hits * 2) {
            result.verdict = .block;
            result.summary = "Too many errors in execution output";
            result.addIssue("Error keywords dominate the output") catch {};
        } else if (fail_hits > 0 and success_hits == 0) {
            result.verdict = .flag;
            result.summary = "Errors detected with no success markers";
            result.addIssue("Execution has errors but no success indicators") catch {};
        }

        return result;
    }

    /// verify → ship: Check tests pass, no regressions
    fn checkVerifyToShipGate(self: *PhaseWorkflow, phase_output: []const u8) GateResult {
        var result = GateResult.init(self.allocator, .pass, "Verification passed");

        if (phase_output.len == 0) {
            result.verdict = .flag;
            result.summary = "Verify phase produced no output";
            result.addIssue("No verification output recorded") catch {};
            return result;
        }

        // Check for pass/ok indicators
        const pass_keywords = [_][]const u8{ "pass", "ok", "success", "passed", "green", "✅", "all tests" };
        var pass_hits: u32 = 0;
        for (pass_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                pass_hits += 1;
            }
        }

        // Check for failure indicators
        const fail_keywords = [_][]const u8{ "fail", "error", "regression", "broken", "❌" };
        var fail_hits: u32 = 0;
        for (fail_keywords) |kw| {
            if (indexOfIgnoreCase(phase_output, kw)) |_| {
                fail_hits += 1;
            }
        }

        if (fail_hits > 0 and pass_hits == 0) {
            result.verdict = .block;
            result.summary = "Verification shows failures with no passes";
            result.addIssue("Tests failing — cannot ship") catch {};
        } else if (fail_hits > pass_hits) {
            result.verdict = .block;
            result.summary = "More failures than passes in verification";
            result.addIssue("Failures outnumber passes") catch {};
        } else if (pass_hits == 0) {
            result.verdict = .flag;
            result.summary = "No explicit pass indicators found";
            result.addIssue("Consider adding explicit pass/fail markers") catch {};
        }

        return result;
    }

    /// Insert a gap closure phase between two existing phases.
    /// Gap phases use decimal numbering (e.g., insert between 1 and 2 → 1.1).
    /// Reference: GSD decimal phases for unplanned work that fills gaps.
    ///
    /// If `after` = 1 and `before` = 2, the gap phase gets number 1.1.
    /// If a gap already exists at 1.1, increments to 1.2, etc.
    pub fn insertGapPhase(
        self: *PhaseWorkflow,
        after: f64,
        before: f64,
        name: []const u8,
        goal: []const u8,
    ) !*WorkflowPhase {
        // Find the base number: use 'after' as the integer base
        const base = @floor(after);
        var gap_number: f64 = base + 0.1;

        // Find next available decimal slot (1.1, 1.2, 1.3, ...)
        while (self.getPhase(gap_number) != null) {
            gap_number += 0.1;
            // Safety: don't exceed the 'before' phase number
            if (gap_number >= before) {
                gap_number = (after + before) / 2.0;
                if (self.getPhase(gap_number) != null) {
                    return error.NoGapSlotAvailable;
                }
                break;
            }
        }

        const phase = try self.allocator.create(WorkflowPhase);
        phase.* = try WorkflowPhase.init(self.allocator, gap_number, name, goal);

        // Gap phases depend on the 'after' phase
        try phase.addDependency(after);

        // The 'before' phase should depend on this gap phase
        if (self.getPhase(before)) |before_phase| {
            try before_phase.addDependency(gap_number);
        }

        // Insert in sorted order by phase number
        var insert_idx: usize = 0;
        for (self.phases.items, 0..) |p, i| {
            if (p.number > gap_number) {
                insert_idx = i;
                break;
            }
            insert_idx = i + 1;
        }
        try self.phases.insert(phase, insert_idx);

        return phase;
    }

    /// List all gap (decimal) phases
    pub fn gapPhases(self: *const PhaseWorkflow) array_list_compat.ArrayList(*WorkflowPhase) {
        var gaps = array_list_compat.ArrayList(*WorkflowPhase).init(self.allocator);
        for (self.phases.items) |phase| {
            if (phase.isGapPhase()) {
                gaps.append(phase) catch {};
            }
        }
        return gaps;
    }

    /// Calculate overall progress percentage
    pub fn progress(self: *const PhaseWorkflow) f64 {
        if (self.phases.items.len == 0) return 0.0;
        var completed: f64 = 0.0;
        for (self.phases.items) |phase| {
            if (phase.status == .completed or phase.status == .verified) {
                completed += 1.0;
            } else if (phase.status == .running) {
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
            // Format number: "1" for whole, "1.1" for gap phases
            if (phase.isGapPhase()) {
                try writer.print("  <phase number=\"{d:.1}\" name=\"{s}\" status=\"{s}\">\n", .{
                    phase.number,
                    phase.name,
                    status_str,
                });
            } else {
                try writer.print("  <phase number=\"{d:.0}\" name=\"{s}\" status=\"{s}\">\n", .{
                    phase.number,
                    phase.name,
                    status_str,
                });
            }
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
            for (phase.tasks.items) |phase_task| {
                try writer.print("    <task id=\"{s}\" status=\"{s}\">\n", .{
                    phase_task.id,
                    @tagName(phase_task.status),
                });
                try writer.print("      <description>{s}</description>\n", .{phase_task.description});
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

    /// Import workflow from XML plan string.
    /// Parses the XML format produced by toXml().
    /// Reference: GSD XML atomic plan format (F5)
    pub fn fromXml(allocator: Allocator, xml: []const u8) !PhaseWorkflow {
        // Extract workflow name
        const name = extractAttribute(xml, "workflow", "name") orelse "imported";
        var wf = try PhaseWorkflow.init(allocator, name);

        // Parse phases
        var pos: usize = 0;
        while (true) {
            const phase_start = std.mem.indexOfPos(u8, xml, pos, "<phase ") orelse break;
            const phase_end = std.mem.indexOfPos(u8, xml, phase_start, "</phase>") orelse break;

            const phase_xml = xml[phase_start .. phase_end + "</phase>".len];
            pos = phase_end + "</phase>".len;

            // Extract phase attributes
            const number_str = extractAttribute(phase_xml, "phase", "number") orelse continue;
            const phase_name = extractAttribute(phase_xml, "phase", "name") orelse continue;
            const status_str = extractAttribute(phase_xml, "phase", "status") orelse "pending";

            const number = std.fmt.parseFloat(f64, number_str) catch continue;

            const goal = extractContent(phase_xml, "goal") orelse "";

            const phase = try allocator.create(WorkflowPhase);
            phase.* = try WorkflowPhase.init(allocator, number, phase_name, goal);

            // Set status
            if (std.mem.eql(u8, status_str, "pending")) {
                phase.status = .pending;
            } else if (std.mem.eql(u8, status_str, "running")) {
                phase.status = .running;
            } else if (std.mem.eql(u8, status_str, "completed")) {
                phase.status = .completed;
            } else if (std.mem.eql(u8, status_str, "verified")) {
                phase.status = .verified;
            } else if (std.mem.eql(u8, status_str, "failed")) {
                phase.status = .failed;
            } else if (std.mem.eql(u8, status_str, "cancelled")) {
                phase.status = .cancelled;
            }

            // Parse dependencies
            if (extractContent(phase_xml, "depends-on")) |deps_str| {
                var dep_iter = std.mem.splitScalar(u8, deps_str, ',');
                while (dep_iter.next()) |dep| {
                    const trimmed = std.mem.trim(u8, dep, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    const dep_num = std.fmt.parseFloat(f64, trimmed) catch continue;
                    try phase.addDependency(dep_num);
                }
            }

            // Parse tasks
            var task_pos: usize = 0;
            while (true) {
                const task_start = std.mem.indexOfPos(u8, phase_xml, task_pos, "<task ") orelse break;
                const task_end = std.mem.indexOfPos(u8, phase_xml, task_start, "</task>") orelse break;

                const task_xml = phase_xml[task_start .. task_end + "</task>".len];
                task_pos = task_end + "</task>".len;

                const task_id = extractAttribute(task_xml, "task", "id") orelse continue;
                const task_status_str = extractAttribute(task_xml, "task", "status") orelse "pending";
                const task_desc = extractContent(task_xml, "description") orelse "";

                const pt = try allocator.create(PhaseTask);
                pt.* = try PhaseTask.init(allocator, task_id, task_desc);

                if (std.mem.eql(u8, task_status_str, "completed") or std.mem.eql(u8, task_status_str, "verified")) {
                    pt.status = .completed;
                } else if (std.mem.eql(u8, task_status_str, "running")) {
                    pt.status = .running;
                } else if (std.mem.eql(u8, task_status_str, "failed")) {
                    pt.status = .failed;
                }

                try phase.addTask(pt);
            }

            // Parse criteria
            var crit_pos: usize = 0;
            while (true) {
                const crit_start = std.mem.indexOfPos(u8, phase_xml, crit_pos, "<criterion ") orelse break;
                const crit_end = std.mem.indexOfPos(u8, phase_xml, crit_start, "</criterion>") orelse break;

                const crit_xml = phase_xml[crit_start .. crit_end + "</criterion>".len];
                crit_pos = crit_end + "</criterion>".len;

                // Extract content between tags
                const content_start = std.mem.indexOfScalar(u8, crit_xml, '>') orelse continue;
                const content_end = std.mem.indexOfPos(u8, crit_xml, content_start, "</criterion>") orelse continue;
                const desc = std.mem.trim(u8, crit_xml[content_start + 1 .. content_end], " \t\r\n");

                if (desc.len == 0) continue;

                const c = try allocator.create(VerificationCriterion);
                c.* = try VerificationCriterion.init(allocator, desc);

                const passed_str = extractAttribute(crit_xml, "criterion", "passed") orelse "false";
                c.passed = std.mem.eql(u8, passed_str, "true");

                try phase.addCriterion(c);
            }

            try wf.addPhase(phase);
        }

        return wf;
    }

    /// Print workflow progress
    pub fn printProgress(self: *PhaseWorkflow) void {
        const stdout = file_compat.File.stdout().writer();
        const pct = self.progress();

        stdout.print("\n=== Workflow: {s} ({d:.0}% complete) ===\n\n", .{ self.name, pct }) catch {};

        for (self.phases.items) |phase| {
            const status_icon = switch (phase.status) {
                .pending => "⏳",
                .running => "🔄",
                .completed => "✅",
                .failed => "❌",
                .cancelled => "🚫",
                .skipped => "⏭️ ",
                .verified => "✓ ",
            };
            if (phase.isGapPhase()) {
                stdout.print("  {s} Phase {d:.1}: {s}\n", .{ status_icon, phase.number, phase.name }) catch {};
            } else {
                stdout.print("  {s} Phase {d:.0}: {s}\n", .{ status_icon, phase.number, phase.name }) catch {};
            }
            stdout.print("     Goal: {s}\n", .{phase.goal}) catch {};

            if (phase.tasks.items.len > 0) {
                var done: u32 = 0;
                for (phase.tasks.items) |phase_task| {
                    if (phase_task.status == .completed or phase_task.status == .verified) done += 1;
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

        // Show gate status if available
        if (self.last_gate_result) |gr| {
            stdout.print("  [REVIEW GATE: {s}", .{gr.verdict.toString()}) catch {};
            if (gr.issues.items.len > 0) {
                stdout.print(" — {d} issue{s}", .{ gr.issues.items.len, if (gr.issues.items.len == 1) "" else "s" }) catch {};
            }
            stdout.print("]\n", .{}) catch {};
        }

        if (self.current_phase) |cp| {
            if (cp == @floor(cp)) {
                stdout.print("  ▶ Current: Phase {d:.0}\n", .{cp}) catch {};
            } else {
                stdout.print("  ▶ Current: Phase {d:.1}\n", .{cp}) catch {};
            }
        } else if (self.nextPhase()) |np| {
            if (np.isGapPhase()) {
                stdout.print("  ▶ Next: Phase {d:.1} ({s})\n", .{ np.number, np.name }) catch {};
            } else {
                stdout.print("  ▶ Next: Phase {d:.0} ({s})\n", .{ np.number, np.name }) catch {};
            }
        }
    }

    /// Execute all tasks across all phases using wave-based dependency resolution.
    /// Tasks execute wave-by-wave. Each completed task auto-commits.
    /// Failed wave triggers rollback to the checkpoint before that wave.
    pub fn executeWaves(self: *PhaseWorkflow, allocator: Allocator) !WaveResult {
        // Collect all PhaseTask objects into TaskInfo slice for the scheduler
        var task_infos = array_list_compat.ArrayList(TaskInfo).init(allocator);
        defer task_infos.deinit();

        for (self.phases.items) |phase| {
            for (phase.tasks.items) |phase_task| {
                try task_infos.append(.{
                    .id = phase_task.id,
                    .depends_on = phase_task.depends_on.items,
                    .wave = 0,
                });
            }
        }

        // Edge case: no tasks to execute
        if (task_infos.items.len == 0) {
            return WaveResult{ .allocator = allocator };
        }

        var scheduler = WaveScheduler{
            .allocator = allocator,
            .tasks = task_infos.items,
        };

        const waves = try scheduler.computeWaves();
        defer {
            for (waves) |wave| allocator.free(wave);
            allocator.free(waves);
        }

        var results = WaveResult{
            .allocator = allocator,
            .total_waves = @as(u32, @intCast(waves.len)),
        };

        for (waves, 0..) |wave, wave_idx| {
            // Save checkpoint before this wave
            const checkpoint = git_mod.getCurrentRef(allocator) catch {
                // Not in a git repo — skip checkpointing
                var no_git_results = WaveResult{
                    .allocator = allocator,
                    .total_waves = @as(u32, @intCast(waves.len)),
                    .completed_waves = @as(u32, @intCast(wave_idx)),
                };
                // Still execute tasks without git safety net
                for (wave) |task_id| {
                    self.markTaskById(task_id, .running);
                    self.markTaskById(task_id, .completed);
                }
                no_git_results.completed_waves += 1;
                return no_git_results;
            };
            defer allocator.free(checkpoint);

            // Execute all tasks in this wave and auto-commit each one
            // Track wave failure — real execution would set this on task failure
            const wave_failed = false;
            for (wave) |task_id| {
                self.markTaskById(task_id, .running);

                // Mark task as completed (real execution would happen here)
                self.markTaskById(task_id, .completed);

                // Atomic commit after each task
                const desc = self.findTaskDescriptionById(task_id) orelse task_id;
                git_mod.autoCommit(allocator, desc) catch {
                    // Commit failure is non-fatal — continue
                };

                // If task execution had failed:
                // wave_failed = true;
                // break;
            }

            if (wave_failed) {
                // Rollback to checkpoint before this wave
                git_mod.rollbackTo(allocator, checkpoint) catch {};
                results.failed = true;
                results.failed_wave = @as(u32, @intCast(wave_idx));
                return results;
            }

            results.completed_waves += 1;
        }

        return results;
    }

    /// Find a PhaseTask by ID across all phases and update its status
    fn markTaskById(self: *PhaseWorkflow, task_id: []const u8, new_status: task.RunState) void {
        for (self.phases.items) |phase| {
            for (phase.tasks.items) |phase_task| {
                if (std.mem.eql(u8, phase_task.id, task_id)) {
                    phase_task.status = new_status;
                    return;
                }
            }
        }
    }

    /// Find a task's description by its ID
    fn findTaskDescriptionById(self: *PhaseWorkflow, task_id: []const u8) ?[]const u8 {
        for (self.phases.items) |phase| {
            for (phase.tasks.items) |phase_task| {
                if (std.mem.eql(u8, phase_task.id, task_id)) {
                    return phase_task.description;
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *PhaseWorkflow) void {
        self.allocator.free(self.name);
        if (self.last_gate_result) |*gr| {
            gr.deinit();
        }
        for (self.phases.items) |phase| {
            phase.deinit();
            self.allocator.destroy(phase);
        }
        self.phases.deinit();
    }
};

// ============================================================
// XML Parsing Helpers
// ============================================================

/// Extract an attribute value from an XML tag.
/// E.g., extractAttribute("<phase number=\"1\" name=\"test\">", "phase", "number") → "1"
fn extractAttribute(xml: []const u8, tag: []const u8, attr: []const u8) ?[]const u8 {
    _ = tag;
    const tag_start = std.mem.indexOf(u8, xml, "<") orelse return null;
    const tag_end = std.mem.indexOfPos(u8, xml, tag_start, ">") orelse return null;
    const tag_content = xml[tag_start + 1 .. tag_end];

    // Find attribute="value"
    const search = std.fmt.allocPrint(std.heap.page_allocator, "{s}=\"", .{attr}) catch return null;
    defer std.heap.page_allocator.free(search);
    const attr_start = std.mem.indexOf(u8, tag_content, search) orelse return null;
    const value_start = attr_start + search.len;
    const value_end = std.mem.indexOfScalarPos(u8, tag_content, value_start, '"') orelse return null;

    return tag_content[value_start..value_end];
}

/// Extract text content between XML tags.
/// E.g., extractContent("<goal>Build the thing</goal>", "goal") → "Build the thing"
fn extractContent(xml: []const u8, tag: []const u8) ?[]const u8 {
    const open_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open_tag);
    const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close_tag);

    const start = std.mem.indexOf(u8, xml, open_tag) orelse return null;
    const content_start = start + open_tag.len;
    const end = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse return null;

    return std.mem.trim(u8, xml[content_start..end], " \t\r\n");
}

// ============================================================
// Case-insensitive search helper (Zig 0.15 removed indexOfIgnoreCase)
// ============================================================

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return @as(usize, 0);
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

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
    const phase_task = try PhaseTask.init(testing.allocator, "T1", "Write module");
    defer {
        var mutable = phase_task;
        mutable.deinit();
    }
    try testing.expectEqualStrings("T1", phase_task.id);
    try testing.expectEqualStrings("Write module", phase_task.description);
    try testing.expectEqual(PhaseStatus.pending, phase_task.status);
    try testing.expectEqual(@as(usize, 0), phase_task.depends_on.items.len);
}

test "PhaseTask - addDependency" {
    var phase_task = try PhaseTask.init(testing.allocator, "T1", "Write module");
    defer phase_task.deinit();
    try phase_task.addDependency("T0");
    try testing.expectEqual(@as(usize, 1), phase_task.depends_on.items.len);
    try testing.expectEqualStrings("T0", phase_task.depends_on.items[0]);
}

test "WorkflowPhase - init and deinit" {
    const phase = try WorkflowPhase.init(testing.allocator, 1, "Setup", "Initialize project");
    defer {
        var mutable = phase;
        mutable.deinit();
    }
    try testing.expectEqual(@as(f64, 1.0), phase.number);
    try testing.expectEqualStrings("Setup", phase.name);
    try testing.expectEqualStrings("Initialize project", phase.goal);
    try testing.expectEqual(PhaseStatus.pending, phase.status);
}

test "WorkflowPhase - addDependency" {
    var phase = try WorkflowPhase.init(testing.allocator, 2, "Build", "Build the thing");
    defer phase.deinit();
    try phase.addDependency(1);
    try testing.expectEqual(@as(usize, 1), phase.depends_on.items.len);
    try testing.expectEqual(@as(f64, 1.0), phase.depends_on.items[0]);
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
    try testing.expectEqual(PhaseStatus.running, p1.status);
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
    try testing.expectEqual(@as(f64, 2.0), next.?.number);
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
    try testing.expectEqual(@as(f64, 1.0), next.?.number);
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
    p2.status = .running;
    try wf.addPhase(p2);

    const p3 = try testing.allocator.create(WorkflowPhase);
    p3.* = try WorkflowPhase.init(testing.allocator, 3, "Third", "Goal 3");
    p3.status = .pending;
    try wf.addPhase(p3);

    // completed(1.0) + running(0.5) + pending(0) = 1.5/3 = 50%
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
    try testing.expectEqual(PhaseStatus.running, p1.status);
    try wf.completePhase(1);
    try testing.expectEqual(PhaseStatus.completed, p1.status);

    // Phase 2
    const next = wf.nextPhase();
    try testing.expect(next != null);
    try testing.expectEqual(@as(f64, 2.0), next.?.number);
    try wf.startPhase(2);
    try wf.completePhase(2);

    // Phase 3
    const next2 = wf.nextPhase();
    try testing.expect(next2 != null);
    try testing.expectEqual(@as(f64, 3.0), next2.?.number);
    try wf.startPhase(3);
    try wf.verifyPhase(3);

    // All done
    try testing.expect(wf.nextPhase() == null);
    const pct = wf.progress();
    try testing.expect(pct > 99.0);
}

test "WorkflowPhase - isGapPhase detection" {
    const regular = try WorkflowPhase.init(testing.allocator, 1, "Phase 1", "Goal");
    defer {
        var mutable = regular;
        mutable.deinit();
    }
    try testing.expect(!regular.isGapPhase());

    const gap = try WorkflowPhase.init(testing.allocator, 1.1, "Gap Fix", "Fill gap");
    defer {
        var mutable2 = gap;
        mutable2.deinit();
    }
    try testing.expect(gap.isGapPhase());
}

test "WorkflowPhase - parentPhaseNumber" {
    const gap = try WorkflowPhase.init(testing.allocator, 2.5, "Gap", "Goal");
    defer {
        var mutable = gap;
        mutable.deinit();
    }
    try testing.expectEqual(@as(f64, 2.0), gap.parentPhaseNumber());
}

test "PhaseWorkflow - insertGapPhase basic" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test-gap");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Design", "Design phase");
    p1.status = .completed;
    try wf.addPhase(p1);

    const p3 = try testing.allocator.create(WorkflowPhase);
    p3.* = try WorkflowPhase.init(testing.allocator, 2, "Implement", "Implementation phase");
    try wf.addPhase(p3);

    // Insert gap phase between 1 and 2
    const gap = try wf.insertGapPhase(1, 2, "Fix Design Gap", "Address missed design issue");
    try testing.expectEqual(@as(f64, 1.1), gap.number);
    try testing.expect(gap.isGapPhase());

    // Gap phase depends on phase 1
    try testing.expectEqual(@as(usize, 1), gap.depends_on.items.len);
    try testing.expectEqual(@as(f64, 1.0), gap.depends_on.items[0]);

    // Phase 2 now depends on gap phase
    try testing.expectEqual(@as(usize, 1), p3.depends_on.items.len);
    try testing.expectEqual(@as(f64, 1.1), p3.depends_on.items[0]);

    // Phase count increased
    try testing.expectEqual(@as(usize, 3), wf.phases.items.len);
}

test "PhaseWorkflow - insertGapPhase multiple gaps" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test-multi-gap");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Phase 1", "Goal 1");
    p1.status = .completed;
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Phase 2", "Goal 2");
    try wf.addPhase(p2);

    const gap1 = try wf.insertGapPhase(1, 2, "Gap 1.1", "First gap");
    try testing.expectEqual(@as(f64, 1.1), gap1.number);

    const gap2 = try wf.insertGapPhase(1, 2, "Gap 1.2", "Second gap");
    try testing.expectEqual(@as(f64, 1.2), gap2.number);

    // Order should be: 1, 1.1, 1.2, 2
    try testing.expectEqual(@as(f64, 1.0), wf.phases.items[0].number);
    try testing.expectEqual(@as(f64, 1.1), wf.phases.items[1].number);
    try testing.expectEqual(@as(f64, 1.2), wf.phases.items[2].number);
    try testing.expectEqual(@as(f64, 2.0), wf.phases.items[3].number);
}

test "PhaseWorkflow - gapPhases lists only decimal phases" {
    var wf = try PhaseWorkflow.init(testing.allocator, "test-list-gaps");
    defer wf.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Phase 1", "Goal 1");
    try wf.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Phase 2", "Goal 2");
    try wf.addPhase(p2);

    _ = try wf.insertGapPhase(1, 2, "Gap 1.1", "First gap");
    _ = try wf.insertGapPhase(1, 2, "Gap 1.2", "Second gap");

    var gaps = wf.gapPhases();
    defer gaps.deinit();
    try testing.expectEqual(@as(usize, 2), gaps.items.len);
}

test "PhaseWorkflow - fromXml round-trip" {
    // Create a workflow, export to XML, then re-import
    var original = try PhaseWorkflow.init(testing.allocator, "round-trip-test");
    defer original.deinit();

    const p1 = try testing.allocator.create(WorkflowPhase);
    p1.* = try WorkflowPhase.init(testing.allocator, 1, "Design", "Design the system");
    p1.status = .completed;
    try original.addPhase(p1);

    const p2 = try testing.allocator.create(WorkflowPhase);
    p2.* = try WorkflowPhase.init(testing.allocator, 2, "Implement", "Build the thing");
    try p2.addDependency(1);
    try original.addPhase(p2);

    // Add a task to phase 2
    const t1 = try testing.allocator.create(PhaseTask);
    t1.* = try PhaseTask.init(testing.allocator, "T1", "Write module");
    try p2.addTask(t1);

    // Add a criterion to phase 1
    const c1 = try testing.allocator.create(VerificationCriterion);
    c1.* = try VerificationCriterion.init(testing.allocator, "Design doc exists");
    c1.passed = true;
    try p1.addCriterion(c1);

    // Export to XML
    const xml = try original.toXml(testing.allocator);
    defer testing.allocator.free(xml);

    // Verify XML contains expected content
    try testing.expect(std.mem.indexOf(u8, xml, "<workflow name=\"round-trip-test\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "completed") != null);

    // Import from XML
    var imported = try PhaseWorkflow.fromXml(testing.allocator, xml);
    defer imported.deinit();

    // Verify imported workflow
    try testing.expectEqualStrings("round-trip-test", imported.name);
    try testing.expectEqual(@as(usize, 2), imported.phases.items.len);

    // Phase 1 should be completed
    const imported_p1 = imported.getPhase(1);
    try testing.expect(imported_p1 != null);
    try testing.expectEqual(PhaseStatus.completed, imported_p1.?.status);
    try testing.expectEqualStrings("Design", imported_p1.?.name);

    // Phase 2 should have dependency on phase 1
    const imported_p2 = imported.getPhase(2);
    try testing.expect(imported_p2 != null);
    try testing.expectEqual(@as(usize, 1), imported_p2.?.depends_on.items.len);
    try testing.expectEqual(@as(f64, 1.0), imported_p2.?.depends_on.items[0]);

    // Phase 2 should have the task
    try testing.expectEqual(@as(usize, 1), imported_p2.?.tasks.items.len);
    try testing.expectEqualStrings("T1", imported_p2.?.tasks.items[0].id);

    // Phase 1 should have the criterion (passed)
    try testing.expectEqual(@as(usize, 1), imported_p1.?.criteria.items.len);
    try testing.expect(imported_p1.?.criteria.items[0].passed);
}

test "PhaseWorkflow - fromXml with gap phase" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<workflow name="gap-test">
        \\  <phase number="1" name="Phase 1" status="completed">
        \\    <goal>Goal 1</goal>
        \\  </phase>
        \\  <phase number="1.1" name="Fix Gap" status="pending">
        \\    <goal>Fix the thing</goal>
        \\    <depends-on>1</depends-on>
        \\  </phase>
        \\  <phase number="2" name="Phase 2" status="pending">
        \\    <goal>Goal 2</goal>
        \\  </phase>
        \\</workflow>
    ;

    var wf = try PhaseWorkflow.fromXml(testing.allocator, xml);
    defer wf.deinit();

    try testing.expectEqual(@as(usize, 3), wf.phases.items.len);

    const gap = wf.getPhase(1.1);
    try testing.expect(gap != null);
    try testing.expect(gap.?.isGapPhase());
    try testing.expectEqualStrings("Fix Gap", gap.?.name);
    try testing.expectEqual(@as(usize, 1), gap.?.depends_on.items.len);
}
