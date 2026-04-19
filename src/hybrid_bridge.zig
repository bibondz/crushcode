const std = @import("std");
const array_list_compat = @import("array_list_compat");
const core = @import("core_api");
const tool_executors = @import("chat_tool_executors");
const mcp_bridge_mod = @import("mcp_bridge");
const widget_types = @import("widget_types");

const Allocator = std.mem.Allocator;
const builtin_tool_schemas = widget_types.builtin_tool_schemas;

/// Unified tool dispatch that tries builtin tools first, then MCP bridge.
/// Replaces the inline builtin→MCP pattern previously in chat_tui_app.zig.
pub const HybridBridge = struct {
    allocator: Allocator,
    mcp_bridge: ?*mcp_bridge_mod.Bridge,

    pub fn init(allocator: Allocator, mcp: ?*mcp_bridge_mod.Bridge) HybridBridge {
        return .{
            .allocator = allocator,
            .mcp_bridge = mcp,
        };
    }

    pub fn deinit(self: *HybridBridge) void {
        // HybridBridge does not own the MCP bridge; caller manages its lifetime.
        _ = self;
    }

    /// Execute a tool by name. Tries builtin first, then MCP.
    /// Returns allocated result string (caller frees with allocator).
    pub fn executeTool(self: *HybridBridge, tool_call: core.ParsedToolCall) ![]const u8 {
        // Try builtin tools first
        if (tool_executors.executeBuiltinTool(self.allocator, tool_call)) |execution| {
            defer self.allocator.free(execution.display);
            return try self.allocator.dupe(u8, execution.result);
        } else |builtin_err| {
            if (builtin_err != error.UnsupportedTool) return builtin_err;

            // Builtin didn't handle it — try MCP bridge
            if (self.mcp_bridge) |bridge| {
                if (bridge.executeTool(tool_call.name, tool_call.arguments)) |mcp_result| {
                    return try self.allocator.dupe(u8, mcp_result);
                } else |_| {
                    return error.UnsupportedTool;
                }
            }

            return error.UnsupportedTool;
        }
    }

    /// Collect all available tool schemas (builtin + MCP) for system prompt.
    /// Returns allocated slice (caller frees each schema's strings + the slice).
    pub fn getAllToolSchemas(self: *HybridBridge) ![]const core.ToolSchema {
        var schemas = array_list_compat.ArrayList(core.ToolSchema).init(self.allocator);

        // Add builtin tool schemas
        for (&builtin_tool_schemas) |schema| {
            try schemas.append(.{
                .name = try self.allocator.dupe(u8, schema.name),
                .description = try self.allocator.dupe(u8, schema.description),
                .parameters = try self.allocator.dupe(u8, schema.parameters),
            });
        }

        // Add MCP tool schemas if bridge is available
        if (self.mcp_bridge) |bridge| {
            const mcp_schemas = bridge.getToolSchemas(self.allocator) catch &.{};
            for (mcp_schemas) |schema| {
                try schemas.append(schema);
            }
            // getToolSchemas returns owned memory — free the slice container only
            // since we've moved each schema into our list
            if (mcp_schemas.len > 0) self.allocator.free(mcp_schemas);
        }

        return schemas.toOwnedSlice();
    }

    /// Check if a tool name is available (builtin or MCP).
    pub fn hasTool(self: *HybridBridge, name: []const u8) bool {
        // Check builtin tool names
        for (&builtin_tool_schemas) |schema| {
            if (std.mem.eql(u8, schema.name, name)) return true;
        }

        // Check MCP tools
        if (self.mcp_bridge) |bridge| {
            const stats = bridge.getStats();
            if (stats.tools > 0) {
                const schemas = bridge.getToolSchemas(self.allocator) catch return false;
                defer {
                    for (schemas) |s| {
                        self.allocator.free(s.name);
                        self.allocator.free(s.description);
                        self.allocator.free(s.parameters);
                    }
                    self.allocator.free(schemas);
                }
                for (schemas) |schema| {
                    if (std.mem.eql(u8, schema.name, name)) return true;
                }
            }
        }

        return false;
    }

    /// Get stats for display
    pub const Stats = struct {
        builtin_count: u32,
        mcp_count: u32,
    };

    pub fn getStats(self: *HybridBridge) Stats {
        var mcp_count: u32 = 0;
        if (self.mcp_bridge) |bridge| {
            const bridge_stats = bridge.getStats();
            mcp_count = @intCast(bridge_stats.tools);
        }
        return .{
            .builtin_count = builtin_tool_schemas.len,
            .mcp_count = mcp_count,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn freeToolSchemas(allocator: Allocator, schemas: []const core.ToolSchema) void {
    for (schemas) |s| {
        allocator.free(s.name);
        allocator.free(s.description);
        allocator.free(s.parameters);
    }
    allocator.free(schemas);
}

test "HybridBridge.init - no MCP bridge" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    try std.testing.expect(bridge.mcp_bridge == null);
    try std.testing.expectEqual(std.testing.allocator, bridge.allocator);
}

test "HybridBridge.init - with nil MCP bridge" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    try std.testing.expect(bridge.mcp_bridge == null);
}

test "HybridBridge.executeTool - unsupported tool returns error" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const tool_call = core.ParsedToolCall{
        .id = "test-1",
        .name = "nonexistent_tool",
        .arguments = "{}",
    };
    const result = bridge.executeTool(tool_call);
    try std.testing.expectError(error.UnsupportedTool, result);
}

test "HybridBridge.executeTool - empty tool name returns error" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const tool_call = core.ParsedToolCall{
        .id = "test-2",
        .name = "",
        .arguments = "{}",
    };
    const result = bridge.executeTool(tool_call);
    try std.testing.expectError(error.UnsupportedTool, result);
}

test "HybridBridge.getAllToolSchemas - correct count" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const schemas = try bridge.getAllToolSchemas();
    defer freeToolSchemas(std.testing.allocator, schemas);
    try std.testing.expectEqual(@as(usize, 6), schemas.len);
}

test "HybridBridge.getAllToolSchemas - returns builtin schemas" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const schemas = try bridge.getAllToolSchemas();
    defer freeToolSchemas(std.testing.allocator, schemas);

    var found = [_]bool{false} ** 6;
    const expected = [_][]const u8{ "read_file", "shell", "write_file", "glob", "grep", "edit" };
    for (schemas) |s| {
        inline for (0..expected.len) |i| {
            if (std.mem.eql(u8, s.name, expected[i])) found[i] = true;
        }
    }
    inline for (0..found.len) |i| {
        try std.testing.expect(found[i]);
    }
}

test "HybridBridge.hasTool - builtin tools" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    try std.testing.expect(bridge.hasTool("read_file"));
    try std.testing.expect(bridge.hasTool("shell"));
    try std.testing.expect(bridge.hasTool("write_file"));
    try std.testing.expect(bridge.hasTool("glob"));
    try std.testing.expect(bridge.hasTool("grep"));
    try std.testing.expect(bridge.hasTool("edit"));
}

test "HybridBridge.hasTool - unknown tool returns false" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    try std.testing.expect(!bridge.hasTool("nonexistent_tool"));
    try std.testing.expect(!bridge.hasTool(""));
}

test "HybridBridge.getStats - builtin count is 6" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const stats = bridge.getStats();
    try std.testing.expectEqual(@as(u32, 6), stats.builtin_count);
    try std.testing.expectEqual(@as(u32, 0), stats.mcp_count);
}

test "HybridBridge.executeTool - builtin shell with echo" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const tool_call = core.ParsedToolCall{
        .id = "test-shell-1",
        .name = "shell",
        .arguments = "{\"command\": \"echo hello_world_from_test\"}",
    };
    const result = try bridge.executeTool(tool_call);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello_world_from_test") != null);
}

test "HybridBridge.executeTool - builtin read_file" {
    const tmp_path = "/tmp/crushcode_test_hybrid_read.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("test content for hybrid bridge");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "test-read-1",
        .name = "read_file",
        .arguments = args,
    };
    const result = try bridge.executeTool(tool_call);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "test content for hybrid bridge") != null);
}

test "HybridBridge.executeTool - builtin write_file + verify" {
    const tmp_path = "/tmp/crushcode_test_hybrid_write.txt";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\": \"{s}\", \"content\": \"hello from write test\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "test-write-1",
        .name = "write_file",
        .arguments = args,
    };
    const result = try bridge.executeTool(tool_call);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Wrote") != null);

    // Verify the file was actually written
    const verify_file = try std.fs.cwd().openFile(tmp_path, .{});
    defer verify_file.close();
    const content = try verify_file.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.eql(u8, content, "hello from write test"));
}

test "HybridBridge.executeTool - builtin glob" {
    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();
    const tool_call = core.ParsedToolCall{
        .id = "test-glob-1",
        .name = "glob",
        .arguments = "{\"pattern\": \"build.zig\"}",
    };
    const result = try bridge.executeTool(tool_call);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "build.zig") != null);
}

test "HybridBridge.executeTool - builtin edit" {
    const tmp_path = "/tmp/crushcode_test_hybrid_edit.txt";
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    try tmp_file.writeAll("hello world");
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var bridge = HybridBridge.init(std.testing.allocator, null);
    defer bridge.deinit();

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"file_path\": \"{s}\", \"old_string\": \"world\", \"new_string\": \"universe\"}}", .{tmp_path});
    defer std.testing.allocator.free(args);

    const tool_call = core.ParsedToolCall{
        .id = "test-edit-1",
        .name = "edit",
        .arguments = args,
    };
    const result = try bridge.executeTool(tool_call);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Edited") != null);

    // Verify the edit took effect
    const verify_file = try std.fs.cwd().openFile(tmp_path, .{});
    defer verify_file.close();
    const content = try verify_file.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.eql(u8, content, "hello universe"));
}
