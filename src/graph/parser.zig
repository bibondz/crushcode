const std = @import("std");
const string_utils = @import("string_utils");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;
const types = @import("types.zig");

/// Supported source languages for AST parsing
pub const SourceLanguage = enum {
    zig,
    typescript,
    javascript,
    python,
    go,
    rust,
    unknown,
};

/// A parsed symbol extracted from source code
pub const ParsedSymbol = struct {
    name: []const u8,
    symbol_type: types.NodeType,
    line: u32,
    end_line: u32,
    signature: ?[]const u8,
    doc_comment: ?[]const u8,
    references: array_list_compat.ArrayList([]const u8), // Symbols this one references
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, symbol_type: types.NodeType, line: u32) !ParsedSymbol {
        return ParsedSymbol{
            .name = try allocator.dupe(u8, name),
            .symbol_type = symbol_type,
            .line = line,
            .end_line = line,
            .signature = null,
            .doc_comment = null,
            .references = array_list_compat.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedSymbol) void {
        self.allocator.free(self.name);
        if (self.signature) |s| self.allocator.free(s);
        if (self.doc_comment) |d| self.allocator.free(d);
        for (self.references.items) |r| self.allocator.free(r);
        self.references.deinit();
    }
};

/// Result of parsing a source file
pub const ParseResult = struct {
    file_path: []const u8,
    language: SourceLanguage,
    symbols: array_list_compat.ArrayList(*ParsedSymbol),
    imports: array_list_compat.ArrayList([]const u8),
    total_lines: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, file_path: []const u8, language: SourceLanguage) ParseResult {
        return ParseResult{
            .file_path = allocator.dupe(u8, file_path) catch "",
            .language = language,
            .symbols = array_list_compat.ArrayList(*ParsedSymbol).init(allocator),
            .imports = array_list_compat.ArrayList([]const u8).init(allocator),
            .total_lines = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParseResult) void {
        for (self.symbols.items) |sym| {
            sym.deinit();
            self.allocator.destroy(sym);
        }
        self.symbols.deinit();
        for (self.imports.items) |imp| self.allocator.free(imp);
        self.imports.deinit();
        if (self.file_path.len > 0) self.allocator.free(self.file_path);
    }
};

/// Source code parser — extracts symbols and relationships using pattern matching
///
/// Reference: Graphify tree-sitter AST extraction
/// Note: Uses pattern matching instead of tree-sitter (Zig stdlib only)
pub const SourceParser = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SourceParser {
        return SourceParser{ .allocator = allocator };
    }

    /// Detect source language from file extension
    pub fn detectLanguage(file_path: []const u8) SourceLanguage {
        if (std.mem.endsWith(u8, file_path, ".zig")) return .zig;
        if (std.mem.endsWith(u8, file_path, ".ts") or std.mem.endsWith(u8, file_path, ".tsx")) return .typescript;
        if (std.mem.endsWith(u8, file_path, ".js") or std.mem.endsWith(u8, file_path, ".jsx")) return .javascript;
        if (std.mem.endsWith(u8, file_path, ".py")) return .python;
        if (std.mem.endsWith(u8, file_path, ".go")) return .go;
        if (std.mem.endsWith(u8, file_path, ".rs")) return .rust;
        return .unknown;
    }

    /// Parse a source file and extract symbols
    pub fn parseFile(self: *SourceParser, file_path: []const u8) !?ParseResult {
        const language = detectLanguage(file_path);
        if (language == .unknown) return null;

        var result = ParseResult.init(self.allocator, file_path, language);

        // Read file content
        const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(content);

        result.total_lines = countLines(content);

        // Parse based on language
        switch (language) {
            .zig => self.parseZig(content, &result) catch |err| std.log.warn("Failed to parse Zig file: {}", .{err}),
            .typescript, .javascript => self.parseTypeScript(content, &result) catch |err| std.log.warn("Failed to parse TS/JS file: {}", .{err}),
            .python => self.parsePython(content, &result) catch |err| std.log.warn("Failed to parse Python file: {}", .{err}),
            .go => self.parseGo(content, &result) catch |err| std.log.warn("Failed to parse Go file: {}", .{err}),
            .rust => self.parseRust(content, &result) catch |err| std.log.warn("Failed to parse Rust file: {}", .{err}),
            .unknown => {},
        }

        return result;
    }

    /// Parse Zig source code
    fn parseZig(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;
        var doc_lines = array_list_compat.ArrayList([]const u8).init(self.allocator);
        defer {
            for (doc_lines.items) |l| self.allocator.free(l);
            doc_lines.deinit();
        }

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            // Collect doc comments
            if (std.mem.startsWith(u8, trimmed, "///")) {
                const doc_text = std.mem.trim(u8, trimmed["///".len..], " ");
                try doc_lines.append(try self.allocator.dupe(u8, doc_text));
                continue;
            }
            // Non-doc-comment, non-empty line: if it's not a declaration, discard doc comments
            if (trimmed.len > 0 and
                !std.mem.startsWith(u8, trimmed, "//") and
                !std.mem.startsWith(u8, trimmed, "pub fn ") and
                !std.mem.startsWith(u8, trimmed, "fn ") and
                !std.mem.startsWith(u8, trimmed, "test ") and
                !std.mem.startsWith(u8, trimmed, "pub const "))
            {
                for (doc_lines.items) |l| self.allocator.free(l);
                doc_lines.clearRetainingCapacity();
            }
            // Parse top-level declarations
            if (std.mem.startsWith(u8, trimmed, "pub fn ") or std.mem.startsWith(u8, trimmed, "fn ")) {
                const name = self.extractIdentifier(if (std.mem.startsWith(u8, trimmed, "pub fn "))
                    trimmed["pub fn ".len..]
                else
                    trimmed["fn ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .function, line_num);
                    sym.*.end_line = line_num;
                    sym.*.signature = try self.allocator.dupe(u8, trimmed);
                    if (doc_lines.items.len > 0) {
                        sym.*.doc_comment = try std.mem.join(self.allocator, " ", doc_lines.items);
                    }
                    try result.symbols.append(sym);
                }
                // Clear collected doc comments
                for (doc_lines.items) |l| self.allocator.free(l);
                doc_lines.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, trimmed, "test ")) {
                // Zig test case: test "name" { ... }
                var test_name: ?[]const u8 = null;
                if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                    const inner = trimmed[start + 1 ..];
                    if (std.mem.indexOf(u8, inner, "\"")) |end| {
                        test_name = inner[0..end];
                    }
                }
                const display_name = test_name orelse "unnamed";
                const sym = try self.allocator.create(ParsedSymbol);
                sym.* = try ParsedSymbol.init(self.allocator, display_name, .test_case, line_num);
                sym.*.signature = try self.allocator.dupe(u8, trimmed);
                if (doc_lines.items.len > 0) {
                    sym.*.doc_comment = try std.mem.join(self.allocator, " ", doc_lines.items);
                }
                try result.symbols.append(sym);
                for (doc_lines.items) |l| self.allocator.free(l);
                doc_lines.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, trimmed, "pub const ") and std.mem.containsAtLeast(u8, trimmed, 1, "= struct")) {
                const name = self.extractIdentifier(trimmed["pub const ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .struct_decl, line_num);
                    sym.*.signature = try self.allocator.dupe(u8, trimmed);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "pub const ") and std.mem.containsAtLeast(u8, trimmed, 1, "= enum")) {
                const name = self.extractIdentifier(trimmed["pub const ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .enum_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "pub const ") and std.mem.containsAtLeast(u8, trimmed, 1, "= union")) {
                const name = self.extractIdentifier(trimmed["pub const ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .union_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "const ")) {
                // Check for import: const mod = @import("module")
                if (std.mem.containsAtLeast(u8, trimmed, 1, "@import")) {
                    if (self.extractImportPath(trimmed)) |path| {
                        try result.imports.append(try self.allocator.dupe(u8, path));
                    }
                }
            }
        }
    }

    /// Parse TypeScript/JavaScript source code
    fn parseTypeScript(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            // Function declarations
            if (std.mem.startsWith(u8, trimmed, "export function ") or std.mem.startsWith(u8, trimmed, "function ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "export function ")) "export function " else "function ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .function, line_num);
                    sym.*.signature = try self.allocator.dupe(u8, trimmed);
                    try result.symbols.append(sym);
                }
            }
            // Class declarations
            else if (std.mem.startsWith(u8, trimmed, "export class ") or std.mem.startsWith(u8, trimmed, "class ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "export class ")) "export class " else "class ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .struct_decl, line_num);
                    try result.symbols.append(sym);
                }
            }
            // Import declarations
            else if (std.mem.startsWith(u8, trimmed, "import ")) {
                if (self.extractTSImportPath(trimmed)) |path| {
                    try result.imports.append(try self.allocator.dupe(u8, path));
                }
            }
        }
    }

    /// Parse Python source code
    fn parsePython(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "def ") or std.mem.startsWith(u8, trimmed, "async def ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "async def ")) "async def " else "def ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .function, line_num);
                    sym.*.signature = try self.allocator.dupe(u8, trimmed);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "class ")) {
                const name = self.extractIdentifier(trimmed["class ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .struct_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "import ") or std.mem.startsWith(u8, trimmed, "from ")) {
                const path = if (std.mem.startsWith(u8, trimmed, "from "))
                    self.extractPyFromImport(trimmed)
                else
                    self.extractPyImport(trimmed);
                if (path) |p| {
                    try result.imports.append(try self.allocator.dupe(u8, p));
                }
            }
        }
    }

    /// Parse Go source code
    fn parseGo(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "func ")) {
                const after_func = trimmed["func ".len..];
                // Handle receiver methods: func (r *Receiver) MethodName
                var name_start: []const u8 = after_func;
                if (std.mem.startsWith(u8, after_func, "(")) {
                    // Skip receiver
                    if (std.mem.indexOf(u8, after_func, ") ")) |idx| {
                        name_start = after_func[idx + 2 ..];
                    }
                }
                const name = self.extractIdentifier(name_start);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .function, line_num);
                    sym.*.signature = try self.allocator.dupe(u8, trimmed);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "type ") and std.mem.containsAtLeast(u8, trimmed, 1, "struct")) {
                const name = self.extractIdentifier(trimmed["type ".len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .struct_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "import ")) {
                if (self.extractGoImport(trimmed)) |path| {
                    try result.imports.append(try self.allocator.dupe(u8, path));
                }
            }
        }
    }

    /// Parse Rust source code
    fn parseRust(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "pub fn ") or std.mem.startsWith(u8, trimmed, "fn ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "pub fn ")) "pub fn " else "fn ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .function, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "struct ") or std.mem.startsWith(u8, trimmed, "pub struct ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "pub struct ")) "pub struct " else "struct ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .struct_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "enum ") or std.mem.startsWith(u8, trimmed, "pub enum ")) {
                const prefix = if (std.mem.startsWith(u8, trimmed, "pub enum ")) "pub enum " else "enum ";
                const name = self.extractIdentifier(trimmed[prefix.len..]);
                if (name.len > 0) {
                    const sym = try self.allocator.create(ParsedSymbol);
                    sym.* = try ParsedSymbol.init(self.allocator, name, .enum_decl, line_num);
                    try result.symbols.append(sym);
                }
            } else if (std.mem.startsWith(u8, trimmed, "use ")) {
                if (self.extractRustUse(trimmed)) |path| {
                    try result.imports.append(try self.allocator.dupe(u8, path));
                }
            }
        }
    }

    /// Extract identifier from the start of a string (stops at non-alphanumeric/underscore)
    fn extractIdentifier(_: *SourceParser, text: []const u8) []const u8 {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '<' and c != '>') break;
        }
        if (i == 0) return "";
        return text[0..i];
    }

    /// Extract import path from Zig @import("...")
    fn extractImportPath(_: *SourceParser, text: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, text, "\"") orelse return null;
        const end = std.mem.indexOf(u8, text[start + 1 ..], "\"") orelse return null;
        return text[start + 1 .. start + 1 + end];
    }

    /// Extract import path from TypeScript import ... from "..."
    fn extractTSImportPath(_: *SourceParser, text: []const u8) ?[]const u8 {
        const from_str = "from \"";
        const start = std.mem.indexOf(u8, text, from_str) orelse return null;
        const path_start = start + from_str.len;
        const end = std.mem.indexOf(u8, text[path_start..], "\"") orelse return null;
        return text[path_start .. path_start + end];
    }

    /// Extract Python import path
    fn extractPyImport(_: *SourceParser, text: []const u8) ?[]const u8 {
        const start = "import ".len;
        if (text.len <= start) return null;
        var end: usize = start;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '.')) {
            end += 1;
        }
        if (end <= start) return null;
        return text[start..end];
    }

    /// Extract Python from-import path
    fn extractPyFromImport(_: *SourceParser, text: []const u8) ?[]const u8 {
        const start = "from ".len;
        const end = std.mem.indexOf(u8, text[start..], " ") orelse return null;
        if (end == 0) return null;
        return text[start .. start + end];
    }

    /// Extract Go import path
    fn extractGoImport(_: *SourceParser, text: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, text, "\"") orelse return null;
        const end = std.mem.indexOf(u8, text[start + 1 ..], "\"") orelse return null;
        return text[start + 1 .. start + 1 + end];
    }

    /// Extract Rust use path
    fn extractRustUse(_: *SourceParser, text: []const u8) ?[]const u8 {
        const start = "use ".len;
        if (text.len <= start) return null;
        var end: usize = start;
        while (end < text.len and text[end] != ';' and text[end] != '{') {
            end += 1;
        }
        if (end <= start) return null;
        return std.mem.trim(u8, text[start..end], " ");
    }

    /// Count lines in content
    const countLines = string_utils.countLines;
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "detectLanguage identifies file extensions" {
    try testing.expectEqual(SourceLanguage.zig, SourceParser.detectLanguage("foo.zig"));
    try testing.expectEqual(SourceLanguage.typescript, SourceParser.detectLanguage("foo.ts"));
    try testing.expectEqual(SourceLanguage.typescript, SourceParser.detectLanguage("foo.tsx"));
    try testing.expectEqual(SourceLanguage.javascript, SourceParser.detectLanguage("foo.js"));
    try testing.expectEqual(SourceLanguage.javascript, SourceParser.detectLanguage("foo.jsx"));
    try testing.expectEqual(SourceLanguage.python, SourceParser.detectLanguage("foo.py"));
    try testing.expectEqual(SourceLanguage.go, SourceParser.detectLanguage("foo.go"));
    try testing.expectEqual(SourceLanguage.rust, SourceParser.detectLanguage("foo.rs"));
    try testing.expectEqual(SourceLanguage.unknown, SourceParser.detectLanguage("foo.txt"));
    try testing.expectEqual(SourceLanguage.unknown, SourceParser.detectLanguage("Makefile"));
}

test "extractIdentifier stops at non-identifier characters" {
    var parser = SourceParser.init(testing.allocator);
    const id = parser.extractIdentifier("sendChat(message: []const u8)");
    try testing.expectEqualStrings("sendChat", id);

    const id2 = parser.extractIdentifier("MyStruct = struct");
    try testing.expectEqualStrings("MyStruct", id2);

    const id3 = parser.extractIdentifier("(self: *Foo)");
    try testing.expectEqualStrings("", id3);
}

test "extractImportPath extracts Zig @import path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractImportPath("const std = @import(\"std\");");
    try testing.expectEqualStrings("std", path.?);

    const path2 = parser.extractImportPath("const types = @import(\"types.zig\");");
    try testing.expectEqualStrings("types.zig", path2.?);

    const no_path = parser.extractImportPath("const foo = bar;");
    try testing.expect(no_path == null);
}

test "extractTSImportPath extracts TS import path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractTSImportPath("import { foo } from \"./bar\";");
    try testing.expectEqualStrings("./bar", path.?);

    const no_import = parser.extractTSImportPath("const x = 1;");
    try testing.expect(no_import == null);
}

test "extractPyFromImport extracts Python from-import path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractPyFromImport("from os.path import join");
    try testing.expectEqualStrings("os.path", path.?);
}

test "extractPyImport extracts Python import path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractPyImport("import os.path");
    try testing.expectEqualStrings("os.path", path.?);

    const path2 = parser.extractPyImport("import sys");
    try testing.expectEqualStrings("sys", path2.?);
}

test "extractGoImport extracts Go import path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractGoImport("import \"fmt\"");
    try testing.expectEqualStrings("fmt", path.?);
}

test "extractRustUse extracts Rust use path" {
    var parser = SourceParser.init(testing.allocator);
    const path = parser.extractRustUse("use std::collections::HashMap;");
    try testing.expectEqualStrings("std::collections::HashMap", path.?);

    const path2 = parser.extractRustUse("use serde::{Serialize, Deserialize};");
    try testing.expectEqualStrings("serde::", path2.?);
}

test "countLines counts correctly" {
    try testing.expectEqual(@as(u32, 1), SourceParser.countLines("hello"));
    try testing.expectEqual(@as(u32, 3), SourceParser.countLines("a\nb\nc"));
    try testing.expectEqual(@as(u32, 2), SourceParser.countLines("a\n"));
}

test "parseZig extracts functions, structs, enums, and imports" {
    const zig_source =
        \\const std = @import("std");
        \\const types = @import("types.zig");
        \\
        \\/// Documentation for my function
        \\pub fn myFunction(x: u32) !void {
        \\    _ = x;
        \\}
        \\
        \\pub const MyStruct = struct {
        \\    field: u32,
        \\};
        \\
        \\pub const Color = enum { red, green, blue };
        \\
        \\fn helper() void {}
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.zig", .zig);
    try parser.parseZig(zig_source, &result);
    defer result.deinit();

    // Should find 4 symbols: myFunction, MyStruct, Color, helper
    try testing.expectEqual(@as(usize, 4), result.symbols.items.len);

    // Check function names exist
    var found_count: usize = 0;
    const expected_names = [_][]const u8{ "myFunction", "MyStruct", "Color", "helper" };
    for (result.symbols.items) |sym| {
        for (expected_names) |name| {
            if (std.mem.eql(u8, sym.name, name)) found_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, expected_names.len), found_count);

    // Check imports
    try testing.expectEqual(@as(usize, 2), result.imports.items.len);
    try testing.expectEqualStrings("std", result.imports.items[0]);
    try testing.expectEqualStrings("types.zig", result.imports.items[1]);

    // Check doc comment on myFunction
    for (result.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "myFunction")) {
            try testing.expect(sym.doc_comment != null);
            try testing.expect(std.mem.indexOf(u8, sym.doc_comment.?, "Documentation") != null);
        }
    }
}

test "parseZig detects test cases, unions, and doc comments" {
    const zig_source =
        \\const std = @import("std");
        \\
        \\/// A tagged union for results
        \\pub const Result = union(enum) {
        \\    ok: []const u8,
        \\    err: u32,
        \\};
        \\
        \\test "basic addition" {
        \\    try std.testing.expectEqual(@as(u32, 3), 1 + 2);
        \\}
        \\
        \\test "string compare" {
        \\    try std.testing.expect(true);
        \\}
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.zig", .zig);
    try parser.parseZig(zig_source, &result);
    defer result.deinit();

    // Should find: Result (union), "basic addition" (test), "string compare" (test)
    var test_count: usize = 0;
    var union_found = false;
    for (result.symbols.items) |sym| {
        if (sym.symbol_type == .test_case) {
            test_count += 1;
        }
        if (sym.symbol_type == .union_decl and std.mem.eql(u8, sym.name, "Result")) {
            union_found = true;
        }
    }
    try testing.expectEqual(@as(usize, 2), test_count);
    try testing.expect(union_found);
}

test "parseTypeScript extracts functions, classes, and imports" {
    const ts_source =
        \\import { foo } from "./bar";
        \\
        \\export function greet(name: string): void {
        \\    console.log(name);
        \\}
        \\
        \\class MyClass {
        \\    method() {}
        \\}
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.ts", .typescript);
    try parser.parseTypeScript(ts_source, &result);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.symbols.items.len);
    try testing.expectEqualStrings("greet", result.symbols.items[0].name);
    try testing.expectEqual(.function, result.symbols.items[0].symbol_type);
    try testing.expectEqualStrings("MyClass", result.symbols.items[1].name);
    try testing.expectEqual(.struct_decl, result.symbols.items[1].symbol_type);

    try testing.expectEqual(@as(usize, 1), result.imports.items.len);
    try testing.expectEqualStrings("./bar", result.imports.items[0]);
}

test "parsePython extracts functions, classes, and imports" {
    const py_source =
        \\import os.path
        \\from sys import argv
        \\
        \\def hello(name):
        \\    print(name)
        \\
        \\async def fetch(url):
        \\    pass
        \\
        \\class MyService:
        \\    def run(self):
        \\        pass
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.py", .python);
    try parser.parsePython(py_source, &result);
    defer result.deinit();

    // Should find: hello, fetch, MyService, run (def inside class also detected)
    try testing.expectEqual(@as(usize, 4), result.symbols.items.len);
    try testing.expectEqualStrings("hello", result.symbols.items[0].name);
    try testing.expectEqualStrings("fetch", result.symbols.items[1].name);
    try testing.expectEqualStrings("MyService", result.symbols.items[2].name);
    try testing.expectEqualStrings("run", result.symbols.items[3].name);

    // 2 imports
    try testing.expectEqual(@as(usize, 2), result.imports.items.len);
}

test "parseGo extracts functions, methods, structs, and imports" {
    const go_source =
        \\import "fmt"
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\}
        \\
        \\func (s *Server) Handle() error {
        \\    return nil
        \\}
        \\
        \\type Config struct {
        \\    Port int
        \\}
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.go", .go);
    try parser.parseGo(go_source, &result);
    defer result.deinit();

    // 2 functions + 1 struct
    try testing.expectEqual(@as(usize, 3), result.symbols.items.len);
    try testing.expectEqualStrings("main", result.symbols.items[0].name);
    try testing.expectEqualStrings("Handle", result.symbols.items[1].name);
    try testing.expectEqualStrings("Config", result.symbols.items[2].name);

    try testing.expectEqual(@as(usize, 1), result.imports.items.len);
    try testing.expectEqualStrings("fmt", result.imports.items[0]);
}

test "parseRust extracts functions, structs, enums, and use statements" {
    const rust_source =
        \\use std::collections::HashMap;
        \\
        \\pub fn new() -> Self {
        \\    Self {}
        \\}
        \\
        \\struct Inner {
        \\    data: Vec<u8>,
        \\}
        \\
        \\pub enum Status {
        \\    Active,
        \\    Inactive,
        \\}
    ;

    var parser = SourceParser.init(testing.allocator);
    var result = ParseResult.init(testing.allocator, "test.rs", .rust);
    try parser.parseRust(rust_source, &result);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.symbols.items.len);
    try testing.expectEqualStrings("new", result.symbols.items[0].name);
    try testing.expectEqual(.function, result.symbols.items[0].symbol_type);
    try testing.expectEqualStrings("Inner", result.symbols.items[1].name);
    try testing.expectEqual(.struct_decl, result.symbols.items[1].symbol_type);
    try testing.expectEqualStrings("Status", result.symbols.items[2].name);
    try testing.expectEqual(.enum_decl, result.symbols.items[2].symbol_type);

    try testing.expectEqual(@as(usize, 1), result.imports.items.len);
    try testing.expectEqualStrings("std::collections::HashMap", result.imports.items[0]);
}
