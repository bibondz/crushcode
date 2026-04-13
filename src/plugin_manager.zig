const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const PluginManager = struct {
    allocator: Allocator,
    registry: PluginRegistry,
    
    // Built-in plugin instances
    pty_plugin: ?PTYPlugin,
    table_formatter: ?TableFormatterPlugin,
    notifier: ?NotifierPlugin,
    shell_strategy: ?ShellStrategyPlugin,
    
    pub fn init(allocator: Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .registry = PluginRegistry.init(allocator),
            .pty_plugin = null,
            .table_formatter = null,
            .notifier = null,
            .shell_strategy = null,
        };
    }
    
    pub fn deinit(self: *PluginManager) void {
        self.registry.deinit();
        
        if (self.pty_plugin) |plugin| {
            plugin.deinit();
        }
        if (self.table_formatter) |plugin| {
            plugin.deinit();
        }
        if (self.notifier) |plugin| {
            plugin.deinit();
        }
        if (self.shell_strategy) |plugin| {
            plugin.deinit();
        }
    }
    
    // Initialize all built-in plugins
    pub fn initializeBuiltIns(self: *PluginManager) !void {
        // Guard clause: allocator must be valid
        if (self.allocator == undefined) {
            return error.InvalidAllocator;
        }
        
        // Initialize PTY Plugin with explicit error handling
        self.pty_plugin = PTYPlugin.init(self.allocator) catch |err| {
            std.log.err("Failed to initialize PTY plugin: {}", .{err});
            return error.PluginInitializationFailed;
        };
        if (self.pty_plugin == null) {
            return error.PTYPluginInitializationFailed;
        }
        try self.registry.registerBuiltIn("pty", Plugin{
            .name = "pty",
            .version = "1.0.0",
            .description = "Terminal management with PTY sessions",
            .type = .built_in,
            .built_in = .{ .pty = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register PTY plugin in registry: {}", .{err});
            return error.PluginRegistrationFailed;
        };
        
        // Initialize Table Formatter Plugin with explicit error handling
        self.table_formatter = TableFormatterPlugin.init(self.allocator) catch |err| {
            std.log.err("Failed to initialize Table Formatter plugin: {}", .{err});
            return error.PluginInitializationFailed;
        };
        if (self.table_formatter == null) {
            return error.TableFormatterPluginInitializationFailed;
        }
        try self.registry.registerBuiltIn("table_formatter", Plugin{
            .name = "table_formatter",
            .version = "1.0.0",
            .description = "Auto-format markdown tables",
            .type = .built_in,
            .built_in = .{ .table_formatter = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Table Formatter plugin in registry: {}", .{err});
            return error.PluginRegistrationFailed;
        };
        
        // Initialize Notifier Plugin with explicit error handling
        self.notifier = NotifierPlugin.init(self.allocator) catch |err| {
            std.log.err("Failed to initialize Notifier plugin: {}", .{err});
            return error.PluginInitializationFailed;
        };
        if (self.notifier == null) {
            return error.NotifierPluginInitializationFailed;
        }
        try self.registry.registerBuiltIn("notifier", Plugin{
            .name = "notifier",
            .version = "1.0.0",
            .description = "Desktop notifications and sound",
            .type = .built_in,
            .built_in = .{ .notifier = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Notifier plugin in registry: {}", .{err});
            return error.PluginRegistrationFailed;
        };
        
        // Initialize Shell Strategy Plugin with explicit error handling
        self.shell_strategy = ShellStrategyPlugin.init(self.allocator) catch |err| {
            std.log.err("Failed to initialize Shell Strategy plugin: {}", .{err});
            return error.PluginInitializationFailed;
        };
        if (self.shell_strategy == null) {
            return error.ShellStrategyPluginInitializationFailed;
        }
        try self.registry.registerBuiltIn("shell_strategy", Plugin{
            .name = "shell_strategy",
            .version = "1.0.0",
            .description = "Non-interactive shell patterns",
            .type = .built_in,
            .built_in = .{ .shell_strategy = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Shell Strategy plugin in registry: {}", .{err});
            return error.PluginRegistrationFailed;
        };
    }
    
    // Route request to appropriate plugin
    pub fn handleRequest(self: *PluginManager, request_type: []const u8, method: []const u8, args: anytype) !PluginResponse {
        // Guard clauses for invalid inputs
        if (request_type.len == 0) {
            return error.EmptyRequestType;
        }
        if (method.len == 0) {
            return error.EmptyMethod;
        }
        
        // Find plugin that can handle this request
        const plugin = self.registry.findPluginForRequest(request_type) orelse {
            return PluginResponse{
                .success = false,
                .err = "No plugin registered to handle this request type",
            };
        };
        
        // Handle request with explicit plugin instance validation
        switch (plugin.built_in) {
            .pty => {
                const pty = self.pty_plugin orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "PTY plugin registered but instance not available for request type '{s}' method '{s}'", .{ request_type, method }) catch "PTY plugin instance not available",
                    };
                };
                
                const pty_method = @enumFromString(PTYMethod, method) orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Invalid PTY method '{s}' for request type '{s}'. Valid methods are: spawn, resize, kill", .{ method, request_type }) catch "Invalid PTY method",
                    };
                };
                
                const pty_request = PTYRequest{
                    .method = pty_method,
                    .args = args,
                };
                
                return pty.spawnPTY(pty_request) catch |err| {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "PTY plugin failed to spawn PTY session for request type '{s}' method '{s}': {}", .{ request_type, method, err }) catch "PTY spawn failed",
                    };
                };
            
            .table_formatter => {
                const formatter = self.table_formatter orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Table Formatter plugin registered but instance not available for request type '{s}' method '{s}'", .{ request_type, method }) catch "Table Formatter plugin instance not available",
                    };
                };
                
                if (!std.mem.eql(u8, method, "format_tables")) {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Invalid method '{s}' for Table Formatter plugin. Only 'format_tables' method is supported", .{method}) catch "Invalid Table Formatter method",
                    };
                }
                
                const text = args.text;
                if (text.len == 0) {
                    return PluginResponse{
                        .success = false,
                        .err = "Empty text provided to Table Formatter plugin",
                    };
                }
                
                return formatter.formatMarkdownTables(text) catch |err| {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Table Formatter plugin failed to format text: {}", .{err}) catch "Table formatting failed",
                    };
                };
            },
            
            .notifier => {
                const notifier = self.notifier orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Notifier plugin registered but instance not available for request type '{s}' method '{s}'", .{ request_type, method }) catch "Notifier plugin instance not available",
                    };
                };
                
                const event_type = @enumFromString(EventType, method) orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Invalid Notifier event type '{s}' for request type '{s}'", .{ method, request_type }) catch "Invalid Notifier event type",
                    };
                };
                
                const event = NotifierEvent{
                    .type = event_type,
                    .session_id = args.session_id,
                    .task_name = args.task_name,
                    .permission = args.permission,
                    .permission_granted = args.permission_granted,
                    .error_message = args.error_message,
                    .timestamp = std.time.timestamp(),
                };
                
                return notifier.handleEvent(event) catch |err| {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Notifier plugin failed to handle event: {}", .{err}) catch "Notifier event handling failed",
                    };
                };
            },
            
            .shell_strategy => {
                const shell = self.shell_strategy orelse {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Shell Strategy plugin registered but instance not available for request type '{s}' method '{s}'", .{ request_type, method }) catch "Shell Strategy plugin instance not available",
                    };
                };
                
                const command = args.command;
                const cmd_args = args.args;
                
                if (command.len == 0) {
                    return PluginResponse{
                        .success = false,
                        .err = "Empty command provided to Shell Strategy plugin",
                    };
                }
                
                return shell.processCommand(command, cmd_args) catch |err| {
                    return PluginResponse{
                        .success = false,
                        .err = std.fmt.allocPrint(self.allocator, "Shell Strategy plugin failed to process command: {}", .{err}) catch "Shell command processing failed",
                    };
                };
            },
        }
    }
    
    // Get plugin status and info
    pub fn getPluginStatus(self: *PluginManager, plugin_name: []const u8) !PluginStatus {
        if (self.registry.getPlugin(plugin_name)) |plugin| {
            const enabled = self.registry.isPluginEnabled(plugin_name);
            const config = self.registry.plugin_configs.get(plugin_name) orelse PluginConfig.default;
            
            return PluginStatus{
                .name = plugin.name,
                .version = plugin.version,
                .description = plugin.description,
                .enabled = enabled,
                .type = plugin.type,
                .config = config,
            };
        }
        
        return error.PluginNotFound;
    }
    
    // Enable/disable plugins
    pub fn setPluginEnabled(self: *PluginManager, plugin_name: []const u8, enabled: bool) !void {
        try self.registry.setPluginEnabled(plugin_name, enabled);
    }
    
    // List all plugins
    pub fn listPlugins(self: *PluginManager) ![]PluginInfo {
        return self.registry.listPlugins();
    }
    
    // Load plugin configuration from a JSON file
    // Format: {"plugin_name":{"enabled":true,"priority":50}, ...}
    pub fn loadPluginConfig(self: *PluginManager, config_path: []const u8) !void {
        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("No plugin config file at {s} — using defaults", .{config_path});
                return;
            }
            return err;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0 or file_size > 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buf);

        const bytes_read = try file.readAll(buf);
        const data = buf[0..bytes_read];

        // Simple JSON parsing: find each "plugin_name":{...}
        var i: usize = 0;
        while (i < data.len and data[i] != '{') : (i += 1) {}
        if (i >= data.len) return;
        i += 1; // skip {

        while (i < data.len) {
            // Skip whitespace
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] == '}') break;
            if (data[i] != '"') break;

            // Parse plugin name
            i += 1;
            const name_start = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const plugin_name = data[name_start..i];
            i += 1;

            // Skip to value
            while (i < data.len and data[i] != ':') : (i += 1) {}
            i += 1;
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] != '{') break;

            // Parse config object
            i += 1; // skip {
            var enabled = true;

            while (i < data.len) {
                while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
                if (i >= data.len or data[i] == '}') { i += 1; break; }
                if (data[i] != '"') break;

                i += 1;
                const field_start = i;
                while (i < data.len and data[i] != '"') : (i += 1) {}
                const field_name = data[field_start..i];
                i += 1;

                while (i < data.len and data[i] != ':') : (i += 1) {}
                i += 1;
                while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}

                if (std.mem.eql(u8, field_name, "enabled")) {
                    if (i + 4 <= data.len and std.mem.eql(u8, data[i .. i + 4], "true")) {
                        enabled = true;
                        i += 4;
                    } else if (i + 5 <= data.len and std.mem.eql(u8, data[i .. i + 5], "false")) {
                        enabled = false;
                        i += 5;
                    }
                } else if (std.mem.eql(u8, field_name, "priority")) {
                    // Skip number
                    while (i < data.len and std.mem.indexOfScalar(u8, "0123456789", data[i]) != null) : (i += 1) {}
                } else {
                    // Skip unknown field value
                    if (data[i] == '"') {
                        i += 1;
                        while (i < data.len and data[i] != '"') : (i += 1) {}
                        i += 1;
                    } else {
                        while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
                    }
                }

                // Skip comma
                while (i < data.len and (data[i] == ',' or data[i] == ' ')) : (i += 1) {}
            }

            // Apply config — disable plugins that are marked disabled
            if (!enabled) {
                self.setPluginEnabled(plugin_name, false) catch {};
            }

            // Skip trailing comma
            while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        }

        std.log.info("Loaded plugin configuration from {s}", .{config_path});
    }
    
    // Save plugin configuration to a JSON file
    pub fn savePluginConfig(self: *PluginManager, config_path: []const u8) !void {
        // Ensure directory exists
        const dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
        std.fs.cwd().makePath(dir) catch {};

        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        const writer = file.writer();
        try writer.writeAll("{");

        const plugins = self.listPlugins() catch &[_]PluginInfo{};
        for (plugins, 0..) |info, idx| {
            if (idx > 0) try writer.writeAll(",");
            const is_enabled = self.registry.isPluginEnabled(info.name);
            try writer.print("\"{s}\":{{\"enabled\":{},\"priority\":50}}", .{
                info.name,
                is_enabled,
            });
        }

        try writer.writeAll("}");
        std.log.info("Saved plugin configuration to {s}", .{config_path});
    }
};

// Import plugin types
const PTYPlugin = @import("pty.zig").PTYPlugin;
const TableFormatterPlugin = @import("table_formatter.zig").TableFormatterPlugin;
const NotifierPlugin = @import("notifier.zig").NotifierPlugin;
const ShellStrategyPlugin = @import("shell_strategy.zig").ShellStrategyPlugin;
const PluginRegistry = @import("registry.zig").PluginRegistry;

// Import shared types
const Plugin = @import("registry.zig").Plugin;
const PluginInfo = @import("registry.zig").PluginInfo;
const PluginConfig = @import("registry.zig").PluginConfig;
const PluginStatus = @import("registry.zig").PluginStatus;

// Import plugin-specific types
const PTYRequest = @import("pty.zig").PTYRequest;
const PTYMethod = @import("pty.zig").PTYMethod;
const EventType = @import("notifier.zig").EventType;
const NotifierEvent = @import("notifier.zig").NotifierEvent;
const PluginResponse = @import("pty.zig").PTYResponse;

// Helper functions
fn @enumFromString(comptime T: type, str: []const u8) ?T {
    inline for (@typeInfo(T).Enum.fields) |field| {
        if (std.mem.eql(u8, str, field.name)) {
            return @field(T, field.name);
        }
    }
    return null;
}