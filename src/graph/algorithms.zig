const std = @import("std");
const array_list_compat = @import("array_list_compat");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// Result types
// ============================================================================

/// PageRank result — maps node IDs to rank scores
pub const PageRankResult = struct {
    ranks: std.StringHashMap(f64),
    allocator: Allocator,

    pub fn init(allocator: Allocator) PageRankResult {
        return .{
            .ranks = std.StringHashMap(f64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PageRankResult) void {
        var iter = self.ranks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ranks.deinit();
    }
};

/// Similarity result for findSimilar
pub const SimilarityResult = struct {
    node_id: []const u8,
    similarity: f64,
};

/// Cluster from tag-based grouping
pub const TagCluster = struct {
    tag: []const u8,
    node_ids: array_list_compat.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, tag: []const u8) !TagCluster {
        return .{
            .tag = try allocator.dupe(u8, tag),
            .node_ids = array_list_compat.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TagCluster) void {
        for (self.node_ids.items) |id| {
            self.allocator.free(id);
        }
        self.node_ids.deinit();
        self.allocator.free(self.tag);
    }
};

/// Graph data passed to algorithm functions — avoids circular import
pub const GraphData = struct {
    nodes: *std.StringHashMap(*types.GraphNode),
    edges: *array_list_compat.ArrayList(*types.GraphEdge),
};

// ============================================================================
// PageRank — iterative power method
// ============================================================================

/// Compute PageRank for all nodes in the graph using the iterative power method.
/// `damping` is typically 0.85. `max_iterations` caps iterations. `tolerance` stops early.
/// Treats edges as undirected (both source→target and target→source contribute).
pub fn computePageRank(
    graph: GraphData,
    allocator: Allocator,
    damping: f64,
    max_iterations: u32,
    tolerance: f64,
) !PageRankResult {
    var result = PageRankResult.init(allocator);
    errdefer result.deinit();

    const n = graph.nodes.count();
    if (n == 0) return result;

    // Collect all node IDs into a slice for indexed access
    var node_ids = array_list_compat.ArrayList([]const u8).init(allocator);
    defer node_ids.deinit();

    var node_iter = graph.nodes.iterator();
    while (node_iter.next()) |entry| {
        const id_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try node_ids.append(id_copy);
    }

    // Build adjacency: for each node, store list of node IDs that point TO it (in-neighbors)
    // and count of outgoing edges (out-degree).
    var in_neighbors = std.StringHashMap(array_list_compat.ArrayList(usize)).init(allocator);
    var out_degree = std.StringHashMap(u32).init(allocator);
    defer {
        var in_iter = in_neighbors.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit();
            allocator.free(entry.key_ptr.*);
        }
        in_neighbors.deinit();
        var od_iter = out_degree.iterator();
        while (od_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        out_degree.deinit();
    }

    // Initialize out-degree and in-neighbor lists
    for (node_ids.items) |id| {
        const od_key = try allocator.dupe(u8, id);
        try out_degree.put(od_key, 0);

        const in_key = try allocator.dupe(u8, id);
        try in_neighbors.put(in_key, array_list_compat.ArrayList(usize).init(allocator));
    }

    // Helper: find index of a node ID in node_ids
    const indexOf = struct {
        fn call(ids: []const []const u8, target: []const u8) ?usize {
            for (ids, 0..) |id, i| {
                if (std.mem.eql(u8, id, target)) return i;
            }
            return null;
        }
    }.call;

    // Populate adjacency from edges (undirected: both directions)
    for (graph.edges.items) |edge| {
        if (indexOf(node_ids.items, edge.source_id)) |src_idx| {
            if (indexOf(node_ids.items, edge.target_id)) |tgt_idx| {
                // source → target
                if (out_degree.getPtr(edge.source_id)) |od| {
                    od.* += 1;
                }
                if (in_neighbors.getPtr(edge.target_id)) |neighbors| {
                    neighbors.append(src_idx) catch {};
                }
                // Also add reverse: target → source (undirected)
                if (out_degree.getPtr(edge.target_id)) |od| {
                    od.* += 1;
                }
                if (in_neighbors.getPtr(edge.source_id)) |neighbors| {
                    neighbors.append(tgt_idx) catch {};
                }
            }
        }
    }

    // Initialize ranks uniformly: 1/N
    var ranks = try allocator.alloc(f64, n);
    defer allocator.free(ranks);
    const initial_rank = 1.0 / @as(f64, @floatFromInt(n));
    for (ranks) |*r| r.* = initial_rank;

    // Power iteration
    var new_ranks = try allocator.alloc(f64, n);
    defer allocator.free(new_ranks);

    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        // Calculate new ranks
        for (new_ranks) |*nr| {
            nr.* = (1.0 - damping) / @as(f64, @floatFromInt(n));
        }

        for (node_ids.items, 0..) |id, i| {
            const neighbors = in_neighbors.get(id) orelse continue;
            const od = out_degree.get(id) orelse 0;
            if (od == 0) continue;
            const share = ranks[i] / @as(f64, @floatFromInt(od));
            for (neighbors.items) |neighbor_idx| {
                new_ranks[neighbor_idx] += damping * share;
            }
        }

        // Check convergence
        var max_delta: f64 = 0.0;
        for (ranks, new_ranks, 0..) |old, new, i| {
            const delta = @abs(new - old);
            if (delta > max_delta) max_delta = delta;
            ranks[i] = new;
        }

        if (max_delta < tolerance) break;
    }

    // Store results
    for (node_ids.items, 0..) |id, i| {
        const id_for_map = try allocator.dupe(u8, id);
        try result.ranks.put(id_for_map, ranks[i]);
    }

    return result;
}

// ============================================================================
// Jaccard Similarity
// ============================================================================

/// Compute Jaccard similarity between two nodes based on their neighbor sets.
/// Returns 0.0 if either node has no neighbors.
pub fn computeJaccardSimilarity(
    graph: GraphData,
    node_a: []const u8,
    node_b: []const u8,
) f64 {
    // We need a temporary allocator for the hash maps.
    // Use the graph's allocator from any node.
    var node_iter = graph.nodes.iterator();
    const allocator = if (node_iter.next()) |entry| entry.value_ptr.*.allocator else return 0.0;

    var neighbors_a = std.StringHashMap(void).init(allocator);
    defer neighbors_a.deinit();
    var neighbors_b = std.StringHashMap(void).init(allocator);
    defer neighbors_b.deinit();

    for (graph.edges.items) |edge| {
        // Neighbors of a
        if (std.mem.eql(u8, edge.source_id, node_a)) {
            _ = neighbors_a.getOrPut(edge.target_id) catch {};
        }
        if (std.mem.eql(u8, edge.target_id, node_a)) {
            _ = neighbors_a.getOrPut(edge.source_id) catch {};
        }
        // Neighbors of b
        if (std.mem.eql(u8, edge.source_id, node_b)) {
            _ = neighbors_b.getOrPut(edge.target_id) catch {};
        }
        if (std.mem.eql(u8, edge.target_id, node_b)) {
            _ = neighbors_b.getOrPut(edge.source_id) catch {};
        }
    }

    const size_a: f64 = @floatFromInt(neighbors_a.count());
    const size_b: f64 = @floatFromInt(neighbors_b.count());
    if (size_a == 0 and size_b == 0) return 1.0; // Both empty → identical
    if (size_a == 0 or size_b == 0) return 0.0;

    // Count intersection
    var intersection: f64 = 0.0;
    var iter = neighbors_a.iterator();
    while (iter.next()) |entry| {
        if (neighbors_b.contains(entry.key_ptr.*)) {
            intersection += 1.0;
        }
    }

    // Jaccard = |A ∩ B| / |A ∪ B| = intersection / (size_a + size_b - intersection)
    const union_size = size_a + size_b - intersection;
    if (union_size == 0) return 0.0;
    return intersection / union_size;
}

// ============================================================================
// Bridge Detection (Articulation Points)
// ============================================================================

/// Find bridge nodes (articulation points) whose removal would disconnect the graph.
/// Uses Tarjan's algorithm for finding articulation points.
pub fn findBridges(
    graph: GraphData,
    allocator: Allocator,
) ![][]const u8 {
    var result = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |id| allocator.free(id);
        result.deinit();
    }

    const n = graph.nodes.count();
    if (n == 0) return result.toOwnedSlice();

    // Build adjacency list (undirected)
    var node_ids = array_list_compat.ArrayList([]const u8).init(allocator);
    defer node_ids.deinit();

    var node_iter = graph.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_ids.append(entry.key_ptr.*);
    }

    // Index lookup
    const indexOf = struct {
        fn call(ids: []const []const u8, target: []const u8) ?usize {
            for (ids, 0..) |id, i| {
                if (std.mem.eql(u8, id, target)) return i;
            }
            return null;
        }
    }.call;

    // Adjacency: idx → list of neighbor idxs
    var adj = try allocator.alloc(array_list_compat.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit();
        allocator.free(adj);
    }
    for (adj) |*list| list.* = array_list_compat.ArrayList(usize).init(allocator);

    for (graph.edges.items) |edge| {
        if (indexOf(node_ids.items, edge.source_id)) |src_idx| {
            if (indexOf(node_ids.items, edge.target_id)) |tgt_idx| {
                try adj[src_idx].append(tgt_idx);
                try adj[tgt_idx].append(src_idx);
            }
        }
    }

    // Tarjan's articulation point algorithm state
    var visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    var disc = try allocator.alloc(u32, n); // Discovery time
    defer allocator.free(disc);
    @memset(disc, 0);

    var low = try allocator.alloc(u32, n); // Lowest discovery time reachable
    defer allocator.free(low);
    @memset(low, 0);

    var parent = try allocator.alloc(i32, n);
    defer allocator.free(parent);
    @memset(parent, -1);

    var is_articulation = try allocator.alloc(bool, n);
    defer allocator.free(is_articulation);
    @memset(is_articulation, false);

    var time: u32 = 0;

    // DFS using explicit stack to avoid stack overflow on large graphs
    const StackFrame = struct {
        u: usize,
        child_idx: usize,
        started: bool,
    };
    var stack = array_list_compat.ArrayList(StackFrame).init(allocator);
    defer stack.deinit();

    for (0..n) |start| {
        if (visited[start]) continue;

        try stack.append(.{ .u = start, .child_idx = 0, .started = false });

        while (stack.items.len > 0) {
            var frame = &stack.items[stack.items.len - 1];

            if (!frame.started) {
                frame.started = true;
                visited[frame.u] = true;
                disc[frame.u] = time;
                low[frame.u] = time;
                time += 1;
            }

            // Process children of frame.u
            if (frame.child_idx < adj[frame.u].items.len) {
                const child = adj[frame.u].items[frame.child_idx];
                frame.child_idx += 1;

                if (!visited[child]) {
                    parent[child] = @intCast(frame.u);
                    try stack.append(.{ .u = child, .child_idx = 0, .started = false });
                } else if (@as(i32, @intCast(child)) != parent[frame.u]) {
                    // Back edge
                    if (disc[child] < low[frame.u]) {
                        low[frame.u] = disc[child];
                    }
                }
            } else {
                // All children processed — update parent's low and check articulation
                _ = stack.pop();

                if (stack.items.len > 0) {
                    const p = stack.items[stack.items.len - 1].u;
                    if (low[frame.u] < low[p]) {
                        low[p] = low[frame.u];
                    }

                    // Check articulation condition:
                    // (1) p is root and has 2+ children, or
                    // (2) p is not root and low[frame.u] >= disc[p]
                    const root = parent[p] == -1;
                    if (root) {
                        // Count children of root
                        var child_count: u32 = 0;
                        for (adj[p].items) |c| {
                            if (@as(i32, @intCast(c)) == parent[p]) continue;
                            if (visited[c]) child_count += 1;
                        }
                        if (child_count >= 2) is_articulation[p] = true;
                    } else {
                        if (low[frame.u] >= disc[p]) is_articulation[p] = true;
                    }
                }
            }
        }
    }

    // Collect articulation points
    for (node_ids.items, 0..) |id, i| {
        if (is_articulation[i]) {
            try result.append(try allocator.dupe(u8, id));
        }
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Path Finding (BFS multi-hop)
// ============================================================================

/// Find a path between two nodes using BFS. Returns intermediate node IDs in the path.
/// `max_hops` limits the search depth. Returns empty if no path found.
pub fn findPaths(
    graph: GraphData,
    allocator: Allocator,
    from_id: []const u8,
    to_id: []const u8,
    max_hops: u32,
) ![][]const u8 {
    // Handle trivial case
    if (std.mem.eql(u8, from_id, to_id)) return &[_][]const u8{};

    var node_ids = array_list_compat.ArrayList([]const u8).init(allocator);
    defer node_ids.deinit();

    var node_iter = graph.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_ids.append(entry.key_ptr.*);
    }

    const indexOf = struct {
        fn call(ids: []const []const u8, target: []const u8) ?usize {
            for (ids, 0..) |id, i| {
                if (std.mem.eql(u8, id, target)) return i;
            }
            return null;
        }
    }.call;

    const n = node_ids.items.len;
    if (n == 0) return &[_][]const u8{};

    const from_idx = indexOf(node_ids.items, from_id) orelse return &[_][]const u8{};
    const to_idx = indexOf(node_ids.items, to_id) orelse return &[_][]const u8{};

    // Build undirected adjacency
    var adj = try allocator.alloc(array_list_compat.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit();
        allocator.free(adj);
    }
    for (adj) |*list| list.* = array_list_compat.ArrayList(usize).init(allocator);

    for (graph.edges.items) |edge| {
        if (indexOf(node_ids.items, edge.source_id)) |src_idx| {
            if (indexOf(node_ids.items, edge.target_id)) |tgt_idx| {
                try adj[src_idx].append(tgt_idx);
                try adj[tgt_idx].append(src_idx);
            }
        }
    }

    // BFS
    var visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    var parent_arr = try allocator.alloc(i32, n);
    defer allocator.free(parent_arr);
    @memset(parent_arr, -1);

    var dist = try allocator.alloc(u32, n);
    defer allocator.free(dist);
    @memset(dist, std.math.maxInt(u32));

    var queue = array_list_compat.ArrayList(usize).init(allocator);
    defer queue.deinit();

    visited[from_idx] = true;
    dist[from_idx] = 0;
    try queue.append(from_idx);

    var found = false;
    var q_idx: usize = 0;
    while (q_idx < queue.items.len) : (q_idx += 1) {
        const u = queue.items[q_idx];
        if (u == to_idx) {
            found = true;
            break;
        }
        if (dist[u] >= max_hops) continue;

        for (adj[u].items) |v| {
            if (!visited[v]) {
                visited[v] = true;
                parent_arr[v] = @intCast(u);
                dist[v] = dist[u] + 1;
                try queue.append(v);
            }
        }
    }

    if (!found) return &[_][]const u8{};

    // Reconstruct path
    var path = array_list_compat.ArrayList(usize).init(allocator);
    defer path.deinit();

    var cur: i32 = @intCast(to_idx);
    while (cur != -1) {
        try path.append(@intCast(cur));
        cur = parent_arr[@intCast(cur)];
    }

    // Reverse to get from→to order, skip start node
    var result = array_list_compat.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |id| allocator.free(id);
        result.deinit();
    }

    // path is to→from, iterate in reverse
    var i: usize = path.items.len;
    while (i > 0) {
        i -= 1;
        const idx = path.items[i];
        // Skip the start node itself
        if (idx == from_idx) continue;
        try result.append(try allocator.dupe(u8, node_ids.items[idx]));
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Tag-based Clustering
// ============================================================================

/// Group nodes by shared attributes (file path used as proxy for tags).
/// Each unique file path becomes a cluster containing all nodes from that file.
pub fn clusterByTags(
    graph: GraphData,
    allocator: Allocator,
) ![]TagCluster {
    var cluster_map = std.StringHashMap(*TagCluster).init(allocator);
    defer {
        var iter = cluster_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        cluster_map.deinit();
    }

    var cluster_list = array_list_compat.ArrayList(*TagCluster).init(allocator);
    errdefer {
        for (cluster_list.items) |c| {
            var mut = c.*;
            mut.deinit();
            allocator.destroy(c);
        }
        cluster_list.deinit();
    }

    var node_iter = graph.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;

        // Use file_path as the clustering tag (proxy for module/feature)
        const tag = node.file_path;

        const gop = try cluster_map.getOrPut(tag);
        if (!gop.found_existing) {
            const tag_key = try allocator.dupe(u8, tag);
            gop.key_ptr.* = tag_key;
            const cluster = try allocator.create(TagCluster);
            cluster.* = try TagCluster.init(allocator, tag);
            gop.value_ptr.* = cluster;
            try cluster_list.append(cluster);
        }

        const cluster = gop.value_ptr.*;
        try cluster.node_ids.append(try allocator.dupe(u8, node.id));
    }

    // Convert to owned slice of TagCluster
    var result = array_list_compat.ArrayList(TagCluster).init(allocator);
    errdefer {
        for (result.items) |*c| c.deinit();
        result.deinit();
    }

    for (cluster_list.items) |cluster_ptr| {
        const moved = TagCluster{
            .tag = cluster_ptr.tag,
            .node_ids = cluster_ptr.node_ids,
            .allocator = cluster_ptr.allocator,
        };
        try result.append(moved);
        allocator.destroy(cluster_ptr);
    }
    cluster_list.deinit();

    return result.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Helper: create a simple test graph with known structure
fn createTestGraph(allocator: Allocator) !KnowledgeGraph {
    var graph = KnowledgeGraph.init(allocator);

    // 4 nodes: A, B, C, D
    // Edges: A→B, B→C, C→D, A→C (creates a well-connected subgraph)
    const nodes = [_]struct { []const u8, []const u8, types.NodeType }{
        .{ "A", "A", .function },
        .{ "B", "B", .function },
        .{ "C", "C", .function },
        .{ "D", "D", .function },
    };

    for (&nodes) |n| {
        const node = try allocator.create(types.GraphNode);
        node.* = try types.GraphNode.init(allocator, n[0], n[1], n[2], "test.zig", 1);
        try graph.addNode(node);
    }

    const edges = [_]struct { []const u8, []const u8 }{
        .{ "A", "B" },
        .{ "B", "C" },
        .{ "C", "D" },
        .{ "A", "C" },
    };

    for (&edges) |e| {
        const edge = try allocator.create(types.GraphEdge);
        edge.* = try types.GraphEdge.init(allocator, e[0], e[1], .calls, .extracted);
        try graph.addEdge(edge);
    }

    return graph;
}

/// Minimal KnowledgeGraph-like struct for testing (avoids importing graph.zig)
const KnowledgeGraph = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(*types.GraphNode),
    edges: array_list_compat.ArrayList(*types.GraphEdge),
    communities: array_list_compat.ArrayList(*types.Community),
    file_count: u32,
    total_source_tokens: u64,

    pub fn init(allocator: Allocator) KnowledgeGraph {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(*types.GraphNode).init(allocator),
            .edges = array_list_compat.ArrayList(*types.GraphEdge).init(allocator),
            .communities = array_list_compat.ArrayList(*types.Community).init(allocator),
            .file_count = 0,
            .total_source_tokens = 0,
        };
    }

    pub fn addNode(self: *KnowledgeGraph, node: *types.GraphNode) !void {
        try self.nodes.put(node.id, node);
    }

    pub fn addEdge(self: *KnowledgeGraph, edge: *types.GraphEdge) !void {
        try self.edges.append(edge);
    }

    pub fn deinit(self: *KnowledgeGraph) void {
        var node_list = array_list_compat.ArrayList(*types.GraphNode).init(self.allocator);
        defer node_list.deinit();
        {
            var node_iter = self.nodes.iterator();
            while (node_iter.next()) |entry| {
                node_list.append(entry.value_ptr.*) catch {};
            }
        }
        self.nodes.deinit();
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

fn graphData(graph: *KnowledgeGraph) GraphData {
    return .{
        .nodes = &graph.nodes,
        .edges = &graph.edges,
    };
}

test "PageRank on simple 4-node graph" {
    const allocator = testing.allocator;
    var graph = try createTestGraph(allocator);
    defer graph.deinit();

    var pr = try computePageRank(graphData(&graph), allocator, 0.85, 30, 0.001);
    defer pr.deinit();

    // All nodes should have a rank
    try testing.expectEqual(@as(usize, 4), pr.ranks.count());

    // Sum of all ranks should be ~1.0
    var sum: f64 = 0.0;
    var iter = pr.ranks.iterator();
    while (iter.next()) |entry| {
        sum += entry.value_ptr.*;
        try testing.expect(entry.value_ptr.* > 0.0);
    }
    try testing.expect(@abs(sum - 1.0) < 0.01);
}

test "Jaccard similarity between known nodes" {
    const allocator = testing.allocator;
    var graph = try createTestGraph(allocator);
    defer graph.deinit();

    // A's neighbors (undirected): B, C
    // B's neighbors (undirected): A, C
    // Intersection: A, C → 2. Union: A, B, C → 3. Jaccard = 2/3 ≈ 0.667
    const sim_ab = computeJaccardSimilarity(graphData(&graph), "A", "B");
    try testing.expect(sim_ab > 0.0);
    try testing.expect(sim_ab <= 1.0);

    // D's neighbors (undirected): C
    // A's neighbors (undirected): B, C
    // Intersection: C → 1. Union: B, C → 2. Jaccard = 0.5
    const sim_ad = computeJaccardSimilarity(graphData(&graph), "A", "D");
    try testing.expect(sim_ad >= 0.0);
    try testing.expect(sim_ad < sim_ab); // A-B more similar than A-D
}

test "Bridge detection on graph with articulation point" {
    const allocator = testing.allocator;

    // Create a graph where C is the bridge between two clusters
    // A—B—C—D—E
    // Removing C disconnects {A,B} from {D,E}
    var graph = KnowledgeGraph.init(allocator);
    defer graph.deinit();

    const node_ids = [_][]const u8{ "A", "B", "C", "D", "E" };
    for (&node_ids) |id| {
        const node = try allocator.create(types.GraphNode);
        node.* = try types.GraphNode.init(allocator, id, id, .function, "test.zig", 1);
        try graph.addNode(node);
    }

    const edge_pairs = [_]struct { []const u8, []const u8 }{
        .{ "A", "B" },
        .{ "B", "C" },
        .{ "C", "D" },
        .{ "D", "E" },
    };
    for (&edge_pairs) |e| {
        const edge = try allocator.create(types.GraphEdge);
        edge.* = try types.GraphEdge.init(allocator, e[0], e[1], .calls, .extracted);
        try graph.addEdge(edge);
    }

    const bridges = try findBridges(graphData(&graph), allocator);
    defer {
        for (bridges) |id| allocator.free(id);
        allocator.free(bridges);
    }

    // C should be detected as a bridge (articulation point)
    var found_c = false;
    for (bridges) |id| {
        if (std.mem.eql(u8, id, "C")) found_c = true;
    }
    try testing.expect(found_c);
}

test "Path finding between two nodes" {
    const allocator = testing.allocator;
    var graph = try createTestGraph(allocator);
    defer graph.deinit();

    // Find path from A to D: A→C→D or A→B→C→D (depends on BFS order)
    const path = try findPaths(graphData(&graph), allocator, "A", "D", 5);
    defer {
        for (path) |id| allocator.free(id);
        allocator.free(path);
    }

    try testing.expect(path.len > 0);

    // Last element should be D
    const last = path[path.len - 1];
    try testing.expect(std.mem.eql(u8, last, "D"));
}

test "Clustering of tagged nodes" {
    const allocator = testing.allocator;

    // Create nodes from different files (file_path = tag)
    var graph = KnowledgeGraph.init(allocator);
    defer graph.deinit();

    const entries = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn1", "fn1", "src/a.zig" },
        .{ "fn2", "fn2", "src/a.zig" },
        .{ "fn3", "fn3", "src/b.zig" },
        .{ "fn4", "fn4", "src/b.zig" },
        .{ "fn5", "fn5", "src/c.zig" },
    };

    for (&entries) |e| {
        const node = try allocator.create(types.GraphNode);
        node.* = try types.GraphNode.init(allocator, e[0], e[1], .function, e[2], 1);
        try graph.addNode(node);
    }

    const clusters = try clusterByTags(graphData(&graph), allocator);
    defer {
        for (clusters) |*c| c.deinit();
        allocator.free(clusters);
    }

    // Should have 3 clusters (one per file)
    try testing.expectEqual(@as(usize, 3), clusters.len);

    // Check that each cluster has the right number of nodes
    var total_nodes: usize = 0;
    for (clusters) |cluster| {
        total_nodes += cluster.node_ids.items.len;
    }
    try testing.expectEqual(@as(usize, 5), total_nodes);
}
