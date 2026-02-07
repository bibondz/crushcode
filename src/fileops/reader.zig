const std = @import("std");

pub const FileReadError = error{
    FileNotFound,
    ReadError,
    NotAFile,
    PermissionDenied,
};

pub const FileContent = struct {
    path: []const u8,
    content: []const u8,
    size: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FileContent) void {
        self.allocator.free(self.content);
    }

    pub fn print(self: *const FileContent) void {
        std.debug.print("=== {s} ({d} bytes) ===\n\n", .{ self.path, self.size });
        std.debug.print("{s}\n", .{self.content});
    }
};

pub const FileReader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileReader {
        return FileReader{ .allocator = allocator };
    }

    pub fn read(self: *FileReader, path: []const u8) !FileContent {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) {
            return FileReadError.NotAFile;
        }

        const content = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(content);

        const bytes_read = try file.readAll(content);
        if (bytes_read != stat.size) {
            return FileReadError.ReadError;
        }

        return FileContent{
            .path = try self.allocator.dupe(u8, path),
            .content = content,
            .size = stat.size,
            .allocator = self.allocator,
        };
    }

    pub fn readMultiple(self: *FileReader, paths: []const []const u8) ![]FileContent {
        var results = std.ArrayListUnmanaged(FileContent){};
        try results.ensureTotalCapacity(self.allocator, paths.len);
        errdefer {
            for (results.items) |*item| {
                item.deinit();
                self.allocator.free(item.path);
            }
            results.deinit(self.allocator);
        }

        for (paths) |path| {
            const content = try self.read(path);
            results.appendAssumeCapacity(content);
        }

        return results.toOwnedSlice(self.allocator);
    }
};
