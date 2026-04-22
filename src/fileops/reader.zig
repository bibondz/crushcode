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
        var raw = try self.read(path);
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const test_alloc = testing.allocator;

test "FileReader.init sets allocator" {
    const reader = FileReader.init(test_alloc);
    try testing.expectEqual(test_alloc, reader.allocator);
}

test "FileReader.read existing file returns correct content" {
    const tmp_path = "/tmp/crushcode_test_read_existing.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello world");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.read(tmp_path);
    defer content.deinit();

    try testing.expectEqualStrings("hello world", content.content);
    try testing.expectEqual(@as(usize, 11), content.size);
    try testing.expectEqualStrings(tmp_path, content.path);
}

test "FileReader.read non-existent file returns FileNotFound" {
    var reader = FileReader.init(test_alloc);
    const result = reader.read("/tmp/crushcode_test_nonexistent_99999.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "FileReader.read directory returns NotAFile" {
    var reader = FileReader.init(test_alloc);
    const result = reader.read("/tmp");
    try testing.expectError(error.NotAFile, result);
}

test "FileReader.read empty file returns empty content" {
    const tmp_path = "/tmp/crushcode_test_read_empty.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.read(tmp_path);
    defer content.deinit();

    try testing.expectEqualStrings("", content.content);
    try testing.expectEqual(@as(usize, 0), content.size);
}

test "FileReader.read file size matches content length" {
    const expected = "The quick brown fox jumps over the lazy dog";
    const tmp_path = "/tmp/crushcode_test_read_size.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll(expected);
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.read(tmp_path);
    defer content.deinit();

    try testing.expectEqual(@as(usize, expected.len), content.size);
    try testing.expectEqual(content.content.len, content.size);
}

test "FileReader.readMultiple reads two files successfully" {
    const path_a = "/tmp/crushcode_test_multi_a.txt";
    const path_b = "/tmp/crushcode_test_multi_b.txt";

    const fa = try std.fs.cwd().createFile(path_a, .{});
    try fa.writeAll("content A");
    fa.close();

    const fb = try std.fs.cwd().createFile(path_b, .{});
    try fb.writeAll("content B is longer");
    fb.close();

    defer std.fs.cwd().deleteFile(path_a) catch {};
    defer std.fs.cwd().deleteFile(path_b) catch {};

    var reader = FileReader.init(test_alloc);
    const paths = [_][]const u8{ path_a, path_b };
    const results = try reader.readMultiple(&paths);
    defer {
        for (results) |*item| {
            item.deinit();
            test_alloc.free(item.path);
        }
        test_alloc.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("content A", results[0].content);
    try testing.expectEqualStrings("content B is longer", results[1].content);
}

test "FileReader.readMultiple with one missing file returns error" {
    const path_a = "/tmp/crushcode_test_multi_existent.txt";
    const path_b = "/tmp/crushcode_test_multi_nonexistent_99999.txt";

    const fa = try std.fs.cwd().createFile(path_a, .{});
    try fa.writeAll("exists");
    fa.close();
    defer std.fs.cwd().deleteFile(path_a) catch {};

    var reader = FileReader.init(test_alloc);
    const paths = [_][]const u8{ path_a, path_b };
    const result = reader.readMultiple(&paths);
    try testing.expectError(error.FileNotFound, result);
}

test "FileReader.readWithHashlines formats lines with hash and line number" {
    const tmp_path = "/tmp/crushcode_test_hashlines.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello\nworld\n");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.readWithHashlines(tmp_path);
    defer content.deinit();

    // Verify the output contains hashline-formatted lines
    // Format: "  LINE#HASH | content\n"
    try testing.expect(content.size > 0);

    // Verify format structure: each line should have " #" and " | "
    try testing.expect(std.mem.indexOf(u8, content.content, " | ") != null);
    try testing.expect(std.mem.indexOf(u8, content.content, "#") != null);

    // Verify line numbers appear
    try testing.expect(std.mem.indexOf(u8, content.content, "1#") != null);
    try testing.expect(std.mem.indexOf(u8, content.content, "2#") != null);
}

test "FileReader.readWithHashlines empty file produces minimal output" {
    const tmp_path = "/tmp/crushcode_test_hashlines_empty.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.readWithHashlines(tmp_path);
    defer content.deinit();

    // Empty file: splitScalar on "" yields one empty string element
    // The trimmed empty string still produces a hashline entry for line 1
    // FNV-1a of "" = FNV offset = 0x811c9dc5
    try testing.expect(std.mem.indexOf(u8, content.content, "1#811c9dc5") != null);
    try testing.expect(std.mem.indexOf(u8, content.content, " | ") != null);
}

test "FileContent.deinit frees content without crash" {
    const tmp_path = "/tmp/crushcode_test_deinit.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("deinit test data");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reader = FileReader.init(test_alloc);
    var content = try reader.read(tmp_path);

    // Verify content is valid before deinit
    try testing.expectEqualStrings("deinit test data", content.content);

    // Store path pointer to free after deinit (deinit only frees content, not path)
    const path = content.path;
    content.deinit();
    test_alloc.free(path);

    // If we reach here without crash or leak detection failure, test passes
}
