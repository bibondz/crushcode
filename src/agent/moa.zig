const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// A simple chat message with role and content.
pub const SimpleMessage = struct {
    role: []const u8,
    content: []const u8,
};

/// Response from a model call via SendFn.
pub const ModelResponse = struct {
    content: []const u8,
    tokens_used: u32 = 0,
};

/// Function pointer type for sending messages to a model.
/// The caller provides this function to handle provider lookup and HTTP communication.
/// Parameters: context pointer, model name, messages, temperature.
pub const SendFn = *const fn (*anyopaque, []const u8, []const SimpleMessage, f64) anyerror!ModelResponse;

/// Configuration for a reference model in the MoA pipeline.
pub const ReferenceModel = struct {
    name: []const u8,
    model: []const u8,
    temperature: f64 = 0.6,
    max_tokens: u32 = 4096,
};

/// Result from a single reference model call within the MoA pipeline.
pub const ReferenceResult = struct {
    /// Name identifier for this reference. Borrowed from config.
    model_name: []const u8,
    /// Response content. Allocator-owned on success; literal "" on failure.
    content: []const u8,
    /// Whether the model call succeeded.
    success: bool,
    /// Error message if the call failed. Allocator-owned.
    error_message: ?[]const u8 = null,
    /// Tokens reported by the model (0 on failure).
    tokens_used: u32 = 0,
    /// Wall-clock time for this reference call in milliseconds.
    duration_ms: u64 = 0,
};

/// Complete result from a MoA query, including all reference responses and synthesis.
pub const MoAResult = struct {
    /// The original query text. Allocator-owned.
    query: []const u8,
    /// Results from each reference model. Allocator-owned slice.
    reference_results: []ReferenceResult,
    /// The synthesized response from the aggregator model. Allocator-owned.
    synthesized_response: []const u8,
    /// Aggregator model name. Borrowed from config.
    aggregator_model: []const u8,
    /// Total wall-clock time for the entire MoA pipeline in milliseconds.
    total_duration_ms: u64,
    /// Number of reference models that returned successfully.
    successful_references: u32,
    /// Total number of reference models that were queried.
    total_references: u32,

    /// Free all owned memory.
    /// Does not free borrowed fields (aggregator_model, model_name in results).
    pub fn deinit(self: *MoAResult, allocator: Allocator) void {
        for (self.reference_results) |*result| {
            if (result.content.len > 0) allocator.free(result.content);
            if (result.error_message) |msg| allocator.free(msg);
        }
        allocator.free(self.reference_results);
        if (self.synthesized_response.len > 0) allocator.free(self.synthesized_response);
        if (self.query.len > 0) allocator.free(self.query);
    }
};

/// Configuration for the MoA engine.
pub const MoAConfig = struct {
    /// Slice of reference models to query in parallel-ish sequence.
    reference_models: []const ReferenceModel,
    /// Model identifier for the aggregator call.
    aggregator_model: []const u8,
    /// Temperature for the aggregator call (lower = more focused).
    aggregator_temperature: f64 = 0.4,
    /// Minimum successful references required before synthesizing.
    min_successful_references: u32 = 1,
    /// System prompt for the aggregator model.
    aggregator_system_prompt: []const u8,
};

/// Default aggregator system prompt for synthesizing reference responses.
pub const default_aggregator_prompt = "You have been provided with a set of responses from various AI models to the latest user query. Your task is to synthesize these responses into a single, high-quality response. It is crucial to critically evaluate the information provided in these responses, recognizing that some of it may be biased or incorrect. Your response should not simply replicate the given answers but should offer a refined, accurate, and comprehensive reply to the instruction.";

/// Default set of reference models (single primary model).
pub const DEFAULT_REFERENCE_MODELS = [_]ReferenceModel{
    .{ .name = "primary", .model = "default", .temperature = 0.6 },
};

/// Create a default MoA configuration with sensible values.
pub fn defaultConfig() MoAConfig {
    return .{
        .reference_models = &DEFAULT_REFERENCE_MODELS,
        .aggregator_model = "default",
        .aggregator_temperature = 0.4,
        .min_successful_references = 1,
        .aggregator_system_prompt = default_aggregator_prompt,
    };
}

/// Mixture-of-Agents engine that dispatches queries to multiple models
/// and synthesizes their responses into a single high-quality answer.
///
/// Usage:
///   1. Create with `init(allocator, config)`
///   2. Enable with `setEnabled(true)`
///   3. Call `query()` or `querySimple()` with a SendFn callback
///   4. Free results with `MoAResult.deinit()`
///   5. Clean up with `deinit()`
pub const MoAEngine = struct {
    allocator: Allocator,
    config: MoAConfig,
    enabled: bool = false,
    total_queries: u32 = 0,
    total_syntheses: u32 = 0,

    /// Initialize a new MoA engine with the given allocator and configuration.
    pub fn init(allocator: Allocator, config: MoAConfig) MoAEngine {
        return .{
            .allocator = allocator,
            .config = config,
            .enabled = false,
            .total_queries = 0,
            .total_syntheses = 0,
        };
    }

    /// Clean up engine resources. Currently a no-op as config is borrowed.
    pub fn deinit(self: *MoAEngine) void {
        _ = self;
    }

    /// Check if the engine is enabled.
    pub fn isEnabled(self: *const MoAEngine) bool {
        return self.enabled;
    }

    /// Enable or disable the engine. Queries fail with error.MoADisabled when disabled.
    pub fn setEnabled(self: *MoAEngine, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Execute a MoA query: dispatch to reference models, collect responses,
    /// and synthesize via the aggregator model.
    ///
    /// Flow:
    ///   1. Record start time
    ///   2. For each reference model, call send_fn and collect results
    ///   3. Verify minimum successful references
    ///   4. Build aggregator prompt with all successful responses
    ///   5. Call aggregator model to synthesize final answer
    ///   6. Return MoAResult with all data (caller must call deinit)
    pub fn query(self: *MoAEngine, messages: []const SimpleMessage, send_fn: SendFn, ctx: *anyopaque) !MoAResult {
        if (!self.enabled) return error.MoADisabled;
        if (messages.len == 0) return error.EmptyMessages;

        const start = std.time.milliTimestamp();

        // Collect reference results
        var results = array_list_compat.ArrayList(ReferenceResult).init(self.allocator);
        defer {
            // Cleanup only runs if toOwnedSlice was NOT called (error path)
            for (results.items) |*r| {
                if (r.content.len > 0) self.allocator.free(r.content);
                if (r.error_message) |msg| self.allocator.free(msg);
            }
            results.deinit();
        }

        var successful: u32 = 0;

        for (self.config.reference_models) |ref_model| {
            const ref_start = std.time.milliTimestamp();
            const response = send_fn(ctx, ref_model.model, messages, ref_model.temperature) catch |err| {
                const err_msg = try self.allocator.dupe(u8, @errorName(err));
                try results.append(.{
                    .model_name = ref_model.name,
                    .content = "",
                    .success = false,
                    .error_message = err_msg,
                    .tokens_used = 0,
                    .duration_ms = @intCast(std.time.milliTimestamp() - ref_start),
                });
                continue;
            };
            const owned_content = if (response.content.len > 0)
                try self.allocator.dupe(u8, response.content)
            else
                "";
            try results.append(.{
                .model_name = ref_model.name,
                .content = owned_content,
                .success = true,
                .tokens_used = response.tokens_used,
                .duration_ms = @intCast(std.time.milliTimestamp() - ref_start),
            });
            successful += 1;
        }

        if (successful < self.config.min_successful_references) {
            return error.InsufficientReferences;
        }

        // Build aggregator prompt
        var agg_buffer = array_list_compat.ArrayList(u8).init(self.allocator);
        defer agg_buffer.deinit();

        const last_msg = messages[messages.len - 1].content;

        const agg_writer = agg_buffer.writer();
        try agg_writer.print("Original query:\n{s}\n\n", .{last_msg});

        var resp_idx: u32 = 0;
        for (results.items) |result| {
            if (!result.success) continue;
            resp_idx += 1;
            try agg_writer.print("Response {d} (from {s}):\n{s}\n\n", .{
                resp_idx,
                result.model_name,
                result.content,
            });
        }

        // Call aggregator model
        const agg_messages = [_]SimpleMessage{
            .{ .role = "system", .content = self.config.aggregator_system_prompt },
            .{ .role = "user", .content = agg_buffer.items },
        };

        const agg_response = try send_fn(ctx, self.config.aggregator_model, &agg_messages, self.config.aggregator_temperature);

        // Build owned result
        const owned_synthesis = if (agg_response.content.len > 0)
            try self.allocator.dupe(u8, agg_response.content)
        else
            "";
        errdefer if (owned_synthesis.len > 0) self.allocator.free(owned_synthesis);

        const owned_query = if (last_msg.len > 0)
            try self.allocator.dupe(u8, last_msg)
        else
            "";
        errdefer if (owned_query.len > 0) self.allocator.free(owned_query);

        // Extract owned slice — defer cleanup becomes no-op on empty list
        const owned_results = try results.toOwnedSlice();

        self.total_queries += 1;
        self.total_syntheses += 1;

        return MoAResult{
            .query = owned_query,
            .reference_results = owned_results,
            .synthesized_response = owned_synthesis,
            .aggregator_model = self.config.aggregator_model,
            .total_duration_ms = @intCast(std.time.milliTimestamp() - start),
            .successful_references = successful,
            .total_references = @intCast(self.config.reference_models.len),
        };
    }

    /// Execute a simple MoA query with a single user prompt.
    /// Wraps the prompt into a SimpleMessage with role="user" and calls query().
    pub fn querySimple(self: *MoAEngine, prompt: []const u8, send_fn: SendFn, ctx: *anyopaque) !MoAResult {
        const messages = [_]SimpleMessage{
            .{ .role = "user", .content = prompt },
        };
        return self.query(&messages, send_fn, ctx);
    }

    /// Get engine statistics as a formatted string. Caller owns the returned memory.
    pub fn getStats(self: *MoAEngine, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "MoA Engine: enabled={}, queries={d}, syntheses={d}, references_per_query={d}", .{
            self.enabled,
            self.total_queries,
            self.total_syntheses,
            self.config.reference_models.len,
        });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Mock SendFn that returns a canned response for all calls.
fn mockSendFn(ctx: *anyopaque, model: []const u8, messages: []const SimpleMessage, temperature: f64) anyerror!ModelResponse {
    _ = ctx;
    _ = model;
    _ = messages;
    _ = temperature;
    return ModelResponse{ .content = "Mock response", .tokens_used = 100 };
}

/// Mock SendFn that fails for model name "fail-model" and succeeds otherwise.
fn failingMockSendFn(ctx: *anyopaque, model: []const u8, messages: []const SimpleMessage, temperature: f64) anyerror!ModelResponse {
    _ = ctx;
    _ = messages;
    _ = temperature;
    if (std.mem.eql(u8, model, "fail-model")) {
        return error.NetworkError;
    }
    return ModelResponse{ .content = "Mock response", .tokens_used = 100 };
}

test "MoAConfig defaults" {
    const config = defaultConfig();
    try std.testing.expectEqual(@as(usize, 1), config.reference_models.len);
    try std.testing.expectEqualStrings("default", config.aggregator_model);
    try std.testing.expectEqual(@as(f64, 0.4), config.aggregator_temperature);
    try std.testing.expectEqual(@as(u32, 1), config.min_successful_references);
    try std.testing.expectEqualStrings("primary", config.reference_models[0].name);
    try std.testing.expectEqualStrings("default", config.reference_models[0].model);
    try std.testing.expectEqual(@as(f64, 0.6), config.reference_models[0].temperature);
    try std.testing.expect(config.aggregator_system_prompt.len > 0);
}

test "MoAEngine init/deinit" {
    const config = defaultConfig();
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    try std.testing.expect(!engine.isEnabled());
    try std.testing.expectEqual(@as(u32, 0), engine.total_queries);
    try std.testing.expectEqual(@as(u32, 0), engine.total_syntheses);
}

test "MoAEngine enable/disable" {
    const config = defaultConfig();
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    try std.testing.expect(!engine.isEnabled());
    engine.setEnabled(true);
    try std.testing.expect(engine.isEnabled());
    engine.setEnabled(false);
    try std.testing.expect(!engine.isEnabled());
}

test "MoAEngine querySimple with mock" {
    const config = defaultConfig();
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    engine.setEnabled(true);

    var ctx_buf: u8 = 0;
    var result = try engine.querySimple("Hello, world", mockSendFn, @ptrCast(&ctx_buf));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello, world", result.query);
    try std.testing.expect(result.synthesized_response.len > 0);
    try std.testing.expectEqualStrings("Mock response", result.synthesized_response);
    try std.testing.expectEqualStrings("default", result.aggregator_model);
    try std.testing.expectEqual(@as(u32, 1), result.successful_references);
    try std.testing.expectEqual(@as(u32, 1), result.total_references);
    try std.testing.expect(result.total_duration_ms >= 0);
    try std.testing.expectEqual(@as(u32, 1), engine.total_queries);
    try std.testing.expectEqual(@as(u32, 1), engine.total_syntheses);

    // Verify reference result
    try std.testing.expectEqual(@as(usize, 1), result.reference_results.len);
    try std.testing.expect(result.reference_results[0].success);
    try std.testing.expectEqualStrings("Mock response", result.reference_results[0].content);
    try std.testing.expectEqualStrings("primary", result.reference_results[0].model_name);
}

test "MoAEngine error resilience" {
    const models = [_]ReferenceModel{
        .{ .name = "good", .model = "good-model", .temperature = 0.6 },
        .{ .name = "bad", .model = "fail-model", .temperature = 0.6 },
    };
    const config = MoAConfig{
        .reference_models = &models,
        .aggregator_model = "default",
        .aggregator_temperature = 0.4,
        .min_successful_references = 1,
        .aggregator_system_prompt = default_aggregator_prompt,
    };
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    engine.setEnabled(true);

    var ctx_buf: u8 = 0;
    var result = try engine.querySimple("Test resilience", failingMockSendFn, @ptrCast(&ctx_buf));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.successful_references);
    try std.testing.expectEqual(@as(usize, 2), result.reference_results.len);

    // First model succeeds
    try std.testing.expect(result.reference_results[0].success);
    try std.testing.expectEqualStrings("Mock response", result.reference_results[0].content);
    try std.testing.expectEqualStrings("good", result.reference_results[0].model_name);

    // Second model fails
    try std.testing.expect(!result.reference_results[1].success);
    try std.testing.expectEqualStrings("", result.reference_results[1].content);
    try std.testing.expect(result.reference_results[1].error_message != null);
    try std.testing.expectEqualStrings("NetworkError", result.reference_results[1].error_message.?);
    try std.testing.expectEqualStrings("bad", result.reference_results[1].model_name);

    // Synthesis should still work with one successful reference
    try std.testing.expect(result.synthesized_response.len > 0);
}

test "MoAEngine getStats" {
    const config = defaultConfig();
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    engine.setEnabled(true);

    const stats = try engine.getStats(std.testing.allocator);
    defer std.testing.allocator.free(stats);

    try std.testing.expect(std.mem.indexOf(u8, stats, "MoA Engine:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "enabled=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "queries=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "syntheses=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "references_per_query=1") != null);
}

test "MoAEngine query fails when disabled" {
    const config = defaultConfig();
    var engine = MoAEngine.init(std.testing.allocator, config);
    defer engine.deinit();
    // Engine is disabled by default

    var ctx_buf: u8 = 0;
    const result = engine.querySimple("Hello", mockSendFn, @ptrCast(&ctx_buf));
    try std.testing.expectError(error.MoADisabled, result);
}
