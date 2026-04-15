const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

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
        const stdout = file_compat.File.stdout().writer();
        stdout.print("=== {s} ({d} bytes) ===\n\n", .{ self.path, self.size }) catch {};
        stdout.print("{s}\n", .{self.content}) catch {};
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

    /// Read a file and annotate each line with content hash (hashline format)
    /// Output format: "  LINE#HASH | actual content"
    pub fn readWithHashlines(self: *FileReader, path: []const u8) !FileContent {
        const raw = try self.read(path);
        errdefer raw.deinit();

        var output = array_list_compat.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const FNV_OFFSET: u32 = 2166136261;
        const FNV_PRIME: u32 = 16777619;

        var lines = std.mem.splitScalar(u8, raw.content, '\n');
        var line_num: u32 = 1;

        while (lines.next()) |line| {
            // Compute FNV-1a hash of trimmed line
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            var h: u32 = FNV_OFFSET;
            for (trimmed) |byte| {
                h ^= @as(u32, byte);
                h *%= FNV_PRIME;
            }

            const formatted = std.fmt.allocPrint(self.allocator, "  {d}#{x:0>8} | {s}\n", .{
                line_num,
                h,
                line,
            }) catch "  (hashline error)\n";
            defer self.allocator.free(formatted);
            output.appendSlice(formatted) catch {};
            line_num += 1;
        }

        const annotated = try output.toOwnedSlice();
        self.allocator.free(raw.content);

        return FileContent{
            .path = raw.path,
            .content = annotated,
            .size = annotated.len,
            .allocator = self.allocator,
        };
    }
};
