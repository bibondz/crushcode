const std = @import("std");
const args_mod = @import("args");
const commands = @import("handlers");
const config_mod = @import("config");

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
        std.mem.eql(u8, command, "list") or
        std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v");
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Early Exit: Handle argument iterator initialization failure
    var args_iter = std.process.argsWithAllocator(allocator) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Error: Failed to allocate memory for argument parsing\n", .{});
            return error.OutOfMemory;
        },
    };
    defer args_iter.deinit();

    // Early Exit: Handle argument parsing failure with comprehensive error handling
    const parsed_args = args_mod.Args.parse(allocator, &args_iter) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Error: Insufficient memory to parse command line arguments\n", .{});
            return error.OutOfMemory;
        },
    };
    defer cleanupParsedArgs(allocator, parsed_args);

    // Early Exit: Handle config loading failure with user-friendly errors
    var config = config_mod.loadOrCreateConfig(allocator) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Error: Failed to allocate memory for configuration\n", .{});
            return error.OutOfMemory;
        },
        error.HomeNotFound => {
            std.debug.print("Error: Cannot find home directory for configuration\n", .{});
            return error.HomeNotFound;
        },
        error.InvalidPath => {
            std.debug.print("Error: Invalid configuration path\n", .{});
            return error.InvalidPath;
        },
        error.FileNotFound => {
            std.debug.print("Error: Configuration file not found and could not be created\n", .{});
            return error.FileNotFound;
        },
        error.AccessDenied => {
            std.debug.print("Error: Permission denied accessing configuration\n", .{});
            return error.AccessDenied;
        },
        else => {
            std.debug.print("Error: Failed to load configuration: {}\n", .{err});
            return err;
        },
    };
    defer config.deinit();

    // Early Exit: No command provided - show help and exit
    if (!parsed_args.has_command) {
        try commands.printHelp();
        return;
    }

    // Early Exit: Handle unknown commands with single exit point and clear error message
    if (!isCommandRecognized(parsed_args.command)) {
        std.debug.print("Error: Unknown command '{s}'\n\n", .{parsed_args.command});
        try commands.printHelp();
        return error.UnknownCommand;
    }

    // Main command dispatch - all edge cases handled above, execution can proceed safely
    if (std.mem.eql(u8, parsed_args.command, "chat")) {
        try commands.handleChat(parsed_args, &config);
    } else if (std.mem.eql(u8, parsed_args.command, "read")) {
        try commands.handleRead(parsed_args);
    } else if (std.mem.eql(u8, parsed_args.command, "shell")) {
        try commands.handleShell(parsed_args);
    } else if (std.mem.eql(u8, parsed_args.command, "list")) {
        try commands.handleList(parsed_args);
    } else if (std.mem.eql(u8, parsed_args.command, "help") or
        std.mem.eql(u8, parsed_args.command, "--help") or
        std.mem.eql(u8, parsed_args.command, "-h"))
    {
        try commands.printHelp();
    } else if (std.mem.eql(u8, parsed_args.command, "version") or
        std.mem.eql(u8, parsed_args.command, "--version") or
        std.mem.eql(u8, parsed_args.command, "-v"))
    {
        try commands.printVersion();
    }
}
