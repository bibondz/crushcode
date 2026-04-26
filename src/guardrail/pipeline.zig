const std = @import("std");

pub const GuardrailAction = enum { allow, deny, redact, ask };

pub const Detection = struct {
    entity_type: []const u8,
    value: []const u8,
    start_pos: usize,
    end_pos: usize,
};

pub const GuardrailResult = struct {
    action: GuardrailAction,
    scanner_name: []const u8,
    reason: ?[]const u8,
    redacted_content: ?[]const u8,
    confidence: f64,
    detections: []const Detection,
    allocator: std.mem.Allocator,

    /// Create an "allow" result with no detections.
    pub fn ok(allocator: std.mem.Allocator) GuardrailResult {
        return GuardrailResult{
            .action = .allow,
            .scanner_name = "",
            .reason = null,
            .redacted_content = null,
            .confidence = 1.0,
            .detections = &.{},
            .allocator = allocator,
        };
    }

    /// Create a "deny" result with a scanner name and reason.
    pub fn deny_(allocator: std.mem.Allocator, scanner_name: []const u8, reason: []const u8) GuardrailResult {
        return GuardrailResult{
            .action = .deny,
            .scanner_name = scanner_name,
            .reason = reason,
            .redacted_content = null,
            .confidence = 1.0,
            .detections = &.{},
            .allocator = allocator,
        };
    }

    /// Free owned memory. Only frees slices that were allocated by this result's allocator.
    pub fn deinit(self: *GuardrailResult) void {
        // detections items are owned individually; free each then the slice
        for (self.detections) |det| {
            self.allocator.free(det.entity_type);
            self.allocator.free(det.value);
        }
        if (self.detections.len > 0) {
            self.allocator.free(self.detections);
        }
        if (self.reason) |r| {
            self.allocator.free(r);
        }
        if (self.redacted_content) |rc| {
            self.allocator.free(rc);
        }
    }
};

pub const GuardrailConfig = struct {
    mode: enum { enforce, monitor },
    max_input_bytes: usize = 1_000_000,
};

pub const GuardrailFn = *const fn (std.mem.Allocator, []const u8, *const GuardrailConfig) anyerror!GuardrailResult;

pub const Guardrail = struct {
    name: []const u8,
    check: GuardrailFn,
    priority: u32,
};

pub const GuardrailPipeline = struct {
    allocator: std.mem.Allocator,
    guardrails: std.ArrayList(Guardrail),
    config: GuardrailConfig,

    /// Initialize a new guardrail pipeline with the given allocator and config.
    pub fn init(allocator: std.mem.Allocator, config: GuardrailConfig) GuardrailPipeline {
        return GuardrailPipeline{
            .allocator = allocator,
            .guardrails = std.ArrayList(Guardrail).init(allocator),
            .config = config,
        };
    }

    /// Register a guardrail scanner. Scanners are sorted by priority before execution.
    pub fn addGuardrail(self: *GuardrailPipeline, guardrail: Guardrail) !void {
        try self.guardrails.append(guardrail);
        // Insertion sort to keep the list sorted by priority (ascending)
        const items = self.guardrails.items;
        var i: usize = items.len - 1;
        while (i > 0) : (i -= 1) {
            if (items[i].priority < items[i - 1].priority) {
                const tmp = items[i];
                items[i] = items[i - 1];
                items[i - 1] = tmp;
            } else {
                break;
            }
        }
    }

    /// Run all registered guardrails against the input.
    /// In enforce mode, deny short-circuits. In monitor mode, all scanners run.
    /// If any scanner redacts, subsequent scanners operate on the redacted text.
    pub fn check(self: *GuardrailPipeline, input: []const u8) anyerror!GuardrailResult {
        // Step 1: Size limit check
        if (input.len > self.config.max_input_bytes) {
            return GuardrailResult.deny_(
                self.allocator,
                "pipeline",
                try self.allocator.dupe(u8, "Input exceeds size limit"),
            );
        }

        var current_input = input;
        var had_deny = false;
        var deny_result: ?GuardrailResult = null;
        var max_confidence: f64 = 0.0;
        var all_detections = std.ArrayList(Detection).init(self.allocator);
        errdefer {
            for (all_detections.items) |det| {
                self.allocator.free(det.entity_type);
                self.allocator.free(det.value);
            }
            all_detections.deinit();
        }

        // Step 2: Run each guardrail sorted by priority
        for (self.guardrails.items) |guardrail| {
            const result = guardrail.check(self.allocator, current_input, &self.config) catch |err| {
                // On scanner error, skip this scanner and continue
                _ = err;
                continue;
            };

            // Collect detections
            for (result.detections) |det| {
                try all_detections.append(det);
            }

            // Track highest confidence
            if (result.confidence > max_confidence) {
                max_confidence = result.confidence;
            }

            // Handle actions
            switch (result.action) {
                .deny => {
                    had_deny = true;
                    if (deny_result == null) {
                        deny_result = result;
                    } else {
                        // Free this result since we only keep the first deny
                        var r = result;
                        r.deinit();
                    }
                    if (self.config.mode == .enforce) {
                        // Short-circuit: build final result from first deny
                        const detections = try all_detections.toOwnedSlice();
                        const reason_owned = if (deny_result.?.reason) |r|
                            try self.allocator.dupe(u8, r)
                        else
                            null;
                        return GuardrailResult{
                            .action = .deny,
                            .scanner_name = try self.allocator.dupe(u8, deny_result.?.scanner_name),
                            .reason = reason_owned,
                            .redacted_content = null,
                            .confidence = max_confidence,
                            .detections = detections,
                            .allocator = self.allocator,
                        };
                    }
                    // In monitor mode: log concept (just continue)
                },
                .redact => {
                    if (result.redacted_content) |rc| {
                        current_input = rc;
                    }
                    // Free the result struct but keep detections (already copied)
                    var r = result;
                    if (r.redacted_content) |_| {
                        // redacted_content is owned by the scanner result
                        // We need to keep current_input pointing to it
                        // but the result owns it. So we'll dup it for safety.
                        const duped = try self.allocator.dupe(u8, current_input);
                        current_input = duped;
                    }
                    r.deinit();
                },
                else => {
                    // allow or ask — free result
                    var r = result;
                    r.deinit();
                },
            }
        }

        // Step 3: Aggregate
        const detections = try all_detections.toOwnedSlice();

        if (had_deny) {
            const reason_owned = if (deny_result.?.reason) |r|
                try self.allocator.dupe(u8, r)
            else
                null;
            return GuardrailResult{
                .action = .deny,
                .scanner_name = try self.allocator.dupe(u8, deny_result.?.scanner_name),
                .reason = reason_owned,
                .redacted_content = null,
                .confidence = max_confidence,
                .detections = detections,
                .allocator = self.allocator,
            };
        }

        // If we redacted, return the redacted content
        if (!std.mem.eql(u8, current_input, input)) {
            return GuardrailResult{
                .action = .redact,
                .scanner_name = "pipeline",
                .reason = null,
                .redacted_content = try self.allocator.dupe(u8, current_input),
                .confidence = max_confidence,
                .detections = detections,
                .allocator = self.allocator,
            };
        }

        // All clear
        return GuardrailResult{
            .action = .allow,
            .scanner_name = "pipeline",
            .reason = null,
            .redacted_content = null,
            .confidence = max_confidence,
            .detections = detections,
            .allocator = self.allocator,
        };
    }

    /// Free pipeline resources.
    pub fn deinit(self: *GuardrailPipeline) void {
        self.guardrails.deinit();
    }
};
