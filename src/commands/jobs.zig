const std = @import("std");
const array_list_compat = @import("array_list_compat");
const shell = @import("shell");

/// Job control - background jobs management
pub const Job = struct {
    id: u32,
    command: []const u8,
    pid: u32,
    status: JobStatus,
    created_at: u64,
};

pub const JobStatus = enum {
    running,
    completed,
    stopped,
    terminated,
};

/// Job list manager
pub const JobManager = struct {
    jobs: array_list_compat.ArrayList(Job),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) JobManager {
        return .{
            .jobs = array_list_compat.ArrayList(Job).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *JobManager) void {
        self.jobs.deinit();
    }

    /// Add a new job
    pub fn add(self: *JobManager, command: []const u8, pid: u32) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        try self.jobs.append(Job{
            .id = id,
            .command = command,
            .pid = pid,
            .status = .running,
            .created_at = std.time.timestamp(),
        });

        return id;
    }

    /// List all jobs
    pub fn list(self: *JobManager) []const Job {
        return self.jobs.items;
    }

    /// Get job by ID
    pub fn get(self: *JobManager, id: u32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    /// Remove completed jobs
    pub fn cleanup(self: *JobManager) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].status == .completed or
                self.jobs.items[i].status == .terminated)
            {
                _ = self.jobs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// Run command in background
pub fn runBackground(command: []const u8, allocator: std.mem.Allocator) !u32 {
    const argv = [_][]const u8{ "sh", "-c", command };
    var child = std.process.Child.init(&argv, allocator);

    // Detach the process - don't wait for it
    _ = try child.spawn();

    // Return a simple ID (the PID is not directly accessible this way)
    return 0;
}

/// Handle jobs command from CLI
pub fn handleJobs(_: [][]const u8) !void {
    // For now, just list available job control syntax
    std.debug.print(
        \\Job Control
        \\
        \\Usage: 
        \\  crushcode shell 'command &'    - Run command in background
        \\  crushcode jobs                - List background jobs (future)
        \\  crushcode fg <job-id>          - Bring job to foreground (future)
        \\  crushcode bg <job-id>          - Resume job in background (future)
        \\  crushcode kill <job-id>       - Terminate job (future)
        \\
        \\Example:
        \\  crushcode shell 'sleep 100 &' 
        \\
    , .{});
}
