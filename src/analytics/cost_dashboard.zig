//! Cost analytics dashboard backed by the session SQLite database.
//!
//! Provides aggregate queries for total cost, today's cost, breakdowns
//! by provider and model, and top expensive sessions.

const std = @import("std");
const sqlite = @import("sqlite");
const session_db_mod = @import("session_db");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const ProviderCost = struct {
    provider: []const u8,
    cost: f64,
    tokens: u64,
    session_count: u64,
};

pub const ModelCost = struct {
    model: []const u8,
    cost: f64,
    tokens: u64,
    session_count: u64,
};

// ---------------------------------------------------------------------------
// CostDashboard
// ---------------------------------------------------------------------------

pub const CostDashboard = struct {
    sdb: *session_db_mod.SessionDB,
    allocator: Allocator,

    /// Initialize a CostDashboard that queries the given session database.
    pub fn init(allocator: Allocator, sdb: *session_db_mod.SessionDB) CostDashboard {
        return .{ .sdb = sdb, .allocator = allocator };
    }

    /// Get total cost across all sessions.
    pub fn getTotalCost(self: *CostDashboard) !TotalCostResult {
        var stmt = try sqlite.Stmt.prepare(&self.sdb.db,
            \\SELECT COALESCE(SUM(total_cost), 0.0), COALESCE(SUM(total_tokens), 0), COUNT(*) FROM session
        );
        defer stmt.deinit();

        if (try stmt.step() != .row) {
            return .{ .total_cost = 0.0, .total_tokens = 0, .session_count = 0 };
        }

        return .{
            .total_cost = stmt.columnDouble(0),
            .total_tokens = @intCast(@max(stmt.columnInt(1), 0)),
            .session_count = @intCast(@max(stmt.columnInt(2), 0)),
        };
    }

    /// Get cost for today (since midnight UTC).
    pub fn getTodayCost(self: *CostDashboard) !TodayCostResult {
        const now = std.time.timestamp();
        // Start of today in UTC: truncate to day boundary (86400 seconds/day)
        const start_of_today: i64 = @divTrunc(now, 86400) * 86400;

        var stmt = try sqlite.Stmt.prepare(&self.sdb.db,
            \\SELECT COALESCE(SUM(total_cost), 0.0), COALESCE(SUM(total_tokens), 0), COUNT(*) FROM session
            \\WHERE created_at >= ?1
        );
        defer stmt.deinit();
        try stmt.bindInt(1, start_of_today);

        if (try stmt.step() != .row) {
            return .{ .cost = 0.0, .tokens = 0, .session_count = 0 };
        }

        return .{
            .cost = stmt.columnDouble(0),
            .tokens = @intCast(@max(stmt.columnInt(1), 0)),
            .session_count = @intCast(@max(stmt.columnInt(2), 0)),
        };
    }

    /// Get cost breakdown by provider, sorted by cost descending.
    pub fn getCostByProvider(self: *CostDashboard) ![]ProviderCost {
        var stmt = try sqlite.Stmt.prepare(&self.sdb.db,
            \\SELECT provider, COALESCE(SUM(total_cost), 0.0), COALESCE(SUM(total_tokens), 0), COUNT(*)
            \\FROM session GROUP BY provider ORDER BY SUM(total_cost) DESC
        );
        defer stmt.deinit();

        var list = std.ArrayList(ProviderCost).empty;
        errdefer {
            for (list.items) |p| self.allocator.free(p.provider);
            list.deinit(self.allocator);
        }

        while (try stmt.step() == .row) {
            try list.append(self.allocator, .{
                .provider = try self.allocator.dupe(u8, stmt.columnText(0)),
                .cost = stmt.columnDouble(1),
                .tokens = @intCast(@max(stmt.columnInt(2), 0)),
                .session_count = @intCast(@max(stmt.columnInt(3), 0)),
            });
        }

        return try list.toOwnedSlice(self.allocator);
    }

    /// Get cost breakdown by model, sorted by cost descending.
    pub fn getCostByModel(self: *CostDashboard) ![]ModelCost {
        var stmt = try sqlite.Stmt.prepare(&self.sdb.db,
            \\SELECT model, COALESCE(SUM(total_cost), 0.0), COALESCE(SUM(total_tokens), 0), COUNT(*)
            \\FROM session GROUP BY model ORDER BY SUM(total_cost) DESC
        );
        defer stmt.deinit();

        var list = std.ArrayList(ModelCost).empty;
        errdefer {
            for (list.items) |m| self.allocator.free(m.model);
            list.deinit(self.allocator);
        }

        while (try stmt.step() == .row) {
            try list.append(self.allocator, .{
                .model = try self.allocator.dupe(u8, stmt.columnText(0)),
                .cost = stmt.columnDouble(1),
                .tokens = @intCast(@max(stmt.columnInt(2), 0)),
                .session_count = @intCast(@max(stmt.columnInt(3), 0)),
            });
        }

        return try list.toOwnedSlice(self.allocator);
    }

    /// Get top 5 most expensive sessions.
    pub fn getTopSessions(self: *CostDashboard) ![]session_db_mod.SessionRow {
        var stmt = try sqlite.Stmt.prepare(&self.sdb.db,
            \\SELECT id, title, model, provider, total_tokens, total_cost, turn_count, duration_seconds, created_at, updated_at
            \\FROM session ORDER BY total_cost DESC LIMIT 5
        );
        defer stmt.deinit();

        var list = std.ArrayList(session_db_mod.SessionRow).empty;
        errdefer {
            for (list.items) |*s| {
                self.allocator.free(s.id);
                self.allocator.free(s.title);
                self.allocator.free(s.model);
                self.allocator.free(s.provider);
            }
            list.deinit(self.allocator);
        }

        while (try stmt.step() == .row) {
            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, stmt.columnText(0)),
                .title = try self.allocator.dupe(u8, stmt.columnText(1)),
                .model = try self.allocator.dupe(u8, stmt.columnText(2)),
                .provider = try self.allocator.dupe(u8, stmt.columnText(3)),
                .total_tokens = @intCast(@max(stmt.columnInt(4), 0)),
                .total_cost = stmt.columnDouble(5),
                .turn_count = @intCast(@max(stmt.columnInt(6), 0)),
                .duration_seconds = @intCast(@max(stmt.columnInt(7), 0)),
                .created_at = stmt.columnInt(8),
                .updated_at = stmt.columnInt(9),
            });
        }

        return try list.toOwnedSlice(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

pub const TotalCostResult = struct { total_cost: f64, total_tokens: u64, session_count: u64 };
pub const TodayCostResult = struct { cost: f64, tokens: u64, session_count: u64 };

/// Format the main cost report: total + today + by provider.
pub fn formatTotalReport(
    allocator: Allocator,
    total: TotalCostResult,
    today: TodayCostResult,
    by_provider: []ProviderCost,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const w = buf.writer(allocator);

    try w.writeAll("\xf0\x9f\x92\xb0 Cost Analytics\n"); // 💰
    try w.writeAll("\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n"); // ────────────────────
    try w.print("Total: ${d:.4} ({d} tokens, {d} sessions)\n", .{ total.total_cost, total.total_tokens, total.session_count });
    try w.print("Today: ${d:.4} ({d} tokens, {d} sessions)\n", .{ today.cost, today.tokens, today.session_count });

    if (by_provider.len > 0) {
        try w.writeAll("\nBy Provider:\n");
        for (by_provider) |p| {
            try w.print("  {s}: ${d:.4}  ({d} tokens, {d} sessions)\n", .{ p.provider, p.cost, p.tokens, p.session_count });
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// Format the cost-by-model report.
pub fn formatByModelReport(
    allocator: Allocator,
    by_model: []ModelCost,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const w = buf.writer(allocator);

    try w.writeAll("\xf0\x9f\x93\x8a Cost by Model\n"); // 📊
    try w.writeAll("\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n"); // ────────────────────

    if (by_model.len == 0) {
        try w.writeAll("  No session data available.\n");
    } else {
        for (by_model) |m| {
            try w.print("  {s}: ${d:.4}  ({d} tokens, {d} sessions)\n", .{ m.model, m.cost, m.tokens, m.session_count });
        }
    }

    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers for freeing slices
// ---------------------------------------------------------------------------

pub fn freeProviderCosts(allocator: Allocator, items: []ProviderCost) void {
    for (items) |p| allocator.free(p.provider);
    allocator.free(items);
}

pub fn freeModelCosts(allocator: Allocator, items: []ModelCost) void {
    for (items) |m| allocator.free(m.model);
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getTotalCost with empty database" {
    var sdb = try session_db_mod.SessionDB.init(std.testing.allocator, ":memory:");
    defer sdb.deinit();

    var dashboard = CostDashboard.init(std.testing.allocator, &sdb);
    const result = try dashboard.getTotalCost();
    try std.testing.expectEqual(@as(f64, 0.0), result.total_cost);
    try std.testing.expectEqual(@as(u64, 0), result.total_tokens);
    try std.testing.expectEqual(@as(u64, 0), result.session_count);
}

test "getTotalCost with sessions" {
    const allocator = std.testing.allocator;
    var sdb = try session_db_mod.SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const s1 = session_db_mod.SessionRow{
        .id = "s1", .title = "Test1", .model = "gpt-4", .provider = "openai",
        .total_tokens = 100, .total_cost = 0.005, .turn_count = 1,
        .duration_seconds = 10, .created_at = 1000, .updated_at = 2000,
    };
    const s2 = session_db_mod.SessionRow{
        .id = "s2", .title = "Test2", .model = "claude-3", .provider = "anthropic",
        .total_tokens = 200, .total_cost = 0.010, .turn_count = 2,
        .duration_seconds = 20, .created_at = 3000, .updated_at = 4000,
    };
    const empty = [_]session_db_mod.MessageRow{};
    try sdb.saveSession(&s1, &empty);
    try sdb.saveSession(&s2, &empty);

    var dashboard = CostDashboard.init(allocator, &sdb);
    const result = try dashboard.getTotalCost();
    try std.testing.expectEqual(@as(u64, 2), result.session_count);
    try std.testing.expectEqual(@as(u64, 300), result.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), result.total_cost, 0.0001);
}

test "getCostByProvider groups correctly" {
    const allocator = std.testing.allocator;
    var sdb = try session_db_mod.SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const s1 = session_db_mod.SessionRow{
        .id = "s1", .title = "", .model = "gpt-4", .provider = "openai",
        .total_tokens = 100, .total_cost = 0.005, .turn_count = 1,
        .duration_seconds = 10, .created_at = 1000, .updated_at = 2000,
    };
    const s2 = session_db_mod.SessionRow{
        .id = "s2", .title = "", .model = "gpt-4o", .provider = "openai",
        .total_tokens = 200, .total_cost = 0.010, .turn_count = 1,
        .duration_seconds = 10, .created_at = 3000, .updated_at = 4000,
    };
    const empty = [_]session_db_mod.MessageRow{};
    try sdb.saveSession(&s1, &empty);
    try sdb.saveSession(&s2, &empty);

    var dashboard = CostDashboard.init(allocator, &sdb);
    const by_provider = try dashboard.getCostByProvider();
    defer freeProviderCosts(allocator, by_provider);

    try std.testing.expectEqual(@as(usize, 1), by_provider.len);
    try std.testing.expectEqualStrings("openai", by_provider[0].provider);
    try std.testing.expectEqual(@as(u64, 300), by_provider[0].tokens);
    try std.testing.expectEqual(@as(u64, 2), by_provider[0].session_count);
}

test "getCostByModel groups correctly" {
    const allocator = std.testing.allocator;
    var sdb = try session_db_mod.SessionDB.init(allocator, ":memory:");
    defer sdb.deinit();

    const s1 = session_db_mod.SessionRow{
        .id = "s1", .title = "", .model = "gpt-4", .provider = "openai",
        .total_tokens = 100, .total_cost = 0.003, .turn_count = 1,
        .duration_seconds = 10, .created_at = 1000, .updated_at = 2000,
    };
    const s2 = session_db_mod.SessionRow{
        .id = "s2", .title = "", .model = "claude-3", .provider = "anthropic",
        .total_tokens = 50, .total_cost = 0.001, .turn_count = 1,
        .duration_seconds = 10, .created_at = 3000, .updated_at = 4000,
    };
    const empty = [_]session_db_mod.MessageRow{};
    try sdb.saveSession(&s1, &empty);
    try sdb.saveSession(&s2, &empty);

    var dashboard = CostDashboard.init(allocator, &sdb);
    const by_model = try dashboard.getCostByModel();
    defer freeModelCosts(allocator, by_model);

    try std.testing.expectEqual(@as(usize, 2), by_model.len);
    // Sorted by cost DESC, so gpt-4 first
    try std.testing.expectEqualStrings("gpt-4", by_model[0].model);
    try std.testing.expectEqualStrings("claude-3", by_model[1].model);
}
