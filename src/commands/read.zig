const std = @import("std");
const fileops_mod = @import("fileops");

pub fn handleRead(args: []const []const u8) !void {
    const allocator = std.heap.page_allocator;

    if (args.len < 1) {
        std.debug.print("Error: No file specified\n\n", .{});
        try printReadHelp();
        return;
    }

    var reader = fileops_mod.FileReader.init(allocator);

    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try printReadHelp();
        return;
    }

    const paths = args;
    const contents = try reader.readMultiple(paths);
    defer {
        for (contents) |*item| {
            item.deinit();
            allocator.free(item.path);
        }
        allocator.free(contents);
    }

    for (contents, 0..) |content, i| {
        if (i > 0) {
            std.debug.print("\n", .{});
        }
        content.print();
    }
}

pub fn printReadHelp() !void {
    std.debug.print(
        \\Crushcode Read Command
        \\
        \\Usage:
        \\  crushcode read <file-path> [file-path...]
        \\  crushcode read --help
        \\
        \\Options:
        \\  --help, -h    Show this help message
        \\
        \\Examples:
        \\  crushcode read src/main.zig
        \\  crushcode read src/main.zig src/commands/chat.zig
        \\
    , .{});
}
