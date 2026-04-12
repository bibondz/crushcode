const std = @import("std");
const array_list_compat = @import("array_list_compat");

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// Axis-aligned rectangular region in terminal cell coordinates.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub const zero: Rect = .{};

    /// Area in cells.
    pub fn area(self: Rect) usize {
        return @as(usize, self.w) * self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    /// True if (col, row) falls inside this rectangle.
    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.x and col < self.x + self.w and
            row >= self.y and row < self.y + self.h;
    }

    /// Intersection of two rectangles.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return .zero;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Clamp right/bottom edges to a maximum width/height.
    pub fn clamp(self: Rect, max_w: u16, max_h: u16) Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .w = @min(self.w, max_w -| self.x),
            .h = @min(self.h, max_h -| self.y),
        };
    }

    /// Shrink by `pad` cells on all four sides.
    pub fn shrink(self: Rect, pad: Padding) Rect {
        return .{
            .x = self.x + pad.left,
            .y = self.y + pad.top,
            .w = self.w -| pad.left -| pad.right,
            .h = self.h -| pad.top -| pad.bottom,
        };
    }
};

/// Per-side padding in terminal cells.
pub const Padding = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub const zero: Padding = .{};

    /// Uniform padding on all sides.
    pub fn all(v: u16) Padding {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    /// Horizontal (left + right) total.
    pub fn horizontal(self: Padding) u16 {
        return self.left + self.right;
    }

    /// Vertical (top + bottom) total.
    pub fn vertical(self: Padding) u16 {
        return self.top + self.bottom;
    }
};

// ---------------------------------------------------------------------------
// Flex layout types
// ---------------------------------------------------------------------------

/// Direction of the main axis for a flex container.
pub const FlexDirection = enum {
    /// Children stacked horizontally (row).
    horizontal,
    /// Children stacked vertically (column).
    vertical,
};

/// How a child node participates in flex distribution along the main axis.
pub const SizeHint = union(enum) {
    /// Fixed size in cells. Not affected by flex distribution.
    fixed: u16,
    /// Proportional — consumes remaining space weighted by the given value.
    /// E.g. `flex(1)` splits equally; `flex(2)` gets double.
    flex: u16,
    /// Take all remaining space after fixed children are satisfied.
    fill,
};

// ---------------------------------------------------------------------------
// LayoutNode — a single node in the layout tree
// ---------------------------------------------------------------------------

pub const LayoutNode = struct {
    /// Unique identifier for lookups after layout computation.
    id: []const u8 = "",
    /// How this node sizes along its parent's main axis.
    size_hint: SizeHint = .fill,
    /// Cross-axis size: .none means stretch to parent cross size.
    cross_size: ?u16 = null,
    /// Direction for child layout. Only meaningful when children.len > 0.
    direction: FlexDirection = .vertical,
    /// Inner padding subtracted before children are laid out.
    padding: Padding = .zero,
    /// Gap between children in cells.
    gap: u16 = 0,

    // --- tree structure ---
    parent: ?*LayoutNode = null,
    children: []*LayoutNode = &.{},

    // --- computed output (set by computeLayout) ---
    rect: Rect = .zero,
    /// True after computeLayout has processed this node.
    computed: bool = false,

    const Self = @This();

    // ---------------------------------------------------------------
    // Builder-style convenience methods
    // ---------------------------------------------------------------

    /// Set the size hint and return self (for chaining).
    pub fn size(self: *Self, hint: SizeHint) *Self {
        self.size_hint = hint;
        return self;
    }

    /// Set cross-axis size and return self.
    pub fn cross(self: *Self, v: u16) *Self {
        self.cross_size = v;
        return self;
    }

    /// Set direction and return self.
    pub fn dir(self: *Self, d: FlexDirection) *Self {
        self.direction = d;
        return self;
    }

    /// Set padding and return self.
    pub fn pad(self: *Self, p: Padding) *Self {
        self.padding = p;
        return self;
    }

    /// Set gap and return self.
    pub fn withGap(self: *Self, g: u16) *Self {
        self.gap = g;
        return self;
    }

    /// Set id and return self.
    pub fn identify(self: *Self, name: []const u8) *Self {
        self.id = name;
        return self;
    }

    /// Assign children (sets parent backpointers).
    pub fn setChildren(self: *Self, kids: []*LayoutNode) void {
        self.children = kids;
        for (kids) |kid| {
            kid.parent = self;
        }
    }
};

// ---------------------------------------------------------------------------
// LayoutEngine — computes absolute Rects for every node in the tree
// ---------------------------------------------------------------------------

pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    root: *LayoutNode,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root: *LayoutNode) Self {
        return .{ .allocator = allocator, .root = root };
    }

    /// (Re)compute the entire layout tree for the given screen dimensions.
    pub fn compute(self: *Self, screen_w: u16, screen_h: u16) void {
        self.root.rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h };
        self.layoutChildren(self.root);
    }

    /// Find a node by id. Returns null if not found.
    pub fn find(self: *Self, id: []const u8) ?*LayoutNode {
        return findNode(self.root, id);
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    /// Recursive flex layout for a container node.
    fn layoutChildren(self: *Self, node: *LayoutNode) void {
        const content = node.rect.shrink(node.padding);
        if (content.w == 0 or content.h == 0) {
            for (node.children) |kid| {
                kid.rect = .zero;
                kid.computed = true;
                self.layoutChildren(kid);
            }
            return;
        }

        const kids = node.children;
        if (kids.len == 0) {
            node.computed = true;
            return;
        }

        const is_horiz = node.direction == .horizontal;
        const main_size: u16 = if (is_horiz) content.w else content.h;
        const cross_size: u16 = if (is_horiz) content.h else content.w;

        // Total gap space between children.
        const total_gap: u16 = node.gap * @as(u16, @intCast(if (kids.len > 1) kids.len - 1 else 0));
        const available = main_size -| total_gap;

        // --- Phase 1: measure fixed children, sum flex weights ---
        var fixed_total: u16 = 0;
        var flex_total: u16 = 0;
        for (kids) |kid| {
            switch (kid.size_hint) {
                .fixed => |v| fixed_total += v,
                .flex => |w| flex_total += w,
                .fill => {},
            }
        }

        // Count fill children (they share equally whatever's left after flex).
        var fill_count: u16 = 0;
        const after_fixed = available -| fixed_total;
        for (kids) |kid| {
            if (kid.size_hint == .fill) fill_count += 1;
        }

        // Space remaining after fixed, consumed by flex + fill.
        const flex_space = after_fixed;
        // Per-unit flex size.
        const flex_unit: f32 = if (flex_total > 0)
            @as(f32, @floatFromInt(flex_space)) / @as(f32, @floatFromInt(flex_total))
        else
            0;
        // Each fill child gets equal share of what's left after flex.
        const fill_each: u16 = if (fill_count > 0) blk: {
            const remaining: f32 = @max(0.0, @as(f32, @floatFromInt(flex_space)) - flex_unit * @as(f32, @floatFromInt(flex_total)));
            const raw: u16 = @intFromFloat(remaining);
            break :blk raw / fill_count;
        } else 0;

        // --- Phase 2: assign main-axis sizes ---
        var main_pos: u16 = if (is_horiz) content.x else content.y;
        for (kids) |kid| {
            const main_len: u16 = switch (kid.size_hint) {
                .fixed => |v| v,
                .flex => |w| @intFromFloat(flex_unit * @as(f32, @floatFromInt(w))),
                .fill => fill_each,
            };

            // Cross-axis: stretch to parent cross unless explicitly set.
            const cross_len: u16 = kid.cross_size orelse cross_size;

            if (is_horiz) {
                kid.rect = .{
                    .x = main_pos,
                    .y = content.y,
                    .w = main_len,
                    .h = cross_len,
                };
            } else {
                kid.rect = .{
                    .x = content.x,
                    .y = main_pos,
                    .w = cross_len,
                    .h = main_len,
                };
            }
            kid.computed = true;
            main_pos += main_len + node.gap;

            // Recurse into children.
            self.layoutChildren(kid);
        }
    }
};

// ---------------------------------------------------------------------------
// findNode helper
// ---------------------------------------------------------------------------

fn findNode(node: *LayoutNode, id: []const u8) ?*LayoutNode {
    if (node.id.len > 0 and std.mem.eql(u8, node.id, id)) return node;
    for (node.children) |kid| {
        if (findNode(kid, id)) |found| return found;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Rect — zero area" {
    try std.testing.expect(Rect.zero.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), Rect.zero.area());
}

test "Rect — area calculation" {
    const r = Rect{ .x = 0, .y = 0, .w = 10, .h = 5 };
    try std.testing.expectEqual(@as(usize, 50), r.area());
}

test "Rect — contains" {
    const r = Rect{ .x = 2, .y = 3, .w = 4, .h = 5 };
    try std.testing.expect(r.contains(2, 3)); // top-left inclusive
    try std.testing.expect(r.contains(5, 7)); // bottom-right inclusive
    try std.testing.expect(!r.contains(6, 3)); // past right edge
    try std.testing.expect(!r.contains(2, 8)); // past bottom edge
    try std.testing.expect(!r.contains(1, 3)); // before left edge
}

test "Rect — intersect" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    const i = Rect.intersect(a, b);
    try std.testing.expectEqual(@as(u16, 5), i.x);
    try std.testing.expectEqual(@as(u16, 5), i.y);
    try std.testing.expectEqual(@as(u16, 5), i.w);
    try std.testing.expectEqual(@as(u16, 5), i.h);
}

test "Rect — intersect no overlap" {
    const a = Rect{ .x = 0, .y = 0, .w = 5, .h = 5 };
    const b = Rect{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try std.testing.expect(Rect.intersect(a, b).isEmpty());
}

test "Rect — shrink with padding" {
    const r = Rect{ .x = 0, .y = 0, .w = 20, .h = 10 };
    const p = Padding{ .top = 1, .right = 2, .bottom = 1, .left = 3 };
    const s = r.shrink(p);
    try std.testing.expectEqual(@as(u16, 3), s.x);
    try std.testing.expectEqual(@as(u16, 1), s.y);
    try std.testing.expectEqual(@as(u16, 15), s.w);
    try std.testing.expectEqual(@as(u16, 8), s.h);
}

test "Rect — clamp" {
    const r = Rect{ .x = 50, .y = 50, .w = 100, .h = 100 };
    const c = r.clamp(80, 70);
    try std.testing.expectEqual(@as(u16, 30), c.w);
    try std.testing.expectEqual(@as(u16, 20), c.h);
}

test "Padding — all uniform" {
    const p = Padding.all(2);
    try std.testing.expectEqual(@as(u16, 2), p.top);
    try std.testing.expectEqual(@as(u16, 2), p.right);
    try std.testing.expectEqual(@as(u16, 2), p.bottom);
    try std.testing.expectEqual(@as(u16, 2), p.left);
    try std.testing.expectEqual(@as(u16, 4), p.horizontal());
    try std.testing.expectEqual(@as(u16, 4), p.vertical());
}

test "Layout — single fixed child fills nothing extra" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var child = LayoutNode{ .size_hint = .{ .fixed = 3 } };
    root.setChildren(&.{&child});

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 0), child.rect.x);
    try std.testing.expectEqual(@as(u16, 0), child.rect.y);
    try std.testing.expectEqual(@as(u16, 80), child.rect.w);
    try std.testing.expectEqual(@as(u16, 3), child.rect.h);
}

test "Layout — two fixed children vertically" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var header = LayoutNode{ .size_hint = .{ .fixed = 1 } };
    var body = LayoutNode{ .size_hint = .{ .fixed = 20 } };
    root.setChildren(&.{ &header, &body });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 0), header.rect.y);
    try std.testing.expectEqual(@as(u16, 1), header.rect.h);
    try std.testing.expectEqual(@as(u16, 1), body.rect.y);
    try std.testing.expectEqual(@as(u16, 20), body.rect.h);
}

test "Layout — flex children split equally" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .horizontal };
    var left = LayoutNode{ .size_hint = .{ .flex = 1 } };
    var right = LayoutNode{ .size_hint = .{ .flex = 1 } };
    root.setChildren(&.{ &left, &right });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 0), left.rect.x);
    try std.testing.expectEqual(@as(u16, 40), left.rect.w);
    try std.testing.expectEqual(@as(u16, 40), right.rect.x);
    try std.testing.expectEqual(@as(u16, 40), right.rect.w);
}

test "Layout — flex with weighted proportions" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .horizontal };
    var sidebar = LayoutNode{ .size_hint = .{ .flex = 1 } };
    var main = LayoutNode{ .size_hint = .{ .flex = 3 } };
    root.setChildren(&.{ &sidebar, &main });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 20), sidebar.rect.w);
    try std.testing.expectEqual(@as(u16, 60), main.rect.w);
}

test "Layout — mixed fixed + flex" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var header = LayoutNode{ .size_hint = .{ .fixed = 1 } };
    var body = LayoutNode{ .size_hint = .{ .flex = 1 } };
    var footer = LayoutNode{ .size_hint = .{ .fixed = 1 } };
    root.setChildren(&.{ &header, &body, &footer });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 1), header.rect.h);
    try std.testing.expectEqual(@as(u16, 1), header.rect.y);
    try std.testing.expectEqual(@as(u16, 22), body.rect.h);
    try std.testing.expectEqual(@as(u16, 1), body.rect.y);
    try std.testing.expectEqual(@as(u16, 1), footer.rect.h);
    try std.testing.expectEqual(@as(u16, 23), footer.rect.y);
}

test "Layout — fill children share equally" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var a = LayoutNode{ .size_hint = .fill };
    var b = LayoutNode{ .size_hint = .fill };
    var c = LayoutNode{ .size_hint = .fill };
    root.setChildren(&.{ &a, &b, &c });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(90, 30);

    try std.testing.expectEqual(@as(u16, 10), a.rect.h);
    try std.testing.expectEqual(@as(u16, 10), b.rect.h);
    try std.testing.expectEqual(@as(u16, 10), c.rect.h);
}

test "Layout — gap between children" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .horizontal, .gap = 2 };
    var left = LayoutNode{ .size_hint = .{ .fixed = 10 } };
    var right = LayoutNode{ .size_hint = .{ .fixed = 10 } };
    root.setChildren(&.{ &left, &right });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    try std.testing.expectEqual(@as(u16, 0), left.rect.x);
    try std.testing.expectEqual(@as(u16, 10), left.rect.w);
    try std.testing.expectEqual(@as(u16, 12), right.rect.x); // 10 + 2 gap
    try std.testing.expectEqual(@as(u16, 10), right.rect.w);
}

test "Layout — padding subtracts from content area" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{
        .direction = .vertical,
        .padding = Padding.all(1),
    };
    var child = LayoutNode{ .size_hint = .fill };
    root.setChildren(&.{&child});

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    // Root rect = full screen
    try std.testing.expectEqual(@as(u16, 80), root.rect.w);
    try std.testing.expectEqual(@as(u16, 24), root.rect.h);

    // Child rect = content area (80-2, 24-2) at position (1,1)
    try std.testing.expectEqual(@as(u16, 1), child.rect.x);
    try std.testing.expectEqual(@as(u16, 1), child.rect.y);
    try std.testing.expectEqual(@as(u16, 78), child.rect.w);
    try std.testing.expectEqual(@as(u16, 22), child.rect.h);
}

test "Layout — nested vertical→horizontal" {
    const allocator = std.testing.allocator;

    // Root: vertical
    //   header (fixed 1)
    //   body (flex 1, horizontal)
    //     sidebar (fixed 20)
    //     content (flex 1)
    //   footer (fixed 1)

    var root = LayoutNode{ .direction = .vertical };
    var header = LayoutNode{ .size_hint = .{ .fixed = 1 } };
    var body = LayoutNode{ .direction = .horizontal, .size_hint = .{ .flex = 1 } };
    var footer = LayoutNode{ .size_hint = .{ .fixed = 1 } };

    var sidebar = LayoutNode{ .size_hint = .{ .fixed = 20 } };
    var content = LayoutNode{ .size_hint = .{ .flex = 1 } };

    body.setChildren(&.{ &sidebar, &content });
    root.setChildren(&.{ &header, &body, &footer });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    // header: y=0, h=1
    try std.testing.expectEqual(@as(u16, 0), header.rect.y);
    try std.testing.expectEqual(@as(u16, 1), header.rect.h);

    // body: y=1, h=22
    try std.testing.expectEqual(@as(u16, 1), body.rect.y);
    try std.testing.expectEqual(@as(u16, 22), body.rect.h);

    // sidebar: x=0, w=20, h=22
    try std.testing.expectEqual(@as(u16, 0), sidebar.rect.x);
    try std.testing.expectEqual(@as(u16, 20), sidebar.rect.w);
    try std.testing.expectEqual(@as(u16, 22), sidebar.rect.h);

    // content: x=20, w=60, h=22
    try std.testing.expectEqual(@as(u16, 20), content.rect.x);
    try std.testing.expectEqual(@as(u16, 60), content.rect.w);
    try std.testing.expectEqual(@as(u16, 22), content.rect.h);

    // footer: y=23, h=1
    try std.testing.expectEqual(@as(u16, 23), footer.rect.y);
    try std.testing.expectEqual(@as(u16, 1), footer.rect.h);
}

test "Layout — find node by id" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var child_a = LayoutNode{ .id = "sidebar", .size_hint = .{ .fixed = 20 } };
    var child_b = LayoutNode{ .id = "main", .size_hint = .{ .flex = 1 } };
    root.setChildren(&.{ &child_a, &child_b });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    const found = engine.find("sidebar");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u16, 20), found.?.rect.w);

    try std.testing.expect(engine.find("nonexistent") == null);
}

test "Layout — cross_size override" {
    const allocator = std.testing.allocator;

    // Horizontal row, but one child has explicit cross height
    var root = LayoutNode{ .direction = .horizontal };
    var tall = LayoutNode{ .size_hint = .{ .fixed = 10 }, .cross_size = 5 };
    var short = LayoutNode{ .size_hint = .{ .fixed = 10 } };
    root.setChildren(&.{ &tall, &short });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    // tall: cross_size = 5 (explicit)
    try std.testing.expectEqual(@as(u16, 5), tall.rect.h);
    // short: cross_size = null → stretch to parent cross (24)
    try std.testing.expectEqual(@as(u16, 24), short.rect.h);
}

test "Layout — opencode-style layout (header + scrollback + input)" {
    const allocator = std.testing.allocator;

    // Simulates opencode's 3-row vertical layout:
    //   header:  fixed 1
    //   content: flex 1  (scrollback)
    //   input:   fixed 3

    var root = LayoutNode{ .direction = .vertical };
    var header = LayoutNode{ .id = "header", .size_hint = .{ .fixed = 1 } };
    var scrollback = LayoutNode{ .id = "scrollback", .size_hint = .{ .flex = 1 } };
    var input = LayoutNode{ .id = "input", .size_hint = .{ .fixed = 3 } };
    root.setChildren(&.{ &header, &scrollback, &input });

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(120, 40);

    try std.testing.expectEqual(@as(u16, 1), header.rect.h);
    try std.testing.expectEqual(@as(u16, 36), scrollback.rect.h);
    try std.testing.expectEqual(@as(u16, 3), input.rect.h);
    try std.testing.expectEqual(@as(u16, 37), input.rect.y);
}

test "Layout — empty children list" {
    const allocator = std.testing.allocator;

    var root = LayoutNode{ .direction = .vertical };
    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(80, 24);

    // Root rect should be full screen
    try std.testing.expectEqual(@as(u16, 80), root.rect.w);
    try std.testing.expectEqual(@as(u16, 24), root.rect.h);
}

test "Layout — zero-size content area produces zero child rects" {
    const allocator = std.testing.allocator;

    // Padding consumes all space
    var root = LayoutNode{
        .direction = .vertical,
        .padding = Padding.all(50),
    };
    var child = LayoutNode{ .size_hint = .fill };
    root.setChildren(&.{&child});

    var engine = LayoutEngine.init(allocator, &root);
    engine.compute(10, 10);

    try std.testing.expect(child.rect.isEmpty());
}

test "Layout — builder chaining" {
    var node = LayoutNode{};
    _ = node.size(.{ .flex = 2 }).cross(10).dir(.horizontal).withGap(1).identify("test");
    try std.testing.expect(node.size_hint == .flex);
    try std.testing.expectEqual(@as(u16, 2), node.size_hint.flex);
    try std.testing.expectEqual(@as(u16, 10), node.cross_size.?);
    try std.testing.expect(node.direction == .horizontal);
    try std.testing.expectEqual(@as(u16, 1), node.gap);
    try std.testing.expect(std.mem.eql(u8, node.id, "test"));
}
