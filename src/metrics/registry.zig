const std = @import("std");
const collector = @import("collector.zig");

/// Definition of a built-in metric with metadata
pub const BuiltinMetric = struct {
    name: []const u8,
    metric_type: collector.MetricType,
    description: []const u8,
    default_labels: []const collector.Label,
};

/// Pre-defined built-in metrics for Crushcode
pub const BUILTIN_METRICS = [_]BuiltinMetric{
    .{ .name = "crushcode_requests_total", .metric_type = .counter, .description = "Total LLM requests", .default_labels = &.{} },
    .{ .name = "crushcode_request_duration_ms", .metric_type = .histogram, .description = "Request latency", .default_labels = &.{} },
    .{ .name = "crushcode_tokens_input_total", .metric_type = .counter, .description = "Input tokens consumed", .default_labels = &.{} },
    .{ .name = "crushcode_tokens_output_total", .metric_type = .counter, .description = "Output tokens generated", .default_labels = &.{} },
    .{ .name = "crushcode_cost_microdollars_total", .metric_type = .counter, .description = "Cumulative cost", .default_labels = &.{} },
    .{ .name = "crushcode_tool_calls_total", .metric_type = .counter, .description = "Tool invocations", .default_labels = &.{} },
    .{ .name = "crushcode_tool_duration_ms", .metric_type = .histogram, .description = "Tool execution time", .default_labels = &.{} },
    .{ .name = "crushcode_guardrail_blocks_total", .metric_type = .counter, .description = "Guardrail interventions", .default_labels = &.{} },
    .{ .name = "crushcode_retry_attempts_total", .metric_type = .counter, .description = "Retry attempts", .default_labels = &.{} },
    .{ .name = "crushcode_cache_hits_total", .metric_type = .counter, .description = "Prompt cache hits", .default_labels = &.{} },
};

/// Convenience wrapper around MetricsCollector that provides
/// domain-specific recording methods for Crushcode operations.
pub const MetricsRegistry = struct {
    collector: collector.MetricsCollector,

    /// Create a new registry with an underlying collector.
    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{
            .collector = collector.MetricsCollector.init(allocator),
        };
    }

    /// Record an LLM request: increment request counter, record duration, tokens, cost.
    pub fn recordRequest(self: *MetricsRegistry, provider: []const u8, model: []const u8, duration_ms: f64, input_tokens: u64, output_tokens: u64, cost_microdollars: f64, status: []const u8) !void {
        const full_labels = &[_]collector.Label{
            .{ .key = "provider", .value = provider },
            .{ .key = "model", .value = model },
            .{ .key = "status", .value = status },
        };
        const labels_without_status = &[_]collector.Label{
            .{ .key = "provider", .value = provider },
            .{ .key = "model", .value = model },
        };

        self.collector.increment("crushcode_requests_total", 1.0, full_labels);
        try self.collector.observe("crushcode_request_duration_ms", duration_ms, labels_without_status);
        self.collector.increment("crushcode_tokens_input_total", @floatFromInt(input_tokens), labels_without_status);
        self.collector.increment("crushcode_tokens_output_total", @floatFromInt(output_tokens), labels_without_status);
        self.collector.increment("crushcode_cost_microdollars_total", cost_microdollars, labels_without_status);
    }

    /// Record a tool call: increment tool counter, record duration.
    pub fn recordToolCall(self: *MetricsRegistry, tool: []const u8, duration_ms: f64, status: []const u8) !void {
        const full_labels = &[_]collector.Label{
            .{ .key = "tool", .value = tool },
            .{ .key = "status", .value = status },
        };
        const labels_without_status = &[_]collector.Label{
            .{ .key = "tool", .value = tool },
        };

        self.collector.increment("crushcode_tool_calls_total", 1.0, full_labels);
        try self.collector.observe("crushcode_tool_duration_ms", duration_ms, labels_without_status);
    }

    /// Record a guardrail block.
    pub fn recordGuardrail(self: *MetricsRegistry, guardrail: []const u8, action: []const u8) void {
        const labels = &[_]collector.Label{
            .{ .key = "guardrail", .value = guardrail },
            .{ .key = "action", .value = action },
        };
        self.collector.increment("crushcode_guardrail_blocks_total", 1.0, labels);
    }

    /// Record a retry attempt.
    pub fn recordRetry(self: *MetricsRegistry, provider: []const u8, error_class: []const u8) void {
        const labels = &[_]collector.Label{
            .{ .key = "provider", .value = provider },
            .{ .key = "error_class", .value = error_class },
        };
        self.collector.increment("crushcode_retry_attempts_total", 1.0, labels);
    }

    /// Record a cache hit.
    pub fn recordCacheHit(self: *MetricsRegistry, cache_type: []const u8) void {
        const labels = &[_]collector.Label{
            .{ .key = "type", .value = cache_type },
        };
        self.collector.increment("crushcode_cache_hits_total", 1.0, labels);
    }

    /// Release all resources.
    pub fn deinit(self: *MetricsRegistry) void {
        self.collector.deinit();
    }
};

// --- Tests ---

test "BUILTIN_METRICS has 10 entries" {
    try std.testing.expectEqual(@as(usize, 10), BUILTIN_METRICS.len);
}

test "recordRequest updates all relevant counters and histograms" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    try reg.recordRequest("ollama", "llama3", 250.0, 100, 50, 12.5, "ok");

    try std.testing.expectEqual(@as(f64, 1.0), reg.collector.getCounter("crushcode_requests_total"));
    try std.testing.expectEqual(@as(f64, 100.0), reg.collector.getCounter("crushcode_tokens_input_total"));
    try std.testing.expectEqual(@as(f64, 50.0), reg.collector.getCounter("crushcode_tokens_output_total"));
    try std.testing.expectEqual(@as(f64, 12.5), reg.collector.getCounter("crushcode_cost_microdollars_total"));

    const h = reg.collector.histograms.get("crushcode_request_duration_ms").?;
    try std.testing.expectEqual(@as(f64, 250.0), h.sum);
    try std.testing.expectEqual(@as(u32, 1), h.count);
}

test "recordToolCall updates counter and histogram" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    try reg.recordToolCall("bash", 15.0, "success");

    try std.testing.expectEqual(@as(f64, 1.0), reg.collector.getCounter("crushcode_tool_calls_total"));
    const h = reg.collector.histograms.get("crushcode_tool_duration_ms").?;
    try std.testing.expectEqual(@as(f64, 15.0), h.sum);
    try std.testing.expectEqual(@as(u32, 1), h.count);
}

test "recordGuardrail increments counter" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    reg.recordGuardrail("safety", "block");
    reg.recordGuardrail("safety", "block");

    try std.testing.expectEqual(@as(f64, 2.0), reg.collector.getCounter("crushcode_guardrail_blocks_total"));
}

test "recordRetry and recordCacheHit" {
    const allocator = std.testing.allocator;
    var reg = MetricsRegistry.init(allocator);
    defer reg.deinit();

    reg.recordRetry("openai", "timeout");
    reg.recordRetry("openai", "timeout");
    reg.recordRetry("openai", "rate_limit");

    try std.testing.expectEqual(@as(f64, 3.0), reg.collector.getCounter("crushcode_retry_attempts_total"));

    reg.recordCacheHit("prompt");
    try std.testing.expectEqual(@as(f64, 1.0), reg.collector.getCounter("crushcode_cache_hits_total"));
}
