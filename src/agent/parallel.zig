const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const collections = @import("collections");
const task = @import("task");
const core = @import("core_api");
const registry = @import("registry");

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

/// Completed work item — produced by worker thread, consumed by main thread
pub const CompletedWork = struct {
    task_id: []const u8, // owned
    success: bool,
    output: []const u8, // owned
    duration_ms: u64,

    pub fn deinit(self: *CompletedWork, allocator: Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.output);
    }
};

/// Thread-safe queue for completed work items.
/// Worker threads push results, main thread drains.
pub const CompletionQueue = struct {
    mutex: std.Thread.Mutex,
    items: array_list_compat.ArrayList(CompletedWork),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CompletionQueue {
        return .{
            .mutex = .{},
            .items = array_list_compat.ArrayList(CompletedWork).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn push(self: *CompletionQueue, item: CompletedWork) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(item) catch {};
    }

    /// Drain all items — caller takes ownership of returned slice.
    /// Caller must free each item and the slice itself.
    pub fn drain(self: *CompletionQueue) []CompletedWork {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.items.items;
        // Reset internal list — caller owns the items now
        self.items = array_list_compat.ArrayList(CompletedWork).init(self.allocator);
        return result;
    }

    pub fn deinit(self: *CompletionQueue) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit();
    }
};

/// Forward declaration for ParallelExecutor (needed for back-reference)
pub const ParallelExecutor = struct {
    allocator: Allocator,
    tasks: array_list_compat.ArrayList(*ParallelTask),
    max_concurrent: u32,
    completed_results: array_list_compat.ArrayList(task.TaskResult),
    completion_queue: CompletionQueue,
    next_id: u32,
    shutting_down: bool,

    pub fn init(allocator: Allocator, max_concurrent: u32) ParallelExecutor {
        return .{
            .allocator = allocator,
            .tasks = array_list_compat.ArrayList(*ParallelTask).init(allocator),
            .max_concurrent = max_concurrent,
            .completed_results = array_list_compat.ArrayList(task.TaskResult).init(allocator),
            .completion_queue = CompletionQueue.init(allocator),
            .next_id = 1,
            .shutting_down = false,
        };
    }

    /// Submit a new task to the executor.
    /// If a slot is available, the task is immediately spawned on a new thread.
    /// Otherwise it stays pending until a slot frees up.
    pub fn submit(self: *ParallelExecutor, prompt: []const u8, provider: []const u8, model: []const u8, api_key: []const u8, base_url: []const u8, category: AgentCategory) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "task_{d}", .{self.next_id});
        self.next_id += 1;

        const parallel_task = try self.allocator.create(ParallelTask);
        parallel_task.* = try ParallelTask.init(self.allocator, id, prompt, provider, model, api_key, base_url, category);
        parallel_task.executor = self;

        try self.tasks.append(parallel_task);

        if (self.canAcceptMore()) {
            self.spawnTask(parallel_task) catch |err| {
                std.log.warn("ParallelExecutor: failed to spawn thread for {s}: {}", .{ id, err });
                // Task stays pending — will be started when slots free up
            };
        }

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
        return collections.countMatching(self.tasks.items, "status", status);
    }

    /// Get count of running tasks
    pub fn runningCount(self: *const ParallelExecutor) u32 {
        return self.countByStatus(.running);
    }

    /// Check if we can accept more concurrent tasks
    pub fn canAcceptMore(self: *const ParallelExecutor) bool {
        return self.runningCount() < self.max_concurrent;
    }

    /// Record a result directly (for synchronous/demo usage).
    /// Used by CLI demo commands that don't use threads.
    pub fn recordResult(self: *ParallelExecutor, task_id: []const u8, output: []const u8, success: bool) !void {
        if (self.getTask(task_id)) |parallel_task| {
            parallel_task.status = if (success) .completed else .failed;
            if (parallel_task.result) |old| self.allocator.free(old);
            parallel_task.result = try self.allocator.dupe(u8, output);

            const result = task.TaskResult{
                .id = try self.allocator.dupe(u8, task_id),
                .state = if (success) .completed else .failed,
                .output = try self.allocator.dupe(u8, output),
                .duration_ms = 0,
                .allocator = self.allocator,
            };
            try self.completed_results.append(result);
        }
    }

    /// Get all completed results (legacy — prefer reapCompleted for threaded tasks)
    pub fn getResults(self: *const ParallelExecutor) []const task.TaskResult {
        return self.completed_results.items;
    }

    /// Drain completion queue and join finished threads.
    /// Call this from the main thread periodically (e.g., in TUI draw loop).
    pub fn reapCompleted(self: *ParallelExecutor) void {
        const completed = self.completion_queue.drain();
        defer self.allocator.free(completed);

        for (completed) |work| {
            // Find the task and update its status/result
            if (self.getTask(work.task_id)) |parallel_task| {
                if (parallel_task.thread) |thread| {
                    thread.join();
                    parallel_task.thread = null;
                }
                parallel_task.status = if (work.success) .completed else .failed;
                if (parallel_task.result) |old| self.allocator.free(old);
                parallel_task.result = work.output;
                // Note: task_id in work is a separate allocation
                self.allocator.free(work.task_id);
            } else {
                self.allocator.free(work.task_id);
                self.allocator.free(work.output);
            }
        }

        // Start pending tasks if slots freed up
        self.startPending() catch {};
    }

    /// Start pending tasks up to max_concurrent limit
    pub fn startPending(self: *ParallelExecutor) !void {
        if (self.shutting_down) return;
        while (self.canAcceptMore()) {
            var found_pending: ?*ParallelTask = null;
            for (self.tasks.items) |parallel_task| {
                if (parallel_task.status == .pending) {
                    found_pending = parallel_task;
                    break;
                }
            }
            const pending = found_pending orelse break;
            try self.spawnTask(pending);
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
            // Strip provider prefix from model name for display (e.g. "nvidia/model" → "model")
            const display_model = if (std.mem.indexOfScalar(u8, parallel_task.model, '/')) |idx| parallel_task.model[idx + 1 ..] else parallel_task.model;
            stdout.print("  {s} [{s}] {s}: {s}/{s} — {s:.40}\n", .{
                status_icon,
                category_name,
                parallel_task.id,
                parallel_task.provider,
                display_model,
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

    /// Wait for all tasks to complete.
    /// Uses reapCompleted loop instead of sleep-based polling.
    pub fn waitForAll(self: *ParallelExecutor) void {
        while (self.countByStatus(.running) > 0 or self.countByStatus(.pending) > 0) {
            self.reapCompleted();
            if (self.countByStatus(.running) > 0 or self.countByStatus(.pending) > 0) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        // Final reap to collect any remaining results
        self.reapCompleted();
    }

    pub fn deinit(self: *ParallelExecutor) void {
        self.shutting_down = true;

        // Join all running threads
        for (self.tasks.items) |parallel_task| {
            if (parallel_task.thread) |thread| {
                thread.join();
                parallel_task.thread = null;
            }
        }

        // Drain any remaining completion queue items
        const remaining = self.completion_queue.drain();
        for (remaining) |work| {
            self.allocator.free(work.task_id);
            self.allocator.free(work.output);
        }
        self.allocator.free(remaining);
        self.completion_queue.deinit();

        // Free all tasks
        for (self.tasks.items) |parallel_task| {
            parallel_task.deinit();
            self.allocator.destroy(parallel_task);
        }
        self.tasks.deinit();

        // Free legacy completed results
        for (self.completed_results.items) |*result| {
            result.deinit();
        }
        self.completed_results.deinit();
    }

    // --- Private methods ---

    fn spawnTask(self: *ParallelExecutor, parallel_task: *ParallelTask) !void {
        if (self.shutting_down) return;
        parallel_task.status = .running;
        const thread = try std.Thread.spawn(.{}, workerThreadMain, .{parallel_task});
        parallel_task.thread = thread;
    }
};

/// A task to be executed by a parallel agent
pub const ParallelTask = struct {
    id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    category: AgentCategory,
    priority: u32,
    status: task.RunState,
    result: ?[]const u8,
    allocator: Allocator,
    thread: ?std.Thread = null,
    executor: ?*ParallelExecutor = null,

    pub fn init(allocator: Allocator, id: []const u8, prompt: []const u8, provider: []const u8, model: []const u8, api_key: []const u8, base_url: []const u8, category: AgentCategory) !ParallelTask {
        return ParallelTask{
            .id = try allocator.dupe(u8, id),
            .prompt = try allocator.dupe(u8, prompt),
            .provider = try allocator.dupe(u8, provider),
            .model = try allocator.dupe(u8, model),
            .api_key = try allocator.dupe(u8, api_key),
            .base_url = try allocator.dupe(u8, base_url),
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
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        if (self.result) |r| self.allocator.free(r);
    }
};

/// Worker thread entry point.
/// Uses a thread-local ArenaAllocator for AI calls to avoid sharing
/// allocator state across threads. Response content is duped onto
/// the executor's allocator before the arena is freed.
/// Never panics — all errors caught and recorded as failures.
fn workerThreadMain(task_ptr: *ParallelTask) void {
    task_ptr.status = .running;
    const start_time = std.time.milliTimestamp();

    // Check if cancelled before starting
    if (task_ptr.status == .cancelled) return;
    if (task_ptr.executor) |exec| {
        if (exec.shutting_down) return;
    }

    const exec = task_ptr.executor orelse return;

    const result: struct {
        success: bool,
        output: []const u8,
        duration_ms: u64,
    } = blk: {
        // Thread-local arena — each worker gets its own allocator so
        // std.http.Client internal state is never shared across threads.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const provider = registry.Provider{
            .name = task_ptr.provider,
            .config = .{
                .base_url = task_ptr.base_url,
                .api_key = task_ptr.api_key,
                .models = &.{},
            },
            .allocator = arena_allocator,
        };

        var client = core.AIClient.init(arena_allocator, provider, task_ptr.model, task_ptr.api_key) catch |err| {
            const err_msg = std.fmt.allocPrint(task_ptr.allocator, "AIClient init failed: {any}", .{err}) catch "AIClient init failed";
            break :blk .{
                .success = false,
                .output = err_msg,
                .duration_ms = 0,
            };
        };
        defer client.deinit();

        const response = client.sendChat(task_ptr.prompt) catch |err| {
            const err_msg = std.fmt.allocPrint(task_ptr.allocator, "sendChat failed: {any}", .{err}) catch "sendChat failed";
            break :blk .{
                .success = false,
                .output = err_msg,
                .duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
            };
        };

        const response_content = if (response.choices.len > 0) response.choices[0].message.content orelse "" else "";
        // Dupe onto executor's allocator so content outlives the thread-local arena
        const owned_content = task_ptr.allocator.dupe(u8, response_content) catch "";
        break :blk .{
            .success = true,
            .output = owned_content,
            .duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
        };
    };

    const work = CompletedWork{
        .task_id = exec.allocator.dupe(u8, task_ptr.id) catch return,
        .success = result.success,
        .output = result.output,
        .duration_ms = result.duration_ms,
    };
    exec.completion_queue.push(work);
}
