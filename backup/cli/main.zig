const std = @import("std");
const args = @import("args.zig");
const commands = @import("commands.zig");

pub fn main() !void {
    printWelcome();

    var args_iter = args.getArgIterator() catch {
        std.debug.print("Failed to initialize argument iterator\n", .{});
        return;
    };

    // Skip program name (we expect it to always succeed)
    _ = args_iter.next();

    // Check if there are remaining arguments
    if (args_iter.next()) |cmd| {
        const command_name = cmd;
        if (std.mem.eql(u8, command_name, "list")) {
            try commands.commandList();
        } else if (std.mem.eql(u8, command_name, "validate")) {
            try commands.commandValidate();
        } else if (std.mem.eql(u8, command_name, "archive")) {
            try commands.commandArchive();
        } else if (std.mem.eql(u8, command_name, "show")) {
            try commands.commandShow();
        } else if (std.mem.eql(u8, command_name, "init")) {
            try commands.commandInit();
        } else {
            try printUnknownCommand();
            try printUsage();
        }
    } else {
        try commands.commandList();
    }
}

fn printWelcome() void {
    std.debug.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║                 crushcode: OpenSpec in Native Zig            ║
        \\║              Spec-Driven Development in Zig Language         ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\. Version: 0.1.0
        \\. Language: Zig 0.15.2+
        \\
    , .{});
}

fn printUsage() !void {
    std.debug.print(
        \\Usage: crushcode [command] [options]
        \\
        \\Commands:
        \\  list                    List all specs and changes
        \\  validate [file]         Validate a spec file
        \\  archive [change-id]     Archive a change proposal
        \\  show [id]               Show spec or change details
        \\  init                    Initialize OpenSpec in current directory
        \\
        \\Options:
        \\  --verbose               Show detailed output
        \\  --help                  Show this help message
        \\  --format=json           Output in JSON format
        \\
    , .{});
}

fn printUnknownCommand() !void {
    std.debug.print(
        \\Error: Unknown command\n
        \\
    , .{});
}
