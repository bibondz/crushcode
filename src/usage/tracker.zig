const std = @import("std");
const array_list_compat = @import("array_list_compat");
const streaming_types = @import("streaming_types");

const Allocator = std.mem.Allocator;

/// Token usage data — canonical definition lives in streaming/types.zig
pub const TokenUsage = streaming_types.TokenUsage;

/// Per-provider usage breakdown
pub const ProviderUsage = struct {
    provider: []const u8,
    model: []const u8,
    request_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    cost_usd: f64,
};

/// Session-level usage tracking
pub const SessionUsage = struct {
    request_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    estimated_cost_usd: f64,
    by_provider: std.StringHashMap(ProviderUsage),

    pub fn init(allocator: Allocator) SessionUsage {
        return SessionUsage{
            .request_count = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .estimated_cost_usd = 0.0,
            .by_provider = std.StringHashMap(ProviderUsage).init(allocator),
        };
    }

    pub fn deinit(self: *SessionUsage) void {
        _ = self.by_provider.iterator();
        self.by_provider.deinit();
    }
};

/// Daily usage tracking (persisted to disk)
pub const DailyUsage = struct {
    date: []const u8, // YYYY-MM-DD
    request_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    estimated_cost_usd: f64,
};

/// Usage tracker — per-session and cumulative token tracking
pub const UsageTracker = struct {
    allocator: Allocator,
    data_dir: []const u8,

    // In-memory session tracking
    session: SessionUsage,

    // Cumulative daily tracking
    daily: DailyUsage,

    // Provider-model key for by_provider map
    provider_keys: array_list_compat.ArrayList([]const u8),

    pub fn init(allocator: Allocator, data_dir: []const u8) UsageTracker {
        // Allocate date buffer; if OOM, use a static fallback and skip formatting
        const date_buf_allocated = allocator.alloc(u8, 10) catch null;
        var fallback_buf = [_]u8{ '0', '0', '0', '0', '-', '0', '0', '-', '0', '0' };
        const date_buf: []u8 = if (date_buf_allocated) |buf| buf else &fallback_buf;
        if (date_buf_allocated != null) formatDate(date_buf);

        return UsageTracker{
            .allocator = allocator,
            .data_dir = data_dir,
            .session = SessionUsage.init(allocator),
            .daily = DailyUsage{
                .date = date_buf,
                .request_count = 0,
                .input_tokens = 0,
                .output_tokens = 0,
                .estimated_cost_usd = 0.0,
            },
            .provider_keys = array_list_compat.ArrayList([]const u8).init(allocator),
        };
    }

    /// Record usage from a single AI request
    pub fn recordUsage(self: *UsageTracker, provider: []const u8, model: []const u8, usage: TokenUsage, cost: f64) !void {
        // Update session totals
        self.session.request_count += 1;
        self.session.input_tokens += usage.input_tokens;
        self.session.output_tokens += usage.output_tokens;
        self.session.cache_read_tokens += usage.cache_read_tokens;
        self.session.cache_write_tokens += usage.cache_write_tokens;
        self.session.estimated_cost_usd += cost;

        // Update daily totals
        self.daily.request_count += 1;
        self.daily.input_tokens += usage.input_tokens;
        self.daily.output_tokens += usage.output_tokens;
        self.daily.estimated_cost_usd += cost;

        // Update per-provider tracking
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ provider, model });
        try self.provider_keys.append(key);

        if (self.session.by_provider.getPtr(key)) |existing| {
            existing.request_count += 1;
            existing.input_tokens += usage.input_tokens;
            existing.output_tokens += usage.output_tokens;
            existing.cache_read_tokens += usage.cache_read_tokens;
            existing.cache_write_tokens += usage.cache_write_tokens;
            existing.cost_usd += cost;
        } else {
            try self.session.by_provider.put(key, ProviderUsage{
                .provider = provider,
                .model = model,
                .request_count = 1,
                .input_tokens = usage.input_tokens,
                .output_tokens = usage.output_tokens,
                .cache_read_tokens = usage.cache_read_tokens,
                .cache_write_tokens = usage.cache_write_tokens,
                .cost_usd = cost,
            });
        }
    }

    /// Get session usage summary
    pub fn getSessionUsage(self: *const UsageTracker) *const SessionUsage {
        return &self.session;
    }

    /// Get daily usage summary
    pub fn getDailyUsage(self: *UsageTracker) *const DailyUsage {
        return &self.daily;
    }

    /// Check if the date has changed since last tracking, and reset daily counters.
    /// Call this before recording usage or checking budgets.
    pub fn checkAndResetDaily(self: *UsageTracker) void {
        var today_buf: [10]u8 = undefined;
        formatDate(&today_buf);

        // If date hasn't changed, no reset needed
        if (std.mem.eql(u8, self.daily.date, &today_buf)) return;

        // Date changed — reset daily counters
        self.daily.request_count = 0;
        self.daily.input_tokens = 0;
        self.daily.output_tokens = 0;
        self.daily.estimated_cost_usd = 0.0;

        // Update date
        @memcpy(self.daily.date, &today_buf);
    }

    /// Check if a new month has started (compared to a stored YYYY-MM string).
    /// Returns true if the current month differs from the given one.
    pub fn isNewMonth(stored_ym: []const u8) bool {
        var today_buf: [10]u8 = undefined;
        formatDate(&today_buf);
        // Compare YYYY-MM (first 7 chars)
        if (stored_ym.len < 7 or today_buf.len < 7) return true;
        return !std.mem.eql(u8, stored_ym[0..7], today_buf[0..7]);
    }

    /// Get current YYYY-MM string (allocated)
    pub fn getCurrentMonth(allocator: Allocator) ![]const u8 {
        var buf: [10]u8 = undefined;
        formatDate(&buf);
        return allocator.dupe(u8, buf[0..7]);
    }

    /// Reset session tracking (start fresh for new conversation)
    pub fn resetSession(self: *UsageTracker) void {
        self.session.request_count = 0;
        self.session.input_tokens = 0;
        self.session.output_tokens = 0;
        self.session.cache_read_tokens = 0;
        self.session.cache_write_tokens = 0;
        self.session.estimated_cost_usd = 0.0;

        // Free provider keys
        for (self.provider_keys.items) |key| {
            self.allocator.free(key);
        }
        self.provider_keys.clearRetainingCapacity();
        self.session.by_provider.clearRetainingCapacity();
    }

    /// Format current date as YYYY-MM-DD using epoch calculation
    fn formatDate(buf: []u8) void {
        const timestamp = std.time.timestamp();
        // Days since epoch (1970-01-01)
        const total_days: i64 = @divFloor(timestamp, 86400);

        // Calculate year, month, day using algorithm from Howard Hinnant
        const z = total_days + 719468;
        const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
        const doe: i64 = z - era * 146097;
        const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: i64 = @divFloor(5 * doy + 2, 153);
        const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: i64 = if (mp < 10) mp + 3 else mp - 9;
        const final_year: i64 = y + @divFloor(m, 13) - @as(i64, if (m <= 2) 1 else 0);

        _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u32, @intCast(@max(final_year, 1970))),
            @as(u32, @intCast(@max(m, 1))),
            @as(u32, @intCast(@max(d, 1))),
        }) catch {};
    }

    pub fn deinit(self: *UsageTracker) void {
        for (self.provider_keys.items) |key| {
            self.allocator.free(key);
        }
        self.provider_keys.deinit();
        self.session.deinit();
        if (self.daily.date.len > 0 and self.daily.date[0] != '0') {
            self.allocator.free(self.daily.date);
        }
    }
};
