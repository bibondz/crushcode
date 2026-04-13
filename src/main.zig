const std = @import("std");
const file_compat = @import("file_compat");
const args_mod = @import("args");
const commands = @import("handlers");
const config_mod = @import("config");

inline fn err_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stderr().writer().print(fmt, args) catch {};
}

/// Helper function to safely cleanup parsed arguments with proper error handling
fn cleanupParsedArgs(allocator: std.mem.Allocator, parsed_args: args_mod.Args) void {
    // Early exit for empty command string (safety check)
    if (parsed_args.command.len == 0) return;

    // Cleanup command safely
    allocator.free(parsed_args.command);

    // Cleanup optional fields safely
    if (parsed_args.provider) |provider| {
        allocator.free(provider);
    }
    if (parsed_args.model) |model| {
        allocator.free(model);
    }
    if (parsed_args.config_file) |config_file| {
        allocator.free(config_file);
    }
    if (parsed_args.profile) |profile| {
        allocator.free(profile);
    }

    // Cleanup remaining arguments safely
    for (parsed_args.remaining) |arg| {
        allocator.free(arg);
    }
    allocator.free(parsed_args.remaining);
}

/// Helper function to check if command is recognized
fn isCommandRecognized(command: []const u8) bool {
    return std.mem.eql(u8, command, "chat") or
        std.mem.eql(u8, command, "read") or
        std.mem.eql(u8, command, "shell") or
        std.mem.eql(u8, command, "write") or
        std.mem.eql(u8, command, "edit") or
        std.mem.eql(u8, command, "git") or
        std.mem.eql(u8, command, "skill") or
        std.mem.eql(u8, command, "skills-load") or
        std.mem.eql(u8, command, "fallback") or
        std.mem.eql(u8, command, "parallel") or
        std.mem.eql(u8, command, "agents") or
        std.mem.eql(u8, command, "tools") or
        std.mem.eql(u8, command, "tui") or
        std.mem.eql(u8, command, "install") or
        std.mem.eql(u8, command, "jobs") or
        std.mem.eql(u8, command, "capabilities") or
        std.mem.eql(u8, command, "worktree") or
        std.mem.eql(u8, command, "graph") or
        std.mem.eql(u8, command, "agent-loop") or
        std.mem.eql(u8, command, "workflow") or
        std.mem.eql(u8, command, "compact") or
        std.mem.eql(u8, command, "scaffold") or
        std.mem.eql(u8, command, "list") or
        std.mem.eql(u8, command, "usage") or
        std.mem.eql(u8, command, "connect") or
        std.mem.eql(u8, command, "profile") or
        std.mem.eql(u8, command, "checkpoint") or
        std.mem.eql(u8, command, "grep") or
        std.mem.eql(u8, command, "lsp") or
        std.mem.eql(u8, command, "mcp") or
        std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v");
}

pub fn main() !void {
    // For CLI tools that run once and exit, use page_allocator directly.
    // The GPA tracking adds overhead and the memory is released on process exit anyway.
    const allocator = std.heap.page_allocator;

    // Graceful shutdown: install SIGINT/SIGTERM handlers so we exit cleanly.
    // Zig's std.os.sigaction wraps the POSIX call. On Windows these are no-ops.
    const Posix = struct {
        fn sigintHandler(sig: c_int) callconv(.c) void {
            _ = sig;
            // Exit with code 130 (128 + SIGINT=2) — standard convention.
            std.posix.exit(130);
        }
    };
    const empty_mask = std.os.linux.sigemptyset();
    _ = std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = Posix.sigintHandler },
        .mask = empty_mask,
        .flags = 0,
    }, null);

    // Early Exit: Handle argument iterator initialization failure
    var args_iter = std.process.argsWithAllocator(allocator) catch |err| switch (err) {
        error.OutOfMemory => {
            err_print("Error: Failed to allocate memory for argument parsing\n", .{});
            return error.OutOfMemory;
        },
    };
    defer args_iter.deinit();

    // Early Exit: Handle argument parsing failure with comprehensive error handling
    const parsed_args = args_mod.Args.parse(allocator, &args_iter) catch |err| switch (err) {
        error.OutOfMemory => {
            err_print("Error: Insufficient memory to parse command line arguments\n", .{});
            return error.OutOfMemory;
        },
    };
    defer cleanupParsedArgs(allocator, parsed_args);

    // Early Exit: Handle config loading failure with user-friendly errors
    var config = config_mod.loadOrCreateConfig(allocator) catch |err| switch (err) {
        error.OutOfMemory => {
            err_print("Error: Failed to allocate memory for configuration\n", .{});
            return error.OutOfMemory;
        },
        error.HomeNotFound => {
            err_print("Error: Cannot find home directory for configuration\n", .{});
            return error.HomeNotFound;
        },
        error.InvalidPath => {
            err_print("Error: Invalid configuration path\n", .{});
            return error.InvalidPath;
        },
        error.FileNotFound => {
            err_print("Error: Configuration file not found and could not be created\n", .{});
            return error.FileNotFound;
        },
        error.AccessDenied => {
            err_print("Error: Permission denied accessing configuration\n", .{});
            return error.AccessDenied;
        },
        else => {
            err_print("Error: Failed to load configuration: {}\n", .{err});
            return err;
        },
    };

    // Skip config cleanup for now - see if basic commands work
    // defer config.deinit();

    // Early Exit: No command provided - show help and exit
    if (!parsed_args.has_command) {
        try commands.printHelp();
        return;
    }

    // Early Exit: Handle unknown commands with single exit point and clear error message
    if (!isCommandRecognized(parsed_args.command)) {
        if (try commands.tryHandlePluginCommand(parsed_args.command)) {
            return;
        }

        err_print("Error: Unknown command '{s}'\n\n", .{parsed_args.command});
        try commands.printHelp();
        return error.UnknownCommand;
    }

    // Main command dispatch - all edge cases handled above, execution can proceed safely.
    // Wrap in a catch for BrokenPipe — if stdout is piped to `head` or similar,
    // writes will fail with BrokenPipe. That's expected, exit cleanly with code 0.
    const main_result: anyerror!void = blk: {
        if (std.mem.eql(u8, parsed_args.command, "chat")) {
            break :blk commands.handleChat(parsed_args, &config);
        } else if (std.mem.eql(u8, parsed_args.command, "read")) {
            break :blk commands.handleRead(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "shell")) {
            break :blk commands.handleShell(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "write")) {
            break :blk commands.handleWrite(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "edit")) {
            break :blk commands.handleEdit(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "git")) {
            break :blk commands.handleGit(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "skill")) {
            break :blk commands.handleSkill(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "skills-load")) {
            break :blk commands.handleSkillsLoad(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "fallback")) {
            break :blk commands.handleFallback(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "parallel")) {
            break :blk commands.handleParallel(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "agents")) {
            break :blk commands.handleAgents(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "tools")) {
            break :blk commands.handleTools(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "plugin")) {
            break :blk commands.handlePlugin(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "tui")) {
            break :blk commands.handleTUI(parsed_args, &config);
        } else if (std.mem.eql(u8, parsed_args.command, "install")) {
            break :blk commands.handleInstall(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "jobs")) {
            break :blk commands.handleJobs(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "capabilities")) {
            break :blk commands.handleCapabilities(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "worktree")) {
            break :blk commands.handleWorktree(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "graph")) {
            break :blk commands.handleGraph(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "agent-loop")) {
            break :blk commands.handleAgentLoop(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "workflow")) {
            break :blk commands.handleWorkflow(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "compact")) {
            break :blk commands.handleCompact(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "scaffold")) {
            break :blk commands.handleScaffold(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "list")) {
            break :blk commands.handleList(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "usage")) {
            break :blk commands.handleUsage(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "connect")) {
            break :blk commands.handleConnect(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "profile")) {
            break :blk commands.handleProfile(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "checkpoint")) {
            break :blk commands.handleCheckpoint(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "grep")) {
            break :blk commands.handleGrep(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "lsp")) {
            break :blk commands.handleLSP(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "mcp")) {
            break :blk commands.handleMCP(parsed_args);
        } else if (std.mem.eql(u8, parsed_args.command, "help") or
            std.mem.eql(u8, parsed_args.command, "--help") or
            std.mem.eql(u8, parsed_args.command, "-h"))
        {
            break :blk commands.printHelp();
        } else if (std.mem.eql(u8, parsed_args.command, "version") or
            std.mem.eql(u8, parsed_args.command, "--version") or
            std.mem.eql(u8, parsed_args.command, "-v"))
        {
            break :blk commands.printVersion();
        }
        break :blk;
    };

    main_result catch |err| switch (err) {
        error.BrokenPipe => return, // Consumer closed the pipe — exit cleanly
        else => return err,
    };
}
