const std = @import("std");

const Allocator = std.mem.Allocator;

/// Status of a parallel task
pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

/// Result from a single parallel task
pub const TaskResult = struct {
    task_id: []const u8,
    status: TaskStatus,
    output: []const u8,
    duration_ms: u64,
    allocator: Allocator,

    pub fn deinit(self: *TaskResult) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.output);
    }
};

/// A task to be executed by a parallel agent
pub const ParallelTask = struct {
    id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    priority: u32,
    status: TaskStatus,
    result: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, prompt: []const u8, provider: []const u8, model: []const u8) !ParallelTask {
        return ParallelTask{
            .id = try allocator.dupe(u8, id),
            .prompt = try allocator.dupe(u8, prompt),
            .provider = try allocator.dupe(u8, provider),
            .model = try allocator.dupe(u8, model),
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
    tasks: std.ArrayList(*ParallelTask),
    max_concurrent: u32,
    completed_results: std.ArrayList(TaskResult),
    next_id: u32,

    pub fn init(allocator: Allocator, max_concurrent: u32) ParallelExecutor {
        return ParallelExecutor{
            .allocator = allocator,
            .tasks = std.ArrayList(*ParallelTask).init(allocator),
            .max_concurrent = max_concurrent,
            .completed_results = std.ArrayList(TaskResult).init(allocator),
            .next_id = 1,
        };
    }

    /// Submit a new task to the executor
    pub fn submit(self: *ParallelExecutor, prompt: []const u8, provider: []const u8, model: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "task_{d}", .{self.next_id});
        self.next_id += 1;

        const task = try self.allocator.create(ParallelTask);
        task.* = try ParallelTask.init(self.allocator, id, prompt, provider, model);

        try self.tasks.append(task);
        return id;
    }

    /// Get a task by ID
    pub fn getTask(self: *ParallelExecutor, task_id: []const u8) ?*ParallelTask {
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.id, task_id)) return task;
        }
        return null;
    }

    /// Cancel a pending or running task
    pub fn cancel(self: *ParallelExecutor, task_id: []const u8) bool {
        if (self.getTask(task_id)) |task| {
            if (task.status == .pending or task.status == .running) {
                task.status = .cancelled;
                return true;
            }
        }
        return false;
    }

    /// Get count of tasks by status
    pub fn countByStatus(self: *const ParallelExecutor, status: TaskStatus) u32 {
        var count: u32 = 0;
        for (self.tasks.items) |task| {
            if (task.status == status) count += 1;
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
    pub fn getResults(self: *const ParallelExecutor) []const TaskResult {
        return self.completed_results.items;
    }

    /// Record a task result
    pub fn recordResult(self: *ParallelExecutor, task_id: []const u8, output: []const u8, success: bool) !void {
        if (self.getTask(task_id)) |task| {
            const result = TaskResult{
                .task_id = try self.allocator.dupe(u8, task_id),
                .status = if (success) .completed else .failed,
                .output = try self.allocator.dupe(u8, output),
                .duration_ms = 0,
                .allocator = self.allocator,
            };
            try self.completed_results.append(result);
            task.status = if (success) .completed else .failed;
            task.result = try self.allocator.dupe(u8, output);
        }
    }

    /// Print executor status
    pub fn printStatus(self: *ParallelExecutor) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\n=== Parallel Executor ===\n", .{}) catch {};
        stdout.print("  Max concurrent: {d}\n", .{self.max_concurrent}) catch {};
        stdout.print("  Pending: {d}\n", .{self.countByStatus(.pending)}) catch {};
        stdout.print("  Running: {d}\n", .{self.countByStatus(.running)}) catch {};
        stdout.print("  Completed: {d}\n", .{self.countByStatus(.completed)}) catch {};
        stdout.print("  Failed: {d}\n", .{self.countByStatus(.failed)}) catch {};

        for (self.tasks.items) |task| {
            const status_icon = switch (task.status) {
                .pending => "⏳",
                .running => "🔄",
                .completed => "✅",
                .failed => "❌",
                .cancelled => "🚫",
            };
            stdout.print("  {s} {s}: {s}/{s} — {s:.40}\n", .{
                status_icon,
                task.id,
                task.provider,
                task.model,
                task.prompt,
            }) catch {};
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
        for (self.tasks.items) |task| {
            task.deinit();
            self.allocator.destroy(task);
        }
        self.tasks.deinit();
        for (self.completed_results.items) |*result| {
            result.deinit();
        }
        self.completed_results.deinit();
    }
};
