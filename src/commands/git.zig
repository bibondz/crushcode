const std = @import("std");
const file_compat = @import("file_compat");
const shell = @import("shell");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub const GitSkill = struct {
    /// Execute git command - helper
    fn run(command: []const u8) !shell.ShellResult {
        const full_command = try std.fmt.allocPrint(std.heap.page_allocator, "git {s}", .{command});
        return shell.executeShellCommand(full_command, null);
    }

    /// Check git status
    pub fn status() !shell.ShellResult {
        return run("status");
    }

    /// Check git diff
    pub fn diff() !shell.ShellResult {
        return run("diff");
    }

    /// Stage files
    pub fn add(files: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "add {s}", .{files});
        return run(cmd);
    }

    /// Create commit
    pub fn commit(msg: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "commit -m \"{s}\"", .{msg});
        return run(cmd);
    }

    /// Push to remote
    pub fn push() !shell.ShellResult {
        return run("push");
    }

    /// Pull from remote
    pub fn pull() !shell.ShellResult {
        return run("pull");
    }

    /// List branches
    pub fn branch() !shell.ShellResult {
        return run("branch");
    }

    /// Create new branch
    pub fn createBranch(branch_name: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "checkout -b {s}", .{branch_name});
        return run(cmd);
    }

    /// Switch branch
    pub fn checkout(branch_name: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "checkout {s}", .{branch_name});
        return run(cmd);
    }

    /// Get current branch name
    pub fn currentBranch() !shell.ShellResult {
        return run("rev-parse --abbrev-ref HEAD");
    }

    /// Check if in git repo
    pub fn isGitRepo() bool {
        const result = run("rev-parse --git-dir") catch return false;
        return result.exit_code == 0;
    }
};

/// Handle git command from CLI
pub fn handleGit(args: [][]const u8) !void {
    if (args.len == 0) {
        try printGitHelp();
        return;
    }

    const subcommand = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcommand, "status")) {
        const result = try GitSkill.status();
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "diff")) {
        const result = try GitSkill.diff();
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "push")) {
        const result = try GitSkill.push();
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "pull")) {
        const result = try GitSkill.pull();
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "branch")) {
        const result = try GitSkill.branch();
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "log")) {
        const result = try GitSkill.run("log --oneline -10");
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "add")) {
        const files = if (sub_args.len > 0) sub_args[0] else ".";
        const result = try GitSkill.add(files);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "commit")) {
        if (sub_args.len == 0) {
            out("Error: commit message required\n", .{});
            out("Usage: crushcode git commit \"your message\"\n", .{});
            return;
        }
        const result = try GitSkill.commit(sub_args[0]);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "checkout")) {
        if (sub_args.len == 0) {
            out("Error: branch name required\n", .{});
            return;
        }
        const result = try GitSkill.checkout(sub_args[0]);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "branch-create")) {
        if (sub_args.len == 0) {
            out("Error: branch name required\n", .{});
            return;
        }
        const result = try GitSkill.createBranch(sub_args[0]);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "is-repo")) {
        if (GitSkill.isGitRepo()) {
            out("Yes, this is a git repository\n", .{});
        } else {
            out("No, not a git repository\n", .{});
        }
    } else {
        out("Unknown git command: {s}\n", .{subcommand});
        try printGitHelp();
    }
}

fn printGitHelp() !void {
    out(
        \\Crushcode Git Command
        \\
        \\Usage:
        \\  crushcode git <subcommand> [options]
        \\
        \\Subcommands:
        \\  status           Show working tree status
        \\  diff             Show changes
        \\  add <files>      Stage files (default: all)
        \\  commit <msg>    Create commit with message
        \\  push             Push to remote
        \\  pull             Pull from remote
        \\  branch            List branches
        \\  branch-create <name>  Create new branch
        \\  checkout <branch>     Switch to branch
        \\  log              Show recent commits
        \\  is-repo          Check if git repository
        \\
        \\Examples:
        \\  crushcode git status
        \\  crushcode git add .
        \\  crushcode git commit "Initial commit"
        \\  crushcode git push
        \\
    , .{});
}
