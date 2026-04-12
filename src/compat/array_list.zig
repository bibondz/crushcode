const std = @import("std");

pub fn ArrayList(comptime T: type) type {
    return struct {
        const Self = @This();
        const Unmanaged = std.ArrayList(T);
        pub const Slice = []T;
        pub const Writer = if (T != u8) void else std.io.GenericWriter(*Self, std.mem.Allocator.Error, appendWrite);

        items: Slice = &.{},
        capacity: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, num: usize) std.mem.Allocator.Error!Self {
            var self = Self.init(allocator);
            try self.ensureTotalCapacity(num);
            return self;
        }

        pub fn deinit(self: *Self) void {
            var unmanaged = self.toUnmanaged();
            unmanaged.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn toOwnedSlice(self: *Self) std.mem.Allocator.Error!Slice {
            var unmanaged = self.toUnmanaged();
            defer self.syncFromUnmanaged(unmanaged);
            return unmanaged.toOwnedSlice(self.allocator);
        }

        pub fn append(self: *Self, item: T) std.mem.Allocator.Error!void {
            var unmanaged = self.toUnmanaged();
            defer self.syncFromUnmanaged(unmanaged);
            try unmanaged.append(self.allocator, item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            var unmanaged = self.toUnmanaged();
            unmanaged.appendAssumeCapacity(item);
            self.syncFromUnmanaged(unmanaged);
        }

        pub fn appendSlice(self: *Self, items: []const T) std.mem.Allocator.Error!void {
            var unmanaged = self.toUnmanaged();
            defer self.syncFromUnmanaged(unmanaged);
            try unmanaged.appendSlice(self.allocator, items);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            var unmanaged = self.toUnmanaged();
            unmanaged.appendSliceAssumeCapacity(items);
            self.syncFromUnmanaged(unmanaged);
        }

        pub fn insert(self: *Self, item: T, index: usize) std.mem.Allocator.Error!void {
            var unmanaged = self.toUnmanaged();
            defer self.syncFromUnmanaged(unmanaged);
            try unmanaged.insert(self.allocator, index, item);
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) std.mem.Allocator.Error!void {
            var unmanaged = self.toUnmanaged();
            defer self.syncFromUnmanaged(unmanaged);
            try unmanaged.ensureTotalCapacity(self.allocator, new_capacity);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            var unmanaged = self.toUnmanaged();
            unmanaged.clearRetainingCapacity();
            self.syncFromUnmanaged(unmanaged);
        }

        pub fn clearAndFree(self: *Self) void {
            var unmanaged = self.toUnmanaged();
            unmanaged.clearAndFree(self.allocator);
            self.syncFromUnmanaged(unmanaged);
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            var unmanaged = self.toUnmanaged();
            const removed = unmanaged.orderedRemove(index);
            self.syncFromUnmanaged(unmanaged);
            return removed;
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            var unmanaged = self.toUnmanaged();
            const removed = unmanaged.swapRemove(index);
            self.syncFromUnmanaged(unmanaged);
            return removed;
        }

        pub fn pop(self: *Self) ?T {
            var unmanaged = self.toUnmanaged();
            const value = unmanaged.pop();
            self.syncFromUnmanaged(unmanaged);
            return value;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        fn appendWrite(self: *Self, bytes: []const u8) std.mem.Allocator.Error!usize {
            try self.appendSlice(bytes);
            return bytes.len;
        }

        fn toUnmanaged(self: *const Self) Unmanaged {
            return .{
                .items = self.items,
                .capacity = self.capacity,
            };
        }

        fn syncFromUnmanaged(self: *Self, unmanaged: Unmanaged) void {
            self.items = unmanaged.items;
            self.capacity = unmanaged.capacity;
        }
    };
}
