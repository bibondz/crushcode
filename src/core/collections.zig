//! Generic collection utilities.
//! Provides comptime-generic helpers that operate on slices of structs
//! using Zig's @field introspection — no traits or interfaces needed.

const std = @import("std");

/// Count items in a slice where `field_name` equals `target`.
///
/// Works with slices of values (`[]const T`) or pointers (`[]const *T`).
/// Generic over the item type via `anytype` — the compiler infers the
/// correct element access pattern at comptime.
///
/// All four status-counting methods in worker.zig, team_coordinator.zig,
/// parallel.zig, and pipeline.zig delegate to this single implementation.
///
/// Example:
///   const n = countMatching(pool.workers.items, "status", .running);
pub fn countMatching(items: anytype, comptime field_name: []const u8, target: anytype) u32 {
    var count: u32 = 0;
    for (items) |item| {
        // Dereference once if item is a pointer so @field works on the struct.
        const val = if (@typeInfo(@TypeOf(item)) == .pointer) item.* else item;
        if (@field(val, field_name) == target) count += 1;
    }
    return count;
}

test "countMatching - value slice" {
    const Item = struct { status: enum { pending, done, failed } };
    const items = [_]Item{
        .{ .status = .pending },
        .{ .status = .done },
        .{ .status = .pending },
        .{ .status = .failed },
    };
    try std.testing.expectEqual(@as(u32, 2), countMatching(&items, "status", .pending));
    try std.testing.expectEqual(@as(u32, 1), countMatching(&items, "status", .done));
    try std.testing.expectEqual(@as(u32, 1), countMatching(&items, "status", .failed));
}

test "countMatching - pointer slice" {
    const TestItem = struct { status: enum { pending, done, failed } };
    const a = TestItem{ .status = .done };
    const b = TestItem{ .status = .pending };
    const c = TestItem{ .status = .done };
    const items = [_]*const TestItem{ &a, &b, &c };
    try std.testing.expectEqual(@as(u32, 2), countMatching(&items, "status", .done));
    try std.testing.expectEqual(@as(u32, 1), countMatching(&items, "status", .pending));
}

test "countMatching - empty slice" {
    const Item = struct { status: enum { pending, done } };
    const items = [_]Item{};
    try std.testing.expectEqual(@as(u32, 0), countMatching(&items, "status", .pending));
}

test "countMatching - no matches" {
    const Item = struct { status: enum { pending, done } };
    const items = [_]Item{ .{ .status = .done }, .{ .status = .done } };
    try std.testing.expectEqual(@as(u32, 0), countMatching(&items, "status", .pending));
}

test "countMatching - all match" {
    const Item = struct { status: enum { pending, done } };
    const items = [_]Item{ .{ .status = .pending }, .{ .status = .pending } };
    try std.testing.expectEqual(@as(u32, 2), countMatching(&items, "status", .pending));
}
