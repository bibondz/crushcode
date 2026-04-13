const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const task = @import("task");

const Allocator = std.mem.Allocator;

/// Agent category - determines which model to use for the task
/// Reference: oh-my-openagent category delegation system
pub const AgentCategory = enum {
    /// Frontend, UI/UX, design, styling, animation
    visual_engineering,
    /// Hard logic, architecture decisions, algorithms
    ultrabrain,
    /// Autonomous research + end-to-end implementation
    deep,
    /// Single-file changes, typo fixes, simple modifications
    quick,
    /// General purpose - uses default model
    general,
    /// Code review and quality assurance
    review,
    /// Research and exploration
    research,
};

/// Get default model for an agent category
/// These are just suggestions — actual model comes from user's config
pub fn getDefaultModelForCategory(category: AgentCategory) []const u8 {
    return switch (category) {
        .visual_engineering => "default",
        .ultrabrain => "default",
        .deep => "default",
        .quick => "default",
        .general => "default",
        .review => "default",
        .research => "default",
    };
}

/// Get default provider for an agent category
/// Uses user's configured default provider — no hardcoded bias
pub fn getDefaultProviderForCategory(category: AgentCategory) []const u8 {
    _ = category;
    return "default";
}

/// Parse category from string (case-insensitive)
pub fn parseCategory(s: []const u8) ?AgentCategory {
    // Simple case-insensitive check - compare lowercase manually
    if (std.ascii.startsWithIgnoreCase(s, "visual") or
        std.mem.eql(u8, s, "visual-engineering") or
        std.mem.eql(u8, s, "ui") or
        std.mem.eql(u8, s, "frontend"))
    {
        return .visual_engineering;
    }
    if (std.ascii.startsWithIgnoreCase(s, "ultrabrain") or
        std.mem.eql(u8, s, "logic") or
        std.mem.eql(u8, s, "hard"))
    {
        return .ultrabrain;
    }
    if (std.ascii.startsWithIgnoreCase(s, "deep") or
        std.mem.eql(u8, s, "autonomous"))
    {
        return .deep;
    }
    if (std.ascii.startsWithIgnoreCase(s, "quick") or
        std.mem.eql(u8, s, "fast") or
        std.mem.eql(u8, s, "simple"))
    {
        return .quick;
    }
    if (std.ascii.startsWithIgnoreCase(s, "review") or
        std.mem.eql(u8, s, "qa"))
    {
        return .review;
    }
    if (std.ascii.startsWithIgnoreCase(s, "research") or
        std.mem.eql(u8, s, "explore"))
    {
        return .research;
    }
    if (std.ascii.startsWithIgnoreCase(s, "general") or
        std.mem.eql(u8, s, "default"))
    {
        return .general;
    }
    return null;
}

/// A task to be executed by a parallel agent
pub const ParallelTask = struct {
    id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    category: AgentCategory,
    priority: u32,
    status: task.RunState,
    result: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, prompt: []const u8, provider: []const u8, model: []const u8, category: AgentCategory) !ParallelTask {
        return ParallelTask{
            .id = try allocator.dupe(u8, id),
            .prompt = try allocator.dupe(u8, prompt),
            .provider = try allocator.dupe(u8, provider),
            .model = try allocator.dupe(u8, model),
            .category = category,
            .priority = 0,
            .status = .pending,
            .result = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParallelTask) void {
        self.allocator.free(self.id);
        self.allocator.free(self.prompt);
        self.allocator.free(self.provider);
        self.allocator.free(self.model);
        if (self.result) |r| self.allocator.free(r);
    }
};

/// Parallel agent executor — manages multiple concurrent AI tasks
///
/// Supports up to 5 concurrent tasks per provider, with task queuing,
/// cancellation, and result collection.
///
/// Reference: oh-my-openagent background-agent system
pub const ParallelExecutor = struct {
    allocator: Allocator,
    tasks: array_list_compat.ArrayList(*ParallelTask),
    max_concurrent: u32,
    completed_results: array_list_compat.ArrayList(task.TaskResult),
    next_id: u32,

    pub fn init(allocator: Allocator, max_concurrent: u32) ParallelExecutor {
        return ParallelExecutor{
            .allocator = allocator,
            .tasks = array_list_compat.ArrayList(*ParallelTask).init(allocator),
            .max_concurrent = max_concurrent,
            .completed_results = array_list_compat.ArrayList(task.TaskResult).init(allocator),
            .next_id = 1,
        };
    }

    /// Submit a new task to the executor
    pub fn submit(self: *ParallelExecutor, prompt: []const u8, provider: []const u8, model: []const u8, category: AgentCategory) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "task_{d}", .{self.next_id});
        self.next_id += 1;

        const parallel_task = try self.allocator.create(ParallelTask);
        parallel_task.* = try ParallelTask.init(self.allocator, id, prompt, provider, model, category);

        try self.tasks.append(parallel_task);
        return id;
    }

    /// Get a task by ID
    pub fn getTask(self: *ParallelExecutor, task_id: []const u8) ?*ParallelTask {
        for (self.tasks.items) |parallel_task| {
            if (std.mem.eql(u8, parallel_task.id, task_id)) return parallel_task;
        }
        return null;
    }

    /// Cancel a pending or running task
    pub fn cancel(self: *ParallelExecutor, task_id: []const u8) bool {
        if (self.getTask(task_id)) |parallel_task| {
            if (parallel_task.status == .pending or parallel_task.status == .running) {
                parallel_task.status = .cancelled;
                return true;
            }
        }
        return false;
    }

    /// Get count of tasks by status
    pub fn countByStatus(self: *const ParallelExecutor, status: task.RunState) u32 {
        var count: u32 = 0;
        for (self.tasks.items) |parallel_task| {
            if (parallel_task.status == status) count += 1;
        }
        return count;
    }

    /// Get count of running tasks
    pub fn runningCount(self: *const ParallelExecutor) u32 {
        return self.countByStatus(.running);
    }

    /// Check if we can accept more concurrent tasks
    pub fn canAcceptMore(self: *const ParallelExecutor) bool {
        return self.runningCount() < self.max_concurrent;
    }

    /// Get all completed results
    pub fn getResults(self: *const ParallelExecutor) []const task.TaskResult {
        return self.completed_results.items;
    }

    /// Record a task result
    pub fn recordResult(self: *ParallelExecutor, task_id: []const u8, output: []const u8, success: bool) !void {
        if (self.getTask(task_id)) |parallel_task| {
            const result = task.TaskResult{
                .id = try self.allocator.dupe(u8, task_id),
                .state = if (success) .completed else .failed,
                .output = try self.allocator.dupe(u8, output),
                .duration_ms = 0,
                .allocator = self.allocator,
            };
            try self.completed_results.append(result);
            parallel_task.status = if (success) .completed else .failed;
            parallel_task.result = try self.allocator.dupe(u8, output);
        }
    }

    /// Print executor status
    pub fn printStatus(self: *ParallelExecutor) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Multi-Agent Executor ===\n", .{}) catch {};
        stdout.print("  Max concurrent: {d}\n", .{self.max_concurrent}) catch {};
        stdout.print("  Pending: {d}\n", .{self.countByStatus(.pending)}) catch {};
        stdout.print("  Running: {d}\n", .{self.countByStatus(.running)}) catch {};
        stdout.print("  Completed: {d}\n", .{self.countByStatus(.completed)}) catch {};
        stdout.print("  Failed: {d}\n", .{self.countByStatus(.failed)}) catch {};

        for (self.tasks.items) |parallel_task| {
            const status_icon = switch (parallel_task.status) {
                .pending => "⏳",
                .running => "🔄",
                .completed => "✅",
                .failed => "❌",
                .cancelled => "🚫",
                .skipped => "⏭️ ",
                .verified => "✓ ",
            };
            const category_name = @tagName(parallel_task.category);
            stdout.print("  {s} [{s}] {s}: {s}/{s} — {s:.40}\n", .{
                status_icon,
                category_name,
                parallel_task.id,
                parallel_task.provider,
                parallel_task.model,
                parallel_task.prompt,
            }) catch {};
        }
    }

    /// Print aggregated results summary
    pub fn printSummary(self: *ParallelExecutor) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Agent Results Summary ===\n", .{}) catch {};

        const completed = self.countByStatus(.completed);
        const failed = self.countByStatus(.failed);
        const total = self.tasks.items.len;

        stdout.print("  Total: {d} | Completed: {d} | Failed: {d}\n\n", .{
            total, completed, failed,
        }) catch {};

        for (self.completed_results.items) |result| {
            const icon = switch (result.state) {
                .completed => "✅",
                .failed => "❌",
                else => "❓",
            };
            stdout.print("  {s} {s}\n", .{ icon, result.id }) catch {};
            if (result.output.len > 0) {
                stdout.print("      {s:.100}\n", .{result.output}) catch {};
            }
        }
    }

    /// Wait for all tasks to complete (polling approach)
    pub fn waitForAll(self: *ParallelExecutor) void {
        // In a real implementation, this would use threads and condition variables
        // For now, iterate and check status
        while (self.countByStatus(.running) > 0 or self.countByStatus(.pending) > 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn deinit(self: *ParallelExecutor) void {
        for (self.tasks.items) |parallel_task| {
            parallel_task.deinit();
            self.allocator.destroy(parallel_task);
        }
        self.tasks.deinit();
        for (self.completed_results.items) |*result| {
            result.deinit();
        }
        self.completed_results.deinit();
    }
};
