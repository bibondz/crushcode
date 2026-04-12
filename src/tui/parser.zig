const std = @import("std");
const array_list_compat = @import("array_list_compat");
const event = @import("event.zig");

const Event = event.Event;
const Modifiers = event.Modifiers;

/// Parser state.
const State = enum {
    ground,
    escape,
    csi,
    ss3,
};

/// Escape sequence parser.
pub const Parser = struct {
    state: State = .ground,
    params: array_list_compat.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .params = array_list_compat.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.params.deinit();
    }

    /// Parse a single byte and return an event when a sequence completes.
    pub fn parse(self: *Parser, byte: u8) ?Event {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) {
                    self.state = .escape;
                    self.params.clearRetainingCapacity();
                    return null;
                }

                return Event{
                    .key_press = .{
                        .key = switch (byte) {
                            '\t' => .tab,
                            0x7f, 0x08 => .backspace,
                            else => .{ .character = @as(u21, @intCast(byte)) },
                        },
                        .mods = .{},
                    },
                };
            },
            .escape => {
                if (byte == '[') {
                    self.state = .csi;
                    return null;
                }

                if (byte == 'O') {
                    self.state = .ss3;
                    return null;
                }

                self.state = .ground;
                return Event{ .key_press = .{ .key = .escape, .mods = .{} } };
            },
            .csi => {
                if ((byte >= '0' and byte <= '?') or (byte >= ' ' and byte <= '/')) {
                    self.params.append(byte) catch {};
                    return null;
                }

                self.state = .ground;
                return self.parseCSI(byte);
            },
            .ss3 => {
                self.state = .ground;
                return self.parseSS3(byte);
            },
        }
    }

    fn parseCSI(self: *Parser, final_byte: u8) ?Event {
        switch (final_byte) {
            'A' => return Event{ .key_press = .{ .key = .up, .mods = self.parseCSIParams() } },
            'B' => return Event{ .key_press = .{ .key = .down, .mods = self.parseCSIParams() } },
            'C' => return Event{ .key_press = .{ .key = .right, .mods = self.parseCSIParams() } },
            'D' => return Event{ .key_press = .{ .key = .left, .mods = self.parseCSIParams() } },
            'H' => return Event{ .key_press = .{ .key = .home, .mods = .{} } },
            'F' => return Event{ .key_press = .{ .key = .end, .mods = .{} } },
            'Z' => return Event{ .key_press = .{ .key = .tab, .mods = .{ .shift = true } } },
            '~' => {
                const primary = parsePrimaryParam(self.params.items);
                return switch (primary) {
                    1, 7 => Event{ .key_press = .{ .key = .home, .mods = .{} } },
                    2 => Event{ .key_press = .{ .key = .insert, .mods = .{} } },
                    3 => Event{ .key_press = .{ .key = .delete, .mods = .{} } },
                    4, 8 => Event{ .key_press = .{ .key = .end, .mods = .{} } },
                    5 => Event{ .key_press = .{ .key = .page_up, .mods = .{} } },
                    6 => Event{ .key_press = .{ .key = .page_down, .mods = .{} } },
                    11 => Event{ .key_press = .{ .key = .f1, .mods = .{} } },
                    12 => Event{ .key_press = .{ .key = .f2, .mods = .{} } },
                    13 => Event{ .key_press = .{ .key = .f3, .mods = .{} } },
                    14 => Event{ .key_press = .{ .key = .f4, .mods = .{} } },
                    15 => Event{ .key_press = .{ .key = .f5, .mods = .{} } },
                    17 => Event{ .key_press = .{ .key = .f6, .mods = .{} } },
                    18 => Event{ .key_press = .{ .key = .f7, .mods = .{} } },
                    19 => Event{ .key_press = .{ .key = .f8, .mods = .{} } },
                    20 => Event{ .key_press = .{ .key = .f9, .mods = .{} } },
                    21 => Event{ .key_press = .{ .key = .f10, .mods = .{} } },
                    23 => Event{ .key_press = .{ .key = .f11, .mods = .{} } },
                    24 => Event{ .key_press = .{ .key = .f12, .mods = .{} } },
                    else => null,
                };
            },
            else => return null,
        }
    }

    fn parseSS3(self: *Parser, byte: u8) ?Event {
        _ = self;
        return switch (byte) {
            'A' => Event{ .key_press = .{ .key = .up, .mods = .{} } },
            'B' => Event{ .key_press = .{ .key = .down, .mods = .{} } },
            'C' => Event{ .key_press = .{ .key = .right, .mods = .{} } },
            'D' => Event{ .key_press = .{ .key = .left, .mods = .{} } },
            'H' => Event{ .key_press = .{ .key = .home, .mods = .{} } },
            'F' => Event{ .key_press = .{ .key = .end, .mods = .{} } },
            'P' => Event{ .key_press = .{ .key = .f1, .mods = .{} } },
            'Q' => Event{ .key_press = .{ .key = .f2, .mods = .{} } },
            'R' => Event{ .key_press = .{ .key = .f3, .mods = .{} } },
            'S' => Event{ .key_press = .{ .key = .f4, .mods = .{} } },
            else => null,
        };
    }

    fn parseCSIParams(self: *Parser) Modifiers {
        var mods = Modifiers{};
        const value = parseModifierParam(self.params.items) orelse return mods;

        switch (value) {
            2 => mods.shift = true,
            3 => mods.alt = true,
            4 => {
                mods.shift = true;
                mods.alt = true;
            },
            5 => mods.ctrl = true,
            6 => {
                mods.shift = true;
                mods.ctrl = true;
            },
            7 => {
                mods.alt = true;
                mods.ctrl = true;
            },
            8 => {
                mods.shift = true;
                mods.alt = true;
                mods.ctrl = true;
            },
            else => {},
        }

        return mods;
    }

    /// Reset parser state.
    pub fn reset(self: *Parser) void {
        self.state = .ground;
        self.params.clearRetainingCapacity();
    }
};

fn parsePrimaryParam(params: []const u8) u16 {
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    if (end == 0) return 0;
    return std.fmt.parseInt(u16, params[0..end], 10) catch 0;
}

fn parseModifierParam(params: []const u8) ?u16 {
    const separator = std.mem.indexOfScalar(u8, params, ';') orelse return null;
    if (separator + 1 >= params.len) return null;
    return std.fmt.parseInt(u16, params[separator + 1 ..], 10) catch null;
}

test "Parser - regular character" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    const evt = parser.parse('a');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .character);
    try std.testing.expect(evt.?.key_press.key.character == 'a');
}

test "Parser - arrow keys via CSI" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expect(parser.parse(0x1b) == null);
    try std.testing.expect(parser.parse('[') == null);
    const evt = parser.parse('A');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .up);
}

test "Parser - escape key" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expect(parser.parse(0x1b) == null);
    const evt = parser.parse('x');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .escape);
}

test "Parser - enter key" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    const evt = parser.parse('\r');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .character);
    try std.testing.expect(evt.?.key_press.key.character == '\r');
}

test "Parser - F1 via SS3" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expect(parser.parse(0x1b) == null);
    try std.testing.expect(parser.parse('O') == null);
    const evt = parser.parse('P');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .f1);
}

test "Parser - CSI modifier parsing" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expect(parser.parse(0x1b) == null);
    try std.testing.expect(parser.parse('[') == null);
    try std.testing.expect(parser.parse('1') == null);
    try std.testing.expect(parser.parse(';') == null);
    try std.testing.expect(parser.parse('5') == null);
    const evt = parser.parse('C');
    try std.testing.expect(evt != null);
    try std.testing.expect(evt.?.key_press.key == .right);
    try std.testing.expect(evt.?.key_press.mods.ctrl);
    try std.testing.expect(!evt.?.key_press.mods.shift);
}
