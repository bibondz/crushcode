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
        const result_opt = src_parser.parseFile(file_path) catch return orelse return;
        var result = result_opt;
        defer result.deinit();
        self.file_count += 1;

        // Extract module name from file path
        const module_name = self.extractModuleName(file_path);
        const module_id_tmp = try std.fmt.allocPrint(self.allocator, "mod.{s}", .{module_name});

        // Add module node (GraphNode.init dupes the id, so free the tmp after)
        const mod_node = try self.allocator.create(types.GraphNode);
        mod_node.* = try types.GraphNode.init(self.allocator, module_id_tmp, module_name, .module, file_path, 1);
        try self.addNode(mod_node);
        self.allocator.free(module_id_tmp);

        // Process symbols
        for (result.symbols.items) |sym| {
            const node_id = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, sym.name });
            // node_id is now owned by the GraphNode and will be freed by deinit
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
            edge.* = try types.GraphEdge.init(self.allocator, mod_node.id, node.id, .contains, .extracted);
            try self.addEdge(edge);

            self.total_source_tokens += node.token_count;
        }

        // Process imports
        for (result.imports.items) |imp| {
            const edge = try self.allocator.create(types.GraphEdge);
            edge.* = try types.GraphEdge.init(self.allocator, mod_node.id, imp, .imports, .extracted);
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
        const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
        const filename = if (last_slash > 0) file_path[last_slash + 1 ..] else file_path;
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
        return filename[0..dot];
    }

    pub fn deinit(self: *KnowledgeGraph) void {
        // Collect all node pointers first, then clean up
        // (we can't iterate and free keys simultaneously since StringHashMap
        // stores key pointers that are the same as node.id)
        var node_list = std.ArrayList(*types.GraphNode).init(self.allocator);
        defer node_list.deinit();
        {
            var node_iter = self.nodes.iterator();
            while (node_iter.next()) |entry| {
                node_list.append(entry.value_ptr.*) catch {};
            }
        }
        // Free the hash map (doesn't free keys — we do that via node deinit)
        self.nodes.deinit();
        // Now free each node
        for (node_list.items) |node| {
            node.deinit();
            self.allocator.destroy(node);
        }

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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "KnowledgeGraph init/deinit" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();
    try testing.expectEqual(@as(u32, 0), graph.file_count);
    try testing.expectEqual(@as(u64, 0), graph.total_source_tokens);
}

test "KnowledgeGraph addNode and getNode" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node = try testing.allocator.create(types.GraphNode);
    node.* = try types.GraphNode.init(testing.allocator, "mod.func1", "func1", .function, "src/test.zig", 10);
    try graph.addNode(node);

    const retrieved = graph.getNode("mod.func1");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("func1", retrieved.?.name);
    try testing.expectEqual(types.NodeType.function, retrieved.?.node_type);

    const missing = graph.getNode("mod.nonexistent");
    try testing.expect(missing == null);
}

test "KnowledgeGraph addEdge" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node1 = try testing.allocator.create(types.GraphNode);
    node1.* = try types.GraphNode.init(testing.allocator, "mod.func1", "func1", .function, "src/a.zig", 1);
    try graph.addNode(node1);

    const node2 = try testing.allocator.create(types.GraphNode);
    node2.* = try types.GraphNode.init(testing.allocator, "mod.func2", "func2", .function, "src/b.zig", 5);
    try graph.addNode(node2);

    const edge = try testing.allocator.create(types.GraphEdge);
    edge.* = try types.GraphEdge.init(testing.allocator, "mod.func1", "mod.func2", .calls, .extracted);
    try graph.addEdge(edge);

    try testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try testing.expectEqualStrings("mod.func1", graph.edges.items[0].source_id);
    try testing.expectEqualStrings("mod.func2", graph.edges.items[0].target_id);
}

test "KnowledgeGraph getNodesByType" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const func_node = try testing.allocator.create(types.GraphNode);
    func_node.* = try types.GraphNode.init(testing.allocator, "mod.fn1", "fn1", .function, "src/a.zig", 1);
    try graph.addNode(func_node);

    const struct_node = try testing.allocator.create(types.GraphNode);
    struct_node.* = try types.GraphNode.init(testing.allocator, "mod.S1", "S1", .struct_decl, "src/a.zig", 10);
    try graph.addNode(struct_node);

    const mod_node = try testing.allocator.create(types.GraphNode);
    mod_node.* = try types.GraphNode.init(testing.allocator, "mod.test", "test", .module, "src/a.zig", 1);
    try graph.addNode(mod_node);

    const funcs = try graph.getNodesByType(.function, testing.allocator);
    defer testing.allocator.free(funcs);
    try testing.expectEqual(@as(usize, 1), funcs.len);

    const structs = try graph.getNodesByType(.struct_decl, testing.allocator);
    defer testing.allocator.free(structs);
    try testing.expectEqual(@as(usize, 1), structs.len);

    const modules = try graph.getNodesByType(.module, testing.allocator);
    defer testing.allocator.free(modules);
    try testing.expectEqual(@as(usize, 1), modules.len);
}

test "KnowledgeGraph getEdgesFrom/To" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const node_a = try testing.allocator.create(types.GraphNode);
    node_a.* = try types.GraphNode.init(testing.allocator, "a", "a", .function, "a.zig", 1);
    try graph.addNode(node_a);

    const node_b = try testing.allocator.create(types.GraphNode);
    node_b.* = try types.GraphNode.init(testing.allocator, "b", "b", .function, "b.zig", 1);
    try graph.addNode(node_b);

    const node_c = try testing.allocator.create(types.GraphNode);
    node_c.* = try types.GraphNode.init(testing.allocator, "c", "c", .function, "c.zig", 1);
    try graph.addNode(node_c);

    const edge_ab = try testing.allocator.create(types.GraphEdge);
    edge_ab.* = try types.GraphEdge.init(testing.allocator, "a", "b", .calls, .extracted);
    try graph.addEdge(edge_ab);

    const edge_ac = try testing.allocator.create(types.GraphEdge);
    edge_ac.* = try types.GraphEdge.init(testing.allocator, "a", "c", .references, .inferred);
    try graph.addEdge(edge_ac);

    const from_a = try graph.getEdgesFrom("a", testing.allocator);
    defer testing.allocator.free(from_a);
    try testing.expectEqual(@as(usize, 2), from_a.len);

    const to_b = try graph.getEdgesTo("b", testing.allocator);
    defer testing.allocator.free(to_b);
    try testing.expectEqual(@as(usize, 1), to_b.len);

    const to_c = try graph.getEdgesTo("c", testing.allocator);
    defer testing.allocator.free(to_c);
    try testing.expectEqual(@as(usize, 1), to_c.len);
}

test "KnowledgeGraph detectCommunities groups nodes by file" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Add module node
    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "mymod", "mymod", .module, "src/mymod.zig", 1);
    try graph.addNode(mod);

    // Add 3 functions in the same file (enough for community)
    for ([_][]const u8{ "mymod.fn1", "mymod.fn2", "mymod.fn3" }, 0..) |id, i| {
        const node = try testing.allocator.create(types.GraphNode);
        node.* = try types.GraphNode.init(testing.allocator, id, id[7..], .function, "src/mymod.zig", @intCast(i + 1));
        try graph.addNode(node);
    }

    try graph.detectCommunities();
    try testing.expectEqual(@as(usize, 1), graph.communities.items.len);
    try testing.expect(graph.communities.items[0].node_ids.items.len >= 2);
}

test "KnowledgeGraph toCompressedContext generates output" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "mymod", "mymod", .module, "src/mymod.zig", 1);
    try graph.addNode(mod);

    const func = try testing.allocator.create(types.GraphNode);
    func.* = try types.GraphNode.init(testing.allocator, "mymod.hello", "hello", .function, "src/mymod.zig", 10);
    try graph.addNode(func);

    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "Codebase Knowledge Graph") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "mymod") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "hello") != null);
}

test "KnowledgeGraph compressionRatio" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // No tokens yet
    try testing.expectEqual(@as(f64, 0.0), graph.compressionRatio());

    // Add some nodes with token counts
    const mod = try testing.allocator.create(types.GraphNode);
    mod.* = try types.GraphNode.init(testing.allocator, "m", "m", .module, "a.zig", 1);
    try graph.addNode(mod);

    const fn1 = try testing.allocator.create(types.GraphNode);
    fn1.* = try types.GraphNode.init(testing.allocator, "m.f1", "f1", .function, "a.zig", 1);
    fn1.token_count = 100;
    try graph.addNode(fn1);

    graph.total_source_tokens = 100;
    const ratio = graph.compressionRatio();
    try testing.expect(ratio > 0.0);
}

test "KnowledgeGraph extractModuleName" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    const name = graph.extractModuleName("src/graph/parser.zig");
    try testing.expectEqualStrings("parser", name);

    const name2 = graph.extractModuleName("build.zig");
    try testing.expectEqualStrings("build", name2);

    const name3 = graph.extractModuleName("src/ai/client.zig");
    try testing.expectEqualStrings("client", name3);
}

test "KnowledgeGraph indexFile parses real Zig source" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Index types.zig — should find the module + struct declarations
    try graph.indexFile("src/graph/types.zig");

    // Module node is "mod.types", symbol nodes are "types.GraphNode" etc.
    try testing.expect(graph.getNode("mod.types") != null);
    try testing.expect(graph.getNode("types.GraphNode") != null);
    try testing.expect(graph.getNode("types.GraphEdge") != null);
    try testing.expect(graph.getNode("types.Community") != null);

    // Verify it has edges (contains edges from module to symbols)
    try testing.expect(graph.edges.items.len > 0);

    // Check compressed context
    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "GraphNode") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "types") != null);
}

test "KnowledgeGraph indexFile parses real codebase files" {
    var graph = KnowledgeGraph.init(testing.allocator);
    defer graph.deinit();

    // Index several files to test multi-file graph building
    try graph.indexFile("src/graph/parser.zig");
    try graph.indexFile("src/graph/types.zig");
    try graph.indexFile("src/graph/graph.zig");

    try testing.expectEqual(@as(u32, 3), graph.file_count);
    try testing.expect(graph.nodes.count() > 10); // Should have many symbols

    // Detect communities
    try graph.detectCommunities();
    try testing.expect(graph.communities.items.len > 0);

    // Generate compressed context
    const ctx = try graph.toCompressedContext(testing.allocator);
    defer testing.allocator.free(ctx);
    try testing.expect(std.mem.indexOf(u8, ctx, "Modules") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Symbols") != null);
}
