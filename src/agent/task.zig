const std = @import("std");

const Allocator = std.mem.Allocator;

/// Shared execution state for tasks across all subsystems
/// Used by: agent/parallel.zig, workflow/phase.zig, commands/jobs.zig
pub const RunState = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
    skipped,
    verified,
};

/// Generic task result
pub const TaskResult = struct {
    id: []const u8,
    state: RunState,
    output: []const u8,
    duration_ms: u64,
    allocator: Allocator,

    pub fn deinit(self: *TaskResult) void {
        self.allocator.free(self.id);
        self.allocator.free(self.output);
    }
};

/// Execution context — where a task runs
pub const ExecutionContext = union(enum) {
    /// Run in current process
    inline_exec,
    /// Run as background process
    background: BackgroundContext,
    /// Run in isolated git worktree
    worktree: WorktreeContext,
};

pub const BackgroundContext = struct {
    pid: u32,
    command: []const u8,
};

pub const WorktreeContext = struct {
    path: []const u8,
    branch: []const u8,
    task_id: []const u8,
};
