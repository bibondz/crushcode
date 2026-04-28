//! Image analysis tool — reads an image file and sends it to a vision-capable
//! AI model for description/analysis. Supports PNG, JPEG, GIF, WebP, BMP.
//!
//! Uses the OpenAI Chat Completions API with image_url content blocks.
//! The tool reads a local image, base64-encodes it, and makes a separate
//! vision API call to get a text description.

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const http_client = @import("http_client");

const Allocator = std.mem.Allocator;

const max_image_bytes: usize = 20 * 1024 * 1024; // 20 MB

/// Supported image extensions.
const supported_exts = &[_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp" };

/// Check if a file path looks like a supported image.
pub fn isSupportedImage(path: []const u8) bool {
    const slice = std.mem.sliceTo(path, 0);
    for (supported_exts) |ext| {
        if (std.mem.endsWith(u8, slice, ext)) return true;
    }
    return false;
}

/// MIME type from extension.
pub fn mimeType(path: []const u8) []const u8 {
    const slice = std.mem.sliceTo(path, 0);
    if (std.mem.endsWith(u8, slice, ".png")) return "image/png";
    if (std.mem.endsWith(u8, slice, ".jpg") or std.mem.endsWith(u8, slice, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, slice, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, slice, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, slice, ".bmp")) return "image/bmp";
    return "application/octet-stream";
}

/// Base64 encode data. Caller owns returned slice.
pub fn base64Encode(allocator: Allocator, data: []const u8) ![]const u8 {
    const out_len = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, out_len);
    return std.base64.standard.Encoder.encode(buf, data);
}

/// Analyze an image file using a vision-capable model.
/// Makes a separate API call with the image as a data URI.
/// Returns a text description of the image content.
pub fn analyzeImage(
    allocator: Allocator,
    image_path: []const u8,
    prompt: []const u8,
    api_base: []const u8,
    api_key: []const u8,
    model: []const u8,
) ![]const u8 {
    if (!isSupportedImage(image_path)) return error.UnsupportedImageFormat;

    // Read image file
    const file = try std.fs.cwd().openFile(image_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > max_image_bytes) return error.ImageTooLarge;

    const image_data = try file.readToEndAlloc(allocator, max_image_bytes);
    defer allocator.free(image_data);

    // Base64 encode
    const b64 = try base64Encode(allocator, image_data);
    defer allocator.free(b64);

    const mime = mimeType(image_path);

    // Build OpenAI-compatible request with vision content blocks
    var body_buf = array_list_compat.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    const w = body_buf.writer();

    // Escape basic JSON special chars in prompt
    try w.writeAll("{\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"messages\":[{\"role\":\"user\",\"content\":[");
    try w.writeAll("{\"type\":\"text\",\"text\":\"");
    try writeJsonEscaped(w, prompt);
    try w.writeAll("\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try w.writeAll(mime);
    try w.writeAll(";base64,");
    try w.writeAll(b64);
    try w.writeAll("\"}}]}],\"max_tokens\":4096}");

    // Build URL
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{api_base});
    defer allocator.free(url);

    // Build headers
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_value },
    };

    // Make HTTP request using the project's http_client
    const response = try http_client.httpPost(allocator, url, headers, body_buf.items);
    defer allocator.free(response.body);

    // Extract content from response JSON
    return extractContentFromJson(allocator, response.body);
}

/// Write a string with JSON escape sequences for special characters.
fn writeJsonEscaped(w: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
}

/// Simple extraction of "content" value from a Chat Completions response.
/// Handles basic JSON escape sequences.
fn extractContentFromJson(allocator: Allocator, json: []const u8) ![]const u8 {
    // Find "content" key in response
    if (std.mem.indexOf(u8, json, "\"content\"")) |content_pos| {
        const after = json[content_pos + 9 ..];
        var i: usize = 0;
        // Skip to colon
        while (i < after.len and after[i] != ':') i += 1;
        if (i < after.len) i += 1;
        // Skip whitespace
        while (i < after.len and after[i] == ' ') i += 1;
        // Expect opening quote
        if (i < after.len and after[i] == '"') {
            i += 1;
            const start = i;
            while (i < after.len and after[i] != '"') {
                if (after[i] == '\\' and i + 1 < after.len) i += 1;
                i += 1;
            }
            const raw = after[start..i];
            return unescapeJson(allocator, raw);
        }
    }

    return try allocator.dupe(u8, json);
}

/// Unescape basic JSON escape sequences.
fn unescapeJson(allocator: Allocator, raw: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, raw.len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < raw.len) {
        if (raw[src] == '\\' and src + 1 < raw.len) {
            switch (raw[src + 1]) {
                'n' => {
                    result[dst] = '\n';
                    src += 2;
                },
                'r' => {
                    result[dst] = '\r';
                    src += 2;
                },
                't' => {
                    result[dst] = '\t';
                    src += 2;
                },
                '\\' => {
                    result[dst] = '\\';
                    src += 2;
                },
                '"' => {
                    result[dst] = '"';
                    src += 2;
                },
                '/' => {
                    result[dst] = '/';
                    src += 2;
                },
                else => {
                    result[dst] = raw[src];
                    src += 1;
                },
            }
            dst += 1;
        } else {
            result[dst] = raw[src];
            src += 1;
            dst += 1;
        }
    }
    return result[0..dst];
}
