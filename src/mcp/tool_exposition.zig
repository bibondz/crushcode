const std = @import("std");

const json = std.json;
const Allocator = std.mem.Allocator;

/// MCP tool schema as exposed to external clients.
pub const MCPTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.Value,
};

/// Provides hardcoded tool schemas for crushcode's built-in tools.
/// These are exposed via MCP `tools/list` so external clients can call them.
pub const ToolExposition = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ToolExposition {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolExposition) void {
        _ = self;
    }

    /// Return the list of all exposed tools with MCP-compatible schemas.
    /// Caller owns the returned slice and must free it with allocator.free().
    /// Each tool's input_schema is a cloned json.Value tree — caller must
    /// call deinitJsonValue on each when done (or just free the slice if
    /// the values don't need individual cleanup in practice).
    pub fn getToolList(self: *ToolExposition) ![]MCPTool {
        const tools = try self.allocator.alloc(MCPTool, 6);

        tools[0] = MCPTool{
            .name = "bash",
            .description = "Execute a shell command",
            .input_schema = try self.bashSchema(),
        };
        tools[1] = MCPTool{
            .name = "file_read",
            .description = "Read file content",
            .input_schema = try self.fileReadSchema(),
        };
        tools[2] = MCPTool{
            .name = "file_write",
            .description = "Write content to file",
            .input_schema = try self.fileWriteSchema(),
        };
        tools[3] = MCPTool{
            .name = "file_edit",
            .description = "Edit file with old/new string replacement",
            .input_schema = try self.fileEditSchema(),
        };
        tools[4] = MCPTool{
            .name = "glob",
            .description = "Find files by pattern",
            .input_schema = try self.globSchema(),
        };
        tools[5] = MCPTool{
            .name = "grep",
            .description = "Search file contents by pattern",
            .input_schema = try self.grepSchema(),
        };

        return tools;
    }

    // -- Schema builders --

    fn bashSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);
        var cmd_obj = json.ObjectMap.init(self.allocator);
        try cmd_obj.put("type", .{ .string = "string" });
        try cmd_obj.put("description", .{ .string = "The command to execute" });
        try props.put("command", .{ .object = cmd_obj });

        var cwd_obj = json.ObjectMap.init(self.allocator);
        try cwd_obj.put("type", .{ .string = "string" });
        try cwd_obj.put("description", .{ .string = "Working directory for the command" });
        try props.put("cwd", .{ .object = cwd_obj });

        var timeout_obj = json.ObjectMap.init(self.allocator);
        try timeout_obj.put("type", .{ .string = "number" });
        try timeout_obj.put("description", .{ .string = "Timeout in milliseconds" });
        try props.put("timeout", .{ .object = timeout_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "command" });

        return self.buildSchema(props, required);
    }

    fn fileReadSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);
        var path_obj = json.ObjectMap.init(self.allocator);
        try path_obj.put("type", .{ .string = "string" });
        try path_obj.put("description", .{ .string = "Absolute path to the file" });
        try props.put("path", .{ .object = path_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "path" });

        return self.buildSchema(props, required);
    }

    fn fileWriteSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);

        var path_obj = json.ObjectMap.init(self.allocator);
        try path_obj.put("type", .{ .string = "string" });
        try path_obj.put("description", .{ .string = "Absolute path to the file" });
        try props.put("path", .{ .object = path_obj });

        var content_obj = json.ObjectMap.init(self.allocator);
        try content_obj.put("type", .{ .string = "string" });
        try content_obj.put("description", .{ .string = "Content to write" });
        try props.put("content", .{ .object = content_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "path" });
        try required.append(.{ .string = "content" });

        return self.buildSchema(props, required);
    }

    fn fileEditSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);

        var path_obj = json.ObjectMap.init(self.allocator);
        try path_obj.put("type", .{ .string = "string" });
        try path_obj.put("description", .{ .string = "Absolute path to the file" });
        try props.put("path", .{ .object = path_obj });

        var old_obj = json.ObjectMap.init(self.allocator);
        try old_obj.put("type", .{ .string = "string" });
        try old_obj.put("description", .{ .string = "Text to find and replace" });
        try props.put("old_string", .{ .object = old_obj });

        var new_obj = json.ObjectMap.init(self.allocator);
        try new_obj.put("type", .{ .string = "string" });
        try new_obj.put("description", .{ .string = "Replacement text" });
        try props.put("new_string", .{ .object = new_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "path" });
        try required.append(.{ .string = "old_string" });
        try required.append(.{ .string = "new_string" });

        return self.buildSchema(props, required);
    }

    fn globSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);

        var pattern_obj = json.ObjectMap.init(self.allocator);
        try pattern_obj.put("type", .{ .string = "string" });
        try pattern_obj.put("description", .{ .string = "Glob pattern to match files" });
        try props.put("pattern", .{ .object = pattern_obj });

        var path_obj = json.ObjectMap.init(self.allocator);
        try path_obj.put("type", .{ .string = "string" });
        try path_obj.put("description", .{ .string = "Base directory for the search" });
        try props.put("path", .{ .object = path_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "pattern" });

        return self.buildSchema(props, required);
    }

    fn grepSchema(self: *ToolExposition) !json.Value {
        var props = json.ObjectMap.init(self.allocator);

        var pattern_obj = json.ObjectMap.init(self.allocator);
        try pattern_obj.put("type", .{ .string = "string" });
        try pattern_obj.put("description", .{ .string = "Regex pattern to search for" });
        try props.put("pattern", .{ .object = pattern_obj });

        var path_obj = json.ObjectMap.init(self.allocator);
        try path_obj.put("type", .{ .string = "string" });
        try path_obj.put("description", .{ .string = "Directory to search in" });
        try props.put("path", .{ .object = path_obj });

        var include_obj = json.ObjectMap.init(self.allocator);
        try include_obj.put("type", .{ .string = "string" });
        try include_obj.put("description", .{ .string = "File pattern to include (e.g. *.zig)" });
        try props.put("include", .{ .object = include_obj });

        var required = json.Array.init(self.allocator);
        try required.append(.{ .string = "pattern" });

        return self.buildSchema(props, required);
    }

    /// Build a JSON Schema object: { "type": "object", "properties": ..., "required": ... }
    fn buildSchema(self: *ToolExposition, props: json.ObjectMap, required: json.Array) !json.Value {
        _ = self;
        var schema = json.ObjectMap.init(props.allocator);
        try schema.put("type", .{ .string = "object" });
        try schema.put("properties", .{ .object = props });
        try schema.put("required", .{ .array = required });
        return .{ .object = schema };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ToolExposition - returns 6 tools" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    try testing.expect(tools.len == 6);
}

test "ToolExposition - tool names are correct" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    try testing.expectEqualStrings("bash", tools[0].name);
    try testing.expectEqualStrings("file_read", tools[1].name);
    try testing.expectEqualStrings("file_write", tools[2].name);
    try testing.expectEqualStrings("file_edit", tools[3].name);
    try testing.expectEqualStrings("glob", tools[4].name);
    try testing.expectEqualStrings("grep", tools[5].name);
}

test "ToolExposition - bash schema has required command field" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    const schema = tools[0].input_schema;
    try testing.expect(schema == .object);
    try testing.expectEqualStrings("object", schema.object.get("type").?.string);

    const required = schema.object.get("required").?.array;
    try testing.expect(required.items.len == 1);
    try testing.expectEqualStrings("command", required.items[0].string);

    const props = schema.object.get("properties").?.object;
    try testing.expect(props.count() == 3); // command, cwd, timeout
}

test "ToolExposition - file_read schema has required path" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    const schema = tools[1].input_schema;
    const required = schema.object.get("required").?.array;
    try testing.expect(required.items.len == 1);
    try testing.expectEqualStrings("path", required.items[0].string);
}

test "ToolExposition - file_edit schema has 3 required fields" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    const schema = tools[3].input_schema;
    const required = schema.object.get("required").?.array;
    try testing.expect(required.items.len == 3);
}

test "ToolExposition - all tools have non-empty descriptions" {
    var exposition = ToolExposition.init(testing.allocator);
    defer exposition.deinit();

    const tools = try exposition.getToolList();
    defer testing.allocator.free(tools);

    for (tools) |tool| {
        try testing.expect(tool.description.len > 0);
    }
}
