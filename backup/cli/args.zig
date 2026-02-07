const std = @import("std");

pub fn getArgIterator() !CustomArgIterator {
    // On Windows, use std.process.argsAlloc
    // On other platforms, use std.process.ArgIterator.init()
    const builtin = @import("builtin");
    const target = builtin.target;
    const os_tag = target.os.tag;

    switch (os_tag) {
        .windows => {
            // On Windows, we need to use argsAlloc
            const allocator = std.heap.page_allocator;

            const args = try std.process.argsAlloc(allocator);
            // Note: We don't free the memory here since the program will exit soon

            return CustomArgIterator{
                .index = 0,
                .argv = args,
                .argv_count = args.len,
            };
        },
        else => {
            // For non-Windows platforms, use the standard init
            return CustomArgIterator.init();
        },
    }
}

pub const ArgIterator = CustomArgIterator;

pub const CustomArgIterator = struct {
    index: usize,
    argv: [][:0]u8,
    argv_count: usize,

    pub fn init() !CustomArgIterator {
        return CustomArgIterator{
            .index = 0,
            .argv = std.process.ArgIterator.init(),
        };
    }

    pub fn next(self: *CustomArgIterator) ?[]const u8 {
        if (self.index >= self.argv_count) {
            return null;
        }
        const result = self.argv[self.index];
        self.index += 1;
        return result;
    }
};
