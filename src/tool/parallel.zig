const std = @import("std");

/// Represents a single tool invocation request.
/// All fields are references — NOT owned by this struct.
pub const ToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    args: []const u8,
};

/// Result of executing a single tool call.
/// Owns `call_id` and `output` — call `deinit()` to free.
pub const ToolResult = struct {
    call_id: []const u8,
    success: bool,
    output: []const u8,
    duration_ms: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolResult) void {
        if (self.call_id.len > 0) {
            self.allocator.free(self.call_id);
        }
        if (self.output.len > 0) {
            self.allocator.free(self.output);
        }
    }
};

/// Function pointer signature for executing a single tool.
/// Implementations must return an owned slice allocated with the given allocator.
pub const ToolExecutorFn = *const fn (
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) anyerror![]const u8;

/// Configuration for parallel execution behavior.
pub const ParallelConfig = struct {
    max_concurrency: u32 = 4,
    timeout_ms: u64 = 30000,
};

/// Executes batches of tool calls in parallel with concurrency limiting.
/// Uses a chunked approach: splits calls into groups of `max_concurrency`,
/// spawns one thread per call within a chunk, waits for all threads to
/// complete, then moves to the next chunk.
pub const ParallelExecutor = struct {
    allocator: std.mem.Allocator,
    config: ParallelConfig,
    executor_fn: ToolExecutorFn,

    /// Initialize a ParallelExecutor.
    /// `executor_fn` is the function that will be called for each tool invocation.
    pub fn init(
        allocator: std.mem.Allocator,
        executor_fn: ToolExecutorFn,
        config: ParallelConfig,
    ) ParallelExecutor {
        return ParallelExecutor{
            .allocator = allocator,
            .config = config,
            .executor_fn = executor_fn,
        };
    }

    /// Execute a batch of tool calls in parallel (up to max_concurrency at a time).
    /// Returns results ordered by the input calls order (not completion order).
    /// Caller owns the returned slice and must call `deinit()` on each ToolResult.
    pub fn executeBatch(self: *ParallelExecutor, calls: []const ToolCall) ![]ToolResult {
        if (calls.len == 0) {
            return try self.allocator.alloc(ToolResult, 0);
        }

        // Single call — no threading overhead
        if (calls.len == 1) {
            const result = try self.executeSingle(calls[0]);
            const results = try self.allocator.alloc(ToolResult, 1);
            results[0] = result;
            return results;
        }

        const results = try self.allocator.alloc(ToolResult, calls.len);

        // Initialize all results to safe defaults
        for (results) |*r| {
            r.* = ToolResult{
                .call_id = "",
                .success = false,
                .output = "",
                .duration_ms = 0,
                .allocator = self.allocator,
            };
        }

        const concurrency = @min(
            self.config.max_concurrency,
            @as(u32, @intCast(calls.len)),
        );

        // Process in chunks of `concurrency` size
        var chunk_start: usize = 0;
        while (chunk_start < calls.len) {
            const chunk_end = @min(chunk_start + concurrency, calls.len);
            const chunk_len = chunk_end - chunk_start;

            const threads = try self.allocator.alloc(std.Thread, chunk_len);
            defer self.allocator.free(threads);

            var contexts = try self.allocator.alloc(WorkerContext, chunk_len);
            defer self.allocator.free(contexts);

            // Spawn one thread per call in this chunk
            for (0..chunk_len) |i| {
                const call_idx = chunk_start + i;
                contexts[i] = WorkerContext{
                    .executor_fn = self.executor_fn,
                    .allocator = self.allocator,
                    .call = calls[call_idx],
                    .result_idx = call_idx,
                    .results = results,
                };
                threads[i] = try std.Thread.spawn(.{}, runWorker, .{&contexts[i]});
            }

            // Wait for all threads in this chunk to complete
            for (0..chunk_len) |i| {
                threads[i].join();
            }

            chunk_start = chunk_end;
        }

        return results;
    }

    /// No-op cleanup. The ParallelExecutor holds no heap resources of its own.
    pub fn deinit(self: *ParallelExecutor) void {
        _ = self;
    }

    /// Execute a single tool call synchronously (no thread overhead).
    fn executeSingle(self: *ParallelExecutor, call: ToolCall) !ToolResult {
        const start_ns = std.time.nanoTimestamp();
        const call_id_duped = try self.allocator.dupe(u8, call.call_id);

        const result = self.executor_fn(self.allocator, call.tool_name, call.args) catch {
            const elapsed_ns = std.time.nanoTimestamp() - start_ns;
            const elapsed_ms = elapsedMs(elapsed_ns);
            return ToolResult{
                .call_id = call_id_duped,
                .success = false,
                .output = "",
                .duration_ms = elapsed_ms,
                .allocator = self.allocator,
            };
        };

        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        const elapsed_ms = elapsedMs(elapsed_ns);
        return ToolResult{
            .call_id = call_id_duped,
            .success = true,
            .output = result,
            .duration_ms = elapsed_ms,
            .allocator = self.allocator,
        };
    }
};

/// Context passed to each worker thread.
const WorkerContext = struct {
    executor_fn: ToolExecutorFn,
    allocator: std.mem.Allocator,
    call: ToolCall,
    result_idx: usize,
    results: []ToolResult,
};

/// Thread entry point: executes a single tool call and writes the result
/// into the shared results array at the pre-assigned index.
fn runWorker(ctx: *WorkerContext) void {
    const start_ns = std.time.nanoTimestamp();
    const call_id_duped = ctx.allocator.dupe(u8, ctx.call.call_id) catch "";

    const exec_result = ctx.executor_fn(
        ctx.allocator,
        ctx.call.tool_name,
        ctx.call.args,
    ) catch {
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        ctx.results[ctx.result_idx] = ToolResult{
            .call_id = call_id_duped,
            .success = false,
            .output = "",
            .duration_ms = elapsedMs(elapsed_ns),
            .allocator = ctx.allocator,
        };
        return;
    };

    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    ctx.results[ctx.result_idx] = ToolResult{
        .call_id = call_id_duped,
        .success = true,
        .output = exec_result,
        .duration_ms = elapsedMs(elapsed_ns),
        .allocator = ctx.allocator,
    };
}

/// Convert an i128 nanosecond delta to milliseconds (u64).
/// Clamps negative values to 0.
fn elapsedMs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, 1_000_000));
}

// ---------------------------------------------------------------------------
// Mock executors for testing
// ---------------------------------------------------------------------------

fn mockExecutorSuccess(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) anyerror![]const u8 {
    _ = tool_name;
    _ = args;
    return try allocator.dupe(u8, "mock result");
}

fn mockExecutorSlow(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) anyerror![]const u8 {
    _ = tool_name;
    _ = args;
    std.Thread.sleep(50_000_000); // 50ms
    return try allocator.dupe(u8, "slow result");
}

fn mockExecutorFail(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) anyerror![]const u8 {
    _ = allocator;
    _ = tool_name;
    _ = args;
    return error.ToolExecutionFailed;
}

/// Module-level atomic counter for the alternating mock executor.
var alt_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

fn mockExecutorAlternating(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) anyerror![]const u8 {
    _ = tool_name;
    _ = args;
    const idx = alt_counter.fetchAdd(1, .monotonic);
    if (idx % 2 == 1) return error.ToolExecutionFailed;
    return try allocator.dupe(u8, "ok");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty batch returns empty slice" {
    const allocator = std.testing.allocator;
    var executor = ParallelExecutor.init(allocator, mockExecutorSuccess, .{});
    defer executor.deinit();

    const calls: []const ToolCall = &[_]ToolCall{};
    const results = try executor.executeBatch(calls);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "single call executes without threading" {
    const allocator = std.testing.allocator;
    var executor = ParallelExecutor.init(allocator, mockExecutorSuccess, .{});
    defer executor.deinit();

    const calls = [_]ToolCall{
        .{ .call_id = "call-1", .tool_name = "read_file", .args = "{}" },
    };
    const results = try executor.executeBatch(&calls);
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].success);
    try std.testing.expectEqualStrings("call-1", results[0].call_id);
    try std.testing.expectEqualStrings("mock result", results[0].output);
    try std.testing.expect(results[0].duration_ms < 1000);
}

test "batch of 3 with concurrency 2 runs in chunks and preserves order" {
    const allocator = std.testing.allocator;
    var executor = ParallelExecutor.init(allocator, mockExecutorSlow, .{
        .max_concurrency = 2,
    });
    defer executor.deinit();

    const calls = [_]ToolCall{
        .{ .call_id = "call-1", .tool_name = "tool_a", .args = "{}" },
        .{ .call_id = "call-2", .tool_name = "tool_b", .args = "{}" },
        .{ .call_id = "call-3", .tool_name = "tool_c", .args = "{}" },
    };

    const results = try executor.executeBatch(&calls);
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    // All 3 results present, in input order
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("call-1", results[0].call_id);
    try std.testing.expectEqualStrings("call-2", results[1].call_id);
    try std.testing.expectEqualStrings("call-3", results[2].call_id);

    for (results) |r| {
        try std.testing.expect(r.success);
        try std.testing.expectEqualStrings("slow result", r.output);
    }
}

test "mixed success and failure preserves order" {
    const allocator = std.testing.allocator;

    // Reset the atomic counter for test isolation
    alt_counter.store(0, .monotonic);

    var executor = ParallelExecutor.init(allocator, mockExecutorAlternating, .{
        .max_concurrency = 4,
    });
    defer executor.deinit();

    const calls = [_]ToolCall{
        .{ .call_id = "c-1", .tool_name = "t", .args = "" },
        .{ .call_id = "c-2", .tool_name = "t", .args = "" },
        .{ .call_id = "c-3", .tool_name = "t", .args = "" },
        .{ .call_id = "c-4", .tool_name = "t", .args = "" },
    };

    const results = try executor.executeBatch(&calls);
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 4), results.len);

    // Check order preserved by call_id
    try std.testing.expectEqualStrings("c-1", results[0].call_id);
    try std.testing.expectEqualStrings("c-2", results[1].call_id);
    try std.testing.expectEqualStrings("c-3", results[2].call_id);
    try std.testing.expectEqualStrings("c-4", results[3].call_id);

    // Verify mixed results: some succeed, some fail
    var success_count: usize = 0;
    var fail_count: usize = 0;
    for (results) |r| {
        if (r.success) {
            success_count += 1;
        } else {
            fail_count += 1;
        }
    }
    try std.testing.expect(success_count > 0);
    try std.testing.expect(fail_count > 0);
}

test "all fail batch returns correct results" {
    const allocator = std.testing.allocator;
    var executor = ParallelExecutor.init(allocator, mockExecutorFail, .{
        .max_concurrency = 2,
    });
    defer executor.deinit();

    const calls = [_]ToolCall{
        .{ .call_id = "fail-1", .tool_name = "bad_tool", .args = "" },
        .{ .call_id = "fail-2", .tool_name = "bad_tool", .args = "" },
        .{ .call_id = "fail-3", .tool_name = "bad_tool", .args = "" },
    };

    const results = try executor.executeBatch(&calls);
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 3), results.len);
    for (results, 0..) |r, i| {
        try std.testing.expect(!r.success);
        try std.testing.expectEqualStrings("", r.output);
        try std.testing.expectEqualStrings(
            @as([]const u8, &[_]u8{ 'f', 'a', 'i', 'l', '-', '1' + @as(u8, @intCast(i)) }),
            r.call_id,
        );
    }
}

test "concurrency limit of 1 runs sequentially" {
    const allocator = std.testing.allocator;
    var executor = ParallelExecutor.init(allocator, mockExecutorSuccess, .{
        .max_concurrency = 1,
    });
    defer executor.deinit();

    const calls = [_]ToolCall{
        .{ .call_id = "seq-1", .tool_name = "t", .args = "" },
        .{ .call_id = "seq-2", .tool_name = "t", .args = "" },
    };

    const results = try executor.executeBatch(&calls);
    defer {
        for (results) |*r| r.deinit();
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].success);
    try std.testing.expect(results[1].success);
    try std.testing.expectEqualStrings("seq-1", results[0].call_id);
    try std.testing.expectEqualStrings("seq-2", results[1].call_id);
}
