const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Confidence level for graph relationships
/// Reference: Graphify confidence tags (EXTRACTED/INFERRED/AMBIGUOUS)
pub const Confidence = enum {
    extracted, // Directly observed in source (e.g., function call, import)
    inferred, // Logically deduced (e.g., interface implementation)
    ambiguous, // Uncertain relationship
};

/// Node types in the codebase graph
pub const NodeType = enum {
    function,
    method,
    struct_decl,
    enum_decl,
    union_decl,
    constant,
    variable,
    import,
    module,
    file,
    type_ref,
    interface,
    test_case,
};

/// Edge types representing relationships between nodes
pub const EdgeType = enum {
    calls, // A calls B
    imports, // A imports B
    inherits, // A inherits from B
    implements, // A implements interface B
    references, // A references type B
    contains, // Module A contains symbol B
    depends_on, // Module A depends on module B
    tests, // Test A tests function B
};

/// A node in the codebase knowledge graph
pub const GraphNode = struct {
    id: []const u8, // Unique identifier (e.g., "module.function")
    name: []const u8, // Short name (e.g., "sendChat")
    node_type: NodeType,
    file_path: []const u8,
    line: u32,
    end_line: u32,
    signature: ?[]const u8, // Function/type signature
    doc_comment: ?[]const u8, // Documentation
    token_count: u32, // Estimated tokens for this node
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        name: []const u8,
        node_type: NodeType,
        file_path: []const u8,
        line: u32,
    ) !GraphNode {
        return GraphNode{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .node_type = node_type,
            .file_path = try allocator.dupe(u8, file_path),
            .line = line,
            .end_line = line,
            .signature = null,
            .doc_comment = null,
            .token_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphNode) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.file_path);
        if (self.signature) |s| self.allocator.free(s);
        if (self.doc_comment) |d| self.allocator.free(d);
    }
};

/// An edge between two nodes in the graph
pub const GraphEdge = struct {
    source_id: []const u8,
    target_id: []const u8,
    edge_type: EdgeType,
    confidence: Confidence,
    weight: f32, // Relationship strength (0.0-1.0)
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        source_id: []const u8,
        target_id: []const u8,
        edge_type: EdgeType,
        confidence: Confidence,
    ) !GraphEdge {
        return GraphEdge{
            .source_id = try allocator.dupe(u8, source_id),
            .target_id = try allocator.dupe(u8, target_id),
            .edge_type = edge_type,
            .confidence = confidence,
            .weight = switch (confidence) {
                .extracted => 1.0,
                .inferred => 0.7,
                .ambiguous => 0.4,
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphEdge) void {
        self.allocator.free(self.source_id);
        self.allocator.free(self.target_id);
    }
};

/// Community (cluster) of related nodes
pub const Community = struct {
    id: u32,
    name: []const u8,
    node_ids: array_list_compat.ArrayList([]const u8),
    cohesion: f32, // How tightly connected (0.0-1.0)
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: u32, name: []const u8) Community {
        return Community{
            .id = id,
            .name = allocator.dupe(u8, name) catch "",
            .node_ids = array_list_compat.ArrayList([]const u8).init(allocator),
            .cohesion = 0.0,
            .allocator = allocator,
        };
    }

    pub fn addNode(self: *Community, node_id: []const u8) !void {
        try self.node_ids.append(try self.allocator.dupe(u8, node_id));
    }

    pub fn deinit(self: *Community) void {
        for (self.node_ids.items) |id| {
            self.allocator.free(id);
        }
        self.node_ids.deinit();
        if (self.name.len > 0) self.allocator.free(self.name);
    }
};
