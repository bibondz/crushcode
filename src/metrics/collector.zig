const std = @import("std");

/// Type of metric being tracked
pub const MetricType = enum { counter, gauge, histogram };

/// Key-value label pair for metric dimensions
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// A single recorded metric with metadata
pub const Metric = struct {
    name: []const u8,
    metric_type: MetricType,
    value: f64,
    labels: []const Label,
    timestamp_ns: i64,
};

/// Default histogram bucket boundaries
pub const default_buckets = [_]f64{ 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };

/// Histogram tracks distribution of values across predefined buckets.
/// Buckets are owned by the histogram; counts has len = buckets.len + 1 (overflow).
pub const Histogram = struct {
    name: []const u8,
    buckets: []const f64,
    counts: []u32,
    sum: f64,
    count: u32,
    labels: []const Label,
    allocator: std.mem.Allocator,

    /// Initialize a histogram with the given bucket boundaries.
    /// Allocates counts array with buckets.len + 1 slots (last is overflow).
    pub fn init(allocator: std.mem.Allocator, name: []const u8, buckets: []const f64) !Histogram {
        const counts = try allocator.alloc(u32, buckets.len + 1);
        @memset(counts, 0);
        return .{
            .name = name,
            .buckets = buckets,
            .counts = counts,
            .sum = 0.0,
            .count = 0,
            .labels = &.{},
            .allocator = allocator,
        };
    }

    /// Record an observed value into the appropriate bucket.
    pub fn observe(self: *Histogram, value: f64) void {
        self.sum += value;
        self.count += 1;
        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                self.counts[i] += 1;
                return;
            }
        }
        // Value exceeds all buckets — increment overflow slot
        self.counts[self.buckets.len] += 1;
    }

    /// Release allocated counts array.
    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
    }
};

/// Central collector for counters, gauges, and histograms.
/// All metric names and label strings stored in internal maps are owned by the collector.
pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(f64),
    gauges: std.StringHashMap(f64),
    histograms: std.StringHashMap(Histogram),
    metric_log: std.ArrayList(Metric),
    /// Backing storage for owned label key/value pairs in metric_log entries
    label_store: std.ArrayList(Label),

    /// Create a new empty collector.
    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(f64).init(allocator),
            .gauges = std.StringHashMap(f64).init(allocator),
            .histograms = std.StringHashMap(Histogram).init(allocator),
            .metric_log = .{},
            .label_store = .{},
        };
    }

    /// Increment a counter by value. Creates if not exists.
    pub fn increment(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) void {
        const owned_name = self.ownedName(name) catch return;
        const current = self.counters.get(owned_name) orelse 0;
        self.counters.put(owned_name, current + value) catch {};
        self.appendLog(owned_name, .counter, value, labels) catch {};
    }

    /// Set a gauge to value. Creates if not exists.
    pub fn gauge(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) void {
        const owned_name = self.ownedName(name) catch return;
        self.gauges.put(owned_name, value) catch {};
        self.appendLog(owned_name, .gauge, value, labels) catch {};
    }

    /// Observe a value in a histogram. Creates histogram with default buckets if not exists.
    pub fn observe(self: *MetricsCollector, name: []const u8, value: f64, labels: []const Label) !void {
        const owned_name = try self.ownedName(name);
        if (!self.histograms.contains(owned_name)) {
            const h = try Histogram.init(self.allocator, owned_name, &default_buckets);
            try self.histograms.put(owned_name, h);
        }
        var h = self.histograms.getPtr(owned_name).?;
        h.observe(value);
        try self.appendLog(owned_name, .histogram, value, labels);
    }

    /// Export all metrics in Prometheus exposition format.
    /// Counters and gauges: `name{key1="val1"} value`
    /// Histograms: `_bucket{le="X"} count`, `_bucket{le="+Inf"} total`, `_sum`, `_count`
    pub fn exportPrometheus(self: *MetricsCollector, writer: anytype) !void {
        var iter = self.counters.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        iter = self.gauges.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        var h_iter = self.histograms.iterator();
        while (h_iter.next()) |entry| {
            const h = entry.value_ptr.*;
            const name = entry.key_ptr.*;
            for (h.buckets, 0..) |bucket, i| {
                try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ name, bucket, h.counts[i] });
            }
            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, h.count });
            try writer.print("{s}_sum {d}\n", .{ name, h.sum });
            try writer.print("{s}_count {d}\n", .{ name, h.count });
        }
    }

    /// Export all metrics as JSONL (one JSON object per line).
    pub fn exportJsonl(self: *MetricsCollector, writer: anytype) !void {
        for (self.metric_log.items) |m| {
            const type_str = switch (m.metric_type) {
                .counter => "counter",
                .gauge => "gauge",
                .histogram => "histogram",
            };
            try writer.print("{{\"ts\":{d},\"name\":\"{s}\",\"type\":\"{s}\",\"value\":{d},\"labels\":{{", .{
                m.timestamp_ns,
                m.name,
                type_str,
                m.value,
            });
            for (m.labels, 0..) |label, i| {
                if (i > 0) {
                    try writer.writeAll(",");
                }
                try writer.print("\"{s}\":\"{s}\"", .{ label.key, label.value });
            }
            try writer.writeAll("}}\n");
        }
    }

    /// Write JSONL metrics to a file (append mode). Creates parent directories if needed.
    pub fn writeToFile(self: *MetricsCollector, path: []const u8) !void {
        // Create parent directories
        if (std.fs.path.dirname(path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        // Use createFile with truncate=false for append, then seek to end
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);

        // Buffer output into an ArrayList, then write once
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        try self.exportJsonl(buf.writer(self.allocator));
        try file.writeAll(buf.items);
    }

    /// Get current counter value (0 if not exists).
    pub fn getCounter(self: *MetricsCollector, name: []const u8) f64 {
        return self.counters.get(name) orelse 0;
    }

    /// Get current gauge value (0 if not exists).
    pub fn getGauge(self: *MetricsCollector, name: []const u8) f64 {
        return self.gauges.get(name) orelse 0;
    }

    /// Release all allocated resources.
    pub fn deinit(self: *MetricsCollector) void {
        // Free histogram internals
        var h_iter = self.histograms.iterator();
        while (h_iter.next()) |entry| {
            var h = entry.value_ptr.*;
            h.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.histograms.deinit();

        // Free counter keys
        {
            var iter = self.counters.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.counters.deinit();
        }

        // Free gauge keys
        {
            var iter = self.gauges.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.gauges.deinit();
        }

        // Free metric_log name strings
        for (self.metric_log.items) |m| {
            self.allocator.free(m.name);
        }
        self.metric_log.deinit(self.allocator);

        // Free owned label strings
        for (self.label_store.items) |label| {
            self.allocator.free(label.key);
            self.allocator.free(label.value);
        }
        self.label_store.deinit(self.allocator);
    }

    // --- Internal helpers ---

    /// Return an owned copy of name, or the existing key if already stored.
    fn ownedName(self: *MetricsCollector, name: []const u8) ![]const u8 {
        // Check if already owned in any map
        if (self.counters.getPtr(name) != null) {
            var iter = self.counters.keyIterator();
            while (iter.next()) |key| {
                if (std.mem.eql(u8, key.*, name)) return key.*;
            }
        }
        if (self.gauges.getPtr(name) != null) {
            var iter = self.gauges.keyIterator();
            while (iter.next()) |key| {
                if (std.mem.eql(u8, key.*, name)) return key.*;
            }
        }
        if (self.histograms.getPtr(name) != null) {
            var iter = self.histograms.keyIterator();
            while (iter.next()) |key| {
                if (std.mem.eql(u8, key.*, name)) return key.*;
            }
        }
        return try self.allocator.dupe(u8, name);
    }

    /// Append a metric to the chronological log. Labels are deep-copied.
    fn appendLog(self: *MetricsCollector, name: []const u8, metric_type: MetricType, value: f64, labels: []const Label) !void {
        // Deep copy labels into label_store
        const owned_labels_start = self.label_store.items.len;
        for (labels) |label| {
            try self.label_store.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, label.key),
                .value = try self.allocator.dupe(u8, label.value),
            });
        }
        const owned_labels: []const Label = self.label_store.items[owned_labels_start..];

        const ts: i64 = @intCast(std.time.nanoTimestamp());
        // Dupe name so metric_log owns its own copy (independent of hashmap keys)
        const owned_log_name = try self.allocator.dupe(u8, name);
        try self.metric_log.append(self.allocator, .{
            .name = owned_log_name,
            .metric_type = metric_type,
            .value = value,
            .labels = owned_labels,
            .timestamp_ns = ts,
        });
    }
};

// --- Tests ---

test "counter increment and accumulation" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{};
    c.increment("test_counter", 1.0, labels);
    c.increment("test_counter", 2.5, labels);
    c.increment("test_counter", 0.5, labels);

    try std.testing.expectEqual(@as(f64, 4.0), c.getCounter("test_counter"));
    try std.testing.expectEqual(@as(f64, 4.0), c.counters.get("test_counter").?);
}

test "gauge set and overwrite" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{};
    c.gauge("temperature", 72.5, labels);
    try std.testing.expectEqual(@as(f64, 72.5), c.getGauge("temperature"));

    c.gauge("temperature", 68.0, labels);
    try std.testing.expectEqual(@as(f64, 68.0), c.getGauge("temperature"));
}

test "histogram bucket assignment" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{};
    try c.observe("latency", 3.0, labels); // bucket[0]=5
    try c.observe("latency", 7.0, labels); // bucket[1]=10
    try c.observe("latency", 15.0, labels); // bucket[2]=25
    try c.observe("latency", 50.0, labels); // bucket[3]=50
    try c.observe("latency", 6000.0, labels); // overflow

    const h = c.histograms.get("latency").?;
    try std.testing.expectEqual(@as(u32, 1), h.counts[0]); // <=5
    try std.testing.expectEqual(@as(u32, 1), h.counts[1]); // <=10
    try std.testing.expectEqual(@as(u32, 1), h.counts[2]); // <=25
    try std.testing.expectEqual(@as(u32, 1), h.counts[3]); // <=50
    try std.testing.expectEqual(@as(u32, 1), h.counts[10]); // overflow (>5000)
}

test "histogram sum and count" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{};
    try c.observe("duration", 10.0, labels);
    try c.observe("duration", 20.0, labels);
    try c.observe("duration", 30.0, labels);

    const h = c.histograms.get("duration").?;
    try std.testing.expectEqual(@as(f64, 60.0), h.sum);
    try std.testing.expectEqual(@as(u32, 3), h.count);
}

test "Prometheus format output" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    c.increment("http_requests", 5.0, &.{});
    c.gauge("cpu_usage", 42.5, &.{});
    c.observe("latency", 100.0, &.{}) catch unreachable;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    c.exportPrometheus(buf.writer(allocator)) catch unreachable;
    const output = buf.items;

    // Counter
    try std.testing.expect(std.mem.indexOf(u8, output, "http_requests 5") != null);
    // Gauge
    try std.testing.expect(std.mem.indexOf(u8, output, "cpu_usage 42.5") != null);
    // Histogram buckets
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_sum 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "latency_count 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "le=\"+Inf\"") != null);
}

test "JSONL format output" {
    const allocator = std.testing.allocator;
    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{
        .{ .key = "provider", .value = "ollama" },
    };
    c.increment("requests", 1.0, labels);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    c.exportJsonl(buf.writer(allocator)) catch unreachable;
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\":\"requests\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"provider\":\"ollama\"") != null);
}

test "file write and read back" {
    const allocator = std.testing.allocator;
    const path = "/tmp/test-metrics-collector.jsonl";

    // Clean up from previous runs
    std.fs.cwd().deleteFile(path) catch {};

    var c = MetricsCollector.init(allocator);
    defer c.deinit();

    const labels = &[_]Label{
        .{ .key = "env", .value = "test" },
    };
    c.increment("file_test_counter", 7.0, labels);
    c.gauge("file_test_gauge", 99.9, &.{});

    c.writeToFile(path) catch |err| {
        std.debug.print("writeToFile failed: {}\n", .{err});
        return err;
    };

    // Read back and verify
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"name\":\"file_test_counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"value\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"env\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"name\":\"file_test_gauge\"") != null);

    // Cleanup
    std.fs.cwd().deleteFile(path) catch {};
}
