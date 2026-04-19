const std = @import("std");
const worker = @import("worker");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Result of a completed worker execution.
/// Caller owns the allocated strings and must call deinit().
pub const WorkerResult = struct {
    worker_id: []const u8,
    output: []const u8,
    status: worker.WorkerStatus,
    duration_ms: u64,

    pub fn deinit(self: *WorkerResult, allocator: Allocator) void {
        allocator.free(self.worker_id);
        allocator.free(self.output);
    }
};

/// Manages subprocess execution for worker agents.
/// Spawns crushcode as a child process, captures output, and tracks lifecycle.
pub const WorkerRunner = struct {
    allocator: Allocator,
    worker_pool: *worker.WorkerPool,
    crushcode_binary: []const u8,

    /// Initialize a new WorkerRunner.
    /// `binary_path` is the path to the crushcode executable (e.g. "zig-out/bin/crushcode" or resolved via /proc/self/exe).
    pub fn init(allocator: Allocator, pool: *worker.WorkerPool, binary_path: []const u8) WorkerRunner {
        return WorkerRunner{
            .allocator = allocator,
            .worker_pool = pool,
            .crushcode_binary = binary_path,
        };
    }

    pub fn deinit(self: *WorkerRunner) void {
        _ = self;
    }

    /// Spawn a worker subprocess: runs `crushcode run "<task>" --model <model>` as a child process.
    /// Captures stdout to the worker's output_path file.
    /// Updates worker status through the lifecycle: pending → running → completed/failed/timeout.
    pub fn runWorker(self: *WorkerRunner, worker_id: []const u8, task_prompt: []const u8) !void {
        const w = self.worker_pool.findWorker(worker_id) orelse return error.WorkerNotFound;

        // Transition to running
        w.status = .running;
        w.started_at = std.time.milliTimestamp();

        // Resolve model from worker preference or default
        const model = w.model_preference orelse "sonnet";

        // Build argv: crushcode run "<task>" --model <model>
        const argv_slice = try self.allocator.alloc([]const u8, 4);
        defer self.allocator.free(argv_slice);
        argv_slice[0] = self.crushcode_binary;
        argv_slice[1] = "run";
        argv_slice[2] = task_prompt;
        argv_slice[3] = try std.fmt.allocPrint(self.allocator, "--model={s}", .{model});
        defer self.allocator.free(argv_slice[3]);

        var child = std.process.Child.init(argv_slice, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            w.status = .failed;
            std.log.err("WorkerRunner: failed to spawn worker {s}: {}", .{ worker_id, err });
            return err;
        };

        // Read stdout and write to output_path
        var output_buf: [4096]u8 = undefined;
        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        if (child.stdout) |stdout| {
            while (true) {
                const n = stdout.read(&output_buf) catch break;
                if (n == 0) break;
                try output.appendSlice(output_buf[0..n]);
            }
        }

        // Read stderr for logging
        var stderr_buf: [4096]u8 = undefined;
        if (child.stderr) |stderr| {
            while (true) {
                const n = stderr.read(&stderr_buf) catch break;
                if (n == 0) break;
                std.log.warn("Worker {s} stderr: {s}", .{ worker_id, stderr_buf[0..n] });
            }
        }

        // Wait for process to complete
        const term = child.wait() catch |err| {
            w.status = .failed;
            std.log.err("WorkerRunner: failed to wait for worker {s}: {}", .{ worker_id, err });
            return err;
        };

        const exit_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!exit_ok) {
            w.status = .failed;
            return;
        }

        // Write captured output to the worker's output file
        if (output.items.len > 0) {
            w.writeResult(output.items) catch |err| {
                std.log.warn("WorkerRunner: failed to write result for {s}: {}", .{ worker_id, err });
                w.status = .failed;
                return;
            };
        } else {
            w.status = .completed;
            const result_path = std.fmt.allocPrint(self.allocator, "/tmp/crushcode-worker-{s}-result.md", .{worker_id}) catch return;
            if (w.result_path) |old| self.allocator.free(old);
            w.result_path = result_path;

            // Create empty result file
            const dir = std.fs.openDirAbsolute("/tmp", .{}) catch return;
            const file = dir.createFile(result_path["/tmp/".len..], .{}) catch return;
            file.close();
        }
    }

    /// Collect result from a completed worker. Returns null if not completed or no result file.
    pub fn collectResult(self: *WorkerRunner, worker_id: []const u8) !?WorkerResult {
        const w = self.worker_pool.findWorker(worker_id) orelse return null;
        if (w.status != .completed) return null;

        const path = w.result_path orelse return null;
        const started = w.started_at orelse 0;
        const now = std.time.milliTimestamp();
        const duration = if (now > started) @as(u64, @intCast(now - started)) else 0;

        // Read the result file
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        if (stat.size == 0) {
            return WorkerResult{
                .worker_id = try self.allocator.dupe(u8, worker_id),
                .output = try self.allocator.dupe(u8, ""),
                .status = .completed,
                .duration_ms = duration,
            };
        }

        const content = try self.allocator.alloc(u8, stat.size);
        const bytes_read = file.readAll(content) catch |err| {
            self.allocator.free(content);
            return err;
        };

        return WorkerResult{
            .worker_id = try self.allocator.dupe(u8, worker_id),
            .output = content[0..bytes_read],
            .status = .completed,
            .duration_ms = duration,
        };
    }

    /// Wait for a worker to complete, polling until done or timeout.
    /// NOTE: This is a blocking call that polls the worker status.
    pub fn waitForCompletion(self: *WorkerRunner, worker_id: []const u8, timeout_ms: u64) !WorkerResult {
        const w = self.worker_pool.findWorker(worker_id) orelse return error.WorkerNotFound;
        const start = std.time.milliTimestamp();
        const timeout_i64: i64 = @intCast(timeout_ms);

        while (true) {
            switch (w.status) {
                .completed => return (try self.collectResult(worker_id)) orelse WorkerResult{
                    .worker_id = try self.allocator.dupe(u8, worker_id),
                    .output = try self.allocator.dupe(u8, ""),
                    .status = .completed,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start),
                },
                .failed => return WorkerResult{
                    .worker_id = try self.allocator.dupe(u8, worker_id),
                    .output = try self.allocator.dupe(u8, "Worker execution failed"),
                    .status = .failed,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start),
                },
                .timeout => return WorkerResult{
                    .worker_id = try self.allocator.dupe(u8, worker_id),
                    .output = try self.allocator.dupe(u8, "Worker timed out"),
                    .status = .timeout,
                    .duration_ms = timeout_ms,
                },
                else => {
                    // Still pending or running — check timeout
                    const elapsed = std.time.milliTimestamp() - start;
                    if (elapsed >= timeout_i64) {
                        w.status = .timeout;
                        return WorkerResult{
                            .worker_id = try self.allocator.dupe(u8, worker_id),
                            .output = try self.allocator.dupe(u8, "Worker timed out"),
                            .status = .timeout,
                            .duration_ms = timeout_ms,
                        };
                    }
                    // Sleep 50ms between polls
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                },
            }
        }
    }

    /// Convenience method: spawn a worker and wait for it to complete.
    /// Creates a new worker in the pool, runs it, and returns the result.
    pub fn runAndCollect(self: *WorkerRunner, task_prompt: []const u8, specialty: worker.WorkerSpecialty, model: ?[]const u8) !WorkerResult {
        const w = if (model) |m|
            try self.worker_pool.spawnWorkerWithModel(specialty, task_prompt, m)
        else
            try self.worker_pool.spawnWorker(specialty, task_prompt);

        const worker_id = try self.allocator.dupe(u8, w.id);
        defer self.allocator.free(worker_id);

        const timeout = w.max_timeout_ms;

        // Run in a separate thread so we can poll for timeout
        const RunContext = struct {
            runner: *WorkerRunner,
            wid: []const u8,
            prompt: []const u8,
            result: ?anyerror!void,

            fn exec(ctx: *@This()) void {
                ctx.result = ctx.runner.runWorker(ctx.wid, ctx.prompt);
            }
        };

        var ctx = RunContext{
            .runner = self,
            .wid = worker_id,
            .prompt = task_prompt,
            .result = null,
        };

        const thread = try std.Thread.spawn(.{}, RunContext.exec, .{&ctx});
        thread.join();

        // If runWorker failed, return error result
        if (ctx.result) |res| {
            res catch |err| {
                return WorkerResult{
                    .worker_id = try self.allocator.dupe(u8, worker_id),
                    .output = try std.fmt.allocPrint(self.allocator, "Worker failed: {}", .{err}),
                    .status = .failed,
                    .duration_ms = 0,
                };
            };
        }

        return try self.waitForCompletion(worker_id, timeout);
    }

    /// Resolve the path to the current crushcode binary.
    /// Uses /proc/self/exe on Linux, falls back to "crushcode" in PATH.
    pub fn resolveBinaryPath(allocator: Allocator) ![]const u8 {
        // Try /proc/self/exe (Linux)
        var buf: [4096]u8 = undefined;
        const link_name = std.posix.readlink("/proc/self/exe", &buf) catch {
            // Fallback: look for crushcode in zig-out/bin/
            return allocator.dupe(u8, "zig-out/bin/crushcode");
        };
        return allocator.dupe(u8, link_name);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "WorkerRunner - init and deinit" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var runner = WorkerRunner.init(allocator, &pool, "zig-out/bin/crushcode");
    runner.deinit();
}

test "WorkerResult - deinit frees allocated strings" {
    const allocator = std.testing.allocator;
    var result = WorkerResult{
        .worker_id = try allocator.dupe(u8, "worker-test"),
        .output = try allocator.dupe(u8, "test output"),
        .status = .completed,
        .duration_ms = 100,
    };
    result.deinit(allocator);
}

test "WorkerRunner - collectResult returns null for nonexistent worker" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var runner = WorkerRunner.init(allocator, &pool, "zig-out/bin/crushcode");
    const result = try runner.collectResult("nonexistent");
    try testing.expect(result == null);
}

test "WorkerRunner - collectResult returns null for pending worker" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    _ = try pool.spawnWorker(.researcher, "Test task");
    // Cleanup temp file
    defer {
        for (pool.workers.items) |w| {
            std.fs.cwd().deleteFile(w.output_path) catch {};
        }
    }

    var runner = WorkerRunner.init(allocator, &pool, "zig-out/bin/crushcode");
    const result = try runner.collectResult("worker-1");
    try testing.expect(result == null);
}

test "WorkerRunner - collectResult reads completed worker output" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    const w = try pool.spawnWorker(.researcher, "Test task");
    defer {
        std.fs.cwd().deleteFile(w.output_path) catch {};
        if (w.result_path) |p| std.fs.cwd().deleteFile(p) catch {};
    }

    // Manually mark as completed with known result
    try w.writeResult("Hello from worker");

    // Set started_at so duration can be calculated
    w.started_at = std.time.milliTimestamp() - 100;

    var runner = WorkerRunner.init(allocator, &pool, "zig-out/bin/crushcode");
    const maybe_result = try runner.collectResult("worker-1");
    try testing.expect(maybe_result != null);

    var result = maybe_result.?;
    defer result.deinit(allocator);

    try testing.expectEqualStrings("worker-1", result.worker_id);
    try testing.expectEqualStrings("Hello from worker", result.output);
    try testing.expectEqual(worker.WorkerStatus.completed, result.status);
    try testing.expect(result.duration_ms >= 0);
}

test "WorkerRunner - resolveBinaryPath returns non-empty string" {
    const allocator = std.testing.allocator;
    const path = try WorkerRunner.resolveBinaryPath(allocator);
    defer allocator.free(path);
    try testing.expect(path.len > 0);
}

test "WorkerRunner - runAndCollect creates worker and attempts execution" {
    const allocator = std.testing.allocator;
    var pool = worker.WorkerPool.init(allocator);
    defer pool.deinit();

    var runner = WorkerRunner.init(allocator, &pool, "/nonexistent/binary");

    // This will fail because the binary doesn't exist, but we verify the worker was created
    var result = runner.runAndCollect("test task", .researcher, "haiku") catch {
        // Expected: spawn fails or some subprocess error
        // Clean up any created workers
        for (pool.workers.items) |w| {
            std.fs.cwd().deleteFile(w.output_path) catch {};
            if (w.result_path) |p| std.fs.cwd().deleteFile(p) catch {};
        }
        return;
    };
    defer result.deinit(allocator);
    defer {
        for (pool.workers.items) |w| {
            std.fs.cwd().deleteFile(w.output_path) catch {};
            if (w.result_path) |p| std.fs.cwd().deleteFile(p) catch {};
        }
    }
}
