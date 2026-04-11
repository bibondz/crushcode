const std = @import("std");

const Allocator = std.mem.Allocator;

/// A single conflict between an edit and current file state
pub const Conflict = struct {
    line_number: u32,
    expected_hash: u32,
    actual_hash: u32,
    expected_preview: []const u8,
    actual_preview: []const u8,
};

/// Resolution strategy for conflicts
pub const ResolutionStrategy = enum {
    reject, // Fail with error
    force, // Apply anyway (user override)
    merge, // Attempt basic merge
};

/// Result of conflict resolution
pub const Resolution = union(enum) {
    rejected: []const u8, // Error message
    applied, // Safe to apply / applied with force
    merged: []const u8, // Merged result
};

/// Conflict detector and resolver for hashline edit validation
pub const ConflictResolver = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ConflictResolver {
        return ConflictResolver{ .allocator = allocator };
    }

    /// Format a conflict for display
    pub fn formatConflict(self: *ConflictResolver, conflict: Conflict) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\Line {d} conflict:
            \\  Expected: {s} (hash: {x:0>8})
            \\  Actual:   {s} (hash: {x:0>8})
        , .{
            conflict.line_number,
            self.truncate(conflict.expected_preview, 60),
            conflict.expected_hash,
            self.truncate(conflict.actual_preview, 60),
            conflict.actual_hash,
        });
    }

    /// Resolve a conflict based on the chosen strategy
    pub fn resolve(self: *ConflictResolver, conflict: Conflict, strategy: ResolutionStrategy) !Resolution {
        switch (strategy) {
            .reject => {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Edit rejected: line {d} was modified externally (hash mismatch: expected {x:0>8}, got {x:0>8})",
                    .{ conflict.line_number, conflict.expected_hash, conflict.actual_hash },
                );
                return .{ .rejected = msg };
            },
            .force => {
                // Apply anyway — just return applied
                return .applied;
            },
            .merge => {
                // Basic merge: if the new content doesn't overlap, insert it
                // For now, this is a simple append strategy
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Merged edit at line {d} (replacing '{s}' with new content)",
                    .{ conflict.line_number, self.truncate(conflict.actual_preview, 30) },
                );
                return .{ .merged = msg };
            },
        }
    }

    /// Truncate a string for preview display
    fn truncate(self: *ConflictResolver, s: []const u8, max_len: usize) []const u8 {
        _ = self;
        if (s.len <= max_len) return s;
        return s[0..max_len];
    }

    /// Print conflict info to stderr
    pub fn printConflict(conflict: Conflict) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print("\x1b[33m⚠ Hashline conflict at line {d}:\x1b[0m\n", .{conflict.line_number}) catch {};
        stderr.print("  Expected hash: {x:0>8}\n", .{conflict.expected_hash}) catch {};
        stderr.print("  Actual hash:   {x:0>8}\n", .{conflict.actual_hash}) catch {};
        stderr.print("  File was modified externally\n", .{}) catch {};
    }

    pub fn deinit(self: *ConflictResolver) void {
        _ = self;
    }
};
