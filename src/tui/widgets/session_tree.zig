//! Session Tree Navigator — tree widget for displaying session hierarchy.
//!
//! Builds a parent-child tree from the session database by parsing the
//! "Fork of <parent_id>" title convention used by fork.zig. Renders a
//! visual tree with indentation, status icons, and navigation support.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A single node in the session tree.
pub const SessionTreeNode = struct {
    id: []const u8,
    title: []const u8,
    parent_id: ?[]const u8,
    provider: []const u8,
    model: []const u8,
    message_count: u32,
    total_cost: f64,
    created_at: i64,
    children: std.ArrayList(*SessionTreeNode),
    expanded: bool,

    pub fn deinit(self: *SessionTreeNode, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.parent_id) |pid| allocator.free(pid);
        allocator.free(self.provider);
        allocator.free(self.model);
        // Recursively deinit children
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }
};

/// Session metadata returned by the database query.
pub const SessionMetadata = struct {
    id: []const u8,
    title: []const u8,
    provider: []const u8,
    model: []const u8,
    turn_count: u32,
    total_cost: f64,
    created_at: i64,
};

// ---------------------------------------------------------------------------
// SessionTreeWidget
// ---------------------------------------------------------------------------

pub const SessionTreeWidget = struct {
    allocator: Allocator,
    root_nodes: std.ArrayList(*SessionTreeNode),
    all_nodes: std.ArrayList(*SessionTreeNode),
    selected_index: u32,
    scroll_offset: u32,
    visible: bool,

    pub fn init(allocator: Allocator) SessionTreeWidget {
        return .{
            .allocator = allocator,
            .root_nodes = std.ArrayList(*SessionTreeNode).empty,
            .all_nodes = std.ArrayList(*SessionTreeNode).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .visible = false,
        };
    }

    pub fn deinit(self: *SessionTreeWidget) void {
        for (self.root_nodes.items) |node| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.root_nodes.deinit(self.allocator);
        // all_nodes shares pointers with root_nodes — already freed above.
        self.all_nodes.deinit(self.allocator);
    }

    /// Load sessions from a database-like source.
    /// `db` must have a `listSessions(Allocator) ![]SessionRow` method
    /// or we accept a pre-built metadata slice via `loadFromMetadata`.
    pub fn loadFromDb(self: *SessionTreeWidget, db: anytype) !void {
        // Clear existing tree
        for (self.root_nodes.items) |node| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.root_nodes.clearRetainingCapacity();
        self.all_nodes.clearRetainingCapacity();
        self.selected_index = 0;
        self.scroll_offset = 0;

        const rows = try db.listSessions(self.allocator);
        defer {
            for (rows) |row| {
                self.allocator.free(row.id);
                self.allocator.free(row.title);
                self.allocator.free(row.model);
                self.allocator.free(row.provider);
            }
            self.allocator.free(rows);
        }

        // Build metadata from rows
        const metadata = try self.allocator.alloc(SessionMetadata, rows.len);
        defer self.allocator.free(metadata);
        for (rows, 0..) |row, i| {
            metadata[i] = .{
                .id = try self.allocator.dupe(u8, row.id),
                .title = try self.allocator.dupe(u8, row.title),
                .provider = try self.allocator.dupe(u8, row.provider),
                .model = try self.allocator.dupe(u8, row.model),
                .turn_count = row.turn_count,
                .total_cost = row.total_cost,
                .created_at = row.created_at,
            };
        }

        try self.buildTree(metadata);
    }

    /// Load from a pre-built slice of SessionMetadata.
    /// Takes ownership of the strings in metadata (caller must dupe beforehand).
    pub fn loadFromMetadata(self: *SessionTreeWidget, metadata: []const SessionMetadata) !void {
        // Clear existing tree
        for (self.root_nodes.items) |node| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.root_nodes.clearRetainingCapacity();
        self.all_nodes.clearRetainingCapacity();
        self.selected_index = 0;
        self.scroll_offset = 0;

        try self.buildTree(metadata);
    }

    /// Build the tree structure from metadata using "Fork of <parent_id>" convention.
    fn buildTree(self: *SessionTreeWidget, metadata: []const SessionMetadata) !void {
        const allocator = self.allocator;

        // Step 1: Create a node for each session
        // Use a temporary map: id → *SessionTreeNode
        var id_map = std.StringHashMap(*SessionTreeNode).init(allocator);
        defer id_map.deinit();

        for (metadata) |meta| {
            const node = try allocator.create(SessionTreeNode);
            node.* = .{
                .id = try allocator.dupe(u8, meta.id),
                .title = try allocator.dupe(u8, meta.title),
                .parent_id = extractParentId(allocator, meta.title),
                .provider = try allocator.dupe(u8, meta.provider),
                .model = try allocator.dupe(u8, meta.model),
                .message_count = meta.turn_count,
                .total_cost = meta.total_cost,
                .created_at = meta.created_at,
                .children = std.ArrayList(*SessionTreeNode).empty,
                .expanded = true,
            };
            try id_map.put(node.id, node);
        }

        // Step 2: Link children to parents
        var it = id_map.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.parent_id) |pid| {
                // Find parent in the map
                if (id_map.get(pid)) |parent| {
                    try parent.children.append(self.allocator, node);
                } else {
                    // Parent not found — treat as root
                    try self.root_nodes.append(self.allocator, node);
                }
            } else {
                // No parent — root node
                try self.root_nodes.append(self.allocator, node);
            }
        }

        // Step 3: Build flat list for navigation
        try self.buildFlatList();
    }

    /// Build the flat navigation list by walking the tree depth-first.
    fn buildFlatList(self: *SessionTreeWidget) !void {
        self.all_nodes.clearRetainingCapacity();
        for (self.root_nodes.items) |node| {
            try self.walkTree(node);
        }
    }

    fn walkTree(self: *SessionTreeWidget, node: *SessionTreeNode) !void {
        try self.all_nodes.append(self.allocator, node);
        if (node.expanded) {
            for (node.children.items) |child| {
                try self.walkTree(child);
            }
        }
    }

    /// Toggle expand/collapse on the currently selected node.
    pub fn toggleExpand(self: *SessionTreeWidget) void {
        if (self.all_nodes.items.len == 0) return;
        if (self.selected_index >= self.all_nodes.items.len) return;
        const node = self.all_nodes.items[self.selected_index];
        if (node.children.items.len == 0) return;
        node.expanded = !node.expanded;
        // Rebuild flat list after toggle
        self.buildFlatList() catch {};
    }

    /// Move selection up.
    pub fn selectUp(self: *SessionTreeWidget) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    /// Move selection down.
    pub fn selectDown(self: *SessionTreeWidget) void {
        if (self.selected_index + 1 < self.all_nodes.items.len) {
            self.selected_index += 1;
        }
    }

    /// Return the session ID of the currently selected node.
    pub fn getSelectedSession(self: *const SessionTreeWidget) ?[]const u8 {
        if (self.all_nodes.items.len == 0) return null;
        if (self.selected_index >= self.all_nodes.items.len) return null;
        return self.all_nodes.items[self.selected_index].id;
    }

    /// Render the tree as a string (for display in TUI message area).
    /// Caller owns the returned slice.
    pub fn render(self: *SessionTreeWidget) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("Session Tree\n");
        try writer.writeAll("────────────────────────────────────────\n");

        if (self.root_nodes.items.len == 0) {
            try writer.writeAll("  (no sessions)\n");
        } else {
            for (self.root_nodes.items, 0..) |node, i| {
                const is_last = (i == self.root_nodes.items.len - 1);
                try self.renderNode(node, 0, is_last, writer);
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Render a single node and its children (recursive).
    fn renderNode(
        self: *SessionTreeWidget,
        node: *SessionTreeNode,
        depth: u32,
        is_last: bool,
        writer: anytype,
    ) !void {
        const is_selected = for (self.all_nodes.items, 0..) |n, i| {
            if (i == self.selected_index and n == node) break true;
        } else false;

        // Build prefix
        var prefix_buf: [256]u8 = undefined;
        var prefix_len: usize = 0;

        // Indentation
        var d: u32 = 0;
        while (d < depth) : (d += 1) {
            const bytes = "│   ";
            @memcpy(prefix_buf[prefix_len .. prefix_len + bytes.len], bytes);
            prefix_len += bytes.len;
        }

        // Branch connector
        if (depth > 0) {
            const connector: []const u8 = if (is_last) "└── " else "├── ";
            @memcpy(prefix_buf[prefix_len .. prefix_len + connector.len], connector);
            prefix_len += connector.len;
        }

        try writer.writeAll(prefix_buf[0..prefix_len]);

        // Status icon
        const icon = if (node.parent_id != null)
            "🟡"
        else if (node.children.items.len > 0)
            "🟢"
        else
            "🔵";

        try writer.writeAll(icon);
        try writer.writeAll(" ");

        // Title (truncated for display)
        const max_title_len: usize = 30;
        const display_title = if (node.title.len > max_title_len) node.title[0..max_title_len] else node.title;
        try writer.writeAll(display_title);

        // Metadata
        if (node.model.len > 0) {
            try writer.writeAll(" (");
            const max_model_len: usize = 20;
            const display_model = if (node.model.len > max_model_len) node.model[0..max_model_len] else node.model;
            try writer.writeAll(display_model);
            try writer.writeAll(", ");
        } else {
            try writer.writeAll(" (");
        }
        try writer.print("{d} msgs, ${d:.4}", .{ node.message_count, node.total_cost });
        try writer.writeAll(")");

        // Selection indicator
        if (is_selected) {
            try writer.writeAll(" ◄");
        }

        try writer.writeAll("\n");

        // Render children if expanded
        if (node.expanded) {
            for (node.children.items, 0..) |child, i| {
                const child_is_last = (i == node.children.items.len - 1);
                try self.renderNode(child, depth + 1, child_is_last, writer);
            }
        }
    }

    /// Render the tree for a simple text-based display (no TUI widget framework).
    /// Returns an ArrayList that the caller can convert to a string.
    pub fn renderToString(self: *SessionTreeWidget, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("📂 Session Tree\n");
        try writer.writeAll("─────────────────────────────────────────────\n");

        if (self.root_nodes.items.len == 0) {
            try writer.writeAll("  (no sessions)\n");
        } else {
            for (self.root_nodes.items, 0..) |node, i| {
                const is_last_root = (i == self.root_nodes.items.len - 1);
                try self.formatNodeRecursive(node, 0, is_last_root, writer);
            }
        }

        try writer.writeAll("─────────────────────────────────────────────\n");
        try writer.print("  {d} sessions, {d} selected\n", .{ self.all_nodes.items.len, self.selected_index });

        return buf.toOwnedSlice(allocator);
    }

    fn formatNodeRecursive(
        self: *SessionTreeWidget,
        node: *SessionTreeNode,
        depth: u32,
        is_last: bool,
        writer: anytype,
    ) !void {
        try self.formatNode(node, depth, is_last, writer);
        if (node.expanded) {
            for (node.children.items, 0..) |child, i| {
                const child_is_last = (i == node.children.items.len - 1);
                try self.formatNodeRecursive(child, depth + 1, child_is_last, writer);
            }
        }
    }

    /// Format a single node line.
    pub fn formatNode(
        _: *SessionTreeWidget,
        node: *SessionTreeNode,
        depth: u32,
        is_last: bool,
        writer: anytype,
    ) !void {
        // Indentation
        var d: u32 = 0;
        while (d < depth) : (d += 1) {
            try writer.writeAll("│   ");
        }

        // Branch connector
        if (depth > 0) {
            if (is_last) {
                try writer.writeAll("└── ");
            } else {
                try writer.writeAll("├── ");
            }
        }

        // Status icon based on type
        if (node.parent_id != null) {
            try writer.writeAll("🟡 "); // Fork
        } else if (node.children.items.len > 0) {
            if (node.expanded) {
                try writer.writeAll("📂 "); // Expanded parent
            } else {
                try writer.writeAll("📁 "); // Collapsed parent
            }
        } else {
            try writer.writeAll("🔵 "); // Leaf/root session
        }

        // Title
        const max_title: usize = 35;
        const title = if (node.title.len > max_title) node.title[0..max_title] else node.title;
        try writer.writeAll(title);

        // Provider/model and stats
        try writer.writeAll(" (");
        if (node.provider.len > 0) {
            const max_prov: usize = 12;
            const prov = if (node.provider.len > max_prov) node.provider[0..max_prov] else node.provider;
            try writer.writeAll(prov);
            if (node.model.len > 0) {
                try writer.writeAll("/");
                const max_model: usize = 15;
                const model = if (node.model.len > max_model) node.model[0..max_model] else node.model;
                try writer.writeAll(model);
            }
        }
        try writer.print(", {d} msgs, ${d:.4})", .{ node.message_count, node.total_cost });

        try writer.writeAll("\n");
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract parent session ID from a title like "Fork of session-123 @42".
/// Returns null if the title doesn't indicate a fork.
/// Returns a newly allocated string.
fn extractParentId(allocator: Allocator, title: []const u8) ?[]const u8 {
    const prefix = "Fork of ";
    if (!std.mem.startsWith(u8, title, prefix)) return null;
    const rest = title[prefix.len..];
    const at_idx = std.mem.lastIndexOfScalar(u8, rest, '@') orelse rest.len;
    const trimmed = std.mem.trimRight(u8, rest[0..at_idx], " ");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}
