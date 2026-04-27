/// Image rendering module for crushcode's TUI.
///
/// Provides Sixel protocol fallback for terminals that don't support Kitty
/// graphics, and a graceful text placeholder for terminals that support
/// neither. Kitty protocol rendering is handled by vaxis directly.
///
/// Sixel reference: https://vt100.net/docs/vt3xx-gp/chapter14.html
const file_compat = @import("file_compat");
const std = @import("std");

// ── Protocol detection ────────────────────────────────────────────────

/// Supported terminal graphics protocols.
pub const GraphicsProtocol = enum {
    kitty,
    sixel,
    none,
};

/// Detect the best available graphics protocol for the current terminal.
///
/// Checks environment variables in priority order:
///   1. TERM_PROGRAM — kitty, ghostty, WezTerm → kitty
///   2. TERM — xterm-kitty → kitty, *sixel* → sixel
///   3. Default → none
pub fn detectProtocol() GraphicsProtocol {
    // TERM_PROGRAM takes priority — it identifies the terminal emulator.
    if (file_compat.getEnv("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "kitty")) return .kitty;
        if (std.mem.eql(u8, tp, "ghostty")) return .kitty; // ghostty supports kitty protocol
        if (std.mem.eql(u8, tp, "WezTerm")) return .kitty; // wezterm supports kitty protocol
    }

    // Fall back to TERM variable.
    if (file_compat.getEnv("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "xterm-kitty") != null) return .kitty;
        if (std.mem.indexOf(u8, term, "sixel") != null) return .sixel;
    }

    return .none;
}

// ── Color quantization helpers ────────────────────────────────────────

/// An RGB color stored as packed u24 for use as a hash map key.
const RgbColor = packed struct(u24) {
    r: u8,
    g: u8,
    b: u8,
};

/// Maximum number of palette entries in a Sixel image.
const max_palette_size: usize = 256;

/// Build a palette of unique colors from RGB pixel data.
/// Populates `palette` with unique colors and `indices` with per-pixel palette indices.
/// Pixels must be `width * height * 3` bytes (RGB, no alpha).
fn buildPalette(
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    pixels: []const u8,
    palette: *std.ArrayList(RgbColor),
    indices: *std.ArrayList(u8),
) !void {
    const pixel_count = @as(usize, width) * @as(usize, height);

    var color_to_index = std.AutoHashMap(RgbColor, u8).init(allocator);
    defer color_to_index.deinit();

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        const r = if (i * 3 + 0 < pixels.len) pixels[i * 3 + 0] else @as(u8, 0);
        const g = if (i * 3 + 1 < pixels.len) pixels[i * 3 + 1] else @as(u8, 0);
        const b = if (i * 3 + 2 < pixels.len) pixels[i * 3 + 2] else @as(u8, 0);
        const color = RgbColor{ .r = r, .g = g, .b = b };

        const entry = try color_to_index.getOrPut(color);
        if (entry.found_existing) {
            try indices.append(allocator, entry.value_ptr.*);
        } else {
            const idx: u8 = @intCast(@min(palette.items.len, max_palette_size - 1));
            try palette.append(allocator, color);
            entry.value_ptr.* = idx;
            try indices.append(allocator, idx);
        }

        // If palette is full, stop adding new entries and use nearest-color matching.
        if (palette.items.len >= max_palette_size) {
            var j: usize = i + 1;
            while (j < pixel_count) : (j += 1) {
                const rr = if (j * 3 + 0 < pixels.len) pixels[j * 3 + 0] else @as(u8, 0);
                const gg = if (j * 3 + 1 < pixels.len) pixels[j * 3 + 1] else @as(u8, 0);
                const bb = if (j * 3 + 2 < pixels.len) pixels[j * 3 + 2] else @as(u8, 0);
                const cc = RgbColor{ .r = rr, .g = gg, .b = bb };
                if (color_to_index.get(cc)) |existing_idx| {
                    try indices.append(allocator, existing_idx);
                } else {
                    try indices.append(allocator, findNearestPaletteIndex(palette.items, cc));
                }
            }
            return;
        }
    }
}

/// Find the nearest color in the palette using Euclidean distance in RGB space.
fn findNearestPaletteIndex(palette: []const RgbColor, target: RgbColor) u8 {
    var best_idx: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);

    for (palette, 0..) |color, idx| {
        const dr: u32 = @abs(@as(i32, @intCast(color.r)) - @as(i32, @intCast(target.r)));
        const dg: u32 = @abs(@as(i32, @intCast(color.g)) - @as(i32, @intCast(target.g)));
        const db: u32 = @abs(@as(i32, @intCast(color.b)) - @as(i32, @intCast(target.b)));
        const dist = dr * dr + dg * dg + db * db;
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = @intCast(idx);
        }
    }

    return best_idx;
}

// ── Sixel encoder ─────────────────────────────────────────────────────

/// Encodes RGB pixel data into Sixel format for terminal display.
///
/// Sixel encodes images as 6-pixel-high vertical bands. Each Sixel
/// character encodes 6 vertical pixels as a bitmask added to ASCII 63.
/// The image is processed top-to-bottom in bands of 6 rows.
pub const SixelEncoder = struct {
    allocator: std.mem.Allocator,

    /// Initialize a new SixelEncoder.
    pub fn init(allocator: std.mem.Allocator) SixelEncoder {
        return .{ .allocator = allocator };
    }

    /// Encode raw RGB pixel data as a Sixel string.
    ///
    /// `pixels` must be `width * height * 3` bytes in RGB order.
    /// Returns an owned slice containing the Sixel escape sequence.
    pub fn encodeRgb(self: SixelEncoder, width: u16, height: u16, pixels: []const u8) ![]const u8 {
        if (width == 0 or height == 0 or pixels.len == 0) return self.allocator.dupe(u8, "");

        var buf = try std.ArrayList(u8).initCapacity(self.allocator, pixels.len);
        const alloc = self.allocator;
        errdefer buf.deinit(alloc);

        // Build palette and per-pixel palette indices.
        var palette: std.ArrayList(RgbColor) = .{};
        defer palette.deinit(alloc);
        var indices: std.ArrayList(u8) = .{};
        defer indices.deinit(alloc);

        buildPalette(alloc, width, height, pixels, &palette, &indices) catch
            return self.allocator.dupe(u8, "");

        if (palette.items.len == 0) return self.allocator.dupe(u8, "");

        // DCS introducer: ESC P q  (Start of Sixel)
        try buf.appendSlice(alloc, "\x1bPq");

        // Define palette: # Pc ; 2 ; R ; G ; B
        // R, G, B values are scaled to 0-100 range per Sixel convention.
        for (palette.items, 0..) |color, idx| {
            const r_scaled: u8 = @intCast(@divTrunc(@as(u16, color.r) * 100, 255));
            const g_scaled: u8 = @intCast(@divTrunc(@as(u16, color.g) * 100, 255));
            const b_scaled: u8 = @intCast(@divTrunc(@as(u16, color.b) * 100, 255));
            try buf.writer(alloc).print("#{d};2;{d};{d};{d}", .{ idx, r_scaled, g_scaled, b_scaled });
        }

        // Process image in 6-pixel-high bands
        const w: usize = width;
        const h: usize = height;
        const num_bands = (h + 5) / 6;

        for (0..num_bands) |band| {
            if (band > 0) {
                // `-` advances to next band (moves cursor down 6 pixels)
                try buf.append(alloc, '-');
            }

            // For each palette color, emit a Sixel row across all columns.
            // Only emit colors that actually appear in this band.
            for (palette.items, 0..) |_, color_idx| {
                const ci: u8 = @intCast(color_idx);
                var color_used = false;

                // Check if this color appears in the current band
                for (0..w) |x| {
                    for (0..6) |row_in_band| {
                        const y = band * 6 + row_in_band;
                        if (y >= h) break;
                        const pix_idx = y * w + x;
                        if (pix_idx < indices.items.len and indices.items[pix_idx] == ci) {
                            color_used = true;
                            break;
                        }
                    }
                    if (color_used) break;
                }

                if (!color_used) continue;

                // Select color
                try buf.writer(alloc).print("#{d}", .{ci});

                for (0..w) |x| {
                    // Build 6-bit mask for this column in the current band
                    var mask: u6 = 0;
                    for (0..6) |row_in_band| {
                        const y = band * 6 + row_in_band;
                        if (y >= h) break;
                        const pix_idx = y * w + x;
                        if (pix_idx < indices.items.len and indices.items[pix_idx] == ci) {
                            mask |= @as(u6, 1) << @intCast(row_in_band);
                        }
                    }

                    // Sixel character = ASCII 63 (?) + bitmask
                    try buf.append(alloc, @as(u8, 63) + @as(u8, mask));

                    // Carriage return within band (move to next column)
                    if (x + 1 < w) {
                        try buf.append(alloc, '$');
                    }
                }
            }
        }

        // String Terminator: ESC \
        try buf.appendSlice(alloc, "\x1b\\");

        return buf.toOwnedSlice(alloc);
    }
};

// ── Text placeholder ──────────────────────────────────────────────────

/// Format a text placeholder box for terminals without graphics support.
///
/// Returns a string like:
/// ```
/// ┌─────────────────┐
/// │ 🖼 image.png     │
/// │ 800×600         │
/// └─────────────────┘
/// ```
pub fn formatPlaceholder(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    width: u16,
    height: u16,
) ![]const u8 {
    // Extract just the filename for display
    const filename = std.fs.path.basename(file_path);

    // Calculate inner width (filename + icon + some padding)
    const label = "🖼 ";
    const inner_w = @max(filename.len + label.len + 2, 16);

    // Size string like "800×600"
    var size_buf: [64]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}×{d}", .{ width, height }) catch "??×??";

    // Build box
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const alloc = allocator;

    // Top border
    try buf.appendSlice(alloc, "┌");
    {
        var i: usize = 0;
        while (i < inner_w) : (i += 1) {
            try buf.appendSlice(alloc, "─");
        }
    }
    try buf.appendSlice(alloc, "┐\n");

    // First line: icon + filename
    try buf.appendSlice(alloc, "│ ");
    try buf.appendSlice(alloc, label);
    try buf.appendSlice(alloc, filename);
    const first_content_len = label.len + filename.len;
    if (first_content_len < inner_w) {
        var i: usize = 0;
        while (i < inner_w - first_content_len) : (i += 1) {
            try buf.append(alloc, ' ');
        }
    }
    try buf.appendSlice(alloc, " │\n");

    // Second line: dimensions
    try buf.appendSlice(alloc, "│ ");
    try buf.appendSlice(alloc, size_str);
    const second_content_len = size_str.len;
    if (second_content_len < inner_w) {
        var i: usize = 0;
        while (i < inner_w - second_content_len) : (i += 1) {
            try buf.append(alloc, ' ');
        }
    }
    try buf.appendSlice(alloc, " │\n");

    // Bottom border
    try buf.appendSlice(alloc, "└");
    {
        var i: usize = 0;
        while (i < inner_w) : (i += 1) {
            try buf.appendSlice(alloc, "─");
        }
    }
    try buf.appendSlice(alloc, "┘\n");

    return buf.toOwnedSlice(alloc);
}

// ── Chat display formatter ────────────────────────────────────────────

/// Format image metadata for display in a chat message.
///
/// For kitty: returns a text marker (vaxis renders the actual image).
/// For sixel: returns a text marker (sixel is rendered separately).
/// For none:  returns the box-drawing placeholder with file size.
pub fn formatImageForChat(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    format: []const u8,
    width: u16,
    height: u16,
    file_size: u64,
    protocol: GraphicsProtocol,
) ![]const u8 {
    const filename = std.fs.path.basename(file_path);

    switch (protocol) {
        .kitty => {
            // Vaxis handles actual rendering — return a marker
            return std.fmt.allocPrint(allocator, "[image: {s} ({d}x{d} {s})]", .{ filename, width, height, format });
        },
        .sixel => {
            // Sixel rendering happens separately via SixelEncoder
            return std.fmt.allocPrint(allocator, "[image: {s} ({d}x{d} {s})]", .{ filename, width, height, format });
        },
        .none => {
            // No graphics support — show the text placeholder with file size
            const placeholder = try formatPlaceholder(allocator, file_path, width, height);
            errdefer allocator.free(placeholder);

            var size_buf: [32]u8 = undefined;
            const human_size = formatFileSize(&size_buf, file_size);

            var buf: std.ArrayList(u8) = .{};
            errdefer buf.deinit(allocator);
            const alloc = allocator;

            try buf.appendSlice(alloc, placeholder);
            allocator.free(placeholder);

            // Append file size line
            try buf.appendSlice(alloc, "  ");
            try buf.appendSlice(alloc, human_size);
            try buf.append(alloc, '\n');

            return buf.toOwnedSlice(alloc);
        },
    }
}

/// Format a file size in human-readable form (e.g., "45KB", "1.2MB").
fn formatFileSize(buf: *[32]u8, size: u64) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d}B", .{size}) catch "??B";
    } else if (size < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d}KB", .{size / 1024}) catch "??KB";
    } else if (size < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d}MB", .{size / (1024 * 1024)}) catch "??MB";
    } else {
        return std.fmt.bufPrint(buf, "{d}GB", .{size / (1024 * 1024 * 1024)}) catch "??GB";
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "detectProtocol returns a value without crashing" {
    // In a test environment TERM/TERM_PROGRAM may or may not be set.
    const proto = detectProtocol();
    _ = proto;
}

test "SixelEncoder encodes empty pixels" {
    const allocator = std.testing.allocator;
    var encoder = SixelEncoder.init(allocator);
    const result = try encoder.encodeRgb(0, 0, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "SixelEncoder encodes a small image" {
    const allocator = std.testing.allocator;
    var encoder = SixelEncoder.init(allocator);

    // 2x2 red image
    const pixels = [_]u8{
        255, 0, 0, // pixel (0,0) red
        255, 0, 0, // pixel (1,0) red
        255, 0, 0, // pixel (0,1) red
        255, 0, 0, // pixel (1,1) red
    };
    const result = try encoder.encodeRgb(2, 2, &pixels);
    defer allocator.free(result);

    // Should start with DCS and end with ST (ESC \)
    try std.testing.expect(result.len > 4);
    try std.testing.expectEqualStrings("\x1bPq", result[0..3]);
    try std.testing.expectEqualStrings("\x1b\\", result[result.len - 2 ..]);
}

test "formatPlaceholder produces box drawing output" {
    const allocator = std.testing.allocator;
    const result = try formatPlaceholder(allocator, "test.png", 800, 600);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "800×600") != null);
}

test "formatImageForChat kitty returns marker" {
    const allocator = std.testing.allocator;
    const result = try formatImageForChat(allocator, "photo.png", "png", 100, 200, 4096, .kitty);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "[image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "photo.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "100x200") != null);
}

test "formatImageForChat none returns placeholder" {
    const allocator = std.testing.allocator;
    const result = try formatImageForChat(allocator, "img.jpg", "jpeg", 640, 480, 2048, .none);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "img.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
}

test "formatFileSize formats correctly" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("512B", formatFileSize(&buf, 512));
    try std.testing.expectEqualStrings("1KB", formatFileSize(&buf, 1024));
    try std.testing.expectEqualStrings("2MB", formatFileSize(&buf, 2 * 1024 * 1024));
    try std.testing.expectEqualStrings("1GB", formatFileSize(&buf, 1024 * 1024 * 1024));
}
