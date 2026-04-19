const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A single phase within a capability pipeline.
/// Describes one step of a multi-step agent workflow.
pub const CapabilityPhase = struct {
    name: []const u8,
    description: []const u8,
    is_parallel: bool,
    expected_output: []const u8,

    pub fn deinit(self: *CapabilityPhase, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.expected_output);
    }
};

/// A capability definition — describes a multi-step agent pipeline.
/// This is a DATA STRUCTURE only — no execution logic.
/// Execution will be wired to the agent loop in a future phase.
pub const Capability = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    phases: array_list_compat.ArrayList(CapabilityPhase),
    required_tools: [][]const u8,

    /// Initialize a new Capability with the given name and description.
    pub fn init(allocator: Allocator, name: []const u8, description: []const u8) !Capability {
        return Capability{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .phases = array_list_compat.ArrayList(CapabilityPhase).init(allocator),
            .required_tools = &[_][]const u8{},
        };
    }

    /// Initialize with required tools.
    pub fn initWithTools(
        allocator: Allocator,
        name: []const u8,
        description: []const u8,
        tools: []const []const u8,
    ) !Capability {
        const cap = try init(allocator, name, description);
        var mutable = cap;
        const owned_tools = try allocator.alloc([]const u8, tools.len);
        for (tools, 0..) |tool, i| {
            owned_tools[i] = try allocator.dupe(u8, tool);
        }
        mutable.required_tools = owned_tools;
        return mutable;
    }

    pub fn deinit(self: *Capability) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);

        for (self.phases.items) |*phase| {
            phase.deinit(self.allocator);
        }
        self.phases.deinit();

        // Free owned tools — if initWithTools was used, the slice and strings are heap-allocated
        // The static empty slice from init() is a zero-length slice, which is safe to skip
        if (self.required_tools.len > 0) {
            for (self.required_tools) |tool| {
                self.allocator.free(tool);
            }
            self.allocator.free(self.required_tools);
        }
    }

    /// Add a phase to the capability pipeline.
    pub fn addPhase(
        self: *Capability,
        name: []const u8,
        description: []const u8,
        is_parallel: bool,
    ) !void {
        const phase = CapabilityPhase{
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .is_parallel = is_parallel,
            .expected_output = try self.allocator.dupe(u8, ""),
        };
        try self.phases.append(phase);
    }

    /// Add a phase with an expected output description.
    pub fn addPhaseWithOutput(
        self: *Capability,
        name: []const u8,
        description: []const u8,
        is_parallel: bool,
        expected_output: []const u8,
    ) !void {
        const phase = CapabilityPhase{
            .name = try self.allocator.dupe(u8, name),
            .description = try self.allocator.dupe(u8, description),
            .is_parallel = is_parallel,
            .expected_output = try self.allocator.dupe(u8, expected_output),
        };
        try self.phases.append(phase);
    }

    /// Validate that the capability is well-formed.
    /// Checks that the capability has at least 1 phase.
    pub fn validate(self: *const Capability) !void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.phases.items.len == 0) return error.NoPhases;
    }

    /// Get the number of phases in this capability.
    pub fn phaseCount(self: *const Capability) usize {
        return self.phases.items.len;
    }

    /// Get a phase by index.
    pub fn getPhase(self: *const Capability, index: usize) ?CapabilityPhase {
        if (index >= self.phases.items.len) return null;
        return self.phases.items[index];
    }

    /// Count how many phases are marked as parallel.
    pub fn parallelPhaseCount(self: *const Capability) usize {
        var count: usize = 0;
        for (self.phases.items) |phase| {
            if (phase.is_parallel) count += 1;
        }
        return count;
    }

    /// Count how many phases are sequential (not parallel).
    pub fn sequentialPhaseCount(self: *const Capability) usize {
        return self.phaseCount() - self.parallelPhaseCount();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Capability - init and deinit" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "test-capability", "A test capability");
    defer cap.deinit();

    try testing.expectEqualStrings("test-capability", cap.name);
    try testing.expectEqualStrings("A test capability", cap.description);
    try testing.expectEqual(@as(usize, 0), cap.phaseCount());
}

test "Capability - addPhase" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "multi-step", "Multi-step pipeline");
    defer cap.deinit();

    try cap.addPhase("research", "Gather information from codebase", false);
    try cap.addPhase("analyze", "Analyze gathered data", false);
    try cap.addPhase("implement", "Implement changes", false);

    try testing.expectEqual(@as(usize, 3), cap.phaseCount());

    const p1 = cap.getPhase(0).?;
    try testing.expectEqualStrings("research", p1.name);
    try testing.expect(!p1.is_parallel);

    const p2 = cap.getPhase(1).?;
    try testing.expectEqualStrings("analyze", p2.name);

    const p3 = cap.getPhase(2).?;
    try testing.expectEqualStrings("implement", p3.name);
}

test "Capability - addPhaseWithOutput" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "with-output", "Pipeline with outputs");
    defer cap.deinit();

    try cap.addPhaseWithOutput(
        "collect",
        "Collect data from files",
        true,
        "A summary of all gathered data",
    );

    const p = cap.getPhase(0).?;
    try testing.expectEqualStrings("collect", p.name);
    try testing.expect(p.is_parallel);
    try testing.expectEqualStrings("A summary of all gathered data", p.expected_output);
}

test "Capability - validate succeeds with phases" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "valid-cap", "A valid capability");
    defer cap.deinit();

    try cap.addPhase("step1", "First step", false);
    try cap.validate();
}

test "Capability - validate rejects empty capability" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "empty-cap", "No phases");
    defer cap.deinit();

    const result = cap.validate();
    try testing.expectError(error.NoPhases, result);
}

test "Capability - validate rejects empty name" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "", "Empty name cap");
    defer cap.deinit();

    try cap.addPhase("step1", "First step", false);

    const result = cap.validate();
    try testing.expectError(error.EmptyName, result);
}

test "Capability - parallel and sequential phase counts" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "mixed", "Mixed parallel/sequential");
    defer cap.deinit();

    try cap.addPhase("step1", "Sequential 1", false);
    try cap.addPhase("step2a", "Parallel A", true);
    try cap.addPhase("step2b", "Parallel B", true);
    try cap.addPhase("step3", "Sequential 2", false);

    try testing.expectEqual(@as(usize, 4), cap.phaseCount());
    try testing.expectEqual(@as(usize, 2), cap.parallelPhaseCount());
    try testing.expectEqual(@as(usize, 2), cap.sequentialPhaseCount());
}

test "Capability - getPhase out of bounds returns null" {
    const allocator = std.testing.allocator;
    var cap = try Capability.init(allocator, "bounds", "Bounds test");
    defer cap.deinit();

    try cap.addPhase("step1", "Only step", false);

    try testing.expect(cap.getPhase(0) != null);
    try testing.expect(cap.getPhase(1) == null);
    try testing.expect(cap.getPhase(99) == null);
}

test "Capability - initWithTools" {
    const allocator = std.testing.allocator;
    const tools = [_][]const u8{ "file_read", "shell_exec", "git" };
    var cap = try Capability.initWithTools(allocator, "tooled", "Has tools", &tools);
    defer cap.deinit();

    try testing.expectEqual(@as(usize, 3), cap.required_tools.len);
    try testing.expectEqualStrings("file_read", cap.required_tools[0]);
    try testing.expectEqualStrings("shell_exec", cap.required_tools[1]);
    try testing.expectEqualStrings("git", cap.required_tools[2]);
}

test "Capability - realistic pipeline" {
    const allocator = std.testing.allocator;
    var cap = try Capability.initWithTools(
        allocator,
        "code-review",
        "Automated code review pipeline",
        &[_][]const u8{ "file_read", "git_diff", "web_search" },
    );
    defer cap.deinit();

    // Phase 1: Collect diffs (sequential)
    try cap.addPhaseWithOutput(
        "collect-diffs",
        "Gather all changed files from git diff",
        false,
        "List of changed files with diffs",
    );

    // Phase 2: Analyze each file in parallel
    try cap.addPhaseWithOutput(
        "analyze-files",
        "Analyze each changed file for issues",
        true,
        "Per-file analysis with issues found",
    );

    // Phase 3: Synthesize review (sequential)
    try cap.addPhaseWithOutput(
        "synthesize-review",
        "Combine all analyses into a cohesive review",
        false,
        "Final code review document",
    );

    try testing.expectEqual(@as(usize, 3), cap.phaseCount());
    try testing.expectEqual(@as(usize, 1), cap.parallelPhaseCount());
    try testing.expectEqual(@as(usize, 2), cap.sequentialPhaseCount());

    try cap.validate();
}
