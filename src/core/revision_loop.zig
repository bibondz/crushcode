const std = @import("std");
const array_list_compat = @import("array_list_compat");
const convergence = @import("convergence");

const Allocator = std.mem.Allocator;

/// Revision result from a single revision pass
pub const RevisionResult = struct {
    revision: u32,
    output: []const u8,
    change_ratio: f64,
    timestamp: i64,

    pub fn deinit(self: *RevisionResult, allocator: Allocator) void {
        allocator.free(self.output);
    }
};

/// Outcome of a revision loop
pub const RevisionOutcome = enum {
    converged, // Change ratio fell below threshold
    max_revisions, // Hit maximum revision count
    stalled, // No meaningful change for stall_rounds consecutive rounds
};

/// Configuration for the revision loop
pub const RevisionConfig = struct {
    max_revisions: u32 = 5,
    convergence_threshold: f64 = 0.05, // 5% change = converged
    stall_rounds: u32 = 3, // 3 rounds with no change = stalled
};

/// State tracked across revision iterations
pub const RevisionState = struct {
    revisions: array_list_compat.ArrayList(RevisionResult),
    outcome: ?RevisionOutcome,
    total_revisions: u32,
    final_change_ratio: f64,

    pub fn init(allocator: Allocator) RevisionState {
        return RevisionState{
            .revisions = array_list_compat.ArrayList(RevisionResult).init(allocator),
            .outcome = null,
            .total_revisions = 0,
            .final_change_ratio = 1.0,
        };
    }

    pub fn deinit(self: *RevisionState, allocator: Allocator) void {
        for (self.revisions.items) |*r| {
            r.deinit(allocator);
        }
        self.revisions.deinit();
    }
};

/// Revision Loop — iteratively refine output until convergence or stall.
/// Used by the agent loop to detect when further revisions yield diminishing returns.
///
/// Usage:
///   1. Create RevisionLoop with config
///   2. Call `shouldContinue()` after each revision
///   3. Call `recordRevision()` with the output
///   4. Check `isComplete()` for final status
///
/// Reference: GSD revision loop + Cavekit convergence detection (F8)
pub const RevisionLoop = struct {
    allocator: Allocator,
    config: RevisionConfig,
    detector: convergence.ConvergenceDetector,
    state: RevisionState,
    current_revision: u32,

    pub fn init(allocator: Allocator, config: RevisionConfig) !RevisionLoop {
        return RevisionLoop{
            .allocator = allocator,
            .config = config,
            .detector = try convergence.ConvergenceDetector.init(allocator, config.convergence_threshold, config.stall_rounds),
            .state = RevisionState.init(allocator),
            .current_revision = 0,
        };
    }

    pub fn deinit(self: *RevisionLoop) void {
        self.detector.deinit();
        self.state.deinit(self.allocator);
    }

    /// Record a revision output. Returns the change ratio vs previous revision.
    pub fn recordRevision(self: *RevisionLoop, output: []const u8) !f64 {
        self.current_revision += 1;

        const change_ratio = self.detector.recordIteration(output);

        const result = RevisionResult{
            .revision = self.current_revision,
            .output = try self.allocator.dupe(u8, output),
            .change_ratio = change_ratio,
            .timestamp = std.time.timestamp(),
        };

        try self.state.revisions.append(result);
        self.state.total_revisions = self.current_revision;
        self.state.final_change_ratio = change_ratio;

        // Determine outcome
        if (self.detector.hasConverged()) {
            self.state.outcome = .converged;
        } else if (self.detector.hasStalled()) {
            self.state.outcome = .stalled;
        } else if (self.current_revision >= self.config.max_revisions) {
            self.state.outcome = .max_revisions;
        }

        return change_ratio;
    }

    /// Whether another revision should be performed
    pub fn shouldContinue(self: *const RevisionLoop) bool {
        return self.state.outcome == null;
    }

    /// Whether the loop has completed (converged, stalled, or max revisions)
    pub fn isComplete(self: *const RevisionLoop) bool {
        return self.state.outcome != null;
    }

    /// Get the final outcome. Returns null if loop is still running.
    pub fn getOutcome(self: *const RevisionLoop) ?RevisionOutcome {
        return self.state.outcome;
    }

    /// Get the best (last converged or most recent) output
    pub fn getBestOutput(self: *const RevisionLoop) ?[]const u8 {
        if (self.state.revisions.items.len == 0) return null;
        return self.state.revisions.items[self.state.revisions.items.len - 1].output;
    }

    /// Get the current revision number (1-based)
    pub fn currentRevision(self: *const RevisionLoop) u32 {
        return self.current_revision;
    }

    /// Summary of revision history
    pub fn summary(self: *const RevisionLoop) RevisionSummary {
        var total_change: f64 = 0;
        for (self.state.revisions.items) |r| {
            total_change += r.change_ratio;
        }
        return RevisionSummary{
            .total_revisions = self.state.total_revisions,
            .outcome = self.state.outcome,
            .final_change_ratio = self.state.final_change_ratio,
            .avg_change_ratio = if (self.state.revisions.items.len > 0) total_change / @as(f64, @floatFromInt(self.state.revisions.items.len)) else 0,
        };
    }
};

pub const RevisionSummary = struct {
    total_revisions: u32,
    outcome: ?RevisionOutcome,
    final_change_ratio: f64,
    avg_change_ratio: f64,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "RevisionLoop - converges on identical output" {
    var loop = try RevisionLoop.init(testing.allocator, .{
        .max_revisions = 10,
        .convergence_threshold = 0.05,
        .stall_rounds = 3,
    });
    defer loop.deinit();

    // First revision — always accepted
    _ = try loop.recordRevision("Initial output about something");
    try testing.expect(loop.shouldContinue());

    // Second — similar output, low change ratio
    _ = try loop.recordRevision("Initial output about something");
    // Third
    _ = try loop.recordRevision("Initial output about something");
    // Fourth should converge (3 identical = stalled, or very low ratio = converged)
    _ = try loop.recordRevision("Initial output about something");

    // After 4 identical revisions, should have converged or stalled
    try testing.expect(loop.isComplete());
}

test "RevisionLoop - stops at max revisions" {
    var loop = try RevisionLoop.init(testing.allocator, .{
        .max_revisions = 3,
        .convergence_threshold = 0.001, // Very low threshold
        .stall_rounds = 100, // Never stall
    });
    defer loop.deinit();

    _ = try loop.recordRevision("Output version A with lots of unique content here");
    try testing.expect(loop.shouldContinue());

    _ = try loop.recordRevision("Output version B with different content altogether");
    try testing.expect(loop.shouldContinue());

    _ = try loop.recordRevision("Output version C with yet more different content");
    try testing.expect(loop.isComplete());
    try testing.expect(loop.getOutcome() == .max_revisions);
}

test "RevisionLoop - summary" {
    var loop = try RevisionLoop.init(testing.allocator, .{
        .max_revisions = 5,
        .convergence_threshold = 0.05,
        .stall_rounds = 3,
    });
    defer loop.deinit();

    _ = try loop.recordRevision("First version of output");
    _ = try loop.recordRevision("First version of output");

    const sum = loop.summary();
    try testing.expect(sum.total_revisions == 2);
    try testing.expect(sum.avg_change_ratio >= 0);
}

test "RevisionLoop - getBestOutput returns latest" {
    var loop = try RevisionLoop.init(testing.allocator, .{
        .max_revisions = 5,
        .convergence_threshold = 0.05,
        .stall_rounds = 3,
    });
    defer loop.deinit();

    try testing.expect(loop.getBestOutput() == null);

    _ = try loop.recordRevision("Version 1");
    _ = try loop.recordRevision("Version 2");

    const best = loop.getBestOutput();
    try testing.expect(best != null);
    try testing.expectEqualStrings("Version 2", best.?);
}
