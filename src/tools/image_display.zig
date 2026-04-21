/// Image display tool — reads image files, validates format, extracts metadata.
///
/// Detects image type from magic bytes, parses dimensions where possible
/// (PNG via IHDR, JPEG via SOF markers), and returns structured info.
/// Does NOT render to terminal — that's the TUI layer's job.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ImageInfo = struct {
    file_path: []const u8,
    width: u16,
    height: u16,
    file_size: u64,
    format: []const u8,
    mime_type: []const u8,

    pub fn deinit(self: *const ImageInfo, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.format);
        allocator.free(self.mime_type);
    }
};

/// Number of bytes to read for magic byte detection.
const HEADER_READ_SIZE: usize = 32;

/// Load image metadata from a file on disk.
///
/// Validates the file exists and is readable, detects image format from
/// magic bytes, and parses dimensions for PNG and JPEG formats.
pub fn loadImageInfo(allocator: Allocator, file_path: []const u8) !ImageInfo {
    // Open the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch
        return error.FileNotFound;
    defer file.close();

    // Get file size from stat
    const stat = file.stat() catch
        return error.StatFailed;
    const file_size: u64 = @intCast(stat.size);

    // Read header bytes for magic detection
    var header_buf: [HEADER_READ_SIZE]u8 = undefined;
    const bytes_read = file.preadAll(&header_buf, 0) catch
        return error.ReadFailed;
    const header = header_buf[0..bytes_read];

    // Detect format from magic bytes
    const detected = detectFormat(header);

    // Parse dimensions for supported formats
    var width: u16 = 0;
    var height: u16 = 0;

    if (std.mem.eql(u8, detected.format, "png")) {
        // PNG IHDR chunk starts at byte 16: 4 bytes width + 4 bytes height (big-endian)
        if (bytes_read >= 24) {
            const w32: u32 = std.mem.readInt(u32, @ptrCast(header[16..20]), .big);
            const h32: u32 = std.mem.readInt(u32, @ptrCast(header[20..24]), .big);
            width = if (w32 <= std.math.maxInt(u16)) @intCast(w32) else std.math.maxInt(u16);
            height = if (h32 <= std.math.maxInt(u16)) @intCast(h32) else std.math.maxInt(u16);
        }
    } else if (std.mem.eql(u8, detected.format, "jpeg")) {
        // For JPEG we need to scan further into the file for SOF markers
        parseJpegDimensions(file, &width, &height) catch {};
    }

    // For GIF/BMP/WebP, dimensions remain 0 (to be improved later)

    return ImageInfo{
        .file_path = try allocator.dupe(u8, file_path),
        .width = width,
        .height = height,
        .file_size = file_size,
        .format = try allocator.dupe(u8, detected.format),
        .mime_type = try allocator.dupe(u8, detected.mime_type),
    };
}

/// Detected format info (non-owning slices into static strings).
const DetectedFormat = struct {
    format: []const u8,
    mime_type: []const u8,
};

/// Detect image format from the first bytes of a file.
fn detectFormat(header: []const u8) DetectedFormat {
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (header.len >= 8 and std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n")) {
        return .{ .format = "png", .mime_type = "image/png" };
    }
    // JPEG: FF D8 FF
    if (header.len >= 3 and header[0] == 0xFF and header[1] == 0xD8 and header[2] == 0xFF) {
        return .{ .format = "jpeg", .mime_type = "image/jpeg" };
    }
    // GIF87a
    if (header.len >= 6 and std.mem.eql(u8, header[0..6], "GIF87a")) {
        return .{ .format = "gif", .mime_type = "image/gif" };
    }
    // GIF89a
    if (header.len >= 6 and std.mem.eql(u8, header[0..6], "GIF89a")) {
        return .{ .format = "gif", .mime_type = "image/gif" };
    }
    // BMP: "BM"
    if (header.len >= 2 and std.mem.eql(u8, header[0..2], "BM")) {
        return .{ .format = "bmp", .mime_type = "image/bmp" };
    }
    // WebP: "RIFF" + 4 bytes size + "WEBP"
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return .{ .format = "webp", .mime_type = "image/webp" };
    }
    return .{ .format = "unknown", .mime_type = "application/octet-stream" };
}

/// Parse JPEG dimensions by scanning for SOF0 (xFFC0) or SOF2 (xFFC2) markers.
///
/// JPEG structure: markers are 0xFF followed by marker type byte.
/// SOF markers contain: 2 bytes length, 1 byte precision, 2 bytes height, 2 bytes width (all big-endian).
fn parseJpegDimensions(file: std.fs.File, width: *u16, height: *u16) !void {
    // Read enough data to find SOF markers — typically within first 64KB
    var buf: [65536]u8 = undefined;
    const n = file.preadAll(&buf, 0) catch return error.ReadFailed;
    const data = buf[0..n];

    // Skip the SOI marker (0xFF 0xD8) — start scanning from byte 2
    var pos: usize = 2;
    while (pos + 9 <= data.len) {
        // Look for marker
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }
        const marker = data[pos + 1];

        // SOF0 (Baseline) or SOF2 (Progressive)
        if (marker == 0xC0 or marker == 0xC2) {
            // Structure after marker: 2 bytes length, 1 byte precision, 2 bytes height, 2 bytes width
            if (pos + 9 > data.len) return;
            height.* = std.mem.readInt(u16, @ptrCast(data[pos + 5 .. pos + 7]), .big);
            width.* = std.mem.readInt(u16, @ptrCast(data[pos + 7 .. pos + 9]), .big);
            return;
        }

        // Skip past this marker's payload.
        // Markers 0xD0-0xD9 (RST, SOI, EOI) and 0x00 (stuffing) have no length field.
        if (marker == 0x00 or (marker >= 0xD0 and marker <= 0xD9)) {
            pos += 2;
            continue;
        }

        // Read marker segment length (includes the 2 length bytes themselves)
        if (pos + 4 > data.len) return;
        const seg_len = std.mem.readInt(u16, @ptrCast(data[pos + 2 .. pos + 4]), .big);
        if (seg_len < 2) return; // malformed
        pos += 2 + @as(usize, seg_len);
    }
}

/// Format image info as a human-readable summary string.
///
/// Returns an allocator-owned string with metadata details.
pub fn formatImageInfo(allocator: Allocator, info: *const ImageInfo) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("Image: {s}\n", .{info.file_path});
    try buf.writer(allocator).print("  Format:   {s}\n", .{info.format});
    try buf.writer(allocator).print("  MIME:     {s}\n", .{info.mime_type});

    if (info.width > 0 and info.height > 0) {
        try buf.writer(allocator).print("  Size:     {d}x{d} pixels\n", .{ info.width, info.height });
    } else {
        try buf.appendSlice(allocator, "  Size:     unknown\n");
    }

    try buf.writer(allocator).print("  File:     {d} bytes", .{info.file_size});

    // Human-readable file size
    if (info.file_size >= 1024 * 1024) {
        try buf.writer(allocator).print(" ({d:.1} MB)", .{@as(f64, @floatFromInt(info.file_size)) / 1024.0 / 1024.0});
    } else if (info.file_size >= 1024) {
        try buf.writer(allocator).print(" ({d:.1} KB)", .{@as(f64, @floatFromInt(info.file_size)) / 1024.0});
    }

    return buf.toOwnedSlice(allocator);
}

/// Check if a file path has a recognized image extension.
///
/// Used for quick filtering before attempting to read magic bytes.
pub fn isImageFile(file_path: []const u8) bool {
    const ext = std.fs.path.extension(file_path);
    if (ext.len < 2) return false;
    const lower = ext[1..]; // skip the dot

    const known = [_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "webp" };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(lower, k)) return true;
    }
    return false;
}

// ── Tests ──

const testing = std.testing;

test "detectFormat PNG" {
    const header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "png"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/png"));
}

test "detectFormat JPEG" {
    const header = "\xff\xd8\xff\xe0\x00\x10JFIF";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "jpeg"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/jpeg"));
}

test "detectFormat GIF87a" {
    const header = "GIF87a\x00\x00\x00";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "gif"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/gif"));
}

test "detectFormat GIF89a" {
    const header = "GIF89a\x00\x00\x00";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "gif"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/gif"));
}

test "detectFormat BMP" {
    const header = "BM\x00\x00\x00";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "bmp"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/bmp"));
}

test "detectFormat WebP" {
    const header = "RIFF\x00\x00\x00\x00WEBP";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "webp"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "image/webp"));
}

test "detectFormat unknown" {
    const header = "random text data";
    const result = detectFormat(header);
    try testing.expect(std.mem.eql(u8, result.format, "unknown"));
    try testing.expect(std.mem.eql(u8, result.mime_type, "application/octet-stream"));
}

test "isImageFile recognizes image extensions" {
    try testing.expect(isImageFile("photo.png"));
    try testing.expect(isImageFile("photo.jpg"));
    try testing.expect(isImageFile("photo.jpeg"));
    try testing.expect(isImageFile("photo.gif"));
    try testing.expect(isImageFile("photo.bmp"));
    try testing.expect(isImageFile("photo.webp"));
    try testing.expect(isImageFile("photo.PNG"));
    try testing.expect(isImageFile("photo.JPG"));
}

test "isImageFile rejects non-image extensions" {
    try testing.expect(!isImageFile("file.txt"));
    try testing.expect(!isImageFile("file.zig"));
    try testing.expect(!isImageFile("Makefile"));
    try testing.expect(!isImageFile("noext"));
}

test "formatImageInfo produces readable output" {
    const info = ImageInfo{
        .file_path = "test.png",
        .width = 800,
        .height = 600,
        .file_size = 1024 * 512,
        .format = "png",
        .mime_type = "image/png",
    };
    const result = try formatImageInfo(testing.allocator, &info);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "test.png") != null);
    try testing.expect(std.mem.indexOf(u8, result, "800x600") != null);
    try testing.expect(std.mem.indexOf(u8, result, "png") != null);
    try testing.expect(std.mem.indexOf(u8, result, "512") != null);
}
