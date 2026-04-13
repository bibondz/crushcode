const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");
const shell = @import("shell");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

/// Skill definition - a callable command with description
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
};

/// Built-in skill executor functions
const SkillExecutor = *const fn (args: []const []const u8) anyerror!shell.ShellResult;

/// Get executor for a skill by name
fn getSkillExecutor(name: []const u8) ?SkillExecutor {
    if (std.mem.eql(u8, name, "echo")) return skillEcho;
    if (std.mem.eql(u8, name, "date")) return skillDate;
    if (std.mem.eql(u8, name, "whoami")) return skillWhoami;
    if (std.mem.eql(u8, name, "uptime")) return skillUptime;
    if (std.mem.eql(u8, name, "hostname")) return skillHostname;
    if (std.mem.eql(u8, name, "pwd")) return skillPwd;
    return null;
}

/// Get all available skill names and descriptions
pub fn getAllSkills() []const Skill {
    return &[_]Skill{
        .{ .name = "echo", .description = "Echo arguments to stdout" },
        .{ .name = "date", .description = "Show current date and time" },
        .{ .name = "whoami", .description = "Show current user" },
        .{ .name = "uptime", .description = "Show system uptime" },
        .{ .name = "hostname", .description = "Show system hostname" },
        .{ .name = "pwd", .description = "Print working directory" },
    };
}

// Built-in skill implementations

fn skillEcho(args: []const []const u8) !shell.ShellResult {
    const allocator = std.heap.page_allocator;
    var output = array_list_compat.ArrayList(u8).init(allocator);
    defer output.deinit();

    for (args, 0..) |arg, i| {
        if (i > 0) try output.append(' ');
        try output.appendSlice(arg);
    }

    return shell.ShellResult{
        .exit_code = 0,
        .stdout = try output.toOwnedSlice(),
        .stderr = "",
    };
}

fn skillDate(args: []const []const u8) !shell.ShellResult {
    _ = args;
    return shell.executeShellCommand("date", null);
}

fn skillWhoami(args: []const []const u8) !shell.ShellResult {
    _ = args;
    return shell.executeShellCommand("whoami", null);
}

fn skillUptime(args: []const []const u8) !shell.ShellResult {
    _ = args;
    return shell.executeShellCommand("uptime", null);
}

fn skillHostname(args: []const []const u8) !shell.ShellResult {
    _ = args;
    return shell.executeShellCommand("hostname", null);
}

fn skillPwd(args: []const []const u8) !shell.ShellResult {
    _ = args;
    return shell.executeShellCommand("pwd", null);
}

/// Handle skill command from CLI
pub fn handleSkill(args: [][]const u8) !void {
    if (args.len == 0) {
        // List all skills
        out("Available Skills:\n\n", .{});

        const skills = getAllSkills();
        for (skills) |skill| {
            out("  {s:20} - {s}\n", .{ skill.name, skill.description });
        }

        out("\nUsage: crushcode skill <name> [args]\n", .{});
        return;
    }

    const skill_name = args[0];
    const skill_args: []const []const u8 = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (getSkillExecutor(skill_name)) |execute| {
        const result = try execute(skill_args);

        if (result.stdout.len > 0) {
            out("{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            out("[Stderr: {s}]\n", .{result.stderr});
        }

        out("[Exit code: {d}]\n", .{result.exit_code});
    } else {
        out("Error: Unknown skill '{s}'\n", .{skill_name});

        const skills = getAllSkills();
        out("Available skills: ", .{});
        for (skills, 0..) |skill, i| {
            if (i > 0) out(", ", .{});
            out("{s}", .{skill.name});
        }
        out("\n", .{});
    }
}
