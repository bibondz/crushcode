const std = @import("std");
const file_compat = @import("file_compat");
const args_mod = @import("args");
const commands = @import("handlers");
const config_mod = @import("config");
const registry = @import("cli_registry");
const update_mod = @import("update");

pub const std_options = std.Options{
    .log_level = .warn,
};

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
    var empty_mask: std.posix.sigset_t = undefined;
    @memset(std.mem.asBytes(&empty_mask), 0);
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

    // Auto-check for updates — runs once per 24 hours, never blocks startup
    {
        if (update_mod.Updater.checkForUpdate(allocator)) |maybe_version| {
            if (maybe_version) |new_version| {
                const stdout = file_compat.File.stdout().writer();
                stdout.print("\n  ┌──────────────────────────────────────────────────┐\n", .{}) catch {};
                stdout.print("  │  Update available: v1.0.0 → v{s}", .{new_version}) catch {};
                stdout.print("  │  Run 'crushcode update' to upgrade                │\n", .{}) catch {};
                stdout.print("  └──────────────────────────────────────────────────┘\n\n", .{}) catch {};
                allocator.free(new_version);
            }
        } else |_| {
            // Silently ignore network errors — don't block startup
        }
    }

    // No command provided — launch interactive TUI chat by default
    if (!parsed_args.has_command) {
        const interactive_args = args_mod.Args{
            .command = try allocator.dupe(u8, "tui"),
            .provider = null,
            .model = null,
            .profile = null,
            .config_file = null,
            .interactive = true,
            .tui = true,
            .json = false,
            .color = null,
            .checkpoint = null,
            .restore = null,
            .agents = null,
            .max_agents = 5,
            .memory = null,
            .memory_limit = 100,
            .stream = false,
            .debug = false,
            .show_thinking = false,
            .permission = null,
            .intensity = null,
            .remaining = &.{},
            .has_command = true,
        };
        defer allocator.free(interactive_args.command);
        try commands.handleTUI(interactive_args, &config);
        return;
    }

    // Main command dispatch — O(1) comptime hash map lookup via registry.
    // Wrap in a catch for BrokenPipe — if stdout is piped to `head` or similar,
    // writes will fail with BrokenPipe. That's expected, exit cleanly with code 0.
    const main_result: anyerror!void = blk: {
        if (registry.dispatch(parsed_args.command, parsed_args, &config)) |_| {
            break :blk;
        } else |err| switch (err) {
            error.CommandNotFound => {
                // Not a built-in command — try plugin fallback
                if (try commands.tryHandlePluginCommand(parsed_args.command)) {
                    break :blk;
                }
                err_print("Error: Unknown command '{s}'\n\n", .{parsed_args.command});
                try commands.printHelp();
                break :blk error.UnknownCommand;
            },
            else => break :blk err,
        }
        break :blk;
    };

    main_result catch |err| switch (err) {
        error.BrokenPipe => return, // Consumer closed the pipe — exit cleanly
        else => return err,
    };
}
