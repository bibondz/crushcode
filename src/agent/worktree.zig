const std = @import("std");
const shell = @import("shell");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Git worktree isolation for per-task execution environments
///
/// Creates isolated git worktrees so tasks can operate on separate branches
/// without interfering with the main working directory.
///
/// Reference: multica execenv/git.go
pub const WorktreeManager = struct {
    allocator: Allocator,
    base_dir: []const u8,
    active_worktrees: array_list_compat.ArrayList(WorktreeInfo),

    pub const WorktreeInfo = struct {
        id: []const u8,
        path: []const u8,
        branch: []const u8,
        task_id: []const u8,
        active: bool,
    };

    pub fn init(allocator: Allocator, base_dir: []const u8) WorktreeManager {
        return WorktreeManager{
            .allocator = allocator,
            .base_dir = base_dir,
            .active_worktrees = array_list_compat.ArrayList(WorktreeInfo).init(allocator),
        };
    }

    /// Create a new isolated worktree for a task
    /// Returns the path to the worktree directory
    pub fn createWorktree(self: *WorktreeManager, task_id: []const u8, branch_suffix: []const u8) ![]const u8 {
        const branch_name = try std.fmt.allocPrint(self.allocator, "crushcode/{s}/{s}", .{ task_id, branch_suffix });
        errdefer self.allocator.free(branch_name);

        const worktree_path = try std.fmt.allocPrint(self.allocator, "{s}/worktree-{s}", .{ self.base_dir, task_id });
        errdefer self.allocator.free(worktree_path);

        var result = try shell.executeShellCommand(try std.fmt.allocPrint(self.allocator, "git worktree add {s} -b {s}", .{ worktree_path, branch_name }), null);
        if (result.exit_code != 0) {
            // Branch might already exist, try without -b
            result = try shell.executeShellCommand(try std.fmt.allocPrint(self.allocator, "git worktree add {s} {s}", .{ worktree_path, branch_name }), null);
            if (result.exit_code != 0) {
                self.allocator.free(branch_name);
                self.allocator.free(worktree_path);
                return error.WorktreeCreateFailed;
            }
        }

        // Track the worktree
        const info = WorktreeInfo{
            .id = try self.allocator.dupe(u8, task_id),
            .path = worktree_path,
            .branch = branch_name,
            .task_id = try self.allocator.dupe(u8, task_id),
            .active = true,
        };
        try self.active_worktrees.append(info);

        return worktree_path;
    }

    /// Remove a worktree after task completion
    pub fn removeWorktree(self: *WorktreeManager, task_id: []const u8) !void {
        for (self.active_worktrees.items, 0..) |info, i| {
            if (std.mem.eql(u8, info.task_id, task_id) and info.active) {
                const result = shell.executeShellCommand(try std.fmt.allocPrint(self.allocator, "git worktree remove {s}", .{info.path}), null) catch null;
                if (result == null or result.?.exit_code != 0) {
                    std.fs.cwd().deleteTree(info.path) catch {};
                }

                self.allocator.free(info.id);
                self.allocator.free(info.path);
                self.allocator.free(info.branch);
                self.allocator.free(info.task_id);

                _ = self.active_worktrees.orderedRemove(i);
                return;
            }
        }
    }

    /// Get worktree info for a task
    pub fn getWorktree(self: *WorktreeManager, task_id: []const u8) ?WorktreeInfo {
        for (self.active_worktrees.items) |info| {
            if (std.mem.eql(u8, info.task_id, task_id) and info.active) {
                return info;
            }
        }
        return null;
    }

    /// Get path to worktree for a task
    pub fn getWorktreePath(self: *WorktreeManager, task_id: []const u8) ?[]const u8 {
        if (self.getWorktree(task_id)) |info| {
            return info.path;
        }
        return null;
    }

    /// List all active worktrees
    pub fn listActive(self: *const WorktreeManager) []const WorktreeInfo {
        return self.active_worktrees.items;
    }

    /// Clean up all worktrees
    pub fn cleanupAll(self: *WorktreeManager) void {
        for (self.active_worktrees.items) |info| {
            const cmd = std.fmt.allocPrint(self.allocator, "git worktree remove {s}", .{info.path}) catch {
                std.fs.cwd().deleteTree(info.path) catch {};
                self.allocator.free(info.id);
                self.allocator.free(info.path);
                self.allocator.free(info.branch);
                self.allocator.free(info.task_id);
                continue;
            };
            defer self.allocator.free(cmd);
            const result = shell.executeShellCommand(cmd, null) catch null;
            if (result == null or result.?.exit_code != 0) {
                std.fs.cwd().deleteTree(info.path) catch {};
            }
            self.allocator.free(info.id);
            self.allocator.free(info.path);
            self.allocator.free(info.branch);
            self.allocator.free(info.task_id);
        }
        self.active_worktrees.clearRetainingCapacity();
    }

    /// Print active worktrees
    pub fn printActive(self: *WorktreeManager) void {
        const stdout = file_compat.File.stdout().writer();
        stdout.print("\n=== Active Worktrees ===\n", .{}) catch {};
        if (self.active_worktrees.items.len == 0) {
            stdout.print("  No active worktrees\n", .{}) catch {};
            return;
        }
        for (self.active_worktrees.items) |info| {
            stdout.print("  {s}: {s} ({s})\n", .{ info.task_id, info.branch, info.path }) catch {};
        }
    }

    pub fn deinit(self: *WorktreeManager) void {
        self.cleanupAll();
        self.active_worktrees.deinit();
    }
};
