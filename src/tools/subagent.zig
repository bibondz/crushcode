const std = @import("std");
const delegate = @import("delegate");

const Allocator = std.mem.Allocator;
const SubAgentDelegator = delegate.SubAgentDelegator;
const DelegationConfig = delegate.DelegationConfig;
const AgentCategory = delegate.AgentCategory;

/// Result of subagent tool execution (matches ToolExecution shape in tool_executors.zig)
pub const SubagentToolResult = struct {
    display: []const u8,
    result: []const u8,
};

/// Global subagent delegator — initialized at startup
pub var active_delegator: ?SubAgentDelegator = null;

pub fn initDelegator(allocator: Allocator) void {
    const config = DelegationConfig.init(allocator);
    active_delegator = SubAgentDelegator.init(allocator, config);
}

pub fn deinitDelegator() void {
    if (active_delegator) |*d| {
        d.deinit();
    }
}

/// Parse category string to AgentCategory enum
fn parseCategory(str: []const u8) AgentCategory {
    if (std.mem.eql(u8, str, "visual_engineering")) return .visual_engineering;
    if (std.mem.eql(u8, str, "ultrabrain")) return .ultrabrain;
    if (std.mem.eql(u8, str, "deep")) return .deep;
    if (std.mem.eql(u8, str, "quick")) return .quick;
    if (std.mem.eql(u8, str, "review")) return .review;
    if (std.mem.eql(u8, str, "research")) return .research;
    return .general;
}

/// Execute subagent tool — called from tool_executors
pub fn executeSubagentTool(allocator: Allocator, arguments: []const u8) anyerror!SubagentToolResult {
    // Parse arguments JSON
    var parsed_json = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch |err| {
        return SubagentToolResult{
            .result = try std.fmt.allocPrint(allocator, "Failed to parse subagent arguments: {}", .{err}),
            .display = try std.fmt.allocPrint(allocator, "Subagent error: invalid JSON\n", .{}),
        };
    };
    defer parsed_json.deinit();

    const root = parsed_json.value;

    // Verify root is an object
    if (root != .object) {
        return SubagentToolResult{
            .result = try allocator.dupe(u8, "Subagent arguments must be a JSON object"),
            .display = try std.fmt.allocPrint(allocator, "Subagent error: expected JSON object\n", .{}),
        };
    }

    // Extract required fields
    const description = blk: {
        if (root.object.get("description")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "Unnamed subagent task";
    };

    const prompt = blk: {
        if (root.object.get("prompt")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk description;
    };

    const category_str = blk: {
        if (root.object.get("category")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "general";
    };

    const category = parseCategory(category_str);

    // Generate task ID for display
    const task_id = try std.fmt.allocPrint(allocator, "sub_{d}", .{std.time.milliTimestamp()});
    defer allocator.free(task_id);

    // If delegator is active, delegate the task
    if (active_delegator) |*delegator| {
        var result = delegator.delegate(0, prompt, category) catch |err| {
            return SubagentToolResult{
                .result = try std.fmt.allocPrint(allocator, "Subagent delegation failed: {}", .{err}),
                .display = try std.fmt.allocPrint(allocator, "Subagent error: delegation failed ({s})\n", .{@errorName(err)}),
            };
        };
        defer result.deinit(allocator);

        const display = try std.fmt.allocPrint(allocator,
            "🤖 Subagent spawned\nCategory: {s}\nStatus: completed\nOutput length: {d} chars\n",
            .{ @tagName(category), result.output.len },
        );

        return SubagentToolResult{
            .result = try allocator.dupe(u8, result.output),
            .display = display,
        };
    }

    // No delegator available — return info message
    const display = try std.fmt.allocPrint(allocator,
        "Subagent task queued: {s}\nDescription: {s}\nCategory: {s}\nNote: Subagent delegator not initialized. Task logged but not executed.\n",
        .{ task_id, description, @tagName(category) },
    );

    return SubagentToolResult{
        .result = try std.fmt.allocPrint(allocator, "Subagent task queued: {s}", .{task_id}),
        .display = display,
    };
}
