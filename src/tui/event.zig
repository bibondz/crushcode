const std = @import("std");

/// Key modifier flags.
pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

/// Special and printable keys.
pub const Key = union(enum) {
    character: u21,
    enter,
    escape,
    backspace,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    unknown: []const u8,
};

/// Mouse button.
pub const MouseButton = enum {
    left,
    middle,
    right,
    release,
};

/// Mouse event.
pub const MouseEvent = struct {
    button: MouseButton,
    x: u16,
    y: u16,
    modifiers: Modifiers,
    drag: bool = false,
};

/// Terminal events.
pub const Event = union(enum) {
    key_press: struct { key: Key, mods: Modifiers },
    mouse: MouseEvent,
    resize: struct { width: u16, height: u16 },
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    paste: []const u8,
};

test "Modifiers - defaults to no flags" {
    const mods = Modifiers{};

    try std.testing.expect(!mods.shift);
    try std.testing.expect(!mods.ctrl);
    try std.testing.expect(!mods.alt);
    try std.testing.expect(!mods.super);
}

test "Event - key press preserves character payload" {
    const evt = Event{
        .key_press = .{
            .key = .{ .character = 'z' },
            .mods = .{ .ctrl = true },
        },
    };

    try std.testing.expect(evt == .key_press);
    try std.testing.expect(evt.key_press.key == .character);
    try std.testing.expectEqual(@as(u21, 'z'), evt.key_press.key.character);
    try std.testing.expect(evt.key_press.mods.ctrl);
    try std.testing.expect(!evt.key_press.mods.alt);
}
