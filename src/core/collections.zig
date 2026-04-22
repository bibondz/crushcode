//! Generic collection utilities.
//! Provides comptime-generic helpers that operate on slices of structs
//! using Zig's @field introspection — no traits or interfaces needed.

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
