const std = @import("std");

/// Danger classification for tool operations.
pub const DangerLevel = enum { safe, moderate, dangerous };

/// Phase of inspection — before or after tool execution.
pub const InspectionPhase = enum { pre, post };

/// Action an inspector can return.
pub const InspectionAction = enum { allow, deny, ask, modify };

/// Result returned by an inspector after examining a tool call.
pub const InspectionResult = struct {
    action: InspectionAction,
    inspector_name: []const u8,
    reason: ?[]const u8 = null,
    modified_args: ?[]const u8 = null,
};

/// A single inspector that can examine tool calls and return a verdict.
pub const ToolInspector = struct {
    name: []const u8,
    inspectFn: *const fn (
        allocator: std.mem.Allocator,
        tool_name: []const u8,
        args: []const u8,
        phase: InspectionPhase,
    ) anyerror!?InspectionResult,
};

/// Pipeline that runs multiple inspectors in order, short-circuiting on deny/ask.
pub const ToolInspectionPipeline = struct {
    allocator: std.mem.Allocator,
    inspectors: std.ArrayList(ToolInspector),

    /// Create an empty pipeline.
    pub fn init(allocator: std.mem.Allocator) ToolInspectionPipeline {
        return .{
            .allocator = allocator,
            .inspectors = std.ArrayList(ToolInspector){},
        };
    }

    /// Append an inspector to the pipeline.
    pub fn addInspector(self: *ToolInspectionPipeline, inspector: ToolInspector) !void {
        try self.inspectors.append(self.allocator, inspector);
    }

    /// Run all inspectors with the `.pre` phase.
    ///
    /// If no inspectors are registered, returns allow immediately.
    /// Short-circuits on `.deny` or `.ask`. Passes modified args forward on `.modify`.
    pub fn inspectPre(self: *ToolInspectionPipeline, tool_name: []const u8, args: []const u8) !InspectionResult {
        return runInspectors(self.allocator, &self.inspectors, tool_name, args, .pre);
    }

    /// Run all inspectors with the `.post` phase.
    ///
    /// Same short-circuit logic as `inspectPre` but applied to tool results.
    pub fn inspectPost(self: *ToolInspectionPipeline, tool_name: []const u8, result: []const u8) !InspectionResult {
        return runInspectors(self.allocator, &self.inspectors, tool_name, result, .post);
    }

    /// Classify a tool name into a danger level.
    pub fn classifyDanger(_: *ToolInspectionPipeline, tool_name: []const u8) DangerLevel {
        const safe_tools = [_][]const u8{ "read_file", "read", "glob", "grep", "web_fetch", "search", "list" };
        for (&safe_tools) |safe| {
            if (std.mem.eql(u8, tool_name, safe)) return .safe;
        }
        const dangerous_tools = [_][]const u8{ "shell", "execute", "delete", "remove", "bash", "exec" };
        for (&dangerous_tools) |dangerous| {
            if (std.mem.eql(u8, tool_name, dangerous)) return .dangerous;
        }
        return .moderate;
    }

    /// Release all resources held by the pipeline.
    pub fn deinit(self: *ToolInspectionPipeline) void {
        self.inspectors.deinit(self.allocator);
    }
};

/// Internal: run the inspector loop shared by inspectPre and inspectPost.
fn runInspectors(
    allocator: std.mem.Allocator,
    inspectors: *std.ArrayList(ToolInspector),
    tool_name: []const u8,
    initial_args: []const u8,
    phase: InspectionPhase,
) !InspectionResult {
    if (inspectors.items.len == 0) {
        return .{ .action = .allow, .inspector_name = "default" };
    }

    var current_args: []const u8 = initial_args;
    for (inspectors.items) |inspector| {
        const result = inspector.inspectFn(allocator, tool_name, current_args, phase) catch continue;
        const r = result orelse continue;
        switch (r.action) {
            .deny => return r,
            .ask => return r,
            .modify => {
                if (r.modified_args) |ma| current_args = ma;
                // Continue to next inspector with modified args
            },
            .allow => {},
        }
    }
    return .{ .action = .allow, .inspector_name = "pipeline_complete" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// -- Mock inspectors --------------------------------------------------------

fn denyInspector(_: std.mem.Allocator, _: []const u8, _: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    return InspectionResult{ .action = .deny, .inspector_name = "deny_all", .reason = "blocked for testing" };
}

fn allowInspector(_: std.mem.Allocator, _: []const u8, _: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    return InspectionResult{ .action = .allow, .inspector_name = "allow_all" };
}

fn modifyInspector(allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    const modified = try allocator.dupe(u8, "modified_args");
    return InspectionResult{ .action = .modify, .inspector_name = "modifier", .modified_args = modified };
}

fn nullInspector(_: std.mem.Allocator, _: []const u8, _: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    return null;
}

fn errorInspector(_: std.mem.Allocator, _: []const u8, _: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    return error.InspectorFailed;
}

// Inspector that records what args it received (for testing modify chain)
var last_seen_args: []const u8 = "";
fn argsRecorder(_: std.mem.Allocator, _: []const u8, args: []const u8, _: InspectionPhase) anyerror!?InspectionResult {
    last_seen_args = args;
    return InspectionResult{ .action = .allow, .inspector_name = "recorder" };
}

// -- Tests ------------------------------------------------------------------

test "classifyDanger safe tools" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("read_file"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("read"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("glob"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("grep"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("web_fetch"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("search"));
    try testing.expectEqual(DangerLevel.safe, pipeline.classifyDanger("list"));
}

test "classifyDanger dangerous tools" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("shell"));
    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("execute"));
    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("delete"));
    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("remove"));
    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("bash"));
    try testing.expectEqual(DangerLevel.dangerous, pipeline.classifyDanger("exec"));
}

test "classifyDanger moderate tools" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try testing.expectEqual(DangerLevel.moderate, pipeline.classifyDanger("write_file"));
    try testing.expectEqual(DangerLevel.moderate, pipeline.classifyDanger("write"));
    try testing.expectEqual(DangerLevel.moderate, pipeline.classifyDanger("edit"));
    try testing.expectEqual(DangerLevel.moderate, pipeline.classifyDanger("create"));
    try testing.expectEqual(DangerLevel.moderate, pipeline.classifyDanger("unknown_tool"));
}

test "inspectPre allow with no inspectors" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    const result = try pipeline.inspectPre("read_file", "{}");
    try testing.expectEqual(InspectionAction.allow, result.action);
    try testing.expectEqualStrings("default", result.inspector_name);
}

test "inspectPre deny short-circuits" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try pipeline.addInspector(.{ .name = "deny_all", .inspectFn = denyInspector });
    try pipeline.addInspector(.{ .name = "allow_all", .inspectFn = allowInspector });

    const result = try pipeline.inspectPre("bash", "rm -rf /");
    try testing.expectEqual(InspectionAction.deny, result.action);
    try testing.expectEqualStrings("deny_all", result.inspector_name);
    try testing.expect(result.reason != null);
    try testing.expectEqualStrings("blocked for testing", result.reason.?);
}

test "inspectPre modify passes args forward" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try pipeline.addInspector(.{ .name = "modifier", .inspectFn = modifyInspector });
    try pipeline.addInspector(.{ .name = "recorder", .inspectFn = argsRecorder });

    last_seen_args = "";
    const result = try pipeline.inspectPre("write", "original_args");
    // Pipeline completes with allow after all inspectors
    try testing.expectEqual(InspectionAction.allow, result.action);
    try testing.expectEqualStrings("pipeline_complete", result.inspector_name);
    // Second inspector should have seen the modified args
    try testing.expectEqualStrings("modified_args", last_seen_args);
}

test "inspectPost deny" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try pipeline.addInspector(.{ .name = "deny_all", .inspectFn = denyInspector });

    const result = try pipeline.inspectPost("read_file", "secret content");
    try testing.expectEqual(InspectionAction.deny, result.action);
    try testing.expectEqualStrings("deny_all", result.inspector_name);
}

test "inspectPre skip on error and null" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    // Erroring inspector should be skipped
    try pipeline.addInspector(.{ .name = "error_inspector", .inspectFn = errorInspector });
    // Null-returning inspector should be skipped
    try pipeline.addInspector(.{ .name = "null_inspector", .inspectFn = nullInspector });
    // This one should be reached
    try pipeline.addInspector(.{ .name = "allow_all", .inspectFn = allowInspector });

    const result = try pipeline.inspectPre("some_tool", "args");
    try testing.expectEqual(InspectionAction.allow, result.action);
    try testing.expectEqualStrings("pipeline_complete", result.inspector_name);
}

test "addInspector count" {
    var pipeline = ToolInspectionPipeline.init(testing.allocator);
    defer pipeline.deinit();

    try testing.expectEqual(@as(usize, 0), pipeline.inspectors.items.len);

    try pipeline.addInspector(.{ .name = "first", .inspectFn = allowInspector });
    try testing.expectEqual(@as(usize, 1), pipeline.inspectors.items.len);

    try pipeline.addInspector(.{ .name = "second", .inspectFn = denyInspector });
    try testing.expectEqual(@as(usize, 2), pipeline.inspectors.items.len);

    try testing.expectEqualStrings("first", pipeline.inspectors.items[0].name);
    try testing.expectEqualStrings("second", pipeline.inspectors.items[1].name);
}
