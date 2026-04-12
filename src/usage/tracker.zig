const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Token usage data matching streaming types
pub const TokenUsage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,

    pub fn totalTokens(self: TokenUsage) u32 {
        return self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens;
    }

    pub fn add(self: TokenUsage, other: TokenUsage) TokenUsage {
        return TokenUsage{
            .input_tokens = self.input_tokens + other.input_tokens,
            .output_tokens = self.output_tokens + other.output_tokens,
            .cache_read_tokens = self.cache_read_tokens + other.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens + other.cache_write_tokens,
        };
    }
};

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
    pub fn getDailyUsage(self: *const UsageTracker) *const DailyUsage {
        return &self.daily;
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

    /// Format current date as YYYY-MM-DD (simple implementation)
    fn formatDate(buf: []u8) void {
        const timestamp = std.time.timestamp();
        // Calculate days since epoch (1970-01-01)
        const days_since_epoch: i64 = @divFloor(timestamp, 86400);
        // Simple year calculation (not leap-year accurate, but functional)
        const approx_year: i64 = 1970 + @divFloor(days_since_epoch * 400, 146097);
        _ = std.fmt.bufPrint(buf, "{d:0>4}-01-01", .{
            @as(u32, @intCast(@max(approx_year, 1970))),
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
