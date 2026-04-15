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

    /// Git blame — show per-line author/commit for a file
    pub fn blame(file: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "blame {s}", .{file});
        return run(cmd);
    }

    /// Git stash — save working directory changes
    pub fn stash() !shell.ShellResult {
        return run("stash");
    }

    /// Git stash pop — apply and remove latest stash
    pub fn stashPop() !shell.ShellResult {
        return run("stash pop");
    }

    /// Git stash list — show all stashes
    pub fn stashList() !shell.ShellResult {
        return run("stash list");
    }

    /// Git stash apply — apply latest stash without removing it
    pub fn stashApply() !shell.ShellResult {
        return run("stash apply");
    }

    /// Git stash drop — remove latest stash
    pub fn stashDrop() !shell.ShellResult {
        return run("stash drop");
    }

    /// Git rebase — rebase current branch onto target
    pub fn rebase(target: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "rebase {s}", .{target});
        return run(cmd);
    }

    /// Git rebase abort — abort an in-progress rebase
    pub fn rebaseAbort() !shell.ShellResult {
        return run("rebase --abort");
    }

    /// Git rebase continue — continue an in-progress rebase
    pub fn rebaseContinue() !shell.ShellResult {
        return run("rebase --continue");
    }

    /// Git merge — merge a branch into current
    pub fn merge(branch_name: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "merge {s}", .{branch_name});
        return run(cmd);
    }

    /// Git merge abort — abort an in-progress merge
    pub fn mergeAbort() !shell.ShellResult {
        return run("merge --abort");
    }

    /// Git bisect start — begin binary search
    pub fn bisectStart() !shell.ShellResult {
        return run("bisect start");
    }

    /// Git bisect good — mark current commit as good
    pub fn bisectGood(rev: ?[]const u8) !shell.ShellResult {
        if (rev) |r| {
            const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "bisect good {s}", .{r});
            return run(cmd);
        }
        return run("bisect good");
    }

    /// Git bisect bad — mark current commit as bad
    pub fn bisectBad(rev: ?[]const u8) !shell.ShellResult {
        if (rev) |r| {
            const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "bisect bad {s}", .{r});
            return run(cmd);
        }
        return run("bisect bad");
    }

    /// Git bisect reset — end bisect session
    pub fn bisectReset() !shell.ShellResult {
        return run("bisect reset");
    }

    /// Git remote list — show remotes
    pub fn remoteList() !shell.ShellResult {
        return run("remote -v");
    }

    /// Git remote add — add a new remote
    pub fn remoteAdd(name: []const u8, url: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "remote add {s} {s}", .{ name, url });
        return run(cmd);
    }

    /// Git remote remove — remove a remote
    pub fn remoteRemove(name: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "remote remove {s}", .{name});
        return run(cmd);
    }

    /// Git log search — search commit history for a string (log -S)
    pub fn logSearch(query: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "log --oneline -20 -S \"{s}\"", .{query});
        return run(cmd);
    }

    /// Git log with custom options
    pub fn logOpts(opts: []const u8) !shell.ShellResult {
        const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "log {s}", .{opts});
        return run(cmd);
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
    } else if (std.mem.eql(u8, subcommand, "blame")) {
        if (sub_args.len == 0) {
            out("Error: file path required\n", .{});
            out("Usage: crushcode git blame <file>\n", .{});
            return;
        }
        const result = try GitSkill.blame(sub_args[0]);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
    } else if (std.mem.eql(u8, subcommand, "stash")) {
        if (sub_args.len == 0) {
            const result = try GitSkill.stash();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "pop")) {
            const result = try GitSkill.stashPop();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "list")) {
            const result = try GitSkill.stashList();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "apply")) {
            const result = try GitSkill.stashApply();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "drop")) {
            const result = try GitSkill.stashDrop();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else {
            out("Unknown stash subcommand: {s}\n", .{sub_args[0]});
            out("Usage: crushcode git stash [pop|list|apply|drop]\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "rebase")) {
        if (sub_args.len == 0) {
            out("Error: target branch required\n", .{});
            out("Usage: crushcode git rebase <branch> [--abort|--continue]\n", .{});
            return;
        }
        if (std.mem.eql(u8, sub_args[0], "--abort")) {
            const result = try GitSkill.rebaseAbort();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "--continue")) {
            const result = try GitSkill.rebaseContinue();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else {
            const result = try GitSkill.rebase(sub_args[0]);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        }
    } else if (std.mem.eql(u8, subcommand, "merge")) {
        if (sub_args.len == 0) {
            out("Error: branch name required\n", .{});
            out("Usage: crushcode git merge <branch> [--abort]\n", .{});
            return;
        }
        if (std.mem.eql(u8, sub_args[0], "--abort")) {
            const result = try GitSkill.mergeAbort();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else {
            const result = try GitSkill.merge(sub_args[0]);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        }
    } else if (std.mem.eql(u8, subcommand, "bisect")) {
        if (sub_args.len == 0) {
            out("Error: bisect subcommand required\n", .{});
            out("Usage: crushcode git bisect <start|good|bad|reset> [revision]\n", .{});
            return;
        }
        if (std.mem.eql(u8, sub_args[0], "start")) {
            const result = try GitSkill.bisectStart();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "good")) {
            const rev = if (sub_args.len > 1) sub_args[1] else null;
            const result = try GitSkill.bisectGood(rev);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "bad")) {
            const rev = if (sub_args.len > 1) sub_args[1] else null;
            const result = try GitSkill.bisectBad(rev);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "reset")) {
            const result = try GitSkill.bisectReset();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else {
            out("Unknown bisect subcommand: {s}\n", .{sub_args[0]});
        }
    } else if (std.mem.eql(u8, subcommand, "remote")) {
        if (sub_args.len == 0) {
            // Default: list remotes
            const result = try GitSkill.remoteList();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "add")) {
            if (sub_args.len < 3) {
                out("Error: remote name and URL required\n", .{});
                out("Usage: crushcode git remote add <name> <url>\n", .{});
                return;
            }
            const result = try GitSkill.remoteAdd(sub_args[1], sub_args[2]);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else if (std.mem.eql(u8, sub_args[0], "remove")) {
            if (sub_args.len < 2) {
                out("Error: remote name required\n", .{});
                out("Usage: crushcode git remote remove <name>\n", .{});
                return;
            }
            const result = try GitSkill.remoteRemove(sub_args[1]);
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        } else {
            // Default action: list
            const result = try GitSkill.remoteList();
            out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
            out("\n[Exit code: {d}]\n", .{result.exit_code});
        }
    } else if (std.mem.eql(u8, subcommand, "log-search") or std.mem.eql(u8, subcommand, "logsearch")) {
        if (sub_args.len == 0) {
            out("Error: search query required\n", .{});
            out("Usage: crushcode git log-search <query>\n", .{});
            return;
        }
        const result = try GitSkill.logSearch(sub_args[0]);
        out("{s}", .{if (result.stdout.len > 0) result.stdout else result.stderr});
        out("\n[Exit code: {d}]\n", .{result.exit_code});
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
        \\Basic Subcommands:
        \\  status              Show working tree status
        \\  diff                Show changes
        \\  add <files>         Stage files (default: all)
        \\  commit <msg>        Create commit with message
        \\  push                Push to remote
        \\  pull                Pull from remote
        \\  branch              List branches
        \\  branch-create <name> Create new branch
        \\  checkout <branch>   Switch to branch
        \\  log [opts]          Show recent commits
        \\  is-repo             Check if git repository
        \\
        \\Advanced Subcommands:
        \\  blame <file>        Show per-line author/commit
        \\  stash [pop|list|apply|drop]  Stash management
        \\  rebase <branch>     Rebase onto target branch
        \\  rebase --abort      Abort in-progress rebase
        \\  rebase --continue   Continue in-progress rebase
        \\  merge <branch>      Merge branch into current
        \\  merge --abort       Abort in-progress merge
        \\  bisect start        Start binary search for bugs
        \\  bisect good [rev]   Mark revision as good
        \\  bisect bad [rev]    Mark revision as bad
        \\  bisect reset        End bisect session
        \\  remote [list]       List remotes (default)
        \\  remote add <n> <url> Add a remote
        \\  remote remove <n>   Remove a remote
        \\  log-search <query>  Search commit history (git log -S)
        \\
        \\Examples:
        \\  crushcode git status
        \\  crushcode git add .
        \\  crushcode git commit "Initial commit"
        \\  crushcode git blame src/main.zig
        \\  crushcode git stash
        \\  crushcode git stash pop
        \\  crushcode git rebase main
        \\  crushcode git merge feature-branch
        \\  crushcode git bisect start
        \\  crushcode git remote add origin https://github.com/user/repo.git
        \\  crushcode git log-search "fn handleRequest"
        \\
    , .{});
}
