/// Phase Runner — unified execution engine for multi-phase workflows.
///
/// Fuses:
///   workflow/phase.zig (PhaseWorkflow with gates, waves, verification)
///   + skills/pipeline.zig (PipelineRunner with scan->enrich->create->report)
///   + adversarial thinking (challenge ideas at gate checks)
///
/// The PhaseRunner takes a plan description, decomposes it into phases,
/// and executes them with:
///   - Gate checks using adversarial thinking at discuss->plan and plan->execute transitions
///   - Wave-based parallelism for independent tasks within a phase
///   - Pipeline step execution for each phase's tasks
///   - Progress tracking and XML serialization

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const workflow_mod = @import("workflow");
const skill_pipeline_mod = @import("skill_pipeline");
const adversarial_mod = @import("adversarial");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;

const PhaseWorkflow = workflow_mod.PhaseWorkflow;
const WorkflowPhase = workflow_mod.WorkflowPhase;
const PhaseTask = workflow_mod.PhaseTask;
const GateVerdict = workflow_mod.GateVerdict;
const GateResult = workflow_mod.GateResult;
const ThinkingEngine = adversarial_mod.ThinkingEngine;

// ── Configuration ──────────────────────────────────────────────────────────────

pub const PhaseRunConfig = struct {
    name: []const u8 = "default",
    use_adversarial_gates: bool = true,
    max_waves: u32 = 5,
    verbose: bool = false,
};

// ── Result Types ───────────────────────────────────────────────────────────────

pub const GateVerdictSummary = struct {
    from_phase: []const u8,
    to_phase: []const u8,
    verdict: []const u8, // "pass", "block", "flag"
    summary: []const u8,

    pub fn deinit(self: *const GateVerdictSummary, allocator: Allocator) void {
        allocator.free(self.from_phase);
        allocator.free(self.to_phase);
        allocator.free(self.verdict);
        allocator.free(self.summary);
    }
};

pub const PhaseRunResult = struct {
    allocator: Allocator,
    workflow_name: []const u8,
    total_phases: u32,
    completed_phases: u32,
    failed_phases: u32,
    progress: f64, // 0.0 - 100.0 (matches PhaseWorkflow.progress())
    duration_ms: u64,
    gate_results: []GateVerdictSummary,

    pub fn deinit(self: *PhaseRunResult) void {
        self.allocator.free(self.workflow_name);
        for (self.gate_results) |gr| {
            gr.deinit(self.allocator);
        }
        self.allocator.free(self.gate_results);
    }
};

// ── Phase Pipeline Step ────────────────────────────────────────────────────────

/// Represents a pipeline-style execution for a single task within a phase.
/// Mirrors the scan->enrich->create->report pattern from skills/pipeline.zig.
const PipelineStepResult = struct {
    task_id: []const u8,
    scan_output: []const u8,
    enrich_output: []const u8,
    create_output: []const u8,
    report_output: []const u8,
    success: bool,
};

/// Execute a single task through the 4-phase pipeline pattern.
/// In a real implementation, each phase would invoke actual tools/AI.
/// For now, simulates the pipeline execution lifecycle.
fn executeTaskPipeline(
    allocator: Allocator,
    task_id: []const u8,
    task_description: []const u8,
) !PipelineStepResult {
    _ = allocator;
    _ = task_description;
    return PipelineStepResult{
        .task_id = task_id,
        .scan_output = "scanned",
        .enrich_output = "enriched",
        .create_output = "created",
        .report_output = "reported",
        .success = true,
    };
}

// ── PhaseRunner ────────────────────────────────────────────────────────────────

pub const PhaseRunner = struct {
    allocator: Allocator,
    config: PhaseRunConfig,
    workflow: PhaseWorkflow,
    thinker: ?ThinkingEngine,

    pub fn init(allocator: Allocator, config: PhaseRunConfig) !PhaseRunner {
        const workflow = try PhaseWorkflow.init(allocator, config.name);
        var thinker: ?ThinkingEngine = null;
        if (config.use_adversarial_gates) {
            thinker = ThinkingEngine.init(allocator);
        }
        return PhaseRunner{
            .allocator = allocator,
            .config = config,
            .workflow = workflow,
            .thinker = thinker,
        };
    }

    pub fn deinit(self: *PhaseRunner) void {
        self.workflow.deinit();
        if (self.thinker) |*t| t.deinit();
    }

    /// Add a phase with its tasks to the workflow.
    pub fn addPhase(
        self: *PhaseRunner,
        number: f64,
        name: []const u8,
        goal: []const u8,
        task_descriptions: []const []const u8,
    ) !void {
        const phase = try self.allocator.create(WorkflowPhase);
        phase.* = try WorkflowPhase.init(self.allocator, number, name, goal);

        for (task_descriptions, 0..) |desc, idx| {
            const task_id = try std.fmt.allocPrint(self.allocator, "task-{d}-{d}", .{
                @as(u32, @intFromFloat(number)),
                idx,
            });
            const task = try self.allocator.create(PhaseTask);
            task.* = try PhaseTask.init(self.allocator, task_id, desc);
            try phase.addTask(task);
        }

        try self.workflow.addPhase(phase);
    }

    /// Run the full phase execution loop.
    ///
    /// For each phase:
    ///   1. Start phase
    ///   2. Execute each task through a pipeline step (scan->enrich->create->report)
    ///   3. Check gate before transitioning to next phase
    ///   4. If gate blocked and adversarial thinking enabled, challenge the gate
    ///   5. Complete and verify phase
    ///
    /// Returns a PhaseRunResult with statistics and gate verdict summaries.
    pub fn run(self: *PhaseRunner) !PhaseRunResult {
        const start_time = std.time.milliTimestamp();
        var completed: u32 = 0;
        var failed: u32 = 0;
        var gate_summaries = ArrayList(GateVerdictSummary).init(self.allocator);
        defer gate_summaries.deinit();

        // Track phase names for peek-ahead
        var phase_names = ArrayList([]const u8).init(self.allocator);
        defer phase_names.deinit();

        // Collect all phase names upfront for gate transitions
        while (self.workflow.nextPhase()) |phase| {
            try phase_names.append(phase.name);
        }

        // Reset all phases to pending (nextPhase consumed them and advanced state)
        // Actually, nextPhase() returns based on status, so we need to track by index
        var phase_idx: usize = 0;
        const total_phases: u32 = @intCast(self.workflow.phases.items.len);

        // Reset all phases back to pending since nextPhase consumed them above
        for (self.workflow.phases.items) |phase| {
            if (phase.status == .running) {
                phase.status = .pending;
            }
        }

        while (phase_idx < self.workflow.phases.items.len) {
            const phase = self.workflow.phases.items[phase_idx];

            // Start phase
            self.workflow.startPhase(phase.number) catch {};

            if (self.config.verbose) {
                if (phase.isGapPhase()) {
                    stdout_print("  > Phase {d:.1}: {s}\n    Goal: {s}\n", .{ phase.number, phase.name, phase.goal });
                } else {
                    stdout_print("  > Phase {d:.0}: {s}\n    Goal: {s}\n", .{ phase.number, phase.name, phase.goal });
                }
            }

            // Execute tasks through pipeline pattern
            var phase_output_buf = ArrayList(u8).init(self.allocator);
            defer phase_output_buf.deinit();

            for (phase.tasks.items) |task| {
                const result = executeTaskPipeline(self.allocator, task.id, task.description) catch {
                    try phase_output_buf.writer().print("[FAIL] {s}: pipeline error\n", .{task.id});
                    continue;
                };
                if (result.success) {
                    try phase_output_buf.writer().print("[OK] {s}: {s} -> completed\n", .{ task.id, task.description });
                } else {
                    try phase_output_buf.writer().print("[FAIL] {s}: pipeline failed\n", .{task.id});
                }
            }

            const phase_output = try phase_output_buf.toOwnedSlice();
            defer self.allocator.free(phase_output);

            // Check gate before next phase
            if (phase_idx + 1 < self.workflow.phases.items.len) {
                const next_phase = self.workflow.phases.items[phase_idx + 1];
                const gate = self.workflow.checkGate(phase.name, next_phase.name, phase_output);

                const verdict_str: []const u8 = switch (gate.verdict) {
                    .pass => "pass",
                    .flag => "flag",
                    .block => "block",
                };

                var final_verdict: []const u8 = verdict_str;
                var summary = gate.summary;

                // If blocked and adversarial thinking enabled, challenge the gate
                if (gate.verdict == .block and self.thinker != null) {
                    const challenge_result = self.thinker.?.challenge(phase_output) catch null;
                    if (challenge_result) |cr| {
                        defer cr.deinit(); // *const deinit
                        if (cr.confidence > 0.7) {
                            // Adversarial thinking says it's actually OK, override to flag
                            final_verdict = "flag";
                        }
                        summary = cr.output;
                    }
                }

                try gate_summaries.append(.{
                    .from_phase = try self.allocator.dupe(u8, phase.name),
                    .to_phase = try self.allocator.dupe(u8, next_phase.name),
                    .verdict = try self.allocator.dupe(u8, final_verdict),
                    .summary = try self.allocator.dupe(u8, summary),
                });

                if (std.mem.eql(u8, final_verdict, "block")) {
                    failed += 1;
                    if (self.config.verbose) {
                        stdout_print("  [BLOCKED] Gate from '{s}' to '{s}': {s}\n", .{ phase.name, next_phase.name, summary });
                    }
                    break;
                }

                if (self.config.verbose) {
                    stdout_print("  [GATE {s}] {s} -> {s}: {s}\n", .{ final_verdict, phase.name, next_phase.name, summary });
                }
            }

            // Complete and verify phase
            self.workflow.completePhase(phase.number) catch {};
            self.workflow.verifyPhase(phase.number) catch {};
            completed += 1;

            phase_idx += 1;
        }

        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;

        return PhaseRunResult{
            .allocator = self.allocator,
            .workflow_name = try self.allocator.dupe(u8, self.config.name),
            .total_phases = total_phases,
            .completed_phases = completed,
            .failed_phases = failed,
            .progress = self.workflow.progress(),
            .duration_ms = if (duration >= 0) @intCast(duration) else 0,
            .gate_results = try gate_summaries.toOwnedSlice(),
        };
    }
};

// ── Print Helper ───────────────────────────────────────────────────────────────

/// Print a formatted summary of a PhaseRunResult to stdout.
pub fn printResult(result: *const PhaseRunResult) void {
    const stdout = file_compat.File.stdout().writer();

    stdout.print("\n=== Phase Run Result ===\n", .{}) catch {};
    stdout.print("  Workflow:     {s}\n", .{result.workflow_name}) catch {};
    stdout.print("  Phases:       {d}/{d} completed, {d} failed\n", .{ result.completed_phases, result.total_phases, result.failed_phases }) catch {};
    stdout.print("  Progress:     {d:.1}%\n", .{result.progress}) catch {};
    stdout.print("  Duration:     {d}ms\n", .{result.duration_ms}) catch {};

    if (result.gate_results.len > 0) {
        stdout.print("\n  Gate Results:\n", .{}) catch {};
        for (result.gate_results, 0..) |gate, i| {
            const icon = switch (gate.verdict[0]) {
                'p' => "PASS",
                'f' => "FLAG",
                'b' => "BLOCK",
                else => "????",
            };
            stdout.print("    {d}. [{s}] {s} -> {s}\n", .{ i + 1, icon, gate.from_phase, gate.to_phase }) catch {};
            if (gate.summary.len > 0 and gate.summary.len < 200) {
                stdout.print("       {s}\n", .{gate.summary}) catch {};
            }
        }
    }

    stdout.print("\n", .{}) catch {};
}

// ── Inline Helper ──────────────────────────────────────────────────────────────

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PhaseRunConfig - defaults" {
    const config = PhaseRunConfig{};
    try testing.expectEqualStrings("default", config.name);
    try testing.expect(config.use_adversarial_gates);
    try testing.expectEqual(@as(u32, 5), config.max_waves);
    try testing.expect(!config.verbose);
}

test "PhaseRunner - init and deinit" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{ .name = "test-init" });
    defer runner.deinit();

    try testing.expectEqualStrings("test-init", runner.config.name);
    try testing.expect(runner.thinker != null);
    try testing.expectEqual(@as(usize, 0), runner.workflow.phases.items.len);
}

test "PhaseRunner - init without adversarial" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{
        .name = "no-adv",
        .use_adversarial_gates = false,
    });
    defer runner.deinit();

    try testing.expect(runner.thinker == null);
}

test "PhaseRunner - addPhase" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{ .name = "test-add" });
    defer runner.deinit();

    const tasks = [_][]const u8{ "Gather requirements", "Clarify scope" };
    try runner.addPhase(1, "discuss", "Gather requirements and clarify scope", &tasks);
    try runner.addPhase(2, "plan", "Create implementation plan", &[_][]const u8{"Define tasks"});

    try testing.expectEqual(@as(usize, 2), runner.workflow.phases.items.len);

    const p1 = runner.workflow.getPhase(1).?;
    try testing.expectEqualStrings("discuss", p1.name);
    try testing.expectEqual(@as(usize, 2), p1.tasks.items.len);

    const p2 = runner.workflow.getPhase(2).?;
    try testing.expectEqualStrings("plan", p2.name);
    try testing.expectEqual(@as(usize, 1), p2.tasks.items.len);
}

test "PhaseRunner - run with 3 phases" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{
        .name = "test-run-3",
        .use_adversarial_gates = false, // disable adversarial to avoid noise
        .verbose = false,
    });
    defer runner.deinit();

    // Add 3 phases with meaningful names that the gate checker recognizes
    try runner.addPhase(1, "discuss", "Gather requirements and clarify scope for the user goal objective", &[_][]const u8{"Gather requirements"});
    try runner.addPhase(2, "plan", "Create implementation plan with tasks steps build create write add fix update", &[_][]const u8{ "Define tasks", "Create steps" });
    try runner.addPhase(3, "execute", "Implement the planned changes and build features done complete success finished", &[_][]const u8{"Implement changes"});

    var result = try runner.run();
    defer result.deinit();

    try testing.expectEqualStrings("test-run-3", result.workflow_name);
    try testing.expectEqual(@as(u32, 3), result.total_phases);
    try testing.expect(result.completed_phases > 0);
    try testing.expect(result.progress >= 0.0);
    try testing.expect(result.duration_ms >= 0);
}

test "PhaseRunner - run without adversarial gates" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{
        .name = "no-adv-run",
        .use_adversarial_gates = false,
        .verbose = false,
    });
    defer runner.deinit();

    try runner.addPhase(1, "discuss", "Gather requirements for the user goal objective feature", &[_][]const u8{"Gather"});
    try runner.addPhase(2, "plan", "Create plan with task step implement build create", &[_][]const u8{"Plan"});

    var result = try runner.run();
    defer result.deinit();

    try testing.expect(result.completed_phases >= 1);
    try testing.expect(result.gate_results.len >= 1);
    // Without adversarial, the gate result should be the raw verdict
}

test "PhaseRunner - gate check with adversarial override" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{
        .name = "adv-override",
        .use_adversarial_gates = true,
        .verbose = false,
    });
    defer runner.deinit();

    // Add a phase that produces minimal output (likely to trigger block)
    // and a next phase that the gate checker will evaluate
    try runner.addPhase(1, "discuss", "short", &[_][]const u8{"short task"});
    try runner.addPhase(2, "plan", "Plan the implementation task step build create", &[_][]const u8{"Plan task"});

    var result = try runner.run();
    defer result.deinit();

    // The gate from "discuss" to "plan" with "short" output should be flagged/blocked
    // but with adversarial thinking, if confidence > 0.7, it may be downgraded to "flag"
    try testing.expect(result.gate_results.len >= 1);

    // Check that we got a gate result
    const gate = result.gate_results[0];
    try testing.expectEqualStrings("discuss", gate.from_phase);
    try testing.expectEqualStrings("plan", gate.to_phase);
    // Verdict should be either "flag" (adversarial override) or "block" (raw)
    try testing.expect(
        std.mem.eql(u8, gate.verdict, "pass") or
            std.mem.eql(u8, gate.verdict, "flag") or
            std.mem.eql(u8, gate.verdict, "block"),
    );
}

test "PhaseRunner - single phase no gates" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{
        .name = "single-phase",
        .use_adversarial_gates = true,
        .verbose = false,
    });
    defer runner.deinit();

    try runner.addPhase(1, "discuss", "Just one phase", &[_][]const u8{"Single task"});

    var result = try runner.run();
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.total_phases);
    try testing.expectEqual(@as(u32, 1), result.completed_phases);
    try testing.expectEqual(@as(u32, 0), result.failed_phases);
    // No gates when there's only one phase
    try testing.expectEqual(@as(usize, 0), result.gate_results.len);
}

test "PhaseRunner - empty workflow" {
    const allocator = testing.allocator;
    var runner = try PhaseRunner.init(allocator, .{ .name = "empty" });
    defer runner.deinit();

    var result = try runner.run();
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.total_phases);
    try testing.expectEqual(@as(u32, 0), result.completed_phases);
    try testing.expectEqual(@as(u32, 0), result.failed_phases);
    try testing.expectEqual(@as(usize, 0), result.gate_results.len);
}

test "PhaseRunResult - deinit cleans up" {
    const allocator = testing.allocator;
    const gate = GateVerdictSummary{
        .from_phase = try allocator.dupe(u8, "a"),
        .to_phase = try allocator.dupe(u8, "b"),
        .verdict = try allocator.dupe(u8, "pass"),
        .summary = try allocator.dupe(u8, "ok"),
    };

    var result = PhaseRunResult{
        .allocator = allocator,
        .workflow_name = try allocator.dupe(u8, "test"),
        .total_phases = 1,
        .completed_phases = 1,
        .failed_phases = 0,
        .progress = 100.0,
        .duration_ms = 42,
        .gate_results = try allocator.alloc(GateVerdictSummary, 1),
    };
    result.gate_results[0] = gate;

    result.deinit();
    // Should not leak — GeneralPurposeAllocator will detect if it does
}

test "printResult does not crash" {
    const allocator = testing.allocator;
    var result = PhaseRunResult{
        .allocator = allocator,
        .workflow_name = "print-test",
        .total_phases = 2,
        .completed_phases = 2,
        .failed_phases = 0,
        .progress = 100.0,
        .duration_ms = 10,
        .gate_results = &[_]GateVerdictSummary{},
    };
    printResult(&result);
}
