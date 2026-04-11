const std = @import("std");

const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const parser = @import("parser.zig");

/// Codebase knowledge graph — represents code structure as a searchable graph
///
/// Reference: Graphify NetworkX graph building with confidence tags
/// Provides significant token compression (71.5x) vs raw source for AI context
pub const KnowledgeGraph = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(*types.GraphNode),
    edges: std.ArrayList(*types.GraphEdge),
    communities: std.ArrayList(*types.Community),
    file_count: u32,
    total_source_tokens: u64,

    pub fn init(allocator: Allocator) KnowledgeGraph {
        return KnowledgeGraph{
            .allocator = allocator,
            .nodes = std.StringHashMap(*types.GraphNode).init(allocator),
            .edges = std.ArrayList(*types.GraphEdge).init(allocator),
            .communities = std.ArrayList(*types.Community).init(allocator),
            .file_count = 0,
            .total_source_tokens = 0,
        };
    }

    /// Add a node to the graph
    pub fn addNode(self: *KnowledgeGraph, node: *types.GraphNode) !void {
        try self.nodes.put(node.id, node);
    }

    /// Add an edge between two nodes
    pub fn addEdge(self: *KnowledgeGraph, edge: *types.GraphEdge) !void {
        try self.edges.append(edge);
    }

    /// Get a node by ID
    pub fn getNode(self: *KnowledgeGraph, id: []const u8) ?*types.GraphNode {
        return self.nodes.get(id);
    }

    /// Get all nodes of a specific type
    pub fn getNodesByType(self: *KnowledgeGraph, node_type: types.NodeType, allocator: Allocator) ![]*types.GraphNode {
        var result = std.ArrayList(*types.GraphNode).init(allocator);
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.*.node_type == node_type) {
                try result.append(entry.value_ptr.*);
            }
        }
        return result.toOwnedSlice();
    }

    /// Get edges from a node
    pub fn getEdgesFrom(self: *KnowledgeGraph, node_id: []const u8, allocator: Allocator) ![]*types.GraphEdge {
        var result = std.ArrayList(*types.GraphEdge).init(allocator);
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.source_id, node_id)) {
                try result.append(edge);
            }
        }
        return result.toOwnedSlice();
    }

    /// Get edges to a node
    pub fn getEdgesTo(self: *KnowledgeGraph, node_id: []const u8, allocator: Allocator) ![]*types.GraphEdge {
        var result = std.ArrayList(*types.GraphEdge).init(allocator);
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.target_id, node_id)) {
                try result.append(edge);
            }
        }
        return result.toOwnedSlice();
    }

    /// Index a source file into the graph
    pub fn indexFile(self: *KnowledgeGraph, file_path: []const u8) !void {
        var src_parser = parser.SourceParser.init(self.allocator);
        const result = src_parser.parseFile(file_path) catch return orelse return;
        self.file_count += 1;

        // Extract module name from file path
        const module_name = self.extractModuleName(file_path);
        const module_id = try std.fmt.allocPrint(self.allocator, "mod.{s}", .{module_name});

        // Add module node
        const mod_node = try self.allocator.create(types.GraphNode);
        mod_node.* = try types.GraphNode.init(self.allocator, module_id, module_name, .module, file_path, 1);
        try self.addNode(mod_node);

        // Process symbols
        for (result.symbols.items) |sym| {
            const node_id = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, sym.name });
            const node = try self.allocator.create(types.GraphNode);
            node.* = types.GraphNode{
                .id = node_id,
                .name = try self.allocator.dupe(u8, sym.name),
                .node_type = sym.symbol_type,
                .file_path = try self.allocator.dupe(u8, file_path),
                .line = sym.line,
                .end_line = sym.end_line,
                .signature = if (sym.signature) |s| try self.allocator.dupe(u8, s) else null,
                .doc_comment = if (sym.doc_comment) |d| try self.allocator.dupe(u8, d) else null,
                .token_count = sym.end_line - sym.line + 1,
                .allocator = self.allocator,
            };
            try self.addNode(node);

            // Add contains edge: module → symbol
            const edge = try self.allocator.create(types.GraphEdge);
            edge.* = try types.GraphEdge.init(self.allocator, module_id, node_id, .contains, .extracted);
            try self.addEdge(edge);

            self.total_source_tokens += node.token_count;
        }

        // Process imports
        for (result.imports.items) |imp| {
            const edge = try self.allocator.create(types.GraphEdge);
            edge.* = try types.GraphEdge.init(self.allocator, module_id, imp, .imports, .extracted);
            try self.addEdge(edge);
        }
    }

    /// Detect communities (clusters of related nodes) using simple connectivity analysis
    /// Reference: Graphify Leiden community detection
    pub fn detectCommunities(self: *KnowledgeGraph) !void {
        // Simple community detection: group by file path
        var file_groups = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
        defer {
            var iter = file_groups.iterator();
            while (iter.next()) |entry| {
                for (entry.value_ptr.items) |id| self.allocator.free(id);
                entry.value_ptr.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            file_groups.deinit();
        }

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            const gop = try file_groups.getOrPut(node.file_path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, node.file_path);
                gop.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
            }
            try gop.value_ptr.append(try self.allocator.dupe(u8, node.id));
        }

        var community_id: u32 = 0;
        var group_iter = file_groups.iterator();
        while (group_iter.next()) |entry| {
            if (entry.value_ptr.items.len < 2) continue;

            const community = try self.allocator.create(types.Community);
            const c_name = self.extractModuleName(entry.key_ptr.*);
            community.* = types.Community.init(self.allocator, community_id, c_name);
            community_id += 1;

            for (entry.value_ptr.items) |node_id| {
                try community.addNode(node_id);
            }

            // Calculate cohesion based on internal edges
            var internal_edges: u32 = 0;
            for (self.edges.items) |edge| {
                for (entry.value_ptr.items) |nid| {
                    if (std.mem.eql(u8, edge.source_id, nid)) {
                        for (entry.value_ptr.items) |nid2| {
                            if (std.mem.eql(u8, edge.target_id, nid2)) {
                                internal_edges += 1;
                            }
                        }
                    }
                }
            }
            const max_possible: f32 = @floatFromInt(entry.value_ptr.items.len * (entry.value_ptr.items.len - 1));
            community.cohesion = if (max_possible > 0) @as(f32, @floatFromInt(internal_edges)) / max_possible else 0.0;

            try self.communities.append(community);
        }
    }

    /// Generate a compressed representation of the graph for AI context
    /// Returns a string with significant token compression vs raw source
    pub fn toCompressedContext(self: *KnowledgeGraph, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("=== Codebase Knowledge Graph ===\n", .{});
        try writer.print("Files: {d} | Nodes: {d} | Edges: {d} | Communities: {d}\n\n", .{
            self.file_count,
            self.nodes.count(),
            self.edges.items.len,
            self.communities.items.len,
        });

        // Communities overview
        if (self.communities.items.len > 0) {
            try writer.print("## Architecture (Communities)\n", .{});
            for (self.communities.items) |community| {
                try writer.print("  [{d}] {s} ({d} symbols, cohesion: {d:.2})\n", .{
                    community.id,
                    community.name,
                    community.node_ids.items.len,
                    community.cohesion,
                });
            }
            try writer.print("\n", .{});
        }

        // Module-level view
        try writer.print("## Modules\n", .{});
        var mod_iter = self.nodes.iterator();
        while (mod_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.node_type != .module) continue;
            try writer.print("  {s} ({s})\n", .{ node.name, node.file_path });
        }

        // Symbol summary
        try writer.print("\n## Symbols\n", .{});
        var sym_iter = self.nodes.iterator();
        while (sym_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.node_type == .module) continue;
            const type_label = @tagName(node.node_type);
            try writer.print("  {s} [{s}] {s}:{d}", .{ node.id, type_label, node.file_path, node.line });
            if (node.doc_comment) |doc| {
                try writer.print(" — {s}", .{doc});
            }
            try writer.print("\n", .{});
        }

        return buf.toOwnedSlice();
    }

    /// Calculate token compression ratio
    pub fn compressionRatio(self: *KnowledgeGraph) f64 {
        if (self.total_source_tokens == 0) return 0.0;
        const graph_tokens: f64 = @floatFromInt(self.nodes.count() * 5 + self.edges.items.len * 3);
        const source_tokens: f64 = @floatFromInt(self.total_source_tokens);
        return source_tokens / graph_tokens;
    }

    /// Print graph statistics
    pub fn printStats(self: *KnowledgeGraph) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\n=== Knowledge Graph Statistics ===\n", .{}) catch {};
        stdout.print("  Files indexed: {d}\n", .{self.file_count}) catch {};
        stdout.print("  Nodes: {d}\n", .{self.nodes.count()}) catch {};
        stdout.print("  Edges: {d}\n", .{self.edges.items.len}) catch {};
        stdout.print("  Communities: {d}\n", .{self.communities.items.len}) catch {};

        // Count by type
        var type_counts = std.AutoHashMap(types.NodeType, u32).init(self.allocator);
        defer type_counts.deinit();
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const t = entry.value_ptr.*.node_type;
            const gop = type_counts.getOrPut(t) catch continue;
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        stdout.print("\n  By type:\n", .{}) catch {};
        var tc_iter = type_counts.iterator();
        while (tc_iter.next()) |entry| {
            stdout.print("    {s}: {d}\n", .{ @tagName(entry.key_ptr.*), entry.value_ptr.* }) catch {};
        }

        const ratio = self.compressionRatio();
        if (ratio > 0) {
            stdout.print("\n  Compression ratio: {d:.1}x\n", .{ratio}) catch {};
        }
    }

    /// Extract module name from file path
    fn extractModuleName(_: *KnowledgeGraph, file_path: []const u8) []const u8 {
        // Get filename without extension
        const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return file_path;
        const filename = file_path[last_slash + 1 ..];
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
        return filename[0..dot];
    }

    pub fn deinit(self: *KnowledgeGraph) void {
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.nodes.deinit();

        for (self.edges.items) |edge| {
            edge.deinit();
            self.allocator.destroy(edge);
        }
        self.edges.deinit();

        for (self.communities.items) |community| {
            community.deinit();
            self.allocator.destroy(community);
        }
        self.communities.deinit();
    }
};
