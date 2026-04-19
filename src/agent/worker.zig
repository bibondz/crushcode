const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

/// Worker specialty — determines the kind of task a worker handles.
/// Each specialty maps to a different skill set in the agent pipeline.
pub const WorkerSpecialty = enum {
    researcher,
    file_ops,
    executor,
    publisher,
    collector,
};

/// Worker status — lifecycle states for a single worker.
pub const WorkerStatus = enum {
    pending,
    running,
    completed,
    failed,
    timeout,
};

/// A single worker agent in the pool.
/// Uses file-based communication: writes task description and results
/// to /tmp/crushcode-worker-{id}.md.
/// At this stage, workers are data structures only — no subprocess spawning.
pub const WorkerAgent = struct {
    allocator: Allocator,
    id: []const u8,
    specialty: WorkerSpecialty,
    model_preference: ?[]const u8,
    output_path: []const u8,
    status: WorkerStatus,
    max_timeout_ms: u64,
    started_at: ?i64,
    result_path: ?[]const u8,

    /// Create a new WorkerAgent with the given parameters.
    /// Caller owns the returned WorkerAgent and must call deinit().
    pub fn init(
        allocator: Allocator,
        id: []const u8,
        specialty: WorkerSpecialty,
        model_preference: ?[]const u8,
    ) !WorkerAgent {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);

        const output_path = try std.fmt.allocPrint(allocator, "/tmp/crushcode-worker-{s}.md", .{id});
        errdefer allocator.free(output_path);

        const owned_model: ?[]const u8 = if (model_preference) |m| try allocator.dupe(u8, m) else null;
        errdefer if (owned_model) |m| allocator.free(m);

        return WorkerAgent{
            .allocator = allocator,
            .id = owned_id,
            .specialty = specialty,
            .model_preference = owned_model,
            .output_path = output_path,
            .status = .pending,
            .max_timeout_ms = 60000,
            .started_at = null,
            .result_path = null,
        };
    }

    pub fn deinit(self: *WorkerAgent) void {
        self.allocator.free(self.id);
        self.allocator.free(self.output_path);
        if (self.model_preference) |m| self.allocator.free(m);
        if (self.result_path) |p| self.allocator.free(p);
    }

    /// Write the task description to the worker's output file.
    /// Creates the file at output_path with the task description as content.
    pub fn writeTaskDescription(self: *WorkerAgent, task_description: []const u8) !void {
        const file = std.fs.cwd().openFile(self.output_path, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                // Try creating via /tmp
                const dir = std.fs.openDirAbsolute("/tmp", .{}) catch return err;
                const f = dir.createFile(self.output_path["/tmp/".len..], .{}) catch return err;
                defer f.close();
                try f.writeAll(task_description);
                return;
            }
            return err;
        };
        defer file.close();
        try file.writeAll(task_description);
    }

    /// Write a result marker to the worker's output file, signaling completion.
    /// Sets status to completed and records result_path.
    pub fn writeResult(self: *WorkerAgent, result_content: []const u8) !void {
        const result_path = try std.fmt.allocPrint(self.allocator, "/tmp/crushcode-worker-{s}-result.md", .{self.id});
        self.result_path = result_path;

        const dir = std.fs.openDirAbsolute("/tmp", .{}) catch return error.FileNotFound;
        const file = dir.createFile(result_path["/tmp/".len..], .{}) catch return error.FileNotFound;
        defer file.close();
        try file.writeAll(result_content);

        self.status = .completed;
    }

    /// Check if this worker's result file exists and has content.
    pub fn checkResultFile(self: *const WorkerAgent) bool {
        const path = self.result_path orelse return false;
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();
        const stat = file.stat() catch return false;
        return stat.size > 0;
    }

    /// Execute a task by spawning a crushcode subprocess.
    /// Sets status to .running, spawns `crushcode run "<task>" --model <model>`,
    /// captures stdout to output_path, and transitions to .completed or .failed.
    pub fn execute(self: *WorkerAgent, allocator: Allocator, binary_path: []const u8, task_prompt: []const u8, model: []const u8) !void {
        self.status = .running;
        self.started_at = std.time.milliTimestamp();

        // Build argv: binary_path run "<task>" --model=<model>
        const model_arg = try std.fmt.allocPrint(allocator, "--model={s}", .{model});
        defer allocator.free(model_arg);

        const argv_slice = try allocator.alloc([]const u8, 4);
        defer allocator.free(argv_slice);
        argv_slice[0] = binary_path;
        argv_slice[1] = "run";
        argv_slice[2] = task_prompt;
        argv_slice[3] = model_arg;

        var child = std.process.Child.init(argv_slice, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            self.status = .failed;
            std.log.err("WorkerAgent.execute: spawn failed for {s}: {}", .{ self.id, err });
            return err;
        };

        // Read stdout
        var output_buf: [4096]u8 = undefined;
        var output = array_list_compat.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.read(&output_buf) catch break;
                if (n == 0) break;
                try output.appendSlice(output_buf[0..n]);
            }
        }

        // Read stderr for logging
        if (child.stderr) |stderr| {
            var stderr_buf: [4096]u8 = undefined;
            while (true) {
                const n = stderr.read(&stderr_buf) catch break;
                if (n == 0) break;
                std.log.warn("Worker {s} stderr: {s}", .{ self.id, stderr_buf[0..n] });
            }
        }

        // Wait for process exit
        const term = child.wait() catch |err| {
            self.status = .failed;
            output.deinit();
            std.log.err("WorkerAgent.execute: wait failed for {s}: {}", .{ self.id, err });
            return err;
        };

        const exit_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!exit_ok) {
            self.status = .failed;
            output.deinit();
            return;
        }

        // Write result
        if (output.items.len > 0) {
            self.writeResult(output.items) catch |err| {
                std.log.warn("WorkerAgent.execute: writeResult failed for {s}: {}", .{ self.id, err });
                self.status = .failed;
                output.deinit();
                return;
            };
        } else {
            self.status = .completed;
            const result_path = std.fmt.allocPrint(allocator, "/tmp/crushcode-worker-{s}-result.md", .{self.id}) catch {
                self.status = .failed;
                output.deinit();
                return;
            };
            if (self.result_path) |old| allocator.free(old);
            self.result_path = result_path;

            // Create empty result file
            const dir = std.fs.openDirAbsolute("/tmp", .{}) catch {
                output.deinit();
                return;
            };
            const file = dir.createFile(result_path["/tmp/".len..], .{}) catch {
                output.deinit();
                return;
            };
            file.close();
        }

        output.deinit();
    }

    /// Read the result file contents. Returns null if not completed or file missing.
    /// Caller owns the returned slice.
    pub fn readResult(self: *WorkerAgent) !?[]const u8 {
        if (self.status != .completed) return null;
        const path = self.result_path orelse return null;

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        if (stat.size == 0) return null;

        const content = try self.allocator.alloc(u8, stat.size);
        const bytes_read = file.readAll(content) catch |err| {
            self.allocator.free(content);
            return err;
        };
        if (bytes_read < stat.size) {
            self.allocator.free(content);
            return null;
        }
        return content[0..bytes_read];
    }
};

/// Pool of worker agents with concurrency management.
/// Manages lifecycle of multiple WorkerAgent instances.
pub const WorkerPool = struct {
    allocator: Allocator,
    workers: array_list_compat.ArrayList(*WorkerAgent),
    max_concurrent: u32,
    active_count: u32,
    next_id: u32,

    /// Initialize a new WorkerPool.
    pub fn init(allocator: Allocator) WorkerPool {
        return WorkerPool{
            .allocator = allocator,
            .workers = array_list_compat.ArrayList(*WorkerAgent).init(allocator),
            .max_concurrent = 5,
            .active_count = 0,
            .next_id = 1,
        };
    }

    /// Initialize with a custom max_concurrent limit.
    pub fn initWithCapacity(allocator: Allocator, max_concurrent: u32) WorkerPool {
        return WorkerPool{
            .allocator = allocator,
            .workers = array_list_compat.ArrayList(*WorkerAgent).init(allocator),
            .max_concurrent = max_concurrent,
            .active_count = 0,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *WorkerPool) void {
        for (self.workers.items) |worker| {
            worker.deinit();
            self.allocator.destroy(worker);
        }
        self.workers.deinit();
    }

    /// Spawn a new worker with the given specialty and task description.
    /// Creates a temp file with the task description.
    /// Returns a pointer to the new WorkerAgent.
    /// Worker starts in "pending" status — actual execution is async (future phase).
    pub fn spawnWorker(self: *WorkerPool, specialty: WorkerSpecialty, task_description: []const u8) !*WorkerAgent {
        if (self.active_count >= self.max_concurrent) {
            return error.PoolFull;
        }

        const id = try std.fmt.allocPrint(self.allocator, "worker-{d}", .{self.next_id});
        self.next_id += 1;

        const worker = try self.allocator.create(WorkerAgent);
        worker.* = try WorkerAgent.init(self.allocator, id, specialty, null);
        self.allocator.free(id);

        // Write task description to temp file
        worker.writeTaskDescription(task_description) catch |err| {
            // Log but don't fail — the file is just a communication mechanism
            std.log.warn("WorkerPool: failed to write task file for {s}: {}", .{ worker.id, err });
        };

        try self.workers.append(worker);
        self.active_count += 1;

        return worker;
    }

    /// Spawn a worker with a specific model preference.
    pub fn spawnWorkerWithModel(
        self: *WorkerPool,
        specialty: WorkerSpecialty,
        task_description: []const u8,
        model: []const u8,
    ) !*WorkerAgent {
        if (self.active_count >= self.max_concurrent) {
            return error.PoolFull;
        }

        const id = try std.fmt.allocPrint(self.allocator, "worker-{d}", .{self.next_id});
        self.next_id += 1;

        const worker = try self.allocator.create(WorkerAgent);
        worker.* = try WorkerAgent.init(self.allocator, id, specialty, model);
        self.allocator.free(id);

        worker.writeTaskDescription(task_description) catch {};

        try self.workers.append(worker);
        self.active_count += 1;

        return worker;
    }

    /// Check the status of a worker by ID.
    /// For completed workers, verifies the result file exists.
    pub fn checkStatus(self: *WorkerPool, worker_id: []const u8) WorkerStatus {
        const worker = self.findWorker(worker_id) orelse return .failed;
        if (worker.status == .completed and !worker.checkResultFile()) {
            return .timeout;
        }
        return worker.status;
    }

    /// Get the result content from a completed worker.
    /// Returns null if worker is not completed or result file doesn't exist.
    pub fn getResult(self: *WorkerPool, worker_id: []const u8) !?[]const u8 {
        const worker = self.findWorker(worker_id) orelse return null;
        if (worker.status != .completed) return null;
        const path = worker.result_path orelse return null;

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        if (stat.size == 0) return null;

        const content = try self.allocator.alloc(u8, stat.size);
        const bytes_read = file.readAll(content) catch |err| {
            self.allocator.free(content);
            return err;
        };
        if (bytes_read < stat.size) {
            self.allocator.free(content);
            return null;
        }
        return content[0..bytes_read];
    }

    /// Remove completed and failed workers from the pool.
    /// Deletes their temp files.
    pub fn cleanup(self: *WorkerPool) void {
        var i: usize = 0;
        while (i < self.workers.items.len) {
            const worker = self.workers.items[i];
            switch (worker.status) {
                .completed, .failed, .timeout => {
                    // Remove temp files
                    self.removeTempFile(worker.output_path);
                    if (worker.result_path) |p| self.removeTempFile(p);

                    worker.deinit();
                    self.allocator.destroy(worker);
                    _ = self.workers.swapRemove(i);
                    if (self.active_count > 0) self.active_count -= 1;
                },
                else => i += 1,
            }
        }
    }

    /// Find a worker by ID.
    pub fn findWorker(self: *WorkerPool, worker_id: []const u8) ?*WorkerAgent {
        for (self.workers.items) |worker| {
            if (std.mem.eql(u8, worker.id, worker_id)) return worker;
        }
        return null;
    }

    /// Get count of workers by status.
    pub fn countByStatus(self: *const WorkerPool, status: WorkerStatus) u32 {
        var count: u32 = 0;
        for (self.workers.items) |worker| {
            if (worker.status == status) count += 1;
        }
        return count;
    }

    /// Print pool status to stdout.
    pub fn printStatus(self: *WorkerPool) void {
        const stdout = file_compat.File.stdout();
        stdout.print("\n=== Worker Pool ===\n", .{}) catch {};
        stdout.print("  Max concurrent: {d}\n", .{self.max_concurrent}) catch {};
        stdout.print("  Active: {d}\n", .{self.active_count}) catch {};
        stdout.print("  Pending: {d}\n", .{self.countByStatus(.pending)}) catch {};
        stdout.print("  Running: {d}\n", .{self.countByStatus(.running)}) catch {};
        stdout.print("  Completed: {d}\n", .{self.countByStatus(.completed)}) catch {};
        stdout.print("  Failed: {d}\n", .{self.countByStatus(.failed)}) catch {};
        stdout.print("  Timeout: {d}\n", .{self.countByStatus(.timeout)}) catch {};

        for (self.workers.items) |worker| {
            const status_icon = switch (worker.status) {
                .pending => "⏳",
                .running => "🔄",
                .completed => "✅",
                .failed => "❌",
                .timeout => "⏰",
            };
            stdout.print("  {s} [{s}] {s}\n", .{
                status_icon,
                @tagName(worker.specialty),
                worker.id,
            }) catch {};
        }
    }

    fn removeTempFile(self: *WorkerPool, path: []const u8) void {
        _ = self;
        std.fs.cwd().deleteFile(path) catch {};
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "WorkerAgent - init and deinit" {
    const allocator = std.testing.allocator;
    var worker = try WorkerAgent.init(allocator, "test-1", .researcher, "gpt-4o");
    defer worker.deinit();

    try testing.expectEqualStrings("test-1", worker.id);
    try testing.expectEqual(WorkerSpecialty.researcher, worker.specialty);
    try testing.expect(worker.model_preference != null);
    try testing.expectEqualStrings("gpt-4o", worker.model_preference.?);
    try testing.expectEqual(WorkerStatus.pending, worker.status);
    try testing.expectEqual(@as(u64, 60000), worker.max_timeout_ms);
    try testing.expect(worker.started_at == null);
    try testing.expect(worker.result_path == null);
}

test "WorkerAgent - init without model preference" {
    const allocator = std.testing.allocator;
    var worker = try WorkerAgent.init(allocator, "test-2", .executor, null);
    defer worker.deinit();

    try testing.expect(worker.model_preference == null);
}

test "WorkerAgent - output path format" {
    const allocator = std.testing.allocator;
    var worker = try WorkerAgent.init(allocator, "42", .file_ops, null);
    defer worker.deinit();

    try testing.expectEqualStrings("/tmp/crushcode-worker-42.md", worker.output_path);
}

test "WorkerAgent - writeTaskDescription creates temp file" {
    const allocator = std.testing.allocator;
    var worker = try WorkerAgent.init(allocator, "write-test", .researcher, null);
    defer worker.deinit();

    // Write task description
    const task = "Research the latest Zig 0.15 features";
    try worker.writeTaskDescription(task);

    // Verify file was created
    const file = std.fs.cwd().openFile(worker.output_path, .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        return err;
    };
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return error.Unexpected;
    try testing.expectEqualStrings(task, buf[0..bytes_read]);

    // Cleanup
    std.fs.cwd().deleteFile(worker.output_path) catch {};
}

test "WorkerAgent - writeResult marks completed" {
    const allocator = std.testing.allocator;
    var worker = try WorkerAgent.init(allocator, "result-test", .executor, null);
    defer worker.deinit();

    try testing.expectEqual(WorkerStatus.pending, worker.status);

    try worker.writeResult("Task completed successfully");

    try testing.expectEqual(WorkerStatus.completed, worker.status);
    try testing.expect(worker.result_path != null);

    // Verify result file
    const result = worker.result_path.?;
    const result_file = std.fs.cwd().openFile(result, .{}) catch return error.FileNotFound;
    defer result_file.close();

    var buf2: [256]u8 = undefined;
    const bytes_read2 = result_file.readAll(&buf2) catch return error.Unexpected;
    try testing.expectEqualStrings("Task completed successfully", buf2[0..bytes_read2]);

    // Cleanup
    std.fs.cwd().deleteFile(result) catch {};
}

test "WorkerPool - init and deinit" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    try testing.expectEqual(@as(u32, 5), pool.max_concurrent);
    try testing.expectEqual(@as(u32, 0), pool.active_count);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(pool.workers.items.len)));
}

test "WorkerPool - init with custom capacity" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.initWithCapacity(allocator, 10);
    defer pool.deinit();

    try testing.expectEqual(@as(u32, 10), pool.max_concurrent);
}

test "WorkerPool - spawnWorker creates worker and temp file" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const worker = try pool.spawnWorker(.researcher, "Analyze codebase structure");

    try testing.expectEqualStrings("worker-1", worker.id);
    try testing.expectEqual(WorkerSpecialty.researcher, worker.specialty);
    try testing.expectEqual(WorkerStatus.pending, worker.status);
    try testing.expectEqual(@as(u32, 1), pool.active_count);
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(pool.workers.items.len)));

    // Verify temp file was created
    const file = std.fs.cwd().openFile(worker.output_path, .{}) catch return error.FileNotFound;
    defer file.close();
    var buf: [256]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return error.Unexpected;
    try testing.expectEqualStrings("Analyze codebase structure", buf[0..bytes_read]);

    // Cleanup temp file
    std.fs.cwd().deleteFile(worker.output_path) catch {};
}

test "WorkerPool - spawnWorker respects max_concurrent" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.initWithCapacity(allocator, 2);
    defer pool.deinit();

    _ = try pool.spawnWorker(.researcher, "Task 1");
    _ = try pool.spawnWorker(.executor, "Task 2");

    const result = pool.spawnWorker(.file_ops, "Task 3");
    try testing.expectError(error.PoolFull, result);
    try testing.expectEqual(@as(u32, 2), pool.active_count);
}

test "WorkerPool - spawnWorkerWithModel" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const worker = try pool.spawnWorkerWithModel(.researcher, "Deep analysis", "claude-opus-4");
    defer {
        std.fs.cwd().deleteFile(worker.output_path) catch {};
    }

    try testing.expect(worker.model_preference != null);
    try testing.expectEqualStrings("claude-opus-4", worker.model_preference.?);
}

test "WorkerPool - checkStatus returns worker status" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const worker = try pool.spawnWorker(.researcher, "Some task");
    defer {
        std.fs.cwd().deleteFile(worker.output_path) catch {};
    }

    try testing.expectEqual(WorkerStatus.pending, pool.checkStatus("worker-1"));
    try testing.expectEqual(WorkerStatus.failed, pool.checkStatus("nonexistent"));
}

test "WorkerPool - getResult reads completed worker output" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const worker = try pool.spawnWorker(.executor, "Execute something");
    defer {
        std.fs.cwd().deleteFile(worker.output_path) catch {};
        if (worker.result_path) |p| std.fs.cwd().deleteFile(p) catch {};
    }

    // Worker not completed yet
    const result_before = try pool.getResult("worker-1");
    try testing.expect(result_before == null);

    // Mark as completed with result
    try worker.writeResult("Execution output: success");

    const result = try pool.getResult("worker-1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("Execution output: success", result.?);
    allocator.free(result.?);
}

test "WorkerPool - cleanup removes completed workers" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);

    const worker1 = try pool.spawnWorker(.researcher, "Task A");
    const worker2 = try pool.spawnWorker(.executor, "Task B");

    // Complete one worker
    try worker1.writeResult("Done A");

    // Track paths before cleanup
    const path1 = try allocator.dupe(u8, worker1.output_path);
    const result1 = try allocator.dupe(u8, worker1.result_path.?);
    const path2 = try allocator.dupe(u8, worker2.output_path);

    pool.cleanup();

    // worker1 should be removed (completed), worker2 should remain (pending)
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(pool.workers.items.len)));
    try testing.expect(pool.findWorker("worker-2") != null);
    try testing.expect(pool.findWorker("worker-1") == null);

    // Cleanup temp files
    std.fs.cwd().deleteFile(path1) catch {};
    std.fs.cwd().deleteFile(result1) catch {};
    allocator.free(path1);
    allocator.free(result1);

    // Clean remaining worker
    std.fs.cwd().deleteFile(path2) catch {};
    allocator.free(path2);

    pool.deinit();
}

test "WorkerPool - cleanup removes failed workers" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);

    const worker = try pool.spawnWorker(.researcher, "Will fail");
    worker.status = .failed;

    const path = try allocator.dupe(u8, worker.output_path);

    pool.cleanup();
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(pool.workers.items.len)));

    std.fs.cwd().deleteFile(path) catch {};
    allocator.free(path);

    pool.deinit();
}

test "WorkerPool - countByStatus" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const w1 = try pool.spawnWorker(.researcher, "Task 1");
    const w2 = try pool.spawnWorker(.executor, "Task 2");
    _ = try pool.spawnWorker(.file_ops, "Task 3");

    w1.status = .completed;
    w2.status = .running;
    // worker-3 stays pending

    try testing.expectEqual(@as(u32, 1), pool.countByStatus(.completed));
    try testing.expectEqual(@as(u32, 1), pool.countByStatus(.running));
    try testing.expectEqual(@as(u32, 1), pool.countByStatus(.pending));

    // Cleanup temp files
    for (pool.workers.items) |w| {
        std.fs.cwd().deleteFile(w.output_path) catch {};
    }
}

test "WorkerPool - sequential IDs" {
    const allocator = std.testing.allocator;
    var pool = WorkerPool.init(allocator);
    defer pool.deinit();

    const w1 = try pool.spawnWorker(.researcher, "Task 1");
    const w2 = try pool.spawnWorker(.researcher, "Task 2");
    const w3 = try pool.spawnWorker(.researcher, "Task 3");

    try testing.expectEqualStrings("worker-1", w1.id);
    try testing.expectEqualStrings("worker-2", w2.id);
    try testing.expectEqualStrings("worker-3", w3.id);

    // Cleanup temp files
    for (pool.workers.items) |w| {
        std.fs.cwd().deleteFile(w.output_path) catch {};
    }
}
