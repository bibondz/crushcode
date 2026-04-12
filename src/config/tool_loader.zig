const std = @import("std");
const array_list_compat = @import("array_list_compat");
const tool_types = @import("tool_types");

const ToolSchema = tool_types.ToolSchema;

fn freeSchemaFields(allocator: std.mem.Allocator, schemas: []const ToolSchema) void {
    for (schemas) |schema| {
        allocator.free(schema.name);
        allocator.free(schema.description);
        allocator.free(schema.parameters);
    }
}

fn freeSchemaList(allocator: std.mem.Allocator, schemas: *array_list_compat.ArrayList(ToolSchema)) void {
    freeSchemaFields(allocator, schemas.items);
    schemas.deinit();
}

fn cloneToolSchema(allocator: std.mem.Allocator, schema: ToolSchema) !ToolSchema {
    return .{
        .name = try allocator.dupe(u8, schema.name),
        .description = try allocator.dupe(u8, schema.description),
        .parameters = try allocator.dupe(u8, schema.parameters),
    };
}

fn getToolsValue(parsed: std.json.Parsed(std.json.Value)) !std.json.Array {
    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidFormat,
    };

    const tools_value = root_object.get("tools") orelse return error.InvalidFormat;
    return switch (tools_value) {
        .array => |array| array,
        else => return error.InvalidFormat,
    };
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidFormat;
    return switch (value) {
        .string => |string| string,
        else => return error.InvalidFormat,
    };
}

fn getUserToolsDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.HomeNotFound;
            defer allocator.free(userprofile);
            return std.fs.path.join(allocator, &.{ userprofile, ".crushcode", "tools" });
        }
        return err;
    };
    defer allocator.free(home);

    return std.fs.path.join(allocator, &.{ home, ".crushcode", "tools" });
}

/// Load default tool schemas embedded in the binary.
pub fn loadDefaultToolSchemas(allocator: std.mem.Allocator) ![]ToolSchema {
    const default_json = @embedFile("default_tools.json");
    return parseToolSchemas(allocator, default_json);
}

/// Load tool schemas from a JSON string.
pub fn parseToolSchemas(allocator: std.mem.Allocator, json_bytes: []const u8) ![]ToolSchema {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const tools_array = try getToolsValue(parsed);

    var schemas = array_list_compat.ArrayList(ToolSchema).init(allocator);
    errdefer freeSchemaList(allocator, &schemas);

    for (tools_array.items) |tool_value| {
        const object = switch (tool_value) {
            .object => |value| value,
            else => return error.InvalidFormat,
        };

        try schemas.append(.{
            .name = try allocator.dupe(u8, try getStringField(object, "name")),
            .description = try allocator.dupe(u8, try getStringField(object, "description")),
            .parameters = try allocator.dupe(u8, try getStringField(object, "parameters")),
        });
    }

    return schemas.toOwnedSlice();
}

/// Load user tool overrides from ~/.crushcode/tools/*.json files.
pub fn loadUserToolSchemas(allocator: std.mem.Allocator) ![]ToolSchema {
    const tools_dir = getUserToolsDir(allocator) catch |err| switch (err) {
        error.HomeNotFound, error.EnvironmentVariableNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(tools_dir);

    var dir = std.fs.openDirAbsolute(tools_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close();

    var all_schemas = array_list_compat.ArrayList(ToolSchema).init(allocator);
    errdefer freeSchemaList(allocator, &all_schemas);

    var walker = dir.walk(allocator) catch return try all_schemas.toOwnedSlice();
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) {
            continue;
        }

        const file = entry.dir.openFile(entry.basename, .{}) catch continue;
        defer file.close();

        const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(contents);

        const schemas = parseToolSchemas(allocator, contents) catch continue;
        defer allocator.free(schemas);

        for (schemas) |schema| {
            try all_schemas.append(schema);
        }
    }

    return all_schemas.toOwnedSlice();
}

/// Merge user overrides onto default schemas by tool name.
pub fn mergeToolSchemas(allocator: std.mem.Allocator, defaults: []const ToolSchema, overrides: []const ToolSchema) ![]ToolSchema {
    var merged = array_list_compat.ArrayList(ToolSchema).init(allocator);
    errdefer freeSchemaList(allocator, &merged);

    for (defaults) |schema| {
        try merged.append(try cloneToolSchema(allocator, schema));
    }

    for (overrides) |schema| {
        for (merged.items, 0..) |existing, idx| {
            if (!std.mem.eql(u8, existing.name, schema.name)) {
                continue;
            }

            freeSchemaFields(allocator, merged.items[idx .. idx + 1]);
            merged.items[idx] = try cloneToolSchema(allocator, schema);
            break;
        } else {
            try merged.append(try cloneToolSchema(allocator, schema));
        }
    }

    return merged.toOwnedSlice();
}

/// Free tool schemas.
pub fn freeToolSchemas(allocator: std.mem.Allocator, schemas: []const ToolSchema) void {
    if (schemas.len == 0) {
        return;
    }

    freeSchemaFields(allocator, schemas);
    allocator.free(schemas);
}
