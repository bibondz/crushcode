/// Main syntax highlighting interface
/// Provides tree-sitter-based syntax highlighting for multiple languages
const std = @import("std");
const vaxis = @import("vaxis");
const tree_sitter = @import("tree_sitter.zig");
const themes = @import("themes.zig");

pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    parser: tree_sitter.Parser,
    current_language: ?Language,
    
    /// Supported programming languages
    pub const Language = enum {
        zig,
        javascript,
        typescript,
        python,
        rust,
        go,
        c,
        cpp,
        json,
        yaml,
        toml,
        markdown,
        shell,
        sql,
        html,
        css,
        unknown,
        
        pub fn fromFileExtension(ext: []const u8) Language {
            if (std.mem.eql(u8, ext, ".zig")) return .zig;
            if (std.mem.eql(u8, ext, ".js")) return .javascript;
            if (std.mem.eql(u8, ext, ".ts")) return .typescript;
            if (std.mem.eql(u8, ext, ".tsx")) return .typescript;
            if (std.mem.eql(u8, ext, ".py")) return .python;
            if (std.mem.eql(u8, ext, ".rs")) return .rust;
            if (std.mem.eql(u8, ext, ".go")) return .go;
            if (std.mem.eql(u8, ext, ".c")) return .c;
            if (std.mem.eql(u8, ext, ".h")) return .c;
            if (std.mem.eql(u8, ext, ".cpp")) return .cpp;
            if (std.mem.eql(u8, ext, ".hpp")) return .cpp;
            if (std.mem.eql(u8, ext, ".json")) return .json;
            if (std.mem.eql(u8, ext, ".yaml")) return .yaml;
            if (std.mem.eql(u8, ext, ".yml")) return .yaml;
            if (std.mem.eql(u8, ext, ".toml")) return .toml;
            if (std.mem.eql(u8, ext, ".md")) return .markdown;
            if (std.mem.eql(u8, ext, ".sh")) return .shell;
            if (std.mem.eql(u8, ext, ".bash")) return .shell;
            if (std.mem.eql(u8, ext, ".zsh")) return .shell;
            if (std.mem.eql(u8, ext, ".sql")) return .sql;
            if (std.mem.eql(u8, ext, ".html")) return .html;
            if (std.mem.eql(u8, ext, ".css")) return .css;
            return .unknown;
        }
        
        pub fn toString(self: Language) []const u8 {
            return switch (self) {
                .zig => "zig",
                .javascript => "javascript",
                .typescript => "typescript",
                .python => "python",
                .rust => "rust",
                .go => "go",
                .c => "c",
                .cpp => "cpp",
                .json => "json",
                .yaml => "yaml",
                .toml => "toml",
                .markdown => "markdown",
                .shell => "shell",
                .sql => "sql",
                .html => "html",
                .css => "css",
                .unknown => "unknown",
            };
        }
    };
    
    /// Represents a highlighted code segment
    pub const HighlightedSegment = struct {
        text: []const u8,
        token_type: TokenType,
        byte_offset: usize,
    };
    
    /// Token types for syntax highlighting
    pub const TokenType = enum {
        // Common token types
        text,
        keyword,
        string,
        number,
        comment,
        function,
        variable,
        type,
        property,
        operator,
        punctuation,
        error,
        warning,
        
        // Language-specific token types
        struct,
        enum,
        union,
        const_,
        var_,
        fn_,
        return_,
        if_,
        else_,
        while_,
        for_,
        async,
        await,
        pub_,
        import_,
        
        // VSCode theme token types
        "comment",
        "string",
        "number",
        "variable",
        "type",
        "function",
        "keyword",
        "operator",
        "punctuation",
        "property",
        "constant",
        "constructor",
        "parameter",
        "tag",
        "attribute",
        "definition",
        "reference",
    };
    
    /// Represents fully highlighted code
    pub const HighlightedCode = struct {
        segments: []HighlightedSegment,
        language: Language,
        theme: *const themes.Theme,
        
        pub fn deinit(self: *HighlightedCode, allocator: std.mem.Allocator) void {
            for (self.segments) |*segment| {
                allocator.free(segment.text);
            }
            allocator.free(self.segments);
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) !SyntaxHighlighter {
        const parser = try tree_sitter.Parser.init(allocator);
        return SyntaxHighlighter{
            .allocator = allocator,
            .parser = parser,
            .current_language = null,
        };
    }
    
    pub fn deinit(self: *SyntaxHighlighter) void {
        self.parser.deinit();
    }
    
    /// Highlight code using the specified language and theme
    pub fn highlight(self: *SyntaxHighlighter, code: []const u8, language: Language, theme: *const themes.Theme) !HighlightedCode {
        // Set language if different from current
        if (self.current_language == null or !std.meta.eql(self.current_language.?, language)) {
            try self.setLanguage(language);
        }
        
        // Parse the code
        const tree = try self.parser.parse(code);
        defer tree.deinit();
        
        // Get the root node
        const root_node = tree.rootNode();
        
        // Generate highlighted segments
        var segments = std.ArrayList(HighlightedSegment).init(self.allocator);
        errdefer {
            for (segments.items) |*segment| {
                self.allocator.free(segment.text);
            }
            segments.deinit();
        }
        
        try self.walkNode(root_node, code, &segments, theme);
        
        return HighlightedCode{
            .segments = segments.toOwnedSlice(),
            .language = language,
            .theme = theme,
        };
    }
    
    /// Set the language for syntax highlighting
    pub fn setLanguage(self: *SyntaxHighlighter, language: Language) !void {
        self.current_language = language;
        // Language-specific initialization will be handled by tree_sitter module
    }
    
    /// Walk the syntax tree and generate highlighted segments
    fn walkNode(self: *SyntaxHighlighter, node: tree_sitter.Node, source_code: []const u8, segments: *std.ArrayList(HighlightedSegment), theme: *const themes.Theme) !void {
        // Simple implementation for now - will be expanded
        const start_byte = node.startByte();
        const end_byte = node.endByte();
        
        if (end_byte > start_byte) {
            const text = try self.allocator.dupe(u8, source_code[start_byte..end_byte]);
            
            const token_type = self.nodeTypeToTokenType(node);
            
            try segments.append(HighlightedSegment{
                .text = text,
                .token_type = token_type,
                .byte_offset = start_byte,
            });
        }
        
        // Recursively process child nodes
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            const child = node.child(i).?;
            try self.walkNode(child, source_code, segments, theme);
        }
    }
    
    /// Convert tree-sitter node type to our token type
    fn nodeTypeToTokenType(self: *SyntaxHighlighter, node: tree_sitter.Node) TokenType {
        const node_type = node.type();
        
        // This is a simplified mapping - in a real implementation,
        // this would be more comprehensive and language-specific
        if (std.mem.indexOf(u8, node_type, "comment") != null) {
            return .comment;
        }
        if (std.mem.indexOf(u8, node_type, "string") != null) {
            return .string;
        }
        if (std.mem.indexOf(u8, node_type, "number") != null) {
            return .number;
        }
        if (std.mem.indexOf(u8, node_type, "function") != null) {
            return .function;
        }
        if (std.mem.indexOf(u8, node_type, "keyword") != null) {
            return .keyword;
        }
        if (std.mem.indexOf(u8, node_type, "type") != null) {
            return .type;
        }
        if (std.mem.indexOf(u8, node_type, "variable") != null) {
            return .variable;
        }
        if (std.mem.indexOf(u8, node_type, "operator") != null) {
            return .operator;
        }
        if (std.mem.indexOf(u8, node_type, "property") != null) {
            return .property;
        }
        
        return .text;
    }
    
    /// Detect language from file extension
    pub fn detectLanguage(file_path: []const u8) Language {
        const ext = std.fs.path.extension(file_path);
        return Language.fromFileExtension(ext);
    }
    
    /// Highlight code with auto-detected language
    pub fn highlightFile(self: *SyntaxHighlighter, file_path: []const u8, code: []const u8, theme: *const themes.Theme) !HighlightedCode {
        const language = self.detectLanguage(file_path);
        return self.highlight(code, language, theme);
    }
};

test "SyntaxHighlighter - basic functionality" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();
    
    const theme = themes.defaultTheme();
    const code = "const x = 1;";
    const language = SyntaxHighlighter.Language.zig;
    
    // This test will work when tree_sitter implementation is complete
    // const highlighted = try highlighter.highlight(code, language, theme);
    // defer highlighted.deinit(allocator);
    // try std.testing.expect(highlighted.segments.len > 0);
}
