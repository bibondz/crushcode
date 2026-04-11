const std = @import("std");

/// Pricing information for a single model
pub const ModelPricing = struct {
    provider: []const u8,
    model: []const u8,
    input_price_per_1m: f64, // USD per 1M input tokens
    output_price_per_1m: f64, // USD per 1M output tokens
    cache_read_price_per_1m: f64, // USD per 1M cache read tokens (0 if N/A)
    cache_write_price_per_1m: f64, // USD per 1M cache write tokens (0 if N/A)
};

/// Pricing table for all supported providers and models
pub const PricingTable = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ModelPricing),

    pub fn init(allocator: std.mem.Allocator) !PricingTable {
        var table = PricingTable{
            .allocator = allocator,
            .entries = std.StringHashMap(ModelPricing).init(allocator),
        };

        try table.addDefaults();
        return table;
    }

    /// Get pricing for a specific provider+model combination
    pub fn getPrice(self: *PricingTable, provider: []const u8, model: []const u8) ?ModelPricing {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ provider, model }) catch return null;
        defer self.allocator.free(key);
        return self.entries.get(key);
    }

    /// Estimate cost for a given token usage
    pub fn estimateCost(self: *PricingTable, provider: []const u8, model: []const u8, input_tokens: u32, output_tokens: u32, cache_read: u32, cache_write: u32) f64 {
        const pricing = self.getPrice(provider, model) orelse return 0.0;

        const input_cost = @as(f64, @floatFromInt(input_tokens)) / 1_000_000.0 * pricing.input_price_per_1m;
        const output_cost = @as(f64, @floatFromInt(output_tokens)) / 1_000_000.0 * pricing.output_price_per_1m;
        const cache_read_cost = if (pricing.cache_read_price_per_1m > 0)
            @as(f64, @floatFromInt(cache_read)) / 1_000_000.0 * pricing.cache_read_price_per_1m
        else
            0.0;
        const cache_write_cost = if (pricing.cache_write_price_per_1m > 0)
            @as(f64, @floatFromInt(cache_write)) / 1_000_000.0 * pricing.cache_write_price_per_1m
        else
            0.0;

        return input_cost + output_cost + cache_read_cost + cache_write_cost;
    }

    /// Quick cost estimate with just input/output tokens
    pub fn estimateCostSimple(self: *PricingTable, provider: []const u8, model: []const u8, input_tokens: u32, output_tokens: u32) f64 {
        return self.estimateCost(provider, model, input_tokens, output_tokens, 0, 0);
    }

    /// Add default pricing data for all known providers
    fn addDefaults(self: *PricingTable) !void {
        // OpenAI
        try self.addPricing("openai", "gpt-4o", 2.50, 10.00, 1.25, 0);
        try self.addPricing("openai", "gpt-4o-mini", 0.15, 0.60, 0.075, 0);
        try self.addPricing("openai", "o1", 15.00, 60.00, 7.50, 0);
        try self.addPricing("openai", "o3-mini", 1.10, 4.40, 0.55, 0);
        try self.addPricing("openai", "gpt-4-turbo", 10.00, 30.00, 5.00, 0);

        // Anthropic
        try self.addPricing("anthropic", "claude-3.5-sonnet", 3.00, 15.00, 0.30, 3.75);
        try self.addPricing("anthropic", "claude-3.5-haiku", 0.80, 4.00, 0.08, 1.00);
        try self.addPricing("anthropic", "claude-3-opus", 15.00, 75.00, 1.50, 18.75);

        // Google
        try self.addPricing("gemini", "gemini-2.0-flash", 0.10, 0.40, 0.025, 0);
        try self.addPricing("gemini", "gemini-2.0-pro", 1.25, 10.00, 0.3125, 0);

        // xAI
        try self.addPricing("xai", "grok-3", 3.00, 15.00, 0, 0);
        try self.addPricing("xai", "grok-3-mini", 0.30, 1.50, 0, 0);

        // Mistral
        try self.addPricing("mistral", "mistral-large", 2.00, 6.00, 0, 0);
        try self.addPricing("mistral", "mistral-small", 0.20, 0.60, 0, 0);

        // Groq
        try self.addPricing("groq", "llama-3.3-70b", 0.59, 0.79, 0, 0);
        try self.addPricing("groq", "mixtral-8x7b", 0.27, 0.27, 0, 0);

        // DeepSeek
        try self.addPricing("deepseek", "deepseek-chat", 0.27, 1.10, 0.07, 0);
        try self.addPricing("deepseek", "deepseek-reasoner", 0.55, 2.19, 0.14, 0);

        // Together AI
        try self.addPricing("together", "meta-llama-3.3-70b", 0.88, 0.88, 0, 0);

        // OpenRouter (passthrough — average pricing)
        try self.addPricing("openrouter", "default", 3.00, 15.00, 0, 0);

        // Zhipu AI
        try self.addPricing("zai", "glm-4", 1.00, 1.00, 0, 0);

        // Local providers (free)
        try self.addPricing("ollama", "default", 0, 0, 0, 0);
        try self.addPricing("lm_studio", "default", 0, 0, 0, 0);
        try self.addPricing("llama_cpp", "default", 0, 0, 0, 0);
    }

    fn addPricing(self: *PricingTable, provider: []const u8, model: []const u8, input_per_1m: f64, output_per_1m: f64, cache_read_per_1m: f64, cache_write_per_1m: f64) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ provider, model });
        const provider_copy = try self.allocator.dupe(u8, provider);
        const model_copy = try self.allocator.dupe(u8, model);

        try self.entries.put(key, ModelPricing{
            .provider = provider_copy,
            .model = model_copy,
            .input_price_per_1m = input_per_1m,
            .output_price_per_1m = output_per_1m,
            .cache_read_price_per_1m = cache_read_per_1m,
            .cache_write_price_per_1m = cache_write_per_1m,
        });
    }

    pub fn deinit(self: *PricingTable) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.provider);
            self.allocator.free(entry.value_ptr.model);
        }
        self.entries.deinit();
    }
};
