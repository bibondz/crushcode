const std = @import("std");
const array_list_compat = @import("array_list_compat");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const PluginRegistry = struct {
    allocator: Allocator,
    plugins: std.StringHashMap(types.Plugin),
    enabled_plugins: std.StringHashMap(bool),
    plugin_configs: std.StringHashMap(types.PluginConfig),

    pub fn init(allocator: Allocator) PluginRegistry {
        return PluginRegistry{
            .allocator = allocator,
            .plugins = std.StringHashMap(types.Plugin).init(allocator),
            .enabled_plugins = std.StringHashMap(bool).init(allocator),
            .plugin_configs = std.StringHashMap(types.PluginConfig).init(allocator),
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        self.plugins.deinit();
        self.enabled_plugins.deinit();
        self.plugin_configs.deinit();
    }

    pub fn registerBuiltIn(self: *PluginRegistry, name: []const u8, plugin: types.Plugin) !void {
        try self.plugins.put(name, plugin);
        try self.enabled_plugins.put(name, true);

        const config = types.PluginConfig{
            .enabled = true,
            .config_data = std.json.ObjectMap.init(self.allocator),
            .priority = 50,
        };
        try self.plugin_configs.put(name, config);

        std.log.info("Registered built-in plugin: {s}", .{name});
    }

    pub fn registerExternal(self: *PluginRegistry, name: []const u8, path: []const u8) !void {
        const external_plugin = types.ExternalPlugin{
            .path = try self.allocator.dupe(u8, path),
            .loaded = false,
        };

        const plugin = types.Plugin{
            .name = try self.allocator.dupe(u8, name),
            .version = "1.0.0",
            .description = try std.fmt.allocPrint(self.allocator, "External plugin from {s}", .{path}),
            .type = .external,
            .external = external_plugin,
            .built_in = null,
        };

        try self.plugins.put(name, plugin);
        std.log.info("Registered external plugin: {s} from {s}", .{ name, path });
    }

    pub fn setPluginEnabled(self: *PluginRegistry, name: []const u8, enabled: bool) !void {
        try self.enabled_plugins.put(name, enabled);
        std.log.info("Plugin {s} {s}", .{ name, if (enabled) "enabled" else "disabled" });
    }

    pub fn isPluginEnabled(self: *PluginRegistry, name: []const u8) bool {
        if (self.enabled_plugins.get(name)) |enabled| {
            return enabled;
        }
        return false;
    }

    pub fn getPlugin(self: *PluginRegistry, name: []const u8) ?types.Plugin {
        return self.plugins.get(name);
    }

    pub fn listPlugins(self: *PluginRegistry) ![]types.PluginInfo {
        var plugin_infos = array_list_compat.ArrayList(types.PluginInfo).init(self.allocator);
        defer plugin_infos.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            const config = self.plugin_configs.get(entry.key_ptr.*) orelse types.PluginConfig.default(self.allocator);

            const info = types.PluginInfo{
                .name = entry.key_ptr.*,
                .version = entry.value_ptr.*.version,
                .description = entry.value_ptr.*.description,
                .type = entry.value_ptr.*.type,
                .enabled = enabled,
                .config = config,
            };

            try plugin_infos.append(info);
        }

        return try plugin_infos.toOwnedSlice();
    }

    pub fn loadEnabledPlugins(self: *PluginRegistry) !void {
        var iter = self.enabled_plugins.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*) {
                if (self.plugins.get(entry.key_ptr.*)) |plugin| {
                    try self.loadPlugin(plugin);
                }
            }
        }
    }

    fn loadPlugin(self: *PluginRegistry, plugin: types.Plugin) !void {
        switch (plugin.type) {
            .builtin => {
                if (plugin.built_in != null) {
                    std.log.info("Loading built-in plugin: {s}", .{plugin.name});
                }
            },
            .external => {
                if (self.plugins.getPtr(plugin.name)) |plugin_ptr| {
                    if (plugin_ptr.external) |*external| {
                        std.log.info("Loading external plugin: {s} from {s}", .{ plugin.name, external.path });
                        external.loaded = true;
                    }
                }
            },
        }
    }

    pub fn unloadPlugin(self: *PluginRegistry, name: []const u8) !void {
        if (self.plugins.get(name)) |plugin| {
            switch (plugin.type) {
                .builtin => {
                    std.log.info("Cannot unload built-in plugin: {s}", .{name});
                },
                .external => {
                    if (self.plugins.getPtr(name)) |plugin_ptr| {
                        if (plugin_ptr.external) |*external| {
                            std.log.info("Unloading external plugin: {s}", .{name});
                            external.loaded = false;
                        }
                    }
                },
            }
        }
    }

    pub fn updatePluginConfig(self: *PluginRegistry, name: []const u8, config_data: std.json.ObjectMap) !void {
        const existing_config = self.plugin_configs.get(name) orelse types.PluginConfig.default(self.allocator);

        const updated_config = types.PluginConfig{
            .enabled = existing_config.enabled,
            .config_data = config_data,
            .priority = existing_config.priority,
        };

        try self.plugin_configs.put(name, updated_config);
        std.log.info("Updated config for plugin: {s}", .{name});
    }

    pub fn getPluginsByType(self: *PluginRegistry, plugin_type: types.PluginType) ![]types.Plugin {
        var plugins_of_type = array_list_compat.ArrayList(types.Plugin).init(self.allocator);
        defer plugins_of_type.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.type == plugin_type) {
                try plugins_of_type.append(entry.value_ptr.*);
            }
        }

        return try plugins_of_type.toOwnedSlice();
    }

    pub fn getPrioritizedPlugins(self: *PluginRegistry) ![]types.Plugin {
        var prioritized = array_list_compat.ArrayList(types.Plugin).init(self.allocator);
        defer prioritized.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            if (enabled) {
                try prioritized.append(entry.value_ptr.*);
            }
        }

        const slice = prioritized.items;
        std.mem.sort(types.Plugin, slice, self, struct {
            fn lessThan(context: *PluginRegistry, a: types.Plugin, b: types.Plugin) bool {
                const config_a = context.plugin_configs.get(a.name) orelse types.PluginConfig.default(context.allocator);
                const config_b = context.plugin_configs.get(b.name) orelse types.PluginConfig.default(context.allocator);
                return config_a.priority > config_b.priority;
            }
        }.lessThan);

        return try prioritized.toOwnedSlice();
    }

    pub fn findPluginForRequest(self: *PluginRegistry, request_type: []const u8) ?types.Plugin {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            if (enabled) {
                const plugin = entry.value_ptr.*;
                if (self.pluginCanHandle(plugin, request_type)) {
                    return plugin;
                }
            }
        }

        return null;
    }

    fn pluginCanHandle(self: *PluginRegistry, plugin: types.Plugin, request_type: []const u8) bool {
        _ = self;

        if (plugin.built_in) |built_in| {
            return switch (built_in) {
                .pty => std.mem.eql(u8, request_type, "pty"),
                .table_formatter => std.mem.eql(u8, request_type, "table_formatter"),
                .notifier => std.mem.eql(u8, request_type, "notifier"),
                .shell_strategy => std.mem.eql(u8, request_type, "shell_strategy"),
            };
        }

        return false;
    }
};
