/// Crush Mode — auto-agentic execution engine.
///
/// Takes a natural language task description, generates an execution plan,
/// runs each step with auto-approval for safe operations, verifies after
/// each step, and auto-commits on success.
///
/// Flow: task → AI plan → parse steps → execute → verify → commit
///
/// Leverages: Knowledge Graph (codebase understanding), Memory (session context),
/// Guardian (safety), existing tool executors (17 builtin tools).
const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

// ── Types ──────────────────────────────────────────────────────────────────────

pub const CrushStepStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,
};

pub const CrushStep = struct {
    index: usize,
    description: []const u8,
    tool: []const u8,
    arguments: []const u8,
    status: CrushStepStatus,
    result: ?[]const u8,
    duration_ms: u64,

    pub fn deinit(self: *const CrushStep, allocator: Allocator) void {
        allocator.free(self.description);
        allocator.free(self.tool);
        allocator.free(self.arguments);
        if (self.result) |r| allocator.free(r);
    }
};

pub const CrushModeState = enum {
    idle,
    planning,
    executing,
    verifying,
    committing,
    done,
    failed,
    cancelled,
};

pub const CrushResult = struct {
    task: []const u8,
    state: CrushModeState,
    total_steps: usize,
    completed_steps: usize,
    failed_steps: usize,
    skipped_steps: usize,
    steps: []CrushStep,
    commit_hash: ?[]const u8,
    duration_ms: u64,

    pub fn deinit(self: *const CrushResult, allocator: Allocator) void {
        allocator.free(self.task);
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
        if (self.commit_hash) |h| allocator.free(h);
    }
};

// ── CrushEngine ────────────────────────────────────────────────────────────────

pub const CrushEngine = struct {
    allocator: Allocator,
    task: []const u8,
    state: CrushModeState,
    steps: array_list_compat.ArrayList(CrushStep),
    current_step: usize,
    project_dir: []const u8,
    auto_approve_read: bool,
    auto_approve_write: bool,
    auto_verify: bool,
    auto_commit: bool,
    started_at: i64,

    pub fn init(
        allocator: Allocator,
        task: []const u8,
        project_dir: []const u8,
    ) CrushEngine {
        return CrushEngine{
            .allocator = allocator,
            .task = allocator.dupe(u8, task) catch task,
            .state = .idle,
            .steps = array_list_compat.ArrayList(CrushStep).init(allocator),
            .current_step = 0,
            .project_dir = project_dir,
            .auto_approve_read = true,
            .auto_approve_write = false,
            .auto_verify = true,
            .auto_commit = true,
            .started_at = 0,
        };
    }

    pub fn deinit(self: *CrushEngine) void {
        if (!std.mem.eql(u8, self.task, "")) self.allocator.free(self.task);
        for (self.steps.items) |*step| step.deinit(self.allocator);
        self.steps.deinit();
    }

    /// Generate a plan prompt that instructs the AI to produce structured steps.
    /// The AI responds with numbered steps, each specifying a tool and arguments.
    pub fn buildPlanPrompt(self: *CrushEngine, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.print(
            \\You are an execution planner. Given a task, produce a numbered list of steps.
            \\Each step must use ONE of these tools: read_file, shell, write_file, edit, glob, grep, list_directory, git_status, git_diff.
            \\
            \\Format each step EXACTLY like this:
            \\STEP <number>: <description>
            \\TOOL: <tool_name>
            \\ARGS: <json_arguments>
            \\
            \\Task: {s}
            \\
            \\Rules:
            \\1. Start by reading relevant files to understand the codebase
            \\2. Make minimal, targeted changes
            \\3. Each step should be atomic and independently verifiable
            \\4. Prefer edit over write_file for existing files
            \\5. End with a verification step (shell: build/test command)
            \\
            \\Steps:
            \\
        , .{self.task});

        return buf.toOwnedSlice();
    }

    /// Parse AI response into execution steps.
    /// Expects format: "STEP N: description\nTOOL: name\nARGS: json"
    pub fn parsePlan(self: *CrushEngine, response: []const u8) !void {
        var lines = std.mem.splitSequence(u8, response, "\n");
        var current_description: ?[]const u8 = null;
        var current_tool: ?[]const u8 = null;
        var current_args: ?[]const u8 = null;
        var step_idx: usize = 0;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) {
                // Empty line might signal end of a step
                if (current_description) |desc| {
                    try self.addStep(
                        desc,
                        current_tool orelse "shell",
                        current_args orelse "{}",
                    );
                    step_idx += 1;
                    current_description = null;
                    current_tool = null;
                    current_args = null;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "STEP ")) {
                // Save previous step if any
                if (current_description) |desc| {
                    try self.addStep(
                        desc,
                        current_tool orelse "shell",
                        current_args orelse "{}",
                    );
                    step_idx += 1;
                }
                // Extract description after "STEP N: "
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                    const desc = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");
                    current_description = try self.allocator.dupe(u8, desc);
                }
            } else if (std.mem.startsWith(u8, trimmed, "TOOL:")) {
                const tool = std.mem.trim(u8, trimmed[5..], " ");
                current_tool = try self.allocator.dupe(u8, tool);
            } else if (std.mem.startsWith(u8, trimmed, "ARGS:")) {
                const args = std.mem.trim(u8, trimmed[5..], " ");
                current_args = try self.allocator.dupe(u8, args);
            }
        }

        // Don't forget the last step
        if (current_description) |desc| {
            try self.addStep(
                desc,
                current_tool orelse "shell",
                current_args orelse "{}",
            );
        }
    }

    fn addStep(self: *CrushEngine, description: []const u8, tool: []const u8, arguments: []const u8) !void {
        try self.steps.append(CrushStep{
            .index = self.steps.items.len,
            .description = description,
            .tool = tool,
            .arguments = arguments,
            .status = .pending,
            .result = null,
            .duration_ms = 0,
        });
    }

    /// Check if a tool call should be auto-approved.
    pub fn shouldAutoApprove(self: *const CrushEngine, tool: []const u8) bool {
        if (self.auto_approve_read) {
            if (std.mem.eql(u8, tool, "read_file") or
                std.mem.eql(u8, tool, "glob") or
                std.mem.eql(u8, tool, "grep") or
                std.mem.eql(u8, tool, "list_directory") or
                std.mem.eql(u8, tool, "file_info") or
                std.mem.eql(u8, tool, "git_status") or
                std.mem.eql(u8, tool, "git_diff") or
                std.mem.eql(u8, tool, "git_log") or
                std.mem.eql(u8, tool, "search_files"))
            {
                return true;
            }
        }
        if (self.auto_approve_write) {
            if (std.mem.eql(u8, tool, "write_file") or
                std.mem.eql(u8, tool, "edit") or
                std.mem.eql(u8, tool, "create_file") or
                std.mem.eql(u8, tool, "shell"))
            {
                return true;
            }
        }
        return false;
    }

    /// Run verification (build) after a step.
    /// Returns true if verification passes.
    pub fn runVerification(self: *CrushEngine) bool {
        // Run build command in project directory
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "zig", "build", "--cache-dir", "/tmp/zigcache" },
            .cwd = self.project_dir,
        }) catch return false;

        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        // Build passes if exit code is 0 AND stderr doesn't contain "error:"
        const has_error = std.mem.indexOf(u8, result.stderr, "error:") != null;
        return result.term == .Exited and result.term.Exited == 0 and !has_error;
    }

    /// Generate a git commit for the changes made.
    /// Returns the commit hash on success.
    pub fn autoCommit(self: *CrushEngine) ?[]const u8 {
        // Stage all changes
        const stage_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "add", "-A" },
            .cwd = self.project_dir,
        }) catch return null;
        self.allocator.free(stage_result.stdout);
        self.allocator.free(stage_result.stderr);

        // Check if there are staged changes
        const status_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "diff", "--cached", "--quiet" },
            .cwd = self.project_dir,
        }) catch return null;
        self.allocator.free(status_result.stdout);
        self.allocator.free(status_result.stderr);

        // If diff --cached --quiet succeeds (exit 0), there are no staged changes
        if (status_result.term == .Exited and status_result.term.Exited == 0) {
            return null;
        }

        // Build commit message from task description
        var msg_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer msg_buf.deinit();
        const w = msg_buf.writer();
        w.print("crush: {s}", .{self.task}) catch return null;

        // Truncate commit message to 72 chars
        const msg = if (msg_buf.items.len > 72) msg_buf.items[0..72] else msg_buf.items;

        const commit_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "commit", "-m", msg },
            .cwd = self.project_dir,
        }) catch return null;
        defer {
            self.allocator.free(commit_result.stdout);
            self.allocator.free(commit_result.stderr);
        }

        if (commit_result.term == .Exited and commit_result.term.Exited == 0) {
            // Extract commit hash from output
            const output = commit_result.stdout;
            if (std.mem.indexOf(u8, output, "[")) |bracket_start| {
                if (std.mem.indexOf(u8, output[bracket_start..], "]")) |bracket_end| {
                    const hash_start = bracket_start + 1;
                    const hash_end = bracket_start + bracket_end;
                    if (hash_end > hash_start) {
                        return self.allocator.dupe(u8, output[hash_start..hash_end]) catch null;
                    }
                }
            }
            return self.allocator.dupe(u8, "committed") catch null;
        }

        return null;
    }

    /// Build a final result from the current engine state.
    pub fn buildResult(self: *const CrushEngine) !CrushResult {
        var completed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        for (self.steps.items) |step| {
            switch (step.status) {
                .completed => completed += 1,
                .failed => failed += 1,
                .skipped => skipped += 1,
                else => {},
            }
        }

        const now = std.time.milliTimestamp();
        const duration = if (now > self.started_at) @as(u64, @intCast(now - self.started_at)) else 0;

        // Copy steps for the result
        const result_steps = try self.allocator.alloc(CrushStep, self.steps.items.len);
        for (self.steps.items, 0..) |step, i| {
            result_steps[i] = CrushStep{
                .index = step.index,
                .description = try self.allocator.dupe(u8, step.description),
                .tool = try self.allocator.dupe(u8, step.tool),
                .arguments = try self.allocator.dupe(u8, step.arguments),
                .status = step.status,
                .result = if (step.result) |r| try self.allocator.dupe(u8, r) else null,
                .duration_ms = step.duration_ms,
            };
        }

        return CrushResult{
            .task = try self.allocator.dupe(u8, self.task),
            .state = self.state,
            .total_steps = self.steps.items.len,
            .completed_steps = completed,
            .failed_steps = failed,
            .skipped_steps = skipped,
            .steps = result_steps,
            .commit_hash = null,
            .duration_ms = duration,
        };
    }

    /// Get a formatted progress string for display.
    pub fn progressString(self: *const CrushEngine, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        const state_icon: []const u8 = switch (self.state) {
            .idle => "◯",
            .planning => "⚙",
            .executing => "▶",
            .verifying => "🔍",
            .committing => "📦",
            .done => "✓",
            .failed => "✕",
            .cancelled => "⊘",
        };

        w.print("{s} Crush Mode: {s}\n", .{ state_icon, self.task }) catch {};
        w.print("  State: {s}  |  Step {d}/{d}\n", .{ @tagName(self.state), self.current_step, self.steps.items.len }) catch {};

        for (self.steps.items) |step| {
            const icon: []const u8 = switch (step.status) {
                .pending => "○",
                .running => "▶",
                .completed => "✓",
                .failed => "✕",
                .skipped => "⊘",
            };
            w.print("  {s} [{d}] {s}\n", .{ icon, step.index + 1, step.description }) catch {};
        }

        return buf.toOwnedSlice();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "CrushEngine init/deinit" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "fix auth bug", ".");
    defer engine.deinit();

    try testing.expect(std.mem.eql(u8, engine.task, "fix auth bug"));
    try testing.expectEqual(CrushModeState.idle, engine.state);
    try testing.expectEqual(@as(usize, 0), engine.steps.items.len);
}

test "CrushEngine.buildPlanPrompt" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "add logging", ".");
    defer engine.deinit();

    const prompt = try engine.buildPlanPrompt(allocator);
    defer allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "add logging") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "STEP") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "TOOL:") != null);
}

test "CrushEngine.parsePlan" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "test task", ".");
    defer engine.deinit();

    const plan_response =
        \\STEP 1: Read the main file
        \\TOOL: read_file
        \\ARGS: {"path": "src/main.zig"}
        \\
        \\STEP 2: Fix the bug
        \\TOOL: edit
        \\ARGS: {"file_path": "src/main.zig", "old_string": "foo", "new_string": "bar"}
        \\
        \\STEP 3: Verify build
        \\TOOL: shell
        \\ARGS: {"command": "zig build"}
        \\
    ;

    try engine.parsePlan(plan_response);
    try testing.expectEqual(@as(usize, 3), engine.steps.items.len);

    try testing.expectEqualStrings("Read the main file", engine.steps.items[0].description);
    try testing.expectEqualStrings("read_file", engine.steps.items[0].tool);

    try testing.expectEqualStrings("Fix the bug", engine.steps.items[1].description);
    try testing.expectEqualStrings("edit", engine.steps.items[1].tool);

    try testing.expectEqualStrings("Verify build", engine.steps.items[2].description);
    try testing.expectEqualStrings("shell", engine.steps.items[2].tool);
}

test "CrushEngine.shouldAutoApprove" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "task", ".");
    defer engine.deinit();

    // Read operations should be auto-approved
    try testing.expect(engine.shouldAutoApprove("read_file"));
    try testing.expect(engine.shouldAutoApprove("glob"));
    try testing.expect(engine.shouldAutoApprove("grep"));
    try testing.expect(engine.shouldAutoApprove("git_status"));

    // Write operations should NOT be auto-approved by default
    try testing.expect(!engine.shouldAutoApprove("write_file"));
    try testing.expect(!engine.shouldAutoApprove("edit"));
    try testing.expect(!engine.shouldAutoApprove("shell"));

    // Enable write auto-approve
    engine.auto_approve_write = true;
    try testing.expect(engine.shouldAutoApprove("write_file"));
    try testing.expect(engine.shouldAutoApprove("edit"));
}

test "CrushEngine.buildResult" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "test task", ".");
    defer engine.deinit();

    try engine.addStep("Step 1", "read_file", "{}");
    engine.steps.items[0].status = .completed;

    try engine.addStep("Step 2", "edit", "{}");
    engine.steps.items[1].status = .pending;

    engine.state = .executing;

    var result = try engine.buildResult();
    defer result.deinit(allocator);

    try testing.expectEqualStrings("test task", result.task);
    try testing.expectEqual(CrushModeState.executing, result.state);
    try testing.expectEqual(@as(usize, 2), result.total_steps);
    try testing.expectEqual(@as(usize, 1), result.completed_steps);
}

test "CrushEngine.progressString" {
    const allocator = testing.allocator;
    var engine = CrushEngine.init(allocator, "fix bug", ".");
    defer engine.deinit();

    try engine.addStep("Read file", "read_file", "{}");
    engine.steps.items[0].status = .completed;

    try engine.addStep("Fix bug", "edit", "{}");
    engine.steps.items[1].status = .running;

    engine.state = .executing;

    const progress = try engine.progressString(allocator);
    defer allocator.free(progress);

    try testing.expect(std.mem.indexOf(u8, progress, "fix bug") != null);
    try testing.expect(std.mem.indexOf(u8, progress, "Read file") != null);
    try testing.expect(std.mem.indexOf(u8, progress, "Fix bug") != null);
}

test "CrushResult deinit cleans up" {
    const allocator = testing.allocator;

    var result = CrushResult{
        .task = try allocator.dupe(u8, "test"),
        .state = .done,
        .total_steps = 0,
        .completed_steps = 0,
        .failed_steps = 0,
        .skipped_steps = 0,
        .steps = &.{},
        .commit_hash = null,
        .duration_ms = 0,
    };
    result.deinit(allocator);
}
