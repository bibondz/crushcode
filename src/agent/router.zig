const std = @import("std");
const array_list_compat = @import("array_list_compat");
const circuit_breaker = @import("circuit_breaker");

const Allocator = std.mem.Allocator;
const CircuitBreaker = circuit_breaker.CircuitBreaker;
const CircuitBreakerMap = circuit_breaker.CircuitBreakerMap;

/// Task category for routing decisions.
/// Each category maps to a model tier based on complexity and cost.
pub const TaskCategory = enum {
    /// Data collection, scraping, simple extraction → fast/cheap model
    data_collection,
    /// Code analysis, review, understanding → standard model
    code_analysis,
    /// Deep reasoning, architecture, complex decisions → premium model
    reasoning,
    /// File operations, read/write, simple transforms → fast model
    file_operations,
    /// Synthesis, summarization, report generation → premium model
    synthesis,
    /// Search, lookup, simple queries → fast model
    search,
};

/// A single routing rule mapping a task category to a model.
pub const RoutingRule = struct {
    category: TaskCategory,
    model: []const u8,
};

/// Model pricing tier for cost estimation.
/// Prices are per 1M tokens (input) in USD.
pub const PricingTier = struct {
    model: []const u8,
    input_cost_per_million: f64,
    output_cost_per_million: f64,
};

/// Default pricing for known model families (rough estimates).
const default_pricing = [_]PricingTier{
    .{ .model = "haiku", .input_cost_per_million = 0.25, .output_cost_per_million = 1.25 },
    .{ .model = "sonnet", .input_cost_per_million = 3.0, .output_cost_per_million = 15.0 },
    .{ .model = "opus", .input_cost_per_million = 15.0, .output_cost_per_million = 75.0 },
    .{ .model = "gpt-4o-mini", .input_cost_per_million = 0.15, .output_cost_per_million = 0.6 },
    .{ .model = "gpt-4o", .input_cost_per_million = 2.5, .output_cost_per_million = 10.0 },
    .{ .model = "deepseek-chat", .input_cost_per_million = 0.14, .output_cost_per_million = 0.28 },
    .{ .model = "gemini-flash", .input_cost_per_million = 0.075, .output_cost_per_million = 0.3 },
    .{ .model = "default", .input_cost_per_million = 3.0, .output_cost_per_million = 15.0 },
};

/// Routing strategy for model selection.
pub const RoutingStrategy = enum {
    /// Use current category→model mapping
    default,
    /// Pick cheapest model meeting quality threshold
    cost_optimized,
    /// Pick provider with lowest recent P95
    latency_aware,
    /// Try models in order, skip circuit-open providers
    fallback_chain,
};

/// Ordered fallback chain of model names.
/// Tries each model in sequence, skipping circuit-open providers.
pub const FallbackChain = struct {
    models: []const []const u8,
    allocator: Allocator,
    /// Internal index tracking (not exposed)
    current_index: usize,

    /// Initialize a fallback chain with an ordered list of model names.
    /// Models slice is duped and owned by the chain.
    pub fn init(allocator: Allocator, models: []const []const u8) !FallbackChain {
        const duped = try allocator.alloc([]const u8, models.len);
        for (models, 0..) |m, i| {
            duped[i] = try allocator.dupe(u8, m);
        }
        return FallbackChain{
            .models = duped,
            .allocator = allocator,
            .current_index = 0,
        };
    }

    /// Get the next available model, skipping circuit-open providers.
    /// Returns null if all models exhausted.
    pub fn next(self: *FallbackChain, breakers: *const CircuitBreakerMap) ?[]const u8 {
        while (self.current_index < self.models.len) {
            const model = self.models[self.current_index];
            self.current_index += 1;

            // Check circuit breaker for this provider
            if (breakers.get(model)) |*breaker| {
                if (!breaker.allow()) continue;
            }
            return model;
        }
        return null;
    }

    /// Reset chain to start from the beginning.
    pub fn resetIndex(self: *FallbackChain) void {
        self.current_index = 0;
    }

    pub fn deinit(self: *FallbackChain) void {
        for (self.models) |m| {
            self.allocator.free(m);
        }
        self.allocator.free(self.models);
    }
};

/// Per-provider latency tracking for latency-aware routing.
pub const ProviderLatency = struct {
    provider: []const u8,
    model: []const u8,
    p50_ms: u64,
    p95_ms: u64,
    sample_count: u32,
    last_updated_ns: i64,

    /// Record a latency sample. Updates P50/P95 estimates using exponential moving average.
    pub fn record(self: *ProviderLatency, latency_ms: u64) void {
        if (self.sample_count == 0) {
            self.p50_ms = latency_ms;
            self.p95_ms = latency_ms;
        } else {
            // Exponential moving average: blend new value with 70/30 weight
            self.p50_ms = @intCast(@divFloor(self.p50_ms * 7 + latency_ms * 3, 10));
            // P95 tracks higher values with 90/10 blend
            const p95_new = @max(self.p95_ms, latency_ms);
            self.p95_ms = @intCast(@divFloor(self.p95_ms * 9 + p95_new, 10));
        }
        self.sample_count += 1;
        self.last_updated_ns = @intCast(std.time.nanoTimestamp());
    }
};

/// Model router — maps task categories to appropriate models.
///
/// Default rules:
///   data_collection, file_operations, search → "haiku" (fast/cheap)
///   code_analysis → "sonnet" (standard)
///   reasoning, synthesis → "opus" (premium)
///
/// Integration point: router returns model name, caller uses ProviderRegistry
/// to create an AIClient for that model.
pub const ModelRouter = struct {
    allocator: Allocator,
    rules: array_list_compat.ArrayList(RoutingRule),
    default_model: []const u8,
    strategy: RoutingStrategy,
    latency_history: std.StringHashMap(ProviderLatency),
    circuit_breakers: CircuitBreakerMap,
    fallback_chain: ?FallbackChain,

    /// Initialize a new ModelRouter with default routing rules.
    pub fn init(allocator: Allocator) !ModelRouter {
        var router = ModelRouter{
            .allocator = allocator,
            .rules = array_list_compat.ArrayList(RoutingRule).init(allocator),
            .default_model = try allocator.dupe(u8, "sonnet"),
            .strategy = .default,
            .latency_history = std.StringHashMap(ProviderLatency).init(allocator),
            .circuit_breakers = CircuitBreakerMap.init(allocator),
            .fallback_chain = null,
        };
        errdefer {
            router.rules.deinit();
            allocator.free(router.default_model);
        }

        // Set up default routing rules
        try router.addRule(.data_collection, "haiku");
        try router.addRule(.code_analysis, "sonnet");
        try router.addRule(.reasoning, "opus");
        try router.addRule(.file_operations, "haiku");
        try router.addRule(.synthesis, "opus");
        try router.addRule(.search, "haiku");

        return router;
    }

    pub fn deinit(self: *ModelRouter) void {
        for (self.rules.items) |rule| {
            self.allocator.free(rule.model);
        }
        self.rules.deinit();
        self.allocator.free(self.default_model);
        // Clean up latency history keys
        var lat_it = self.latency_history.keyIterator();
        while (lat_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.latency_history.deinit();
        // Clean up circuit breakers keys
        var cb_it = self.circuit_breakers.keyIterator();
        while (cb_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.circuit_breakers.deinit();
        // Clean up fallback chain
        if (self.fallback_chain) |*fc| {
            fc.deinit();
        }
    }

    /// Route a task category to the appropriate model.
    /// Returns the model name from matching rule, or default_model if no rule matches.
    pub fn routeForTask(self: *const ModelRouter, category: TaskCategory) []const u8 {
        for (self.rules.items) |rule| {
            if (rule.category == category) return rule.model;
        }
        return self.default_model;
    }

    /// Add or update a routing rule for a task category.
    /// If a rule already exists for the category, it is updated.
    pub fn addRule(self: *ModelRouter, category: TaskCategory, model: []const u8) !void {
        // Check if rule already exists — update it
        for (self.rules.items) |*rule| {
            if (rule.category == category) {
                const new_model = try self.allocator.dupe(u8, model);
                self.allocator.free(rule.model);
                rule.model = new_model;
                return;
            }
        }

        // Add new rule
        const new_model = try self.allocator.dupe(u8, model);
        try self.rules.append(.{
            .category = category,
            .model = new_model,
        });
    }

    /// Remove a routing rule for a task category.
    /// Returns true if a rule was removed, false if no rule existed.
    pub fn removeRule(self: *ModelRouter, category: TaskCategory) bool {
        for (self.rules.items, 0..) |rule, i| {
            if (rule.category == category) {
                self.allocator.free(rule.model);
                _ = self.rules.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Estimate cost for a task based on the routed model and estimated tokens.
    /// Returns cost in USD (rough estimate).
    pub fn estimateCost(self: *const ModelRouter, category: TaskCategory, estimated_tokens: u64) f64 {
        const model = self.routeForTask(category);
        return self.estimateCostForModel(model, estimated_tokens);
    }

    /// Estimate cost for a specific model and token count.
    /// Uses input pricing as a rough estimate (50/50 input/output split assumed).
    pub fn estimateCostForModel(self: *const ModelRouter, model: []const u8, estimated_tokens: u64) f64 {
        _ = self;
        const pricing = getPricing(model);
        const tokens_f64 = @as(f64, @floatFromInt(estimated_tokens));
        // Assume 50/50 split between input and output tokens
        const input_tokens = tokens_f64 * 0.5;
        const output_tokens = tokens_f64 * 0.5;
        const input_cost = (input_tokens / 1_000_000.0) * pricing.input_cost_per_million;
        const output_cost = (output_tokens / 1_000_000.0) * pricing.output_cost_per_million;
        return input_cost + output_cost;
    }

    /// Get all routing rules as a slice.
    pub fn getRules(self: *const ModelRouter) []const RoutingRule {
        return self.rules.items;
    }

    /// Parse a TaskCategory from string (case-insensitive).
    pub fn parseCategory(s: []const u8) ?TaskCategory {
        if (std.ascii.startsWithIgnoreCase(s, "data_collection") or
            std.mem.eql(u8, s, "data-collection") or
            std.mem.eql(u8, s, "collect"))
        {
            return .data_collection;
        }
        if (std.ascii.startsWithIgnoreCase(s, "code_analysis") or
            std.mem.eql(u8, s, "code-analysis") or
            std.mem.eql(u8, s, "code"))
        {
            return .code_analysis;
        }
        if (std.ascii.startsWithIgnoreCase(s, "reasoning") or
            std.mem.eql(u8, s, "reason"))
        {
            return .reasoning;
        }
        if (std.ascii.startsWithIgnoreCase(s, "file_operations") or
            std.mem.eql(u8, s, "file-operations") or
            std.mem.eql(u8, s, "file"))
        {
            return .file_operations;
        }
        if (std.ascii.startsWithIgnoreCase(s, "synthesis") or
            std.mem.eql(u8, s, "synthesize") or
            std.mem.eql(u8, s, "summary"))
        {
            return .synthesis;
        }
        if (std.ascii.startsWithIgnoreCase(s, "search") or
            std.mem.eql(u8, s, "lookup"))
        {
            return .search;
        }
        return null;
    }

    /// Set the routing strategy.
    pub fn setStrategy(self: *ModelRouter, strategy: RoutingStrategy) void {
        self.strategy = strategy;
    }

    /// Set the fallback chain for fallback_chain strategy.
    /// Models are duped and owned by the router.
    pub fn setFallbackChain(self: *ModelRouter, models: []const []const u8) !void {
        if (self.fallback_chain) |*fc| {
            fc.deinit();
        }
        self.fallback_chain = try FallbackChain.init(self.allocator, models);
    }

    /// Get or create a circuit breaker for a provider.
    /// Returns null only on allocation failure.
    pub fn getCircuitBreaker(self: *ModelRouter, provider: []const u8) ?*CircuitBreaker {
        if (self.circuit_breakers.getPtr(provider)) |cb| {
            return cb;
        }
        // Create a new circuit breaker: 5 failures, 60s reset timeout
        const cb = CircuitBreaker.init(provider, 5, 60 * std.time.ns_per_s);
        const key = self.allocator.dupe(u8, provider) catch return null;
        self.circuit_breakers.put(key, cb) catch {
            self.allocator.free(key);
            return null;
        };
        return self.circuit_breakers.getPtr(provider);
    }

    /// Record latency for a provider+model combination.
    pub fn recordLatency(self: *ModelRouter, provider: []const u8, model: []const u8, latency_ms: u64) void {
        // Build composite key: "provider|model"
        const key_len = provider.len + 1 + model.len;
        const key = self.allocator.alloc(u8, key_len) catch return;
        @memcpy(key[0..provider.len], provider);
        key[provider.len] = '|';
        @memcpy(key[provider.len + 1 ..], model);

        if (self.latency_history.getPtr(key)) |latency| {
            latency.record(latency_ms);
            self.allocator.free(key);
        } else {
            var latency = ProviderLatency{
                .provider = provider,
                .model = model,
                .p50_ms = 0,
                .p95_ms = 0,
                .sample_count = 0,
                .last_updated_ns = 0,
            };
            latency.record(latency_ms);
            self.latency_history.put(key, latency) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Route using the configured strategy.
    pub fn routeWithStrategy(self: *ModelRouter, category: TaskCategory) []const u8 {
        switch (self.strategy) {
            .default => return self.routeForTask(category),
            .cost_optimized => return self.routeForTask(category),
            .latency_aware => {
                const model = self.routeForTask(category);
                // Check if this provider has high P95 latency
                var it = self.latency_history.iterator();
                var best_model: ?[]const u8 = null;
                var best_p95: u64 = std.math.maxInt(u64);
                while (it.next()) |entry| {
                    if (entry.value_ptr.p95_ms < best_p95) {
                        best_p95 = entry.value_ptr.p95_ms;
                        best_model = entry.value_ptr.model;
                    }
                }
                // If best latency is significantly better, use it; otherwise keep default
                if (best_model) |bm| {
                    if (best_p95 < 5000) {
                        return bm;
                    }
                }
                return model;
            },
            .fallback_chain => {
                if (self.fallback_chain) |*fc| {
                    fc.resetIndex();
                    if (fc.next(&self.circuit_breakers)) |model| {
                        return model;
                    }
                }
                return self.routeForTask(category);
            },
        }
    }
};

/// Get pricing for a model (partial match on model name).
fn getPricing(model: []const u8) PricingTier {
    // Try exact match first
    for (&default_pricing) |p| {
        if (std.mem.eql(u8, p.model, model)) return p;
    }
    // Try partial match
    var buf: [256]u8 = undefined;
    if (model.len < buf.len) {
        const lower = std.ascii.lowerString(&buf, model);
        for (&default_pricing) |p| {
            if (std.mem.indexOf(u8, lower, p.model) != null) return p;
        }
    }
    // Default pricing
    return .{ .model = "default", .input_cost_per_million = 3.0, .output_cost_per_million = 15.0 };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ModelRouter - default routing rules" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    try testing.expectEqualStrings("haiku", router.routeForTask(.data_collection));
    try testing.expectEqualStrings("sonnet", router.routeForTask(.code_analysis));
    try testing.expectEqualStrings("opus", router.routeForTask(.reasoning));
    try testing.expectEqualStrings("haiku", router.routeForTask(.file_operations));
    try testing.expectEqualStrings("opus", router.routeForTask(.synthesis));
    try testing.expectEqualStrings("haiku", router.routeForTask(.search));
}

test "ModelRouter - default model is sonnet" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    try testing.expectEqualStrings("sonnet", router.default_model);
}

test "ModelRouter - addRule overrides default" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    // Override code_analysis to use gpt-4o
    try router.addRule(.code_analysis, "gpt-4o");
    try testing.expectEqualStrings("gpt-4o", router.routeForTask(.code_analysis));

    // Other rules should remain unchanged
    try testing.expectEqualStrings("haiku", router.routeForTask(.data_collection));
    try testing.expectEqualStrings("opus", router.routeForTask(.reasoning));
}

test "ModelRouter - addRule adds new mapping" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    // Override all categories to use one model
    try router.addRule(.data_collection, "deepseek-chat");
    try router.addRule(.code_analysis, "deepseek-chat");
    try router.addRule(.reasoning, "deepseek-chat");
    try router.addRule(.file_operations, "deepseek-chat");
    try router.addRule(.synthesis, "deepseek-chat");
    try router.addRule(.search, "deepseek-chat");

    try testing.expectEqualStrings("deepseek-chat", router.routeForTask(.data_collection));
    try testing.expectEqualStrings("deepseek-chat", router.routeForTask(.code_analysis));
    try testing.expectEqualStrings("deepseek-chat", router.routeForTask(.reasoning));
}

test "ModelRouter - removeRule" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    // Remove the code_analysis rule
    const removed = router.removeRule(.code_analysis);
    try testing.expect(removed);

    // Should fall back to default model
    try testing.expectEqualStrings("sonnet", router.routeForTask(.code_analysis));

    // Removing again should return false
    const removed_again = router.removeRule(.code_analysis);
    try testing.expect(!removed_again);
}

test "ModelRouter - getRules returns all rules" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    const rules = router.getRules();
    try testing.expectEqual(@as(usize, 6), rules.len);
}

test "ModelRouter - estimateCost for haiku" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    // haiku: $0.25/1M input, $1.25/1M output
    // 10000 tokens, 50/50 split = 5000 input + 5000 output
    // cost = (5000/1M * 0.25) + (5000/1M * 1.25) = 0.00125 + 0.00625 = 0.0075
    const cost = router.estimateCost(.data_collection, 10000);
    try testing.expect(cost > 0.007 and cost < 0.008);
}

test "ModelRouter - estimateCost for opus" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    // opus: $15/1M input, $75/1M output
    // 100000 tokens, 50/50 split = 50000 input + 50000 output
    // cost = (50000/1M * 15) + (50000/1M * 75) = 0.75 + 3.75 = 4.5
    const cost = router.estimateCost(.reasoning, 100000);
    try testing.expect(cost > 4.4 and cost < 4.6);
}

test "ModelRouter - estimateCostForModel" {
    const allocator = std.testing.allocator;
    var router = try ModelRouter.init(allocator);
    defer router.deinit();

    const cost = router.estimateCostForModel("sonnet", 1_000_000);
    // sonnet: $3/1M input, $15/1M output, 50/50 split
    // cost = (500000/1M * 3) + (500000/1M * 15) = 1.5 + 7.5 = 9.0
    try testing.expect(cost > 8.9 and cost < 9.1);
}

test "ModelRouter - parseCategory" {
    try testing.expectEqual(TaskCategory.data_collection, ModelRouter.parseCategory("data_collection"));
    try testing.expectEqual(TaskCategory.data_collection, ModelRouter.parseCategory("data-collection"));
    try testing.expectEqual(TaskCategory.code_analysis, ModelRouter.parseCategory("code_analysis"));
    try testing.expectEqual(TaskCategory.code_analysis, ModelRouter.parseCategory("code"));
    try testing.expectEqual(TaskCategory.reasoning, ModelRouter.parseCategory("reasoning"));
    try testing.expectEqual(TaskCategory.file_operations, ModelRouter.parseCategory("file_operations"));
    try testing.expectEqual(TaskCategory.file_operations, ModelRouter.parseCategory("file"));
    try testing.expectEqual(TaskCategory.synthesis, ModelRouter.parseCategory("synthesis"));
    try testing.expectEqual(TaskCategory.search, ModelRouter.parseCategory("search"));
    try testing.expect(ModelRouter.parseCategory("unknown") == null);
}

test "ModelRouter - parseCategory case insensitive" {
    try testing.expectEqual(TaskCategory.data_collection, ModelRouter.parseCategory("DATA_COLLECTION"));
    try testing.expectEqual(TaskCategory.reasoning, ModelRouter.parseCategory("Reasoning"));
    try testing.expectEqual(TaskCategory.search, ModelRouter.parseCategory("SEARCH"));
}

test "getPricing - exact match" {
    const p = getPricing("haiku");
    try testing.expectEqualStrings("haiku", p.model);
    try testing.expect(p.input_cost_per_million > 0);
}

test "getPricing - partial match" {
    const p = getPricing("claude-3-haiku");
    try testing.expect(p.input_cost_per_million > 0);
    try testing.expect(p.input_cost_per_million < 1.0); // haiku is cheap
}

test "getPricing - unknown model returns default" {
    const p = getPricing("totally-unknown-model-xyz");
    try testing.expectEqualStrings("default", p.model);
    try testing.expect(p.input_cost_per_million > 0);
}
