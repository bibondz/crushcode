const std = @import("std");
const array_list_compat = @import("array_list_compat");
const Allocator = std.mem.Allocator;

pub const PluginRegistry = struct {
    allocator: Allocator,
    plugins: std.StringHashMap(Plugin),
    enabled_plugins: std.StringHashMap(bool),
    plugin_configs: std.StringHashMap(PluginConfig),

    pub fn init(allocator: Allocator) PluginRegistry {
        return PluginRegistry{
            .allocator = allocator,
            .plugins = std.StringHashMap(Plugin).init(allocator),
            .enabled_plugins = std.StringHashMap(bool).init(allocator),
            .plugin_configs = std.StringHashMap(PluginConfig).init(allocator),
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        self.plugins.deinit();
        self.enabled_plugins.deinit();
        self.plugin_configs.deinit();
    }

    // Register a built-in plugin
    pub fn registerBuiltIn(self: *PluginRegistry, name: []const u8, plugin: Plugin) !void {
        try self.plugins.put(name, plugin);

        // Enable built-in plugins by default
        try self.enabled_plugins.put(name, true);

        // Default config for built-ins
        const config = PluginConfig{
            .enabled = true,
            .config_data = std.json.ObjectMap.init(self.allocator),
            .priority = 50,
        };
        try self.plugin_configs.put(name, config);

        std.log.info("Registered built-in plugin: {s}", .{name});
    }

    // Register external plugin
    pub fn registerExternal(self: *PluginRegistry, name: []const u8, path: []const u8) !void {
        const external_plugin = ExternalPlugin{
            .path = try self.allocator.dupe(u8, path),
            .loaded = false,
        };

        const plugin = Plugin{
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

    // Enable/disable plugin
    pub fn setPluginEnabled(self: *PluginRegistry, name: []const u8, enabled: bool) !void {
        try self.enabled_plugins.put(name, enabled);
        std.log.info("Plugin {s} {s}", .{ name, if (enabled) "enabled" else "disabled" });
    }

    // Check if plugin is enabled
    pub fn isPluginEnabled(self: *PluginRegistry, name: []const u8) bool {
        if (self.enabled_plugins.get(name)) |enabled| {
            return enabled;
        }
        return false;
    }

    // Get plugin by name
    pub fn getPlugin(self: *PluginRegistry, name: []const u8) ?Plugin {
        return self.plugins.get(name);
    }

    // List all registered plugins
    pub fn listPlugins(self: *PluginRegistry) ![]PluginInfo {
        var plugin_infos = array_list_compat.ArrayList(PluginInfo).init(self.allocator);
        defer plugin_infos.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            const config = self.plugin_configs.get(entry.key_ptr.*) orelse PluginConfig.default(self.allocator);

            const info = PluginInfo{
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

    // Load all enabled plugins
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

    // Load a single plugin
    fn loadPlugin(self: *PluginRegistry, plugin: Plugin) !void {
        switch (plugin.type) {
            .builtin => {
                if (plugin.built_in != null) {
                    std.log.info("Loading built-in plugin: {s}", .{plugin.name});
                    // Built-in plugins are already loaded
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

    // Unload a plugin
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

    // Update plugin configuration
    pub fn updatePluginConfig(self: *PluginRegistry, name: []const u8, config_data: std.json.ObjectMap) !void {
        const existing_config = self.plugin_configs.get(name) orelse PluginConfig.default(self.allocator);

        const updated_config = PluginConfig{
            .enabled = existing_config.enabled,
            .config_data = config_data,
            .priority = existing_config.priority,
        };

        try self.plugin_configs.put(name, updated_config);
        std.log.info("Updated config for plugin: {s}", .{name});
    }

    // Get plugins by type
    pub fn getPluginsByType(self: *PluginRegistry, plugin_type: PluginType) ![]Plugin {
        var plugins_of_type = array_list_compat.ArrayList(Plugin).init(self.allocator);
        defer plugins_of_type.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.type == plugin_type) {
                try plugins_of_type.append(entry.value_ptr.*);
            }
        }

        return try plugins_of_type.toOwnedSlice();
    }

    // Get prioritized plugin list
    pub fn getPrioritizedPlugins(self: *PluginRegistry) ![]Plugin {
        var prioritized = array_list_compat.ArrayList(Plugin).init(self.allocator);
        defer prioritized.deinit();

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            if (enabled) {
                try prioritized.append(entry.value_ptr.*);
            }
        }

        // Sort by priority (higher priority first)
        const slice = prioritized.items;
        std.mem.sort(Plugin, slice, self, struct {
            fn lessThan(context: *PluginRegistry, a: Plugin, b: Plugin) bool {
                const config_a = context.plugin_configs.get(a.name) orelse PluginConfig.default(context.allocator);
                const config_b = context.plugin_configs.get(b.name) orelse PluginConfig.default(context.allocator);
                return config_a.priority > config_b.priority;
            }
        }.lessThan);

        return try prioritized.toOwnedSlice();
    }

    // Find plugin that can handle request
    pub fn findPluginForRequest(self: *PluginRegistry, request_type: []const u8) ?Plugin {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const enabled = self.isPluginEnabled(entry.key_ptr.*);
            if (enabled) {
                const plugin = entry.value_ptr.*;

                // Check if plugin can handle this request type
                if (self.pluginCanHandle(plugin, request_type)) {
                    return plugin;
                }
            }
        }

        return null;
    }

    fn pluginCanHandle(self: *PluginRegistry, plugin: Plugin, request_type: []const u8) bool {
        _ = self;

        // Built-in plugins have known capabilities
        if (plugin.built_in) |built_in| {
            return switch (built_in) {
                .pty => std.mem.eql(u8, request_type, "pty"),
                .table_formatter => std.mem.eql(u8, request_type, "table_formatter"),
                .notifier => std.mem.eql(u8, request_type, "notifier"),
                .shell_strategy => std.mem.eql(u8, request_type, "shell_strategy"),
            };
        }

        // External plugins would need to declare capabilities
        // For now, return false for external
        return false;
    }
};

// Plugin types and structures
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    type: PluginType,
    built_in: ?BuiltInPlugin,
    external: ?ExternalPlugin,
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

pub const PluginType = enum {
    builtin,
    external,
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
