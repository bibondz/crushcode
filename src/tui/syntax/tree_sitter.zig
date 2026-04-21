/// Tree-sitter integration for syntax highlighting
/// Compatible with zat/flow-syntax API structure
const std = @import("std");

// External tree-sitter bindings (would be provided by C library)
extern struct ts_parser;
extern struct ts_tree;
extern struct ts_node;
extern struct ts_query;
extern struct ts_query_cursor;
extern struct ts_query_match;
extern struct ts_query_capture;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    ptr: ?*ts_parser = null,
    
    pub fn init(allocator: std.mem.Allocator) !Parser {
        // In real implementation, this would call ts_parser_new()
        return Parser{
            .allocator = allocator,
            .ptr = null, // Would be actual parser pointer
        };
    }
    
    pub fn deinit(self: *Parser) void {
        // In real implementation, this would call ts_parser_delete()
        _ = self;
    }
    
    pub fn setLanguage(self: *Parser, lang_fn: fn () ?*const anyopaque) !void {
        // In real implementation, this would set the tree-sitter language
        _ = self;
        _ = lang_fn;
        // Example: ts_parser_set_language(self.ptr, lang_fn());
    }
    
    pub fn parse(self: *Parser, source_code: []const u8, old_tree: ?*Tree) !Tree {
        // In real implementation, this would parse the code
        _ = self;
        _ = old_tree;
        return Tree.init(source_code, self.allocator);
    }
    
    pub fn reset(self: *Parser) void {
        // Reset parser state
        _ = self;
    }
};

pub const Tree = struct {
    ptr: ?*ts_tree = null,
    source_code: []const u8,
    allocator: std.mem.Allocator,
    
    fn init(source_code: []const u8, allocator: std.mem.Allocator) Tree {
        return Tree{
            .source_code = source_code,
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Tree) void {
        // In real implementation, this would call ts_tree_delete()
        _ = self;
    }
    
    pub fn rootNode(self: *const Tree) Node {
        return Node.init(self.source_code, self.allocator);
    }
    
    pub fn edit(self: *Tree, input: anytype) void {
        // In real implementation, this would call ts_tree_edit()
        _ = self;
        _ = input;
    }
};

pub const Node = struct {
    ptr: ?*ts_node = null,
    source_code: []const u8,
    allocator: std.mem.Allocator,
    
    fn init(source_code: []const u8, allocator: std.mem.Allocator) Node {
        return Node{
            .source_code = source_code,
            .allocator = allocator,
        };
    }
    
    pub fn type(self: *const Node) []const u8 {
        // In real implementation, this would call ts_node_type()
        _ = self;
        return "source_file";
    }
    
    pub fn startPoint(self: *const Node) Point {
        // In real implementation, this would call ts_node_start_point()
        _ = self;
        return Point{ .row = 0, .column = 0 };
    }
    
    pub fn endPoint(self: *const Node) Point {
        // In real implementation, this would call ts_node_end_point()
        _ = self;
        return Point{ .row = 0, .column = 0 };
    }
    
    pub fn startByte(self: *const Node) usize {
        // In real implementation, this would call ts_node_start_byte()
        _ = self;
        return 0;
    }
    
    pub fn endByte(self: *const Node) usize {
        // In real implementation, this would call ts_node_end_byte()
        _ = self;
        return self.source_code.len;
    }
    
    pub fn childCount(self: *const Node) u32 {
        // In real implementation, this would call ts_node_child_count()
        _ = self;
        return 0;
    }
    
    pub fn child(self: *const Node, index: u32) ?Node {
        // In real implementation, this would call ts_node_child()
        _ = self;
        _ = index;
        return null;
    }
    
    pub fn nextSibling(self: *const Node) ?Node {
        // In real implementation, this would call ts_node_next_sibling()
        _ = self;
        return null;
    }
    
    pub fn prevSibling(self: *const Node) ?Node {
        // In real implementation, this would call ts_node_prev_sibling()
        _ = self;
        return null;
    }
    
    pub fn parent(self: *const Node) ?Node {
        // In real implementation, this would call ts_node_parent()
        _ = self;
        return null;
    }
    
    pub fn hasError(self: *const Node) bool {
        // In real implementation, this would call ts_node_has_error()
        _ = self;
        return false;
    }
    
    pub fn isError(self: *const Node) bool {
        // In real implementation, this would check if node is error
        _ = self;
        return false;
    }
    
    pub fn isMissing(self: *const Node) bool {
        // In real implementation, this would call ts_node_is_missing()
        _ = self;
        return false;
    }
    
    pub fn isNamed(self: *const Node) bool {
        // In real implementation, this would call ts_node_is_named()
        _ = self;
        return true;
    }
    
    pub fn isVisible(self: *const Node) bool {
        // In real implementation, this would call ts_node_is_visible()
        _ = self;
        return true;
    }
};

pub const Point = struct {
    row: u32,
    column: u32,
};

pub const Range = struct {
    start_point: Point,
    end_point: Point,
    start_byte: usize,
    end_byte: usize,
};

pub const Query = struct {
    ptr: ?*ts_query = null,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Query {
        return Query{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Query) void {
        // In real implementation, this would call ts_query_delete()
        _ = self;
    }
    
    pub fn captureCount(self: *const Query) u32 {
        // In real implementation, this would call ts_query_capture_count()
        _ = self;
        return 0;
    }
    
    pub fn captureNameForId(self: *const Query, id: u32) []const u8 {
        // In real implementation, this would call ts_query_capture_name_for_id()
        _ = self;
        return "";
    }
};

pub const QueryCursor = struct {
    ptr: ?*ts_query_cursor = null,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) QueryCursor {
        return QueryCursor{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *QueryCursor) void {
        // In real implementation, this would call ts_query_cursor_delete()
        _ = self;
    }
    
    pub fn exec(self: *QueryCursor, query: *const Query, node: *const Node) void {
        // In real implementation, this would call ts_query_cursor_exec()
        _ = self;
        _ = query;
        _ = node;
    }
    
    pub fn nextMatch(self: *QueryCursor) ?QueryMatch {
        // In real implementation, this would call ts_query_cursor_next_match()
        _ = self;
        return null;
    }
};

pub const QueryMatch = struct {
    id: u32,
    pattern_index: u32,
    captures: []QueryCapture,
};

pub const QueryCapture = struct {
    node: Node,
    index: u32,
};

// Language-specific functions (these would be provided by tree-sitter language grammars)
pub const Language = struct {
    name: []const u8,
    lang_fn: fn () ?*const anyopaque,
    highlights_query: ?[]const u8 = null,
    injections_query: ?[]const u8 = null,
};

// Supported languages
pub const languages = struct {
    pub const zig: Language = .{
        .name = "zig",
        .lang_fn = tree_sitter_zig,
        .highlights_query = @embedFile("queries/zig/highlights.scm"),
    };
    
    pub const javascript: Language = .{
        .name = "javascript", 
        .lang_fn = tree_sitter_javascript,
        .highlights_query = @embedFile("queries/javascript/highlights.scm"),
    };
    
    pub const python: Language = .{
        .name = "python",
        .lang_fn = tree_sitter_python,
        .highlights_query = @embedFile("queries/python/highlights.scm"),
    };
    
    pub const rust: Language = .{
        .name = "rust",
        .lang_fn = tree_sitter_rust,
        .highlights_query = @embedFile("queries/rust/highlights.scm"),
    };
    
    pub const go: Language = .{
        .name = "go",
        .lang_fn = tree_sitter_go,
        .highlights_query = @embedFile("queries/go/highlights.scm"),
    };
    
    pub fn fromExtension(ext: []const u8) ?*const Language {
        if (std.mem.eql(u8, ext, ".zig")) return &languages.zig;
        if (std.mem.eql(u8, ext, ".js")) return &languages.javascript;
        if (std.mem.eql(u8, ext, ".ts")) return &languages.javascript;
        if (std.mem.eql(u8, ext, ".py")) return &languages.python;
        if (std.mem.eql(u8, ext, ".rs")) return &languages.rust;
        if (std.mem.eql(u8, ext, ".go")) return &languages.go;
        return null;
    }
};

// Tree-sitter language functions (stubs for now)
fn tree_sitter_zig() ?*const anyopaque {
    // In real implementation, this would return tree_sitter_zig()
    @panic("tree_sitter_zig not implemented - need tree-sitter bindings");
}

fn tree_sitter_javascript() ?*const anyopaque {
    // In real implementation, this would return tree_sitter_javascript()
    @panic("tree_sitter_javascript not implemented - need tree-sitter bindings");
}

fn tree_sitter_python() ?*const anyopaque {
    // In real implementation, this would return tree_sitter_python()
    @panic("tree_sitter_python not implemented - need tree-sitter bindings");
}

fn tree_sitter_rust() ?*const anyopaque {
    // In real implementation, this would return tree_sitter_rust()
    @panic("tree_sitter_rust not implemented - need tree-sitter bindings");
}

fn tree_sitter_go() ?*const anyopaque {
    // In real implementation, this would return tree_sitter_go()
    @panic("tree_sitter_go not implemented - need tree-sitter bindings");
}

// Query cache for better performance
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(*Query),
    
    pub fn init(allocator: std.mem.Allocator) QueryCache {
        return QueryCache{
            .allocator = allocator,
            .cache = std.StringHashMap(*Query).init(allocator),
        };
    }
    
    pub fn deinit(self: *QueryCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
    }
    
    pub fn get(self: *QueryCache, language: *const Language, query_type: QueryType) !*Query {
        const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{
            language.name, @tagName(query_type)
        });
        defer self.allocator.free(key);
        
        if (self.cache.get(key)) |query| {
            return query;
        }
        
        // Create new query
        const query = try self.allocator.create(Query);
        query.* = Query.init(self.allocator);
        
        try self.cache.put(key, query);
        return query;
    }
    
    pub fn release(self: *QueryCache, query: *Query, query_type: QueryType) void {
        // Query would be cached, so no action needed
        _ = self;
        _ = query;
        _ = query_type;
    }
};

pub const QueryType = enum {
    highlights,
    injections,
    locals,
    matches,
};

// VSCode theme integration helper
pub const ThemeColors = struct {
    // Common VSCode theme colors
    @"comment": []const u8 = "#6A9955",
    @"string": []const u8 = "#CE9178",
    @"number": []const u8 = "#B5CEA8",
    @"variable": []const u8 = "#9CDCFE",
    @"type": []const u8 = "#4EC9B0",
    @"function": []const u8 = "#DCDCAA",
    @"keyword": []const u8 = "#569CD6",
    @"operator": []const u8 = "#D4D4D4",
    @"punctuation": []const u8 = "#D4D4D4",
    @"property": []const u8 = "#9CDCFE",
    @"constant": []const u8 = "#4FC1FF",
    @"constructor": []const u8 = "#4EC9B0",
    @"parameter": []const u8 = "#9CDCFE",
    @"tag": []const u8 = "#569CD6",
    @"attribute": []const u8 = "#9CDCFE",
    @"definition": []const u8 = "#569CD6",
    @"reference": []const u8 = "#9CDCFE",
    
    pub fn parseHexColor(color_str: []const u8) !u32 {
        if (color_str.len == 0) return error.EmptyColor;
        if (color_str[0] == '#') {
            const hex = color_str[1..];
            if (hex.len == 6) {
                return std.fmt.parseInt(u32, hex, 16);
            } else if (hex.len == 3) {
                // Expand shorthand hex
                var expanded: [6]u8 = undefined;
                expanded[0] = hex[0];
                expanded[1] = hex[0];
                expanded[2] = hex[1];
                expanded[3] = hex[1];
                expanded[4] = hex[2];
                expanded[5] = hex[2];
                return std.fmt.parseInt(u32, &expanded, 16);
            }
        }
        return error.InvalidColorFormat;
    }
};

// This structure is compatible with zat/flow-syntax design
// In a real implementation, this would be a thin wrapper around the actual tree-sitter C library
