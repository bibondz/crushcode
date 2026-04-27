const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const shell = @import("shell");

const Allocator = std.mem.Allocator;
const posix = std.posix;

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Maximum number of concurrent background jobs
pub const MAX_CONCURRENT_JOBS: usize = 50;

/// Age threshold for automatic cleanup (8 hours in seconds)
pub const CLEANUP_AGE_SECONDS: i64 = 8 * 60 * 60;

/// Job control - background job tracking
pub const Job = struct {
    id: u32,
    command: []const u8,
    pid: u32,
    status: JobStatus,
    created_at: i64,
    stdout_path: ?[]const u8,
    stderr_path: ?[]const u8,
    exit_code: ?u8,
};

pub const JobStatus = enum {
    running,
    completed,
    stopped,
    terminated,
};

/// Background job manager with process tracking and output capture
pub const JobManager = struct {
    jobs: array_list_compat.ArrayList(Job),
    next_id: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) JobManager {
        return .{
            .jobs = array_list_compat.ArrayList(Job).init(allocator),
            .next_id = 1,
            .allocator = allocator,
        };
    }

    /// Free all tracked jobs and their allocated resources
    pub fn deinit(self: *JobManager) void {
        for (self.jobs.items) |job| {
            self.allocator.free(job.command);
            if (job.stdout_path) |p| self.allocator.free(p);
            if (job.stderr_path) |p| self.allocator.free(p);
        }
        self.jobs.deinit();
    }

    /// Count currently running jobs
    fn runningCount(self: *const JobManager) usize {
        var count: usize = 0;
        for (self.jobs.items) |job| {
            if (job.status == .running) count += 1;
        }
        return count;
    }

    /// Spawn a command as a background process with stdout/stderr capture.
    /// Pipes output to temp files in /tmp/crushcode-job-{id}.out and .err.
    /// Returns the assigned job ID.
    pub fn spawnBackground(self: *JobManager, command: []const u8, cwd: ?[]const u8) !u32 {
        // Enforce concurrent job limit
        if (self.runningCount() >= MAX_CONCURRENT_JOBS) {
            return error.TooManyJobs;
        }

        const id = self.next_id;
        self.next_id += 1;

        // Build temp file paths
        const stdout_path = try std.fmt.allocPrint(self.allocator, "/tmp/crushcode-job-{d}.out", .{id});
        errdefer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, "/tmp/crushcode-job-{d}.err", .{id});
        errdefer self.allocator.free(stderr_path);

        // Build shell command with output redirection
        const full_cmd = if (cwd) |cwd_path|
            try std.fmt.allocPrint(self.allocator, "cd '{s}' 2>/dev/null; {s} > {s} 2> {s}", .{ cwd_path, command, stdout_path, stderr_path })
        else
            try std.fmt.allocPrint(self.allocator, "{s} > {s} 2> {s}", .{ command, stdout_path, stderr_path });
        defer self.allocator.free(full_cmd);

        const argv = [_][]const u8{ "sh", "-c", full_cmd };
        var child = std.process.Child.init(&argv, self.allocator);

        // Spawn as background process
        _ = try child.spawn();

        const pid: u32 = @intCast(child.id);
        const cmd_copy = try self.allocator.dupe(u8, command);

        try self.jobs.append(Job{
            .id = id,
            .command = cmd_copy,
            .pid = pid,
            .status = .running,
            .created_at = std.time.timestamp(),
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .exit_code = null,
        });

        return id;
    }

    /// Non-blocking check of a job's status via waitpid with WNOHANG.
    /// Updates internal state if the process has exited.
    /// On Windows, returns running status (background job monitoring not supported).
    pub fn checkStatus(self: *JobManager, id: u32) !JobStatus {
        const job = self.get(id) orelse return error.JobNotFound;

        if (job.status != .running) return job.status;

        if (@import("builtin").os.tag == .windows) {
            // Windows: no POSIX waitpid; assume still running
            return .running;
        }

        const result = posix.waitpid(@intCast(job.pid), posix.W.NOHANG);

        if (result.pid == 0) {
            // Still running
            return .running;
        }

        // Process has exited — determine how
        if (posix.W.IFEXITED(result.status)) {
            job.exit_code = posix.W.EXITSTATUS(result.status);
            job.status = .completed;
        } else if (posix.W.IFSIGNALED(result.status)) {
            job.exit_code = 1;
            job.status = .terminated;
        } else {
            job.status = .stopped;
        }

        return job.status;
    }

    /// Read captured stdout/stderr for a completed job.
    /// Returns null if the job is still running.
    /// Caller must free both returned strings with the provided allocator.
    pub fn getOutput(self: *JobManager, allocator: Allocator, id: u32) !?struct { stdout: []const u8, stderr: []const u8 } {
        const job = self.get(id) orelse return error.JobNotFound;

        if (job.status == .running) return null;

        const stdout_content = try readTempFileAlloc(allocator, job.stdout_path);
        errdefer allocator.free(stdout_content);
        const stderr_content = try readTempFileAlloc(allocator, job.stderr_path);

        return .{
            .stdout = stdout_content,
            .stderr = stderr_content,
        };
    }

    /// Send SIGTERM to a running job (POSIX only; no-op on Windows).
    pub fn killJob(self: *JobManager, id: u32) !void {
        const job = self.get(id) orelse return error.JobNotFound;

        if (job.status != .running) return;

        if (@import("builtin").os.tag == .windows) {
            // Windows: no POSIX signals; mark terminated directly
            job.status = .terminated;
            job.exit_code = 137;
            return;
        }

        posix.kill(@intCast(job.pid), posix.SIG.TERM) catch |err| {
            return err;
        };

        job.status = .terminated;
        job.exit_code = 137; // 128 + SIGTERM(9)
    }

    /// Remove completed/terminated/stopped jobs older than CLEANUP_AGE_SECONDS.
    /// Deletes associated temp files and frees resources.
    pub fn cleanupOld(self: *JobManager) void {
        const now = std.time.timestamp();
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            const age = now - job.created_at;
            if (age >= CLEANUP_AGE_SECONDS and job.status != .running) {
                if (job.stdout_path) |path| {
                    std.fs.deleteFileAbsolute(path) catch {};
                    self.allocator.free(path);
                }
                if (job.stderr_path) |path| {
                    std.fs.deleteFileAbsolute(path) catch {};
                    self.allocator.free(path);
                }
                self.allocator.free(job.command);
                _ = self.jobs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Add a new job (backward-compatible entry point)
    pub fn add(self: *JobManager, command: []const u8, pid: u32) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        const cmd_copy = try self.allocator.dupe(u8, command);

        try self.jobs.append(Job{
            .id = id,
            .command = cmd_copy,
            .pid = pid,
            .status = .running,
            .created_at = std.time.timestamp(),
            .stdout_path = null,
            .stderr_path = null,
            .exit_code = null,
        });

        return id;
    }

    /// List all tracked jobs
    pub fn list(self: *JobManager) []const Job {
        return self.jobs.items;
    }

    /// Get a mutable reference to a job by ID
    pub fn get(self: *JobManager, id: u32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    /// Remove all completed/terminated jobs and free their resources
    pub fn cleanup(self: *JobManager) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].status == .completed or
                self.jobs.items[i].status == .terminated)
            {
                const job = self.jobs.items[i];
                if (job.stdout_path) |path| {
                    std.fs.deleteFileAbsolute(path) catch {};
                    self.allocator.free(path);
                }
                if (job.stderr_path) |path| {
                    std.fs.deleteFileAbsolute(path) catch {};
                    self.allocator.free(path);
                }
                self.allocator.free(job.command);
                _ = self.jobs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// Read a temp file into an allocated string.
/// Always returns an allocated string (empty on failure).
fn readTempFileAlloc(allocator: Allocator, path: ?[]const u8) ![]const u8 {
    const p = path orelse return try allocator.dupe(u8, "");
    return std.fs.cwd().readFileAlloc(allocator, p, 1024 * 1024) catch
        try allocator.dupe(u8, "");
}

// Global job manager instance (lazily initialized)
var global_manager: ?JobManager = null;

fn getManager() *JobManager {
    if (global_manager == null) {
        global_manager = JobManager.init(std.heap.page_allocator);
    }
    return &global_manager.?;
}

/// Run command in background using the global job manager.
/// Returns the assigned job ID.
pub fn runBackground(command: []const u8, allocator: Allocator) !u32 {
    _ = allocator;
    const mgr = getManager();
    return mgr.spawnBackground(command, null);
}

/// Handle jobs command from CLI.
/// Subcommands: list (default), output <id>, kill <id>, cleanup
pub fn handleJobs(args: [][]const u8) !void {
    const mgr = getManager();

    // No args or "list": show all jobs with current status
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const jobs = mgr.list();
        if (jobs.len == 0) {
            out("No background jobs.\n", .{});
            return;
        }
        out("ID     STATUS        PID      EXIT                 COMMAND\n", .{});
        for (jobs) |job_ref| {
            // Refresh status for running jobs
            const job = mgr.get(job_ref.id) orelse continue;
            if (job.status == .running) {
                _ = mgr.checkStatus(job.id) catch {};
            }
            const status_str = switch (job.status) {
                .running => "running",
                .completed => "completed",
                .stopped => "stopped",
                .terminated => "terminated",
            };
            if (job.exit_code) |code| {
                out("{d:<6} {s:<14}{d:<9}{d:<21}{s}\n", .{ job.id, status_str, job.pid, code, job.command });
            } else {
                out("{d:<6} {s:<14}{d:<9}{s:<21}{s}\n", .{ job.id, status_str, job.pid, "-", job.command });
            }
        }
        return;
    }

    // "output <id>": show captured stdout/stderr for a job
    if (std.mem.eql(u8, args[0], "output")) {
        if (args.len < 2) {
            out("Usage: jobs output <id>\n", .{});
            return;
        }
        const id = std.fmt.parseInt(u32, args[1], 10) catch {
            out("Invalid job ID: {s}\n", .{args[1]});
            return;
        };
        const result = mgr.getOutput(std.heap.page_allocator, id) catch |err| {
            out("Error: {s}\n", .{@errorName(err)});
            return;
        };
        if (result) |output| {
            out("=== stdout ===\n{s}\n", .{output.stdout});
            out("=== stderr ===\n{s}\n", .{output.stderr});
            std.heap.page_allocator.free(output.stdout);
            std.heap.page_allocator.free(output.stderr);
        } else {
            out("Job {d} is still running.\n", .{id});
        }
        return;
    }

    // "kill <id>": terminate a running job
    if (std.mem.eql(u8, args[0], "kill")) {
        if (args.len < 2) {
            out("Usage: jobs kill <id>\n", .{});
            return;
        }
        const id = std.fmt.parseInt(u32, args[1], 10) catch {
            out("Invalid job ID: {s}\n", .{args[1]});
            return;
        };
        mgr.killJob(id) catch |err| {
            out("Error: {s}\n", .{@errorName(err)});
            return;
        };
        out("Job {d} terminated.\n", .{id});
        return;
    }

    // "cleanup": remove old completed/terminated jobs
    if (std.mem.eql(u8, args[0], "cleanup")) {
        mgr.cleanupOld();
        out("Old jobs cleaned up.\n", .{});
        return;
    }

    out("Unknown subcommand: {s}\n", .{args[0]});
    out("Usage: jobs [list|output <id>|kill <id>|cleanup]\n", .{});
}
