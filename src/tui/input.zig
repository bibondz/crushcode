const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const Parser = @import("parser.zig").Parser;
const Event = @import("event.zig").Event;

/// Input reader that converts raw terminal bytes into parsed events.
pub const InputReader = struct {
    parser: Parser,
    tty_in: file_compat.File,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tty_in: file_compat.File) InputReader {
        return .{
            .parser = Parser.init(allocator),
            .tty_in = tty_in,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InputReader) void {
        self.parser.deinit();
    }

    /// Read the next parsed event, returning null on timeout or incomplete sequence.
    pub fn readEvent(self: *InputReader) ?Event {
        const reader = self.tty_in.reader();
        const byte = reader.readByte() catch return null;
        return self.parser.parse(byte);
    }

    /// Drain all currently pending bytes into a newly allocated event slice.
    pub fn drainEvents(self: *InputReader, allocator: std.mem.Allocator) ![]Event {
        _ = self.allocator;

        var events = array_list_compat.ArrayList(Event).init(allocator);
        errdefer events.deinit();

        const reader = self.tty_in.reader();
        while (true) {
            const byte = reader.readByte() catch break;
            if (self.parser.parse(byte)) |evt| {
                try events.append(evt);
            }
        }

        return events.toOwnedSlice();
    }
};
