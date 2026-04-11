const std = @import("std");

/// FNV-1a 32-bit hash for content hashline generation
/// Fast, zero dependencies, good collision resistance for line content
pub const Hashline = struct {
    line_number: u32,
    content_hash: u32,

    /// FNV-1a offset basis
    const FNV_OFFSET: u32 = 2166136261;
    /// FNV-1a prime
    const FNV_PRIME: u32 = 16777619;

    /// Generate a 32-bit FNV-1a hash for content
    pub fn hash(content: []const u8) u32 {
        var h: u32 = FNV_OFFSET;
        for (content) |byte| {
            h ^= @as(u32, byte);
            h *%= FNV_PRIME;
        }
        return h;
    }

    /// Generate hash for a line, trimming whitespace for normalization
    pub fn hashLine(line_number: u32, content: []const u8) Hashline {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        return Hashline{
            .line_number = line_number,
            .content_hash = hash(trimmed),
        };
    }

    /// Format hashline as "LINE#HASH" string (8-char hex)
    pub fn format(self: Hashline, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}#{x:0>8}", .{
            self.line_number,
            self.content_hash,
        });
    }

    /// Parse "LINE#HASH" string back into Hashline
    pub fn parse(str: []const u8) !Hashline {
        // Find the # separator
        const sep_idx = std.mem.indexOfScalar(u8, str, '#') orelse return error.InvalidHashline;

        const line_str = str[0..sep_idx];
        const hash_str = str[sep_idx + 1 ..];

        if (line_str.len == 0 or hash_str.len == 0) return error.InvalidHashline;

        const line_number = std.fmt.parseInt(u32, line_str, 10) catch return error.InvalidHashline;
        const content_hash = std.fmt.parseInt(u32, hash_str, 16) catch return error.InvalidHashline;

        return Hashline{
            .line_number = line_number,
            .content_hash = content_hash,
        };
    }

    /// Validate that this hashline matches the actual content
    pub fn validate(self: Hashline, actual_content: []const u8) bool {
        const actual = hashLine(self.line_number, actual_content);
        return actual.content_hash == self.content_hash;
    }

    /// Compare two hashlines for equality
    pub fn eql(a: Hashline, b: Hashline) bool {
        return a.line_number == b.line_number and a.content_hash == b.content_hash;
    }
};

/// Format a full file with hashline annotations
/// Output: "  LINE#HASH | actual content\n"
pub fn formatFileWithHashlines(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 1;

    while (lines.next()) |line| {
        const hl = Hashline.hashLine(line_num, line);
        const formatted = try std.fmt.allocPrint(allocator, "  {d}#{x:0>8} | {s}\n", .{
            hl.line_number,
            hl.content_hash,
            line,
        });
        defer allocator.free(formatted);
        try output.appendSlice(formatted);
        line_num += 1;
    }

    return output.toOwnedSlice();
}

/// Extract just the content from a hashline-annotated line
/// Input: "  42#a3b4c5d6 | const x = 1;"
/// Output: "const x = 1;"
pub fn extractContentFromHashline(line: []const u8) []const u8 {
    // Find the " | " separator
    const sep = std.mem.indexOf(u8, line, " | ") orelse return line;
    return line[sep + 3 ..];
}
