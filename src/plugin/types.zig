const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PluginType = enum {
    builtin,
    external,
};

pub const BuiltInPlugin = union(enum) {
    pty: void,
    table_formatter: void,
    notifier: void,
    shell_strategy: void,
};

pub const ExternalPlugin = struct {
    path: []const u8,
    loaded: bool,
};

pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    type: PluginType,
    built_in: ?BuiltInPlugin,
    external: ?ExternalPlugin,
};

pub const PluginInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    type: PluginType,
    enabled: bool,
    config: PluginConfig,
};

pub const PluginConfig = struct {
    enabled: bool,
    config_data: std.json.ObjectMap,
    priority: u32,

    pub fn default(allocator: Allocator) PluginConfig {
        return PluginConfig{
            .enabled = true,
            .config_data = std.json.ObjectMap.init(allocator),
            .priority = 50,
        };
    }
};

pub const PluginStatus = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    enabled: bool,
    type: PluginType,
    config: PluginConfig,
};

pub const PluginResponse = struct {
    success: bool,
    data: ?std.json.Value = null,
    text: ?[]const u8 = null,
    message: ?[]const u8 = null,
    err: ?[]const u8 = null,

    pub fn fromPTY(response: anytype) PluginResponse {
        return PluginResponse{
            .success = response.success,
            .data = response.data,
            .message = response.message,
            .err = response.err,
        };
    }
};
