const std = @import("std");

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
    references: std.ArrayList([]const u8), // Symbols this one references
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, symbol_type: types.NodeType, line: u32) !ParsedSymbol {
        return ParsedSymbol{
            .name = try allocator.dupe(u8, name),
            .symbol_type = symbol_type,
            .line = line,
            .end_line = line,
            .signature = null,
            .doc_comment = null,
            .references = std.ArrayList([]const u8).init(allocator),
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
    symbols: std.ArrayList(*ParsedSymbol),
    imports: std.ArrayList([]const u8),
    total_lines: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, file_path: []const u8, language: SourceLanguage) ParseResult {
        return ParseResult{
            .file_path = allocator.dupe(u8, file_path) catch "",
            .language = language,
            .symbols = std.ArrayList(*ParsedSymbol).init(allocator),
            .imports = std.ArrayList([]const u8).init(allocator),
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
            .zig => self.parseZig(content, &result) catch {},
            .typescript, .javascript => self.parseTypeScript(content, &result) catch {},
            .python => self.parsePython(content, &result) catch {},
            .go => self.parseGo(content, &result) catch {},
            .rust => self.parseRust(content, &result) catch {},
            .unknown => {},
        }

        return result;
    }

    /// Parse Zig source code
    fn parseZig(self: *SourceParser, content: []const u8, result: *ParseResult) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;
        var in_doc_comment = false;
        var doc_lines = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (doc_lines.items) |l| self.allocator.free(l);
            doc_lines.deinit();
        }

        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t");

            // Collect doc comments
            if (std.mem.startsWith(u8, trimmed, "///")) {
                in_doc_comment = true;
                const doc_text = std.mem.trim(u8, trimmed["///".len..], " ");
                try doc_lines.append(try self.allocator.dupe(u8, doc_text));
                continue;
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
        while (end < text.len and std.ascii.isAlphanumeric(text[end]) or (end < text.len and text[end] == '.')) {
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
    fn countLines(content: []const u8) u32 {
        var count: u32 = 1;
        for (content) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }
};
