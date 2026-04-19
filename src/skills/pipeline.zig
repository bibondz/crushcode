//! Multi-phase skill execution engine.
//! Runs skills through a structured Scan → Enrich → Create → Report pipeline.
//! Each pipeline consists of ordered steps grouped into phases that execute sequentially.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// ── Enums ──────────────────────────────────────────────────────────────────────

/// The four phases of a skill pipeline, executed in order.
pub const PipelinePhase = enum {
    scan,
    enrich,
    create,
    report,

    pub fn label(self: PipelinePhase) []const u8 {
        return switch (self) {
            .scan => "Scan",
            .enrich => "Enrich",
            .create => "Create",
            .report => "Report",
        };
    }

    /// Returns the next phase in sequence, or null if this is the last one.
    pub fn next(self: PipelinePhase) ?PipelinePhase {
        return switch (self) {
            .scan => .enrich,
            .enrich => .create,
            .create => .report,
            .report => null,
        };
    }

    /// All phases in execution order.
    pub const all = [_]PipelinePhase{ .scan, .enrich, .create, .report };
};

/// Status of an individual step within a pipeline phase.
pub const PhaseStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,

    pub fn label(self: PhaseStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .skipped => "skipped",
        };
    }
};

/// Overall status of a pipeline.
pub const PipelineStatus = enum {
    idle,
    running,
    completed,
    failed,
    paused,

    pub fn label(self: PipelineStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .paused => "paused",
        };
    }
};

// ── PhaseStep ──────────────────────────────────────────────────────────────────

/// A single step within a pipeline phase.
pub const PhaseStep = struct {
    allocator: Allocator,
    name: []const u8,
    phase: PipelinePhase,
    description: []const u8,
    is_parallel: bool,
    status: PhaseStatus,
    input: []const u8,
    output: []const u8,
    error_message: ?[]const u8,
    started_at: ?i64,
    completed_at: ?i64,

    pub fn init(
        allocator: Allocator,
        name: []const u8,
        phase: PipelinePhase,
        description: []const u8,
        is_parallel: bool,
    ) !PhaseStep {
        return PhaseStep{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .phase = phase,
            .description = try allocator.dupe(u8, description),
            .is_parallel = is_parallel,
            .status = .pending,
            .input = try allocator.dupe(u8, ""),
            .output = try allocator.dupe(u8, ""),
            .error_message = null,
            .started_at = null,
            .completed_at = null,
        };
    }

    pub fn deinit(self: *PhaseStep) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.input);
        self.allocator.free(self.output);
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Mark step as running with current timestamp.
    pub fn start(self: *PhaseStep) void {
        self.status = .running;
        self.started_at = std.time.milliTimestamp();
    }

    /// Mark step as completed with output.
    pub fn complete(self: *PhaseStep, output: []const u8) !void {
        self.allocator.free(self.output);
        self.output = try self.allocator.dupe(u8, output);
        self.status = .completed;
        self.completed_at = std.time.milliTimestamp();
    }

    /// Mark step as failed with an error message.
    pub fn fail(self: *PhaseStep, err_msg: []const u8) !void {
        if (self.error_message) |old| {
            self.allocator.free(old);
        }
        self.error_message = try self.allocator.dupe(u8, err_msg);
        self.status = .failed;
        self.completed_at = std.time.milliTimestamp();
    }

    /// Get duration in milliseconds, or 0 if not yet started/completed.
    pub fn durationMs(self: *const PhaseStep) i64 {
        const start_ts = self.started_at orelse return 0;
        const end_ts = self.completed_at orelse std.time.milliTimestamp();
        return end_ts - start_ts;
    }

    /// Reset step to pending state.
    pub fn reset(self: *PhaseStep) void {
        self.status = .pending;
        self.started_at = null;
        self.completed_at = null;
        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }
    }
};

// ── PipelineResult ─────────────────────────────────────────────────────────────

/// Summary result of a pipeline execution.
pub const PipelineResult = struct {
    pipeline_name: []const u8,
    status: PipelineStatus,
    total_steps: u32,
    completed_steps: u32,
    failed_steps: u32,
    duration_ms: u64,
    output_path: []const u8,

    pub fn deinit(self: *PipelineResult, allocator: Allocator) void {
        allocator.free(self.pipeline_name);
        allocator.free(self.output_path);
    }
};

// ── SkillPipeline ──────────────────────────────────────────────────────────────

/// A named pipeline consisting of ordered steps across four phases.
pub const SkillPipeline = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    steps: array_list_compat.ArrayList(*PhaseStep),
    current_phase: ?PipelinePhase,
    status: PipelineStatus,
    started_at: ?i64,
    completed_at: ?i64,

    pub fn init(allocator: Allocator, name: []const u8, description: []const u8) !SkillPipeline {
        return SkillPipeline{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .steps = array_list_compat.ArrayList(*PhaseStep).init(allocator),
            .current_phase = null,
            .status = .idle,
            .started_at = null,
            .completed_at = null,
        };
    }

    pub fn deinit(self: *SkillPipeline) void {
        for (self.steps.items) |step| {
            var mut_step = step;
            mut_step.deinit();
            self.allocator.destroy(mut_step);
        }
        self.steps.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.description);
    }

    /// Add a step to the pipeline. Returns a pointer to the created step.
    pub fn addStep(
        self: *SkillPipeline,
        name: []const u8,
        phase: PipelinePhase,
        description: []const u8,
        is_parallel: bool,
    ) !*PhaseStep {
        const step_ptr = try self.allocator.create(PhaseStep);
        step_ptr.* = try PhaseStep.init(self.allocator, name, phase, description, is_parallel);
        try self.steps.append(step_ptr);
        return step_ptr;
    }

    /// Get all steps belonging to a specific phase.
    pub fn getStepsByPhase(self: *SkillPipeline, phase: PipelinePhase) ![]*PhaseStep {
        var result = array_list_compat.ArrayList(*PhaseStep).init(self.allocator);
        errdefer result.deinit();

        for (self.steps.items) |step| {
            if (step.phase == phase) {
                try result.append(step);
            }
        }
        return result.toOwnedSlice();
    }

    /// Advance to the next phase in the pipeline.
    pub fn advancePhase(self: *SkillPipeline) bool {
        if (self.current_phase) |cp| {
            self.current_phase = cp.next();
        } else {
            self.current_phase = .scan;
        }
        return self.current_phase != null;
    }

    /// Reset all steps to pending and clear pipeline state.
    pub fn reset(self: *SkillPipeline) void {
        for (self.steps.items) |step| {
            step.reset();
        }
        self.current_phase = null;
        self.status = .idle;
        self.started_at = null;
        self.completed_at = null;
    }

    /// Count steps by status.
    pub fn countByStatus(self: *const SkillPipeline, target: PhaseStatus) u32 {
        var count: u32 = 0;
        for (self.steps.items) |step| {
            if (step.status == target) count += 1;
        }
        return count;
    }

    /// Total duration in milliseconds.
    pub fn durationMs(self: *const SkillPipeline) u64 {
        const start_ts = self.started_at orelse return 0;
        const end_ts = self.completed_at orelse std.time.milliTimestamp();
        const diff = end_ts - start_ts;
        return if (diff > 0) @intCast(diff) else 0;
    }

    /// Execute all steps in phase order. Steps marked parallel are still
    /// executed sequentially (threading is a future enhancement).
    pub fn execute(self: *SkillPipeline) !PipelineResult {
        self.status = .running;
        self.started_at = std.time.milliTimestamp();

        for (&PipelinePhase.all) |phase| {
            self.current_phase = phase;

            // Gather steps for this phase
            var phase_steps = array_list_compat.ArrayList(*PhaseStep).init(self.allocator);
            defer phase_steps.deinit();

            for (self.steps.items) |step| {
                if (step.phase == phase) {
                    try phase_steps.append(step);
                }
            }

            // Execute each step in order
            for (phase_steps.items) |step| {
                step.start();

                // Mock execution: generate output based on step metadata
                const mock_output = try std.fmt.allocPrint(self.allocator, "[{s}] {s}: {s} completed", .{
                    phase.label(),
                    step.name,
                    step.description,
                });
                step.complete(mock_output) catch {
                    self.allocator.free(mock_output);
                    step.fail("Failed to complete step") catch {};
                    self.status = .failed;
                    self.completed_at = std.time.milliTimestamp();
                    return self.makeResult();
                };
                self.allocator.free(mock_output);
            }
        }

        self.status = .completed;
        self.completed_at = std.time.milliTimestamp();
        return self.makeResult();
    }

    /// Build a PipelineResult from current state.
    fn makeResult(self: *SkillPipeline) PipelineResult {
        return PipelineResult{
            .pipeline_name = self.allocator.dupe(u8, self.name) catch "",
            .status = self.status,
            .total_steps = @intCast(self.steps.items.len),
            .completed_steps = self.countByStatus(.completed),
            .failed_steps = self.countByStatus(.failed),
            .duration_ms = self.durationMs(),
            .output_path = self.allocator.dupe(u8, "") catch "",
        };
    }
};

// ── PipelineRunner ─────────────────────────────────────────────────────────────

/// Manages multiple pipelines, provides templates, and persists results.
pub const PipelineRunner = struct {
    allocator: Allocator,
    pipelines: array_list_compat.ArrayList(*SkillPipeline),
    max_concurrent: u32,
    results_dir: []const u8,

    pub fn init(allocator: Allocator, results_dir: []const u8) !PipelineRunner {
        return PipelineRunner{
            .allocator = allocator,
            .pipelines = array_list_compat.ArrayList(*SkillPipeline).init(allocator),
            .max_concurrent = 5,
            .results_dir = try allocator.dupe(u8, results_dir),
        };
    }

    pub fn deinit(self: *PipelineRunner) void {
        for (self.pipelines.items) |pipeline| {
            var mut_p = pipeline;
            mut_p.deinit();
            self.allocator.destroy(mut_p);
        }
        self.pipelines.deinit();
        self.allocator.free(self.results_dir);
    }

    /// Create a new empty pipeline and register it.
    pub fn createPipeline(self: *PipelineRunner, name: []const u8, description: []const u8) !*SkillPipeline {
        const pipeline_ptr = try self.allocator.create(SkillPipeline);
        pipeline_ptr.* = try SkillPipeline.init(self.allocator, name, description);
        try self.pipelines.append(pipeline_ptr);
        return pipeline_ptr;
    }

    /// Add a step to a pipeline by index.
    pub fn addStep(
        self: *PipelineRunner,
        pipeline_idx: usize,
        name: []const u8,
        phase: PipelinePhase,
        description: []const u8,
        is_parallel: bool,
    ) !*PhaseStep {
        if (pipeline_idx >= self.pipelines.items.len) return error.PipelineNotFound;
        return self.pipelines.items[pipeline_idx].addStep(name, phase, description, is_parallel);
    }

    /// Run a pipeline by index. Creates results directory and writes output.
    pub fn runPipeline(self: *PipelineRunner, pipeline_idx: usize) !PipelineResult {
        if (pipeline_idx >= self.pipelines.items.len) return error.PipelineNotFound;

        // Ensure results directory exists
        std.fs.cwd().makePath(self.results_dir) catch {};

        var pipeline = self.pipelines.items[pipeline_idx];
        var result = try pipeline.execute();

        // Write result to file in results_dir
        const output_file = try std.fmt.allocPrint(self.allocator, "{s}{s}-result.txt", .{
            self.results_dir,
            pipeline.name,
        });
        defer self.allocator.free(output_file);

        const file = std.fs.cwd().createFile(output_file, .{}) catch null;
        if (file) |f| {
            defer f.close();
            var buf: [1024]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "Pipeline: {s}\nStatus: {s}\nSteps: {d}/{d} completed, {d} failed\nDuration: {d}ms\n", .{
                result.pipeline_name,
                @tagName(result.status),
                result.completed_steps,
                result.total_steps,
                result.failed_steps,
                result.duration_ms,
            }) catch return result;
            f.writeAll(header) catch {};
        }

        // Update output_path in result
        self.allocator.free(result.output_path);
        result.output_path = try self.allocator.dupe(u8, output_file);

        return result;
    }

    /// Get a formatted status string for a pipeline.
    pub fn getPipelineStatus(self: *PipelineRunner, pipeline_idx: usize) ![]const u8 {
        if (pipeline_idx >= self.pipelines.items.len) return error.PipelineNotFound;

        const pipeline = self.pipelines.items[pipeline_idx];
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const w = buf.writer();
        w.print("=== Pipeline: {s} ===\n", .{pipeline.name}) catch {};
        w.print("  Description: {s}\n", .{pipeline.description}) catch {};
        w.print("  Status:      {s}\n", .{@tagName(pipeline.status)}) catch {};
        if (pipeline.current_phase) |cp| {
            w.print("  Phase:       {s}\n", .{@tagName(cp)}) catch {};
        }
        w.print("  Steps:       {d}\n", .{pipeline.steps.items.len}) catch {};
        w.print("  Completed:   {d}\n", .{pipeline.countByStatus(.completed)}) catch {};
        w.print("  Failed:      {d}\n", .{pipeline.countByStatus(.failed)}) catch {};
        w.print("  Pending:     {d}\n", .{pipeline.countByStatus(.pending)}) catch {};

        if (pipeline.steps.items.len > 0) {
            w.print("\n  Steps:\n", .{}) catch {};
            for (pipeline.steps.items, 0..) |step, idx| {
                const parallel_marker = if (step.is_parallel) " (parallel)" else "";
                w.print("    {d}. [{s}] {s} — {s}{s}\n", .{
                    idx + 1,
                    step.phase.label(),
                    step.name,
                    step.status.label(),
                    parallel_marker,
                }) catch {};
            }
        }

        return buf.toOwnedSlice();
    }

    /// List all registered pipelines as a formatted string.
    pub fn listPipelines(self: *PipelineRunner) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const w = buf.writer();
        w.print("=== Pipelines ({d}) ===\n", .{self.pipelines.items.len}) catch {};

        if (self.pipelines.items.len == 0) {
            w.print("  No pipelines registered.\n", .{}) catch {};
        } else {
            for (self.pipelines.items, 0..) |pipeline, idx| {
                const steps_info = pipeline.steps.items.len;
                const completed = pipeline.countByStatus(.completed);
                w.print("  {d}. {s} [{s}] — {d} steps ({d} done)\n", .{
                    idx + 1,
                    pipeline.name,
                    @tagName(pipeline.status),
                    steps_info,
                    completed,
                }) catch {};
            }
        }

        return buf.toOwnedSlice();
    }

    /// Get results for a pipeline (re-reads the result file if it exists).
    pub fn getResults(self: *PipelineRunner, pipeline_idx: usize) ![]PipelineResult {
        if (pipeline_idx >= self.pipelines.items.len) return error.PipelineNotFound;
        return &[_]PipelineResult{};
    }

    /// Build a pipeline from a built-in template.
    /// Templates: "research", "refactor", "review"
    pub fn buildFromTemplate(self: *PipelineRunner, template_name: []const u8) !*SkillPipeline {
        if (std.mem.eql(u8, template_name, "research")) {
            return self.buildResearchTemplate();
        } else if (std.mem.eql(u8, template_name, "refactor")) {
            return self.buildRefactorTemplate();
        } else if (std.mem.eql(u8, template_name, "review")) {
            return self.buildReviewTemplate();
        } else {
            return error.UnknownTemplate;
        }
    }

    /// Research template: scan → enrich(parallel: web + docs + code) → create → report
    fn buildResearchTemplate(self: *PipelineRunner) !*SkillPipeline {
        const pipeline = try self.createPipeline("research", "Research pipeline: gather, enrich, synthesize, report");

        _ = try pipeline.addStep("gather-context", .scan, "Gather context and input data", false);
        _ = try pipeline.addStep("web-search", .enrich, "Search web for relevant information", true);
        _ = try pipeline.addStep("docs-lookup", .enrich, "Look up documentation", true);
        _ = try pipeline.addStep("code-search", .enrich, "Search codebase for related code", true);
        _ = try pipeline.addStep("synthesize", .create, "Synthesize findings into coherent output", false);
        _ = try pipeline.addStep("save-summary", .report, "Save summary and present findings", false);

        return pipeline;
    }

    /// Refactor template: scan(analyze code) → enrich(find patterns) → create(apply changes) → report
    fn buildRefactorTemplate(self: *PipelineRunner) !*SkillPipeline {
        const pipeline = try self.createPipeline("refactor", "Refactor pipeline: analyze, find patterns, apply changes, summarize");

        _ = try pipeline.addStep("analyze-code", .scan, "Analyze code structure and complexity", false);
        _ = try pipeline.addStep("find-patterns", .enrich, "Find code patterns and anti-patterns", false);
        _ = try pipeline.addStep("find-deps", .enrich, "Find dependencies and usages", true);
        _ = try pipeline.addStep("apply-changes", .create, "Apply refactoring changes", false);
        _ = try pipeline.addStep("summarize-diff", .report, "Summarize changes and diff", false);

        return pipeline;
    }

    /// Review template: scan(read files) → enrich(check patterns + security) → create(write review) → report
    fn buildReviewTemplate(self: *PipelineRunner) !*SkillPipeline {
        const pipeline = try self.createPipeline("review", "Review pipeline: read files, check patterns, write review, present findings");

        _ = try pipeline.addStep("read-files", .scan, "Read and parse changed files", false);
        _ = try pipeline.addStep("check-patterns", .enrich, "Check for code pattern violations", true);
        _ = try pipeline.addStep("check-security", .enrich, "Check for security issues", true);
        _ = try pipeline.addStep("write-review", .create, "Write review with findings", false);
        _ = try pipeline.addStep("present-findings", .report, "Present findings and recommendations", false);

        return pipeline;
    }

    /// List available template names and descriptions.
    pub fn listTemplates(allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const w = buf.writer();
        w.print("=== Pipeline Templates ===\n", .{}) catch {};
        w.print("  research  — Gather, enrich (parallel: web + docs + code), synthesize, report\n", .{}) catch {};
        w.print("  refactor  — Analyze code, find patterns, apply changes, summarize diff\n", .{}) catch {};
        w.print("  review    — Read files, check patterns + security, write review, present findings\n", .{}) catch {};

        return buf.toOwnedSlice();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PhaseStep - init and deinit" {
    const allocator = testing.allocator;
    var step = try PhaseStep.init(allocator, "test-step", .scan, "A test step", false);
    defer step.deinit();

    try testing.expectEqualStrings("test-step", step.name);
    try testing.expectEqualStrings("A test step", step.description);
    try testing.expectEqual(PipelinePhase.scan, step.phase);
    try testing.expectEqual(PhaseStatus.pending, step.status);
    try testing.expect(!step.is_parallel);
    try testing.expect(step.started_at == null);
    try testing.expect(step.completed_at == null);
}

test "PhaseStep - start and complete" {
    const allocator = testing.allocator;
    var step = try PhaseStep.init(allocator, "step", .scan, "desc", false);
    defer step.deinit();

    step.start();
    try testing.expectEqual(PhaseStatus.running, step.status);
    try testing.expect(step.started_at != null);

    try step.complete("output data");
    try testing.expectEqual(PhaseStatus.completed, step.status);
    try testing.expectEqualStrings("output data", step.output);
    try testing.expect(step.completed_at != null);
}

test "PhaseStep - fail" {
    const allocator = testing.allocator;
    var step = try PhaseStep.init(allocator, "step", .scan, "desc", false);
    defer step.deinit();

    step.start();
    try step.fail("something went wrong");
    try testing.expectEqual(PhaseStatus.failed, step.status);
    try testing.expect(step.error_message != null);
    try testing.expectEqualStrings("something went wrong", step.error_message.?);
}

test "PhaseStep - reset" {
    const allocator = testing.allocator;
    var step = try PhaseStep.init(allocator, "step", .scan, "desc", false);
    defer step.deinit();

    step.start();
    try step.complete("done");
    try testing.expectEqual(PhaseStatus.completed, step.status);

    step.reset();
    try testing.expectEqual(PhaseStatus.pending, step.status);
    try testing.expect(step.started_at == null);
    try testing.expect(step.completed_at == null);
    try testing.expect(step.error_message == null);
}

test "PhaseStep - durationMs" {
    const allocator = testing.allocator;
    var step = try PhaseStep.init(allocator, "step", .scan, "desc", false);
    defer step.deinit();

    // Before starting: 0
    try testing.expectEqual(@as(i64, 0), step.durationMs());

    step.start();
    // While running: positive duration
    try testing.expect(step.durationMs() >= 0);

    try step.complete("done");
    // After completing: positive duration
    try testing.expect(step.durationMs() >= 0);
}

test "PipelinePhase - next" {
    try testing.expectEqual(PipelinePhase.enrich, PipelinePhase.scan.next());
    try testing.expectEqual(PipelinePhase.create, PipelinePhase.enrich.next());
    try testing.expectEqual(PipelinePhase.report, PipelinePhase.create.next());
    try testing.expectEqual(@as(?PipelinePhase, null), PipelinePhase.report.next());
}

test "PipelinePhase - all" {
    try testing.expectEqual(@as(usize, 4), PipelinePhase.all.len);
    try testing.expectEqual(PipelinePhase.scan, PipelinePhase.all[0]);
    try testing.expectEqual(PipelinePhase.enrich, PipelinePhase.all[1]);
    try testing.expectEqual(PipelinePhase.create, PipelinePhase.all[2]);
    try testing.expectEqual(PipelinePhase.report, PipelinePhase.all[3]);
}

test "SkillPipeline - init and deinit" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test-pipeline", "A test pipeline");
    defer pipeline.deinit();

    try testing.expectEqualStrings("test-pipeline", pipeline.name);
    try testing.expectEqualStrings("A test pipeline", pipeline.description);
    try testing.expectEqual(PipelineStatus.idle, pipeline.status);
    try testing.expectEqual(@as(usize, 0), pipeline.steps.items.len);
    try testing.expect(pipeline.current_phase == null);
}

test "SkillPipeline - addStep" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test", "test desc");
    defer pipeline.deinit();

    _ = try pipeline.addStep("scan-1", .scan, "Gather data", false);
    _ = try pipeline.addStep("enrich-1", .enrich, "Enrich data", true);
    _ = try pipeline.addStep("create-1", .create, "Create output", false);
    _ = try pipeline.addStep("report-1", .report, "Report results", false);

    try testing.expectEqual(@as(usize, 4), pipeline.steps.items.len);
    try testing.expectEqualStrings("scan-1", pipeline.steps.items[0].name);
    try testing.expectEqualStrings("enrich-1", pipeline.steps.items[1].name);
    try testing.expectEqualStrings("create-1", pipeline.steps.items[2].name);
    try testing.expectEqualStrings("report-1", pipeline.steps.items[3].name);
}

test "SkillPipeline - getStepsByPhase" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test", "test desc");
    defer pipeline.deinit();

    _ = try pipeline.addStep("scan-1", .scan, "Scan 1", false);
    _ = try pipeline.addStep("scan-2", .scan, "Scan 2", false);
    _ = try pipeline.addStep("enrich-1", .enrich, "Enrich 1", true);
    _ = try pipeline.addStep("create-1", .create, "Create 1", false);

    const scan_steps = try pipeline.getStepsByPhase(.scan);
    defer allocator.free(scan_steps);
    try testing.expectEqual(@as(usize, 2), scan_steps.len);

    const enrich_steps = try pipeline.getStepsByPhase(.enrich);
    defer allocator.free(enrich_steps);
    try testing.expectEqual(@as(usize, 1), enrich_steps.len);

    const report_steps = try pipeline.getStepsByPhase(.report);
    defer allocator.free(report_steps);
    try testing.expectEqual(@as(usize, 0), report_steps.len);
}

test "SkillPipeline - advancePhase" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test", "test desc");
    defer pipeline.deinit();

    // First advance: null → scan
    try testing.expect(pipeline.advancePhase());
    try testing.expectEqual(PipelinePhase.scan, pipeline.current_phase);

    // scan → enrich
    try testing.expect(pipeline.advancePhase());
    try testing.expectEqual(PipelinePhase.enrich, pipeline.current_phase);

    // enrich → create
    try testing.expect(pipeline.advancePhase());
    try testing.expectEqual(PipelinePhase.create, pipeline.current_phase);

    // create → report
    try testing.expect(pipeline.advancePhase());
    try testing.expectEqual(PipelinePhase.report, pipeline.current_phase);

    // report → null (end)
    try testing.expect(!pipeline.advancePhase());
    try testing.expect(pipeline.current_phase == null);
}

test "SkillPipeline - reset" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test", "test desc");
    defer pipeline.deinit();

    _ = try pipeline.addStep("step-1", .scan, "Step 1", false);

    pipeline.status = .running;
    pipeline.current_phase = .scan;
    pipeline.started_at = std.time.milliTimestamp();

    pipeline.reset();

    try testing.expectEqual(PipelineStatus.idle, pipeline.status);
    try testing.expect(pipeline.current_phase == null);
    try testing.expect(pipeline.started_at == null);
    try testing.expectEqual(PhaseStatus.pending, pipeline.steps.items[0].status);
}

test "SkillPipeline - execute with mock steps" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test-exec", "Execution test");
    defer pipeline.deinit();

    _ = try pipeline.addStep("gather", .scan, "Gather data", false);
    _ = try pipeline.addStep("enrich-a", .enrich, "Enrich A", true);
    _ = try pipeline.addStep("enrich-b", .enrich, "Enrich B", true);
    _ = try pipeline.addStep("create", .create, "Create output", false);
    _ = try pipeline.addStep("report", .report, "Report results", false);

    var result = try pipeline.execute();
    defer result.deinit(allocator);

    try testing.expectEqual(PipelineStatus.completed, result.status);
    try testing.expectEqual(@as(u32, 5), result.total_steps);
    try testing.expectEqual(@as(u32, 5), result.completed_steps);
    try testing.expectEqual(@as(u32, 0), result.failed_steps);
    try testing.expect(result.duration_ms >= 0);
    try testing.expectEqual(PipelineStatus.completed, pipeline.status);
}

test "SkillPipeline - countByStatus" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "test", "test desc");
    defer pipeline.deinit();

    const s1 = try pipeline.addStep("s1", .scan, "Step 1", false);
    const s2 = try pipeline.addStep("s2", .enrich, "Step 2", false);
    const s3 = try pipeline.addStep("s3", .create, "Step 3", false);

    try testing.expectEqual(@as(u32, 3), pipeline.countByStatus(.pending));
    try testing.expectEqual(@as(u32, 0), pipeline.countByStatus(.completed));

    s1.start();
    try s1.complete("done");
    try testing.expectEqual(@as(u32, 1), pipeline.countByStatus(.completed));
    try testing.expectEqual(@as(u32, 2), pipeline.countByStatus(.pending));

    s2.start();
    try s2.fail("error");
    try testing.expectEqual(@as(u32, 1), pipeline.countByStatus(.completed));
    try testing.expectEqual(@as(u32, 1), pipeline.countByStatus(.failed));
    try testing.expectEqual(@as(u32, 1), pipeline.countByStatus(.pending));
    _ = s3;
}

test "PipelineRunner - init and deinit" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/pipeline-results/");
    defer runner.deinit();

    try testing.expectEqualStrings(".crushcode/pipeline-results/", runner.results_dir);
    try testing.expectEqual(@as(u32, 5), runner.max_concurrent);
    try testing.expectEqual(@as(usize, 0), runner.pipelines.items.len);
}

test "PipelineRunner - createPipeline" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const p1 = try runner.createPipeline("pipeline-1", "First pipeline");
    const p2 = try runner.createPipeline("pipeline-2", "Second pipeline");

    try testing.expectEqual(@as(usize, 2), runner.pipelines.items.len);
    try testing.expectEqualStrings("pipeline-1", p1.name);
    try testing.expectEqualStrings("pipeline-2", p2.name);
}

test "PipelineRunner - addStep" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    _ = try runner.createPipeline("test", "Test pipeline");

    const step = try runner.addStep(0, "scan-1", .scan, "Scan step", false);
    try testing.expectEqualStrings("scan-1", step.name);
    try testing.expectEqual(PipelinePhase.scan, step.phase);

    // Out of bounds
    const result = runner.addStep(99, "bad", .scan, "bad", false);
    try testing.expectError(error.PipelineNotFound, result);
}

test "PipelineRunner - runPipeline" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const pipeline = try runner.createPipeline("test-run", "Run test");
    _ = try pipeline.addStep("scan-1", .scan, "Scan data", false);
    _ = try pipeline.addStep("enrich-1", .enrich, "Enrich data", true);
    _ = try pipeline.addStep("create-1", .create, "Create output", false);
    _ = try pipeline.addStep("report-1", .report, "Report results", false);

    var result = try runner.runPipeline(0);
    defer result.deinit(allocator);

    try testing.expectEqual(PipelineStatus.completed, result.status);
    try testing.expectEqual(@as(u32, 4), result.total_steps);
    try testing.expectEqual(@as(u32, 4), result.completed_steps);
    try testing.expectEqual(@as(u32, 0), result.failed_steps);
    try testing.expect(result.output_path.len > 0);

    // Out of bounds
    const bad_result = runner.runPipeline(99);
    try testing.expectError(error.PipelineNotFound, bad_result);
}

test "PipelineRunner - getPipelineStatus" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const pipeline = try runner.createPipeline("status-test", "Status test");
    _ = try pipeline.addStep("step-1", .scan, "First step", false);

    const status_str = try runner.getPipelineStatus(0);
    defer allocator.free(status_str);

    try testing.expect(std.mem.indexOf(u8, status_str, "status-test") != null);
    try testing.expect(std.mem.indexOf(u8, status_str, "idle") != null);
    try testing.expect(std.mem.indexOf(u8, status_str, "step-1") != null);

    // Out of bounds
    const bad = runner.getPipelineStatus(99);
    try testing.expectError(error.PipelineNotFound, bad);
}

test "PipelineRunner - listPipelines" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    _ = try runner.createPipeline("alpha", "Alpha pipeline");
    _ = try runner.createPipeline("beta", "Beta pipeline");

    const listing = try runner.listPipelines();
    defer allocator.free(listing);

    try testing.expect(std.mem.indexOf(u8, listing, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, listing, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, listing, "2") != null);
}

test "PipelineRunner - listPipelines empty" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const listing = try runner.listPipelines();
    defer allocator.free(listing);

    try testing.expect(std.mem.indexOf(u8, listing, "No pipelines") != null);
}

test "PipelineRunner - buildFromTemplate research" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const pipeline = try runner.buildFromTemplate("research");
    try testing.expectEqualStrings("research", pipeline.name);
    try testing.expectEqual(@as(usize, 6), pipeline.steps.items.len);

    // Verify phase distribution
    try testing.expectEqual(PipelinePhase.scan, pipeline.steps.items[0].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[1].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[2].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[3].phase);
    try testing.expectEqual(PipelinePhase.create, pipeline.steps.items[4].phase);
    try testing.expectEqual(PipelinePhase.report, pipeline.steps.items[5].phase);

    // Enrich steps are parallel
    try testing.expect(pipeline.steps.items[1].is_parallel);
    try testing.expect(pipeline.steps.items[2].is_parallel);
    try testing.expect(pipeline.steps.items[3].is_parallel);
}

test "PipelineRunner - buildFromTemplate refactor" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const pipeline = try runner.buildFromTemplate("refactor");
    try testing.expectEqualStrings("refactor", pipeline.name);
    try testing.expectEqual(@as(usize, 5), pipeline.steps.items.len);

    try testing.expectEqual(PipelinePhase.scan, pipeline.steps.items[0].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[1].phase);
    try testing.expectEqual(PipelinePhase.create, pipeline.steps.items[3].phase);
    try testing.expectEqual(PipelinePhase.report, pipeline.steps.items[4].phase);
}

test "PipelineRunner - buildFromTemplate review" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const pipeline = try runner.buildFromTemplate("review");
    try testing.expectEqualStrings("review", pipeline.name);
    try testing.expectEqual(@as(usize, 5), pipeline.steps.items.len);

    try testing.expectEqual(PipelinePhase.scan, pipeline.steps.items[0].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[1].phase);
    try testing.expectEqual(PipelinePhase.enrich, pipeline.steps.items[2].phase);
    try testing.expect(pipeline.steps.items[1].is_parallel);
    try testing.expect(pipeline.steps.items[2].is_parallel);
}

test "PipelineRunner - buildFromTemplate unknown" {
    const allocator = testing.allocator;
    var runner = try PipelineRunner.init(allocator, ".crushcode/test-results/");
    defer runner.deinit();

    const result = runner.buildFromTemplate("nonexistent");
    try testing.expectError(error.UnknownTemplate, result);
}

test "PipelineRunner - listTemplates" {
    const allocator = testing.allocator;
    const templates = try PipelineRunner.listTemplates(allocator);
    defer allocator.free(templates);

    try testing.expect(std.mem.indexOf(u8, templates, "research") != null);
    try testing.expect(std.mem.indexOf(u8, templates, "refactor") != null);
    try testing.expect(std.mem.indexOf(u8, templates, "review") != null);
}

test "PipelineResult - deinit" {
    const allocator = testing.allocator;
    var result = PipelineResult{
        .pipeline_name = try allocator.dupe(u8, "test"),
        .status = .completed,
        .total_steps = 4,
        .completed_steps = 4,
        .failed_steps = 0,
        .duration_ms = 100,
        .output_path = try allocator.dupe(u8, "/tmp/result.txt"),
    };
    result.deinit(allocator);
    // Should not leak — GeneralPurposeAllocator will detect if it does
}

test "PipelinePhase - label" {
    try testing.expectEqualStrings("Scan", PipelinePhase.scan.label());
    try testing.expectEqualStrings("Enrich", PipelinePhase.enrich.label());
    try testing.expectEqualStrings("Create", PipelinePhase.create.label());
    try testing.expectEqualStrings("Report", PipelinePhase.report.label());
}

test "PhaseStatus - label" {
    try testing.expectEqualStrings("pending", PhaseStatus.pending.label());
    try testing.expectEqualStrings("running", PhaseStatus.running.label());
    try testing.expectEqualStrings("completed", PhaseStatus.completed.label());
    try testing.expectEqualStrings("failed", PhaseStatus.failed.label());
    try testing.expectEqualStrings("skipped", PhaseStatus.skipped.label());
}

test "PipelineStatus - label" {
    try testing.expectEqualStrings("idle", PipelineStatus.idle.label());
    try testing.expectEqualStrings("running", PipelineStatus.running.label());
    try testing.expectEqualStrings("completed", PipelineStatus.completed.label());
    try testing.expectEqualStrings("failed", PipelineStatus.failed.label());
    try testing.expectEqualStrings("paused", PipelineStatus.paused.label());
}

test "PhaseStep - is_parallel flag" {
    const allocator = testing.allocator;
    var seq_step = try PhaseStep.init(allocator, "seq", .scan, "sequential", false);
    defer seq_step.deinit();
    var par_step = try PhaseStep.init(allocator, "par", .enrich, "parallel", true);
    defer par_step.deinit();

    try testing.expect(!seq_step.is_parallel);
    try testing.expect(par_step.is_parallel);
}

test "SkillPipeline - phase ordering enforcement" {
    const allocator = testing.allocator;
    var pipeline = try SkillPipeline.init(allocator, "ordering", "Phase ordering test");
    defer pipeline.deinit();

    // Add steps in mixed phase order
    _ = try pipeline.addStep("create-1", .create, "Create step", false);
    _ = try pipeline.addStep("scan-1", .scan, "Scan step", false);
    _ = try pipeline.addStep("report-1", .report, "Report step", false);
    _ = try pipeline.addStep("enrich-1", .enrich, "Enrich step", false);

    // Execute should still run in scan→enrich→create→report order
    var result = try pipeline.execute();
    defer result.deinit(allocator);

    try testing.expectEqual(PipelineStatus.completed, result.status);
    try testing.expectEqual(@as(u32, 4), result.completed_steps);

    // Verify execution order: scan ran first, then enrich, etc.
    const scan_step = pipeline.steps.items[1]; // scan-1 (added second)
    const enrich_step = pipeline.steps.items[3]; // enrich-1 (added fourth)
    const create_step = pipeline.steps.items[0]; // create-1 (added first)
    const report_step = pipeline.steps.items[2]; // report-1 (added third)

    try testing.expect(scan_step.completed_at != null);
    try testing.expect(enrich_step.completed_at != null);
    try testing.expect(create_step.completed_at != null);
    try testing.expect(report_step.completed_at != null);

    // Verify temporal ordering: scan < enrich < create < report
    try testing.expect(scan_step.completed_at.? <= enrich_step.completed_at.?);
    try testing.expect(enrich_step.completed_at.? <= create_step.completed_at.?);
    try testing.expect(create_step.completed_at.? <= report_step.completed_at.?);
}
