const std = @import("std");

const Allocator = std.mem.Allocator;

/// Budget configuration
pub const BudgetConfig = struct {
    daily_limit_usd: f64 = 0.0,
    monthly_limit_usd: f64 = 0.0,
    per_session_limit_usd: f64 = 0.0,
    alert_threshold_pct: f64 = 0.8,

    pub fn isSet(self: *const BudgetConfig) bool {
        return self.daily_limit_usd > 0 or self.monthly_limit_usd > 0 or self.per_session_limit_usd > 0;
    }
};

/// Budget status snapshot
pub const BudgetStatus = struct {
    daily_spent: f64,
    daily_limit: f64,
    monthly_spent: f64,
    monthly_limit: f64,
    session_spent: f64,
    session_limit: f64,
    percent_used: f64,

    pub fn isOverBudget(self: *const BudgetStatus) bool {
        if (self.daily_limit > 0 and self.daily_spent >= self.daily_limit) return true;
        if (self.monthly_limit > 0 and self.monthly_spent >= self.monthly_limit) return true;
        if (self.session_limit > 0 and self.session_spent >= self.session_limit) return true;
        return false;
    }

    pub fn shouldAlert(self: *const BudgetStatus, threshold: f64) bool {
        if (self.daily_limit > 0 and self.daily_spent / self.daily_limit >= threshold) return true;
        if (self.monthly_limit > 0 and self.monthly_spent / self.monthly_limit >= threshold) return true;
        if (self.session_limit > 0 and self.session_spent / self.session_limit >= threshold) return true;
        return false;
    }
};

/// Budget manager — tracks spending against configurable limits
pub const BudgetManager = struct {
    config: BudgetConfig,
    daily_spent: f64,
    monthly_spent: f64,
    session_spent: f64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: BudgetConfig) BudgetManager {
        return BudgetManager{
            .config = config,
            .daily_spent = 0.0,
            .monthly_spent = 0.0,
            .session_spent = 0.0,
            .allocator = allocator,
        };
    }

    /// Record a cost from a request
    pub fn recordCost(self: *BudgetManager, cost_usd: f64) void {
        self.daily_spent += cost_usd;
        self.monthly_spent += cost_usd;
        self.session_spent += cost_usd;
    }

    /// Check current budget status
    pub fn checkBudget(self: *const BudgetManager) BudgetStatus {
        var max_pct: f64 = 0.0;

        if (self.config.daily_limit_usd > 0) {
            const pct = self.daily_spent / self.config.daily_limit_usd;
            if (pct > max_pct) max_pct = pct;
        }
        if (self.config.monthly_limit_usd > 0) {
            const pct = self.monthly_spent / self.config.monthly_limit_usd;
            if (pct > max_pct) max_pct = pct;
        }
        if (self.config.per_session_limit_usd > 0) {
            const pct = self.session_spent / self.config.per_session_limit_usd;
            if (pct > max_pct) max_pct = pct;
        }

        return BudgetStatus{
            .daily_spent = self.daily_spent,
            .daily_limit = self.config.daily_limit_usd,
            .monthly_spent = self.monthly_spent,
            .monthly_limit = self.config.monthly_limit_usd,
            .session_spent = self.session_spent,
            .session_limit = self.config.per_session_limit_usd,
            .percent_used = max_pct,
        };
    }

    /// Check if we should show a budget alert
    pub fn shouldAlert(self: *const BudgetManager) bool {
        if (!self.config.isSet()) return false;
        const status = self.checkBudget();
        return status.shouldAlert(self.config.alert_threshold_pct);
    }

    /// Check if we're over budget (should block requests)
    pub fn isOverBudget(self: *const BudgetManager) bool {
        if (!self.config.isSet()) return false;
        const status = self.checkBudget();
        return status.isOverBudget();
    }

    /// Print a budget alert to stderr
    pub fn printAlert(self: *BudgetManager) void {
        const status = self.checkBudget();
        const stderr = std.io.getStdErr().writer();

        if (status.isOverBudget()) {
            stderr.print("\x1b[31m⚠ BUDGET EXCEEDED: ${d:.2} spent\x1b[0m\n", .{self.session_spent}) catch {};
            if (self.config.daily_limit_usd > 0) {
                stderr.print("  Daily: ${d:.2} / ${d:.2}\n", .{ status.daily_spent, status.daily_limit }) catch {};
            }
            if (self.config.per_session_limit_usd > 0) {
                stderr.print("  Session: ${d:.2} / ${d:.2}\n", .{ status.session_spent, status.session_limit }) catch {};
            }
        } else if (status.shouldAlert(self.config.alert_threshold_pct)) {
            stderr.print("\x1b[33m⚠ Budget alert: ${d:.2} spent ({d:.0}% of limit)\x1b[0m\n", .{
                self.session_spent,
                status.percent_used * 100.0,
            }) catch {};
        }
    }

    /// Reset session spending
    pub fn resetSession(self: *BudgetManager) void {
        self.session_spent = 0.0;
    }

    /// Format cost as a compact string
    pub fn formatCost(allocator: Allocator, cost: f64) ![]const u8 {
        if (cost < 0.001) {
            return std.fmt.allocPrint(allocator, "${d:.4}", .{cost});
        } else if (cost < 1.0) {
            return std.fmt.allocPrint(allocator, "${d:.3}", .{cost});
        } else {
            return std.fmt.allocPrint(allocator, "${d:.2}", .{cost});
        }
    }

    pub fn deinit(self: *BudgetManager) void {
        _ = self;
    }
};
