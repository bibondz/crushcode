const std = @import("std");
const string_utils = @import("string_utils");
const Allocator = std.mem.Allocator;

/// Compression level applied to file content based on relevance score.
pub const CompressionLevel = enum {
    /// Full source code — critical files with score > 0.8
    full,
    /// Function signatures + types + doc comments — important files, score 0.5–0.8
    signatures,
    /// Public structs, enums, type declarations only — supporting files, score 0.2–0.5
    @"interface",
    /// One-line per file summary — background files, score < 0.2
    summary,
};

/// Per-level file counts in a compression result.
pub const FilesByLevel = struct {
    full: u32 = 0,
    signatures: u32 = 0,
    @"interface": u32 = 0,
    summary: u32 = 0,
};

/// Result of compressing a set of context files.
pub const CompressionResult = struct {
    original_tokens: u64,
    compressed_tokens: u64,
    ratio: f64,
    files_by_level: FilesByLevel,

    pub fn deinit(self: *CompressionResult, allocator: Allocator, compressed_output: ?[]const u8) void {
        _ = self;
        if (compressed_output) |out| allocator.free(out);
    }
};

/// FileInfo mirror — avoids importing smart_context (standalone module).
/// Reuses the same field layout as smart_context.FileInfo.
pub const FileInfo = struct {
    path: []const u8,
    content: []const u8,
    estimated_tokens: u32,
};

/// Standalone semantic compressor — pattern-based (no AST parsing).
/// Takes file content strings and returns compressed representations.
pub const SemanticCompressor = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SemanticCompressor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SemanticCompressor) void {
        _ = self;
    }

    /// Pick compression level based on a relevance score.
    pub fn levelForScore(score: f64) CompressionLevel {
        if (score > 0.8) return .full;
        if (score > 0.5) return .signatures;
        if (score > 0.2) return .@"interface";
        return .summary;
    }

    /// Apply the specified compression level to file content.
    pub fn compressFile(self: *SemanticCompressor, content: []const u8, level: CompressionLevel) ![]const u8 {
        return switch (level) {
            .full => self.compressFull(content),
            .signatures => try self.compressToSignatures(content),
            .@"interface" => try self.compressToInterface(content),
            .summary => try self.compressToSummary("file", content),
        };
    }

    /// Return content as-is (no compression).
    pub fn compressFull(self: *SemanticCompressor, content: []const u8) []const u8 {
        _ = self;
        return content;
    }

    /// Extract function signatures, type definitions, doc comments, and imports.
    /// Skip function bodies by counting braces.
    pub fn compressToSignatures(self: *SemanticCompressor, content: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        var lines = std.mem.splitSequence(u8, content, "\n");
        var brace_depth: u32 = 0;
        var in_function_body: bool = false;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Count braces to track nesting
            for (trimmed) |ch| {
                if (ch == '{') {
                    brace_depth += 1;
                    if (brace_depth == 1 and isPubDeclaration(trimmed)) {
                        in_function_body = true;
                    }
                } else if (ch == '}') {
                    if (brace_depth > 0) brace_depth -= 1;
                    if (brace_depth == 0) {
                        in_function_body = false;
                    }
                }
            }

            // Skip lines inside function bodies (depth > 0 and we entered via pub fn)
            if (in_function_body and brace_depth > 0) {
                // Only keep the signature line (depth just became > 0)
                // Check if this line opened the brace
                if (brace_depth == 1 and isPubDeclaration(trimmed)) {
                    // Keep just the signature part (up to first '{')
                    if (std.mem.indexOfScalar(u8, trimmed, '{')) |brace_pos| {
                        try buf.appendSlice(self.allocator, trimmed[0..brace_pos]);
                        try buf.appendSlice(self.allocator, ";\n");
                    } else {
                        try buf.appendSlice(self.allocator, trimmed);
                        try buf.appendSlice(self.allocator, ";\n");
                    }
                }
                continue;
            }

            // Outside function bodies — keep relevant lines
            const should_keep =
                isDocComment(trimmed) or
                isPubDeclaration(trimmed) or
                isTypeDefinition(trimmed) or
                isImportLine(trimmed) or
                trimmed.len == 0; // blank lines between declarations

            if (should_keep) {
                // For pub fn lines that contain '{', truncate to signature
                if (isPubDeclaration(trimmed) and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    if (std.mem.indexOfScalar(u8, trimmed, '{')) |brace_pos| {
                        try buf.appendSlice(self.allocator, trimmed[0..brace_pos]);
                        try buf.appendSlice(self.allocator, ";\n");
                        // Mark that we entered a body
                        in_function_body = true;
                        continue;
                    }
                }
                try buf.appendSlice(self.allocator, trimmed);
                try buf.appendSlice(self.allocator, "\n");
            }
        }

        if (buf.items.len == 0) {
            return try self.allocator.dupe(u8, "(empty after signature extraction)");
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    /// Extract ONLY public struct fields, enum variants, and type declarations.
    /// Skip all function bodies, implementations, private members.
    pub fn compressToInterface(self: *SemanticCompressor, content: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        var lines = std.mem.splitSequence(u8, content, "\n");
        var brace_depth: u32 = 0;
        var in_struct_like: bool = false;
        var in_function: bool = false;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Count braces
            for (trimmed) |ch| {
                if (ch == '{') {
                    brace_depth += 1;
                } else if (ch == '}') {
                    if (brace_depth > 0) brace_depth -= 1;
                    if (brace_depth == 0) {
                        in_struct_like = false;
                        in_function = false;
                    }
                }
            }

            // Detect struct/enum/union start
            if (std.mem.indexOf(u8, trimmed, "struct") != null or
                std.mem.indexOf(u8, trimmed, "enum") != null or
                std.mem.indexOf(u8, trimmed, "union") != null or
                std.mem.indexOf(u8, trimmed, "opaque") != null)
            {
                if (std.mem.indexOfScalar(u8, trimmed, '{') != null) {
                    // This is the opening line of a struct/enum/union
                    try buf.appendSlice(self.allocator, trimmed);
                    try buf.appendSlice(self.allocator, "\n");
                    in_struct_like = true;
                    in_function = false;
                    continue;
                }
            }

            // Detect function start — skip entirely
            if (std.mem.indexOf(u8, trimmed, "fn") != null and
                std.mem.indexOfScalar(u8, trimmed, '{') != null)
            {
                in_function = true;
                continue;
            }

            // Skip function bodies
            if (in_function) continue;

            // Inside struct/enum — keep field declarations
            if (in_struct_like and brace_depth > 0) {
                // Keep lines that look like field declarations
                if (trimmed.len > 0 and trimmed[0] != '}') {
                    // Keep pub fields and all fields of public types
                    try buf.appendSlice(self.allocator, "  ");
                    try buf.appendSlice(self.allocator, trimmed);
                    try buf.appendSlice(self.allocator, "\n");
                }
                continue;
            }

            // Top-level: keep pub const type declarations and imports
            if (std.mem.startsWith(u8, trimmed, "pub const") or
                std.mem.startsWith(u8, trimmed, "pub var") or
                isImportLine(trimmed))
            {
                // Skip if it's a function alias (contains "=" and "fn")
                if (std.mem.indexOf(u8, trimmed, "fn") != null) continue;
                try buf.appendSlice(self.allocator, trimmed);
                try buf.appendSlice(self.allocator, "\n");
            }

            // Keep doc comments
            if (isDocComment(trimmed)) {
                try buf.appendSlice(self.allocator, trimmed);
                try buf.appendSlice(self.allocator, "\n");
            }
        }

        if (buf.items.len == 0) {
            return try self.allocator.dupe(u8, "(empty after interface extraction)");
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    /// Return single line summary: "file.zig: N lines, M pub functions, K types"
    pub fn compressToSummary(self: *SemanticCompressor, file_path: []const u8, content: []const u8) ![]const u8 {
        const line_count = countLines(content);
        const pub_fn_count = countPubFunctions(content);
        const type_count = countTypes(content);
        return try std.fmt.allocPrint(self.allocator, "{s}: {d} lines, {d} pub functions, {d} types", .{ file_path, line_count, pub_fn_count, type_count });
    }

    /// Simple token estimation: len / 4 (rough char-to-token ratio).
    pub fn estimateTokens(self: *SemanticCompressor, content: []const u8) u64 {
        _ = self;
        return @intCast(@divTrunc(content.len, 4));
    }

    /// Compress a batch of files with their relevance scores.
    /// Returns the concatenated compressed output and stats.
    pub fn compressContext(self: *SemanticCompressor, files: []const FileInfo, relevance_scores: []const f64) !CompressionResult {
        var total_original: u64 = 0;
        var total_compressed: u64 = 0;
        var by_level = FilesByLevel{};
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        for (files, 0..) |file, i| {
            const score = if (i < relevance_scores.len) relevance_scores[i] else 0.0;
            const level = levelForScore(score);
            const original_tokens = self.estimateTokens(file.content);
            total_original += original_tokens;

            switch (level) {
                .full => {
                    by_level.full += 1;
                    try output.appendSlice(self.allocator, file.content);
                    try output.appendSlice(self.allocator, "\n");
                    total_compressed += original_tokens;
                },
                .signatures => {
                    by_level.signatures += 1;
                    const compressed = self.compressToSignatures(file.content) catch "(compression error)";
                    defer if (!std.mem.eql(u8, compressed, "(compression error)")) self.allocator.free(compressed);
                    total_compressed += self.estimateTokens(compressed);
                    try output.appendSlice(self.allocator, compressed);
                    try output.appendSlice(self.allocator, "\n");
                },
                .@"interface" => {
                    by_level.@"interface" += 1;
                    const compressed = self.compressToInterface(file.content) catch "(compression error)";
                    defer if (!std.mem.eql(u8, compressed, "(compression error)")) self.allocator.free(compressed);
                    total_compressed += self.estimateTokens(compressed);
                    try output.appendSlice(self.allocator, compressed);
                    try output.appendSlice(self.allocator, "\n");
                },
                .summary => {
                    by_level.summary += 1;
                    const compressed = self.compressToSummary(file.path, file.content) catch "(summary error)";
                    defer if (!std.mem.eql(u8, compressed, "(summary error)")) self.allocator.free(compressed);
                    total_compressed += self.estimateTokens(compressed);
                    try output.appendSlice(self.allocator, compressed);
                    try output.appendSlice(self.allocator, "\n");
                },
            }
        }

        const ratio: f64 = if (total_compressed > 0)
            @as(f64, @floatFromInt(total_original)) / @as(f64, @floatFromInt(total_compressed))
        else
            0.0;

        return CompressionResult{
            .original_tokens = total_original,
            .compressed_tokens = total_compressed,
            .ratio = ratio,
            .files_by_level = by_level,
        };
    }

    /// Format a human-readable compression report.
    pub fn formatCompressionReport(self: *SemanticCompressor, result: CompressionResult) ![]const u8 {
        const original_k = @divTrunc(result.original_tokens, 1000);
        const compressed_k = @divTrunc(result.compressed_tokens, 1000);
        return try std.fmt.allocPrint(self.allocator,
            "Compressed {d}K tokens → {d}K tokens ({d:.1}:1 ratio)\n  Full: {d} files, Signatures: {d} files, Interface: {d} files, Summary: {d} files",
            .{
                original_k,
                compressed_k,
                result.ratio,
                result.files_by_level.full,
                result.files_by_level.signatures,
                result.files_by_level.@"interface",
                result.files_by_level.summary,
            },
        );
    }
};

// ── Private helpers ────────────────────────────────────────────────────────────

fn isDocComment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "///") or std.mem.startsWith(u8, line, "//!") or
        std.mem.startsWith(u8, line, "//!");
}

fn isPubDeclaration(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "pub ");
}

fn isTypeDefinition(line: []const u8) bool {
    // Match: pub const X = struct, pub const X = enum, etc.
    // Also match bare: const X = struct { ... }
    const markers = [_][]const u8{ "struct", "enum", "union", "opaque" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, line, marker) != null) return true;
    }
    return false;
}

fn isImportLine(line: []const u8) bool {
    // Zig: const ... = @import(...)
    if (std.mem.indexOf(u8, line, "@import") != null) return true;
    // JS/TS: import ... from / require(
    if (std.mem.startsWith(u8, line, "import ") or std.mem.startsWith(u8, line, "const ") and std.mem.indexOf(u8, line, "require(") != null) return true;
    // Python: import / from ... import
    if (std.mem.startsWith(u8, line, "import ") or std.mem.startsWith(u8, line, "from ")) return true;
    return false;
}

fn countPubFunctions(content: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "pub fn")) {
            count += 1;
        }
    }
    return count;
}

fn countTypes(content: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "= struct") != null or
            std.mem.indexOf(u8, trimmed, "= enum") != null or
            std.mem.indexOf(u8, trimmed, "= union") != null or
            std.mem.indexOf(u8, trimmed, "= opaque") != null)
        {
            count += 1;
        }
    }
    return count;
}

const countLines = string_utils.countLines;

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "isDocComment detects /// and //!" {
    try testing.expect(isDocComment("/// doc comment"));
    try testing.expect(isDocComment("//! module doc"));
    try testing.expect(!isDocComment("// regular comment"));
    try testing.expect(!isDocComment("pub fn foo()"));
}

test "isPubDeclaration detects pub keyword" {
    try testing.expect(isPubDeclaration("pub fn foo() void"));
    try testing.expect(isPubDeclaration("pub const X = 5"));
    try testing.expect(!isPubDeclaration("fn foo() void"));
    try testing.expect(!isPubDeclaration("const X = 5"));
}

test "isTypeDefinition detects struct/enum/union" {
    try testing.expect(isTypeDefinition("pub const Foo = struct {"));
    try testing.expect(isTypeDefinition("const Bar = enum {"));
    try testing.expect(isTypeDefinition("const Baz = union {"));
    try testing.expect(!isTypeDefinition("pub fn foo() void"));
}

test "isImportLine detects Zig imports" {
    try testing.expect(isImportLine("const std = @import(\"std\");"));
    try testing.expect(isImportLine("import React from 'react'"));
    try testing.expect(!isImportLine("pub fn main() void"));
}

test "countPubFunctions counts correctly" {
    const content =
        \\pub fn foo() void {}
        \\fn bar() void {}
        \\pub fn baz() void {}
    ;
    try testing.expectEqual(@as(u32, 2), countPubFunctions(content));
}

test "countTypes counts struct/enum/union definitions" {
    const content =
        \\pub const Foo = struct { x: u32 };
        \\pub const Bar = enum { a, b };
        \\const Baz = union { x: u32, y: f64 };
    ;
    try testing.expectEqual(@as(u32, 3), countTypes(content));
}

test "countLines counts newlines" {
    try testing.expectEqual(@as(u32, 1), countLines("hello"));
    try testing.expectEqual(@as(u32, 3), countLines("a\nb\nc"));
    try testing.expectEqual(@as(u32, 0), countLines(""));
}

test "estimateTokens uses len/4 ratio" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const tokens = compressor.estimateTokens("abcdefghij"); // 10 chars
    try testing.expectEqual(@as(u64, 2), tokens); // 10/4 = 2
}

test "levelForScore returns correct levels" {
    try testing.expectEqual(CompressionLevel.full, SemanticCompressor.levelForScore(0.9));
    try testing.expectEqual(CompressionLevel.signatures, SemanticCompressor.levelForScore(0.6));
    try testing.expectEqual(CompressionLevel.@"interface", SemanticCompressor.levelForScore(0.3));
    try testing.expectEqual(CompressionLevel.summary, SemanticCompressor.levelForScore(0.1));
}

test "compressFull returns content as-is" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const content = "pub fn main() void {}";
    const result = compressor.compressFull(content);
    try testing.expectEqualStrings(content, result);
}

test "compressToSummary formats correctly" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const content = "pub fn foo() void {}\npub fn bar() void {}\npub const X = struct {};";
    const result = try compressor.compressToSummary("test.zig", content);
    defer std.testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "test.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, "2 pub functions") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1 types") != null);
}

test "compressToSignatures extracts pub declarations" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const content =
        \\/// Module doc
        \\const std = @import("std");
        \\pub fn main() void {
        \\    std.debug.print("hello", .{});
        \\}
        \\pub const Config = struct { path: []const u8 };
    ;
    const result = try compressor.compressToSignatures(content);
    defer std.testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "/// Module doc") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@import") != null);
    try testing.expect(std.mem.indexOf(u8, result, "pub fn main()") != null);
    // Should NOT contain the function body
    try testing.expect(std.mem.indexOf(u8, result, "std.debug.print") == null);
}

test "compressToInterface extracts only type info" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const content =
        \\pub const Config = struct {
        \\    path: []const u8,
        \\    max_tokens: u32,
        \\};
        \\pub fn init() Config {
        \\    return .{ .path = "", .max_tokens = 100 };
        \\}
        \\pub const default_max: u32 = 128;
    ;
    const result = try compressor.compressToInterface(content);
    defer std.testing.allocator.free(result);
    // Should contain struct fields
    try testing.expect(std.mem.indexOf(u8, result, "path:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "max_tokens:") != null);
    // Should contain pub const that's not a function
    try testing.expect(std.mem.indexOf(u8, result, "pub const default_max") != null);
    // Should NOT contain function body
    try testing.expect(std.mem.indexOf(u8, result, "return .{") == null);
}

test "formatCompressionReport formats correctly" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();
    const result = CompressionResult{
        .original_tokens = 45000,
        .compressed_tokens = 9000,
        .ratio = 5.0,
        .files_by_level = .{ .full = 3, .signatures = 5, .@"interface" = 8, .summary = 12 },
    };
    const report = try compressor.formatCompressionReport(result);
    defer std.testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "45K") != null);
    try testing.expect(std.mem.indexOf(u8, report, "9K") != null);
    try testing.expect(std.mem.indexOf(u8, report, "5.0:1") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Full: 3") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Signatures: 5") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Interface: 8") != null);
    try testing.expect(std.mem.indexOf(u8, report, "Summary: 12") != null);
}

test "compressContext compresses multiple files" {
    var compressor = SemanticCompressor.init(std.testing.allocator);
    defer compressor.deinit();

    const long_body =
        \\pub fn helper_one() void {
        \\    const x = 1 + 2 + 3;
        \\    const y = x * x;
        \\    std.debug.print("{}\n", .{y});
        \\}
        \\pub fn helper_two() void {
        \\    const a = 100;
        \\    const b = 200;
        \\    std.debug.print("{}\n", .{a + b});
        \\}
        \\pub fn helper_three() void {
        \\    for (0..10) |i| {
        \\        std.debug.print("{}\n", .{i});
        \\    }
        \\}
    ;

    const files = [_]FileInfo{
        .{ .path = "critical.zig", .content = long_body, .estimated_tokens = 200 },
        .{ .path = "important.zig", .content = long_body, .estimated_tokens = 200 },
        .{ .path = "background.zig", .content = long_body, .estimated_tokens = 200 },
    };
    const scores = [_]f64{ 0.9, 0.6, 0.1 };

    const result = try compressor.compressContext(&files, &scores);
    try testing.expect(result.original_tokens > 0);
    try testing.expect(result.compressed_tokens > 0);
    try testing.expect(result.compressed_tokens < result.original_tokens);
    try testing.expectEqual(@as(u32, 1), result.files_by_level.full);
    try testing.expectEqual(@as(u32, 1), result.files_by_level.signatures);
    try testing.expectEqual(@as(u32, 1), result.files_by_level.summary);
    try testing.expect(result.ratio > 1.0);
}
