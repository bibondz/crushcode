const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");

const Allocator = std.mem.Allocator;

pub const ConfidenceLevel = enum { high, medium, low, unknown };

pub const DetectionMethod = enum { magic_bytes, content_pattern, extension, unknown };

pub const FileContentType = struct {
    allocator: Allocator,
    label: []const u8,
    mime_type: []const u8,
    description: []const u8,
    group: []const u8,
    is_text: bool,
    extensions: [][]const u8,

    pub fn deinit(self: *FileContentType) void {
        self.allocator.free(self.label);
        self.allocator.free(self.mime_type);
        self.allocator.free(self.description);
        self.allocator.free(self.group);
        for (self.extensions) |e| self.allocator.free(e);
        self.allocator.free(self.extensions);
    }
};

pub const DetectionResult = struct {
    allocator: Allocator,
    file_path: []const u8,
    content_type: ?*FileContentType,
    confidence: f64,
    confidence_level: ConfidenceLevel,
    detected_by: DetectionMethod,
    file_size: u64,

    pub fn deinit(self: *DetectionResult) void {
        self.allocator.free(self.file_path);
        // Note: content_type is owned by FileDetector, not freed here
    }
};

const MagicSignature = struct {
    offset: u32,
    bytes: []const u8,
    label: []const u8,
};

pub const FileDetector = struct {
    allocator: Allocator,
    known_types: array_list_compat.ArrayList(*FileContentType),
    magic_sigs: array_list_compat.ArrayList(MagicSignature),
    read_size: u32,

    pub fn init(allocator: Allocator) !FileDetector {
        var d = FileDetector{
            .allocator = allocator,
            .known_types = array_list_compat.ArrayList(*FileContentType).init(allocator),
            .magic_sigs = array_list_compat.ArrayList(MagicSignature).init(allocator),
            .read_size = 2048,
        };
        try d.registerDefaults();
        return d;
    }

    pub fn deinit(self: *FileDetector) void {
        for (self.known_types.items) |ct| {
            ct.deinit();
            self.allocator.destroy(ct);
        }
        self.known_types.deinit();
        self.magic_sigs.deinit();
    }

    fn regType(self: *FileDetector, label: []const u8, mime: []const u8, desc: []const u8, group: []const u8, is_text: bool, exts: []const []const u8) !*FileContentType {
        const ct = try self.allocator.create(FileContentType);
        const ext_list = try self.allocator.alloc([]const u8, exts.len);
        for (exts, 0..) |e, i| ext_list[i] = try self.allocator.dupe(u8, e);
        ct.* = .{
            .allocator = self.allocator,
            .label = try self.allocator.dupe(u8, label),
            .mime_type = try self.allocator.dupe(u8, mime),
            .description = try self.allocator.dupe(u8, desc),
            .group = try self.allocator.dupe(u8, group),
            .is_text = is_text,
            .extensions = ext_list,
        };
        try self.known_types.append(ct);
        return ct;
    }

    fn regMagic(self: *FileDetector, offset: u32, bytes: []const u8, label: []const u8) !void {
        try self.magic_sigs.append(.{ .offset = offset, .bytes = bytes, .label = label });
    }

    fn registerDefaults(self: *FileDetector) !void {
        // Code types
        _ = try self.regType("zig", "text/x-zig", "Zig source", "code", true, &.{"zig"});
        _ = try self.regType("python", "text/x-python", "Python source", "code", true, &.{ "py", "pyi" });
        _ = try self.regType("javascript", "application/javascript", "JavaScript source", "code", true, &.{ "js", "mjs" });
        _ = try self.regType("typescript", "application/typescript", "TypeScript source", "code", true, &.{ "ts", "tsx" });
        _ = try self.regType("rust", "text/rust", "Rust source", "code", true, &.{"rs"});
        _ = try self.regType("go", "text/x-go", "Go source", "code", true, &.{"go"});
        _ = try self.regType("c", "text/x-c", "C source", "code", true, &.{ "c", "h" });
        _ = try self.regType("cpp", "text/x-c++", "C++ source", "code", true, &.{ "cpp", "hpp", "cc", "cxx" });
        _ = try self.regType("java", "text/x-java", "Java source", "code", true, &.{"java"});
        _ = try self.regType("csharp", "text/x-csharp", "C# source", "code", true, &.{ "cs", "csx" });
        _ = try self.regType("ruby", "text/x-ruby", "Ruby source", "code", true, &.{"rb"});
        _ = try self.regType("shell", "text/x-shellscript", "Shell script", "code", true, &.{ "sh", "bash", "zsh" });
        _ = try self.regType("sql", "application/sql", "SQL", "code", true, &.{ "sql", "pgsql" });
        _ = try self.regType("makefile", "text/x-makefile", "Makefile", "code", true, &.{"mk"});
        _ = try self.regType("dockerfile", "text/x-dockerfile", "Dockerfile", "code", true, &.{});
        _ = try self.regType("toml", "application/toml", "TOML", "code", true, &.{"toml"});

        // Text types
        _ = try self.regType("json", "application/json", "JSON", "text", true, &.{"json"});
        _ = try self.regType("yaml", "application/yaml", "YAML", "text", true, &.{ "yaml", "yml" });
        _ = try self.regType("xml", "application/xml", "XML", "text", true, &.{ "xml", "svg", "xsl" });
        _ = try self.regType("html", "text/html", "HTML", "text", true, &.{ "html", "htm" });
        _ = try self.regType("css", "text/css", "CSS", "text", true, &.{ "css", "scss" });
        _ = try self.regType("markdown", "text/markdown", "Markdown", "text", true, &.{ "md", "mdx" });
        _ = try self.regType("csv", "text/csv", "CSV", "text", true, &.{"csv"});
        _ = try self.regType("ini", "text/x-ini", "INI config", "text", true, &.{ "ini", "cfg" });
        _ = try self.regType("diff", "text/x-diff", "Diff/Patch", "text", true, &.{ "diff", "patch" });
        _ = try self.regType("plaintext", "text/plain", "Plain text", "text", true, &.{"txt"});

        // Image types
        _ = try self.regType("png", "image/png", "PNG image", "image", false, &.{"png"});
        _ = try self.regType("jpeg", "image/jpeg", "JPEG image", "image", false, &.{ "jpg", "jpeg" });
        _ = try self.regType("gif", "image/gif", "GIF image", "image", false, &.{"gif"});
        _ = try self.regType("bmp", "image/bmp", "BMP image", "image", false, &.{"bmp"});
        _ = try self.regType("webp", "image/webp", "WebP image", "image", false, &.{"webp"});

        // Binary types
        _ = try self.regType("pdf", "application/pdf", "PDF document", "document", false, &.{"pdf"});
        _ = try self.regType("zip", "application/zip", "ZIP archive", "archive", false, &.{ "zip", "jar" });
        _ = try self.regType("gzip", "application/gzip", "Gzip archive", "archive", false, &.{ "gz", "tgz" });
        _ = try self.regType("elf", "application/x-elf", "ELF binary", "binary", false, &.{});
        _ = try self.regType("mp4", "video/mp4", "MP4 video", "video", false, &.{ "mp4", "m4v" });
        _ = try self.regType("mp3", "audio/mpeg", "MP3 audio", "audio", false, &.{"mp3"});

        // Magic bytes
        try self.regMagic(0, "\x89PNG\r\n\x1a\n", "png");
        try self.regMagic(0, "\xff\xd8\xff", "jpeg");
        try self.regMagic(0, "GIF87a", "gif");
        try self.regMagic(0, "GIF89a", "gif");
        try self.regMagic(0, "BM", "bmp");
        try self.regMagic(0, "RIFF", "webp"); // simplified
        try self.regMagic(0, "PK\x03\x04", "zip");
        try self.regMagic(0, "%PDF-", "pdf");
        try self.regMagic(0, "\x7fELF", "elf");
        try self.regMagic(0, "\x1f\x8b", "gzip");
    }

    pub fn detectFile(self: *FileDetector, file_path: []const u8) !DetectionResult {
        const content = blk: {
            const file = std.fs.cwd().openFile(file_path, .{}) catch {
                break :blk @as(?[]u8, null);
            };
            defer file.close();
            const stat = file.stat() catch {
                break :blk @as(?[]u8, null);
            };
            const read_len = @min(@as(usize, @intCast(stat.size)), self.read_size);
            const buf = self.allocator.alloc(u8, read_len) catch {
                break :blk @as(?[]u8, null);
            };
            const bytes_read = file.readAll(buf) catch {
                self.allocator.free(buf);
                break :blk @as(?[]u8, null);
            };
            if (bytes_read < buf.len) {
                break :blk @as(?[]u8, buf[0..bytes_read]);
            }
            break :blk @as(?[]u8, buf);
        };

        if (content) |data| {
            defer self.allocator.free(data);
            const ext = std.fs.path.extension(file_path);
            const result = self.detectBytes(data, ext);

            return DetectionResult{
                .allocator = self.allocator,
                .file_path = try self.allocator.dupe(u8, file_path),
                .content_type = result.content_type,
                .confidence = result.confidence,
                .confidence_level = result.confidence_level,
                .detected_by = result.detected_by,
                .file_size = data.len,
            };
        }

        return DetectionResult{
            .allocator = self.allocator,
            .file_path = try self.allocator.dupe(u8, file_path),
            .content_type = null,
            .confidence = 0.0,
            .confidence_level = .unknown,
            .detected_by = .unknown,
            .file_size = 0,
        };
    }

    pub const ByteResult = struct {
        content_type: ?*FileContentType,
        confidence: f64,
        confidence_level: ConfidenceLevel,
        detected_by: DetectionMethod,
    };

    pub fn detectBytes(self: *FileDetector, bytes: []const u8, ext_hint: []const u8) ByteResult {
        // Layer 1: Magic bytes
        if (self.detectMagic(bytes)) |result| return result;

        // Layer 2: Content patterns (only for text)
        if (self.isLikelyText(bytes)) {
            if (self.detectContentPattern(bytes)) |result| return result;
        }

        // Layer 3: Extension fallback
        if (ext_hint.len > 1) {
            const ext_lower = ext_hint[1..]; // skip the dot
            if (self.findByExtension(ext_lower)) |ct| {
                return .{ .content_type = ct, .confidence = 0.5, .confidence_level = .low, .detected_by = .extension };
            }
        }

        return .{ .content_type = null, .confidence = 0.0, .confidence_level = .unknown, .detected_by = .unknown };
    }

    fn detectMagic(self: *FileDetector, bytes: []const u8) ?ByteResult {
        for (self.magic_sigs.items) |sig| {
            const end = sig.offset + sig.bytes.len;
            if (bytes.len < end) continue;
            if (std.mem.eql(u8, bytes[sig.offset..end], sig.bytes)) {
                if (self.findByLabel(sig.label)) |ct| {
                    return .{ .content_type = ct, .confidence = 0.99, .confidence_level = .high, .detected_by = .magic_bytes };
                }
            }
        }
        return null;
    }

    fn detectContentPattern(self: *FileDetector, bytes: []const u8) ?ByteResult {
        // Zig: const std = @import
        if (std.mem.indexOf(u8, bytes, "@import") != null and std.mem.indexOf(u8, bytes, "pub fn") != null) {
            if (self.findByLabel("zig")) |ct| return .{ .content_type = ct, .confidence = 0.9, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Rust: fn main() + let/println!
        if (std.mem.indexOf(u8, bytes, "fn main") != null and std.mem.indexOf(u8, bytes, "let ") != null) {
            if (self.findByLabel("rust")) |ct| return .{ .content_type = ct, .confidence = 0.88, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Python: def + import / if __name__
        if (std.mem.indexOf(u8, bytes, "def ") != null and std.mem.indexOf(u8, bytes, "import ") != null) {
            if (std.mem.indexOf(u8, bytes, "if __name__") != null or std.mem.indexOf(u8, bytes, "class ") != null) {
                if (self.findByLabel("python")) |ct| return .{ .content_type = ct, .confidence = 0.88, .confidence_level = .high, .detected_by = .content_pattern };
            }
        }
        // Go: package + func
        if (std.mem.indexOf(u8, bytes, "package ") != null and std.mem.indexOf(u8, bytes, "func ") != null) {
            if (self.findByLabel("go")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // TypeScript: interface / type ... =
        if (std.mem.indexOf(u8, bytes, "interface ") != null or (std.mem.indexOf(u8, bytes, "type ") != null and std.mem.indexOf(u8, bytes, " = ") != null)) {
            if (std.mem.indexOf(u8, bytes, ": ") != null and std.mem.indexOf(u8, bytes, "=>") != null) {
                if (self.findByLabel("typescript")) |ct| return .{ .content_type = ct, .confidence = 0.82, .confidence_level = .high, .detected_by = .content_pattern };
            }
        }
        // JavaScript: function/const/=>/require
        if (std.mem.indexOf(u8, bytes, "function ") != null or std.mem.indexOf(u8, bytes, "const ") != null) {
            if (std.mem.indexOf(u8, bytes, "require(") != null or std.mem.indexOf(u8, bytes, "=>") != null) {
                if (self.findByLabel("javascript")) |ct| return .{ .content_type = ct, .confidence = 0.8, .confidence_level = .high, .detected_by = .content_pattern };
            }
        }
        // Java: public class + import java
        if (std.mem.indexOf(u8, bytes, "public class") != null) {
            if (self.findByLabel("java")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // C#: using System + namespace
        if (std.mem.indexOf(u8, bytes, "using System") != null) {
            if (self.findByLabel("csharp")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // C: #include + int main
        if (std.mem.indexOf(u8, bytes, "#include") != null and std.mem.indexOf(u8, bytes, "int main") != null) {
            if (std.mem.indexOf(u8, bytes, "std::") != null) {
                if (self.findByLabel("cpp")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
            }
            if (self.findByLabel("c")) |ct| return .{ .content_type = ct, .confidence = 0.82, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Dockerfile: FROM + RUN
        if (std.mem.indexOf(u8, bytes, "FROM ") != null and std.mem.indexOf(u8, bytes, "RUN ") != null) {
            if (self.findByLabel("dockerfile")) |ct| return .{ .content_type = ct, .confidence = 0.9, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // JSON: starts with { or [
        if (bytes.len > 0 and (bytes[0] == '{' or bytes[0] == '[')) {
            if (std.mem.indexOf(u8, bytes, "\":") != null or std.mem.indexOf(u8, bytes, "\": ") != null) {
                if (self.findByLabel("json")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
            }
        }
        // XML: <?xml or <html
        if (std.mem.startsWith(u8, bytes, "<?xml") or std.mem.startsWith(u8, bytes, "<html")) {
            if (self.findByLabel("xml")) |ct| return .{ .content_type = ct, .confidence = 0.9, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // HTML: <html or <!DOCTYPE html
        if (std.mem.indexOf(u8, bytes, "<html") != null or std.mem.indexOf(u8, bytes, "<!DOCTYPE") != null) {
            if (self.findByLabel("html")) |ct| return .{ .content_type = ct, .confidence = 0.88, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Shell: #!/bin/bash or #!/bin/sh
        if (std.mem.startsWith(u8, bytes, "#!/bin/bash") or std.mem.startsWith(u8, bytes, "#!/bin/sh") or std.mem.startsWith(u8, bytes, "#!/usr/bin/env bash")) {
            if (self.findByLabel("shell")) |ct| return .{ .content_type = ct, .confidence = 0.95, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Python shebang
        if (std.mem.startsWith(u8, bytes, "#!/usr/bin/env python")) {
            if (self.findByLabel("python")) |ct| return .{ .content_type = ct, .confidence = 0.95, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // SQL: SELECT ... FROM
        if (std.mem.indexOf(u8, bytes, "SELECT ") != null and std.mem.indexOf(u8, bytes, " FROM ") != null) {
            if (self.findByLabel("sql")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // TOML: [package] or [dependencies]
        if (std.mem.indexOf(u8, bytes, "[package]") != null or std.mem.indexOf(u8, bytes, "[dependencies]") != null) {
            if (self.findByLabel("toml")) |ct| return .{ .content_type = ct, .confidence = 0.85, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Diff: --- a/ + +++ b/
        if (std.mem.startsWith(u8, bytes, "--- ") and std.mem.indexOf(u8, bytes, "+++ ") != null) {
            if (self.findByLabel("diff")) |ct| return .{ .content_type = ct, .confidence = 0.9, .confidence_level = .high, .detected_by = .content_pattern };
        }
        // Markdown: # heading or ## heading
        if (std.mem.startsWith(u8, bytes, "# ") or std.mem.startsWith(u8, bytes, "## ")) {
            if (self.findByLabel("markdown")) |ct| return .{ .content_type = ct, .confidence = 0.7, .confidence_level = .medium, .detected_by = .content_pattern };
        }
        return null;
    }

    fn isLikelyText(self: *FileDetector, bytes: []const u8) bool {
        _ = self;
        if (bytes.len == 0) return true;
        var null_count: u32 = 0;
        const check_len = @min(bytes.len, 512);
        for (bytes[0..check_len]) |b| {
            if (b == 0) null_count += 1;
        }
        // If more than 10% null bytes, likely binary
        return @as(f64, @floatFromInt(null_count)) / @as(f64, @floatFromInt(check_len)) < 0.1;
    }

    pub fn findByLabel(self: *FileDetector, label: []const u8) ?*FileContentType {
        for (self.known_types.items) |ct| {
            if (std.mem.eql(u8, ct.label, label)) return ct;
        }
        return null;
    }

    fn findByExtension(self: *FileDetector, ext: []const u8) ?*FileContentType {
        for (self.known_types.items) |ct| {
            for (ct.extensions) |e| {
                if (std.mem.eql(u8, e, ext)) return ct;
            }
        }
        return null;
    }

    pub fn detectLanguage(self: *FileDetector, file_path: []const u8) []const u8 {
        const content = blk: {
            const file = std.fs.cwd().openFile(file_path, .{}) catch {
                const ext = std.fs.path.extension(file_path);
                if (ext.len > 1) {
                    if (self.findByExtension(ext[1..])) |ct| return ct.description;
                }
                break :blk @as(?[]u8, null);
            };
            defer file.close();
            const stat = file.stat() catch break :blk @as(?[]u8, null);
            const read_len = @min(@as(usize, @intCast(stat.size)), self.read_size);
            const buf = self.allocator.alloc(u8, read_len) catch break :blk @as(?[]u8, null);
            const bytes_read = file.readAll(buf) catch {
                self.allocator.free(buf);
                break :blk @as(?[]u8, null);
            };
            if (bytes_read < buf.len) break :blk @as(?[]u8, buf[0..bytes_read]);
            break :blk @as(?[]u8, buf);
        };
        defer if (content) |data| self.allocator.free(data);
        if (content) |data| {
            const result = self.detectBytes(data, std.fs.path.extension(file_path));
            if (result.content_type) |ct| return ct.description;
        }
        return "Unknown";
    }
};

// ── Tests ──

const testing = std.testing;

test "FileDetector - magic byte detection PNG" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    const result = d.detectBytes(png_header, ".png");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("png", result.content_type.?.label);
    try testing.expect(result.confidence > 0.9);
    try testing.expect(result.detected_by == .magic_bytes);
}

test "FileDetector - magic byte detection JPEG" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("\xff\xd8\xff\xe0\x00\x10JFIF", ".jpg");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("jpeg", result.content_type.?.label);
    try testing.expect(result.detected_by == .magic_bytes);
}

test "FileDetector - magic byte detection PDF" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("%PDF-1.4 some content", ".pdf");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("pdf", result.content_type.?.label);
}

test "FileDetector - content pattern detection Zig" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("const std = @import(\"std\");\npub fn main() void {}", ".zig");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("zig", result.content_type.?.label);
    try testing.expect(result.detected_by == .content_pattern);
}

test "FileDetector - content pattern detection Python" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("def hello():\n    import os\nif __name__ == \"__main__\":\n    pass", ".py");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("python", result.content_type.?.label);
}

test "FileDetector - content pattern detection Rust" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("fn main() {\n    let x = 1;\n}", ".rs");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("rust", result.content_type.?.label);
}

test "FileDetector - content pattern detection Go" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("package main\n\nfunc main() {\n}", ".go");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("go", result.content_type.?.label);
}

test "FileDetector - content pattern detection Dockerfile" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("FROM ubuntu:22.04\nRUN apt-get update", "");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("dockerfile", result.content_type.?.label);
}

test "FileDetector - extension fallback" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("random binary\x00\x01\x02", ".rb");
    try testing.expect(result.content_type != null);
    try testing.expectEqualStrings("ruby", result.content_type.?.label);
    try testing.expect(result.detected_by == .extension);
    try testing.expect(result.confidence == 0.5);
}

test "FileDetector - unknown file" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    const result = d.detectBytes("some random text without patterns", ".xyz");
    try testing.expect(result.content_type == null);
    try testing.expect(result.detected_by == .unknown);
}

test "FileDetector - isLikelyText" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.isLikelyText("Hello, world!"));
    try testing.expect(!d.isLikelyText("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
}

test "FileDetector - detectLanguage" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    // Test with actual file
    const lang = d.detectLanguage("src/main.zig");
    try testing.expect(std.mem.eql(u8, lang, "Zig source"));
}

test "FileDetector - registers defaults" {
    var d = try FileDetector.init(testing.allocator);
    defer d.deinit();
    try testing.expect(d.known_types.items.len >= 35);
    try testing.expect(d.magic_sigs.items.len >= 10);
    try testing.expect(d.findByLabel("zig") != null);
    try testing.expect(d.findByLabel("python") != null);
    try testing.expect(d.findByLabel("rust") != null);
    try testing.expect(d.findByLabel("png") != null);
}
