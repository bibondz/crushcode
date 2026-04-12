const std = @import("std");
const file_compat = @import("file_compat");
const tracker_mod = @import("tracker.zig");
const budget_mod = @import("budget.zig");

const SessionUsage = tracker_mod.SessionUsage;
const DailyUsage = tracker_mod.DailyUsage;
const BudgetStatus = budget_mod.BudgetStatus;

/// Usage report formatting and display
pub const UsageReport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UsageReport {
        return UsageReport{ .allocator = allocator };
    }

    /// Print a session usage report to stdout
    pub fn printSessionReport(self: *UsageReport, usage: *const SessionUsage) void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Session Usage ===\n", .{}) catch {};
        stdout.print("  Requests: {d}\n", .{usage.request_count}) catch {};
        stdout.print("  Tokens: {d} in / {d} out", .{ usage.input_tokens, usage.output_tokens }) catch {};
        if (usage.cache_read_tokens > 0) {
            stdout.print(" / {d} cache read", .{usage.cache_read_tokens}) catch {};
        }
        stdout.print("\n", .{}) catch {};
        stdout.print("  Cost: ${d:.4}\n", .{usage.estimated_cost_usd}) catch {};

        // Per-provider breakdown
        if (usage.by_provider.count() > 0) {
            stdout.print("\n  By provider:\n", .{}) catch {};
            var iter = usage.by_provider.iterator();
            while (iter.next()) |entry| {
                const pu = entry.value_ptr;
                stdout.print("    {s} ({s}): {d} req | ${d:.4}\n", .{
                    pu.provider,
                    pu.model,
                    pu.request_count,
                    pu.cost_usd,
                }) catch {};
            }
        }
    }

    /// Print a daily usage report
    pub fn printDailyReport(self: *UsageReport, daily: *const DailyUsage) void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Daily Usage ({s}) ===\n", .{daily.date}) catch {};
        stdout.print("  Requests: {d}\n", .{daily.request_count}) catch {};
        stdout.print("  Tokens: {d} in / {d} out\n", .{ daily.input_tokens, daily.output_tokens }) catch {};
        stdout.print("  Cost: ${d:.4}\n", .{daily.estimated_cost_usd}) catch {};
    }

    /// Print a full report combining session, daily, and budget info
    pub fn printFullReport(self: *UsageReport, session: *const SessionUsage, daily: *const DailyUsage, budget_status: ?BudgetStatus) void {
        self.printSessionReport(session);
        self.printDailyReport(daily);

        if (budget_status) |bs| {
            const stdout = file_compat.File.stdout().writer();
            stdout.print("\n=== Budget ===\n", .{}) catch {};

            if (bs.daily_limit > 0) {
                const pct = bs.daily_spent / bs.daily_limit * 100.0;
                const icon = if (pct >= 100) "🔴" else if (pct >= 80) "🟡" else "✅";
                stdout.print("  Daily: ${d:.4} / ${d:.2} ({d:.0}%) {s}\n", .{
                    bs.daily_spent,
                    bs.daily_limit,
                    pct,
                    icon,
                }) catch {};
            }
            if (bs.monthly_limit > 0) {
                const pct = bs.monthly_spent / bs.monthly_limit * 100.0;
                const icon = if (pct >= 100) "🔴" else if (pct >= 80) "🟡" else "✅";
                stdout.print("  Monthly: ${d:.4} / ${d:.2} ({d:.0}%) {s}\n", .{
                    bs.monthly_spent,
                    bs.monthly_limit,
                    pct,
                    icon,
                }) catch {};
            }
            if (bs.session_limit > 0) {
                const pct = bs.session_spent / bs.session_limit * 100.0;
                const icon = if (pct >= 100) "🔴" else if (pct >= 80) "🟡" else "✅";
                stdout.print("  Session: ${d:.4} / ${d:.2} ({d:.0}%) {s}\n", .{
                    bs.session_spent,
                    bs.session_limit,
                    pct,
                    icon,
                }) catch {};
            }
            if (bs.daily_limit == 0 and bs.monthly_limit == 0 and bs.session_limit == 0) {
                stdout.print("  No budget limits configured\n", .{}) catch {};
            }
        }
    }

    /// Print a compact inline usage summary (for after each AI response)
    pub fn printInlineUsage(self: *UsageReport, input_tokens: u32, output_tokens: u32, cost: f64) void {
        _ = self;
        const stdout = file_compat.File.stdout().writer();
        if (cost > 0.001) {
            stdout.print("\x1b[2m({d} tokens in / {d} out | ${d:.4})\x1b[0m", .{ input_tokens, output_tokens, cost }) catch {};
        } else {
            stdout.print("\x1b[2m({d} tokens in / {d} out)\x1b[0m", .{ input_tokens, output_tokens }) catch {};
        }
    }

    pub fn deinit(self: *UsageReport) void {
        _ = self;
    }
};
