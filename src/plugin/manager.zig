const std = @import("std");

const types = @import("types.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

const PTYPlugin = @import("pty").PTYPlugin;
const TableFormatterPlugin = @import("table_formatter").TableFormatterPlugin;
const NotifierPlugin = @import("notifier").NotifierPlugin;
const ShellStrategyPlugin = @import("shell_strategy").ShellStrategyPlugin;

const PTYMethod = @import("pty").PTYMethod;
const PTYArgs = @import("pty").PTYArgs;
const EventType = @import("notifier").EventType;

pub const PluginManager = struct {
    allocator: Allocator,
    registry: registry.PluginRegistry,

    pty_plugin: ?PTYPlugin,
    table_formatter: ?TableFormatterPlugin,
    notifier: ?NotifierPlugin,
    shell_strategy: ?ShellStrategyPlugin,

    pub fn init(allocator: Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .registry = registry.PluginRegistry.init(allocator),
            .pty_plugin = null,
            .table_formatter = null,
            .notifier = null,
            .shell_strategy = null,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        self.registry.deinit();

        if (self.pty_plugin) |*plugin| plugin.deinit();
        if (self.table_formatter) |_| {}
        if (self.notifier) |*plugin| plugin.deinit();
        if (self.shell_strategy) |*plugin| plugin.deinit();
    }

    pub fn initializeBuiltIns(self: *PluginManager) !void {
        self.pty_plugin = PTYPlugin.init(self.allocator);
        self.registry.registerBuiltIn("pty", types.Plugin{
            .name = "pty",
            .version = "1.0.0",
            .description = "Terminal management with PTY sessions",
            .type = .builtin,
            .built_in = .{ .pty = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register PTY plugin: {}", .{err});
            return error.PluginRegistrationFailed;
        };

        self.table_formatter = TableFormatterPlugin.init(self.allocator);
        self.registry.registerBuiltIn("table_formatter", types.Plugin{
            .name = "table_formatter",
            .version = "1.0.0",
            .description = "Auto-format markdown tables",
            .type = .builtin,
            .built_in = .{ .table_formatter = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Table Formatter plugin: {}", .{err});
            return error.PluginRegistrationFailed;
        };

        self.notifier = NotifierPlugin.init(self.allocator);
        self.registry.registerBuiltIn("notifier", types.Plugin{
            .name = "notifier",
            .version = "1.0.0",
            .description = "Desktop notifications and sound",
            .type = .builtin,
            .built_in = .{ .notifier = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Notifier plugin: {}", .{err});
            return error.PluginRegistrationFailed;
        };

        self.shell_strategy = ShellStrategyPlugin.init(self.allocator);
        self.registry.registerBuiltIn("shell_strategy", types.Plugin{
            .name = "shell_strategy",
            .version = "1.0.0",
            .description = "Non-interactive shell patterns",
            .type = .builtin,
            .built_in = .{ .shell_strategy = {} },
            .external = null,
        }) catch |err| {
            std.log.err("Failed to register Shell Strategy plugin: {}", .{err});
            return error.PluginRegistrationFailed;
        };
    }

    pub fn handleRequest(self: *PluginManager, request_type: []const u8, method: []const u8, args: anytype) !types.PluginResponse {
        if (request_type.len == 0) return error.EmptyRequestType;
        if (method.len == 0) return error.EmptyMethod;

        const plugin = self.registry.findPluginForRequest(request_type) orelse {
            return types.PluginResponse{ .success = false, .err = "No plugin registered to handle this request type" };
        };

        const built_in = plugin.built_in orelse {
            return types.PluginResponse{ .success = false, .err = "Request matched a plugin without a built-in implementation" };
        };

        switch (built_in) {
            .pty => {
                const pty = self.pty_plugin orelse return types.PluginResponse{ .success = false, .err = "PTY plugin is not initialized" };
                const pty_method = std.meta.stringToEnum(PTYMethod, method) orelse {
                    return types.PluginResponse{ .success = false, .err = "Invalid PTY method" };
                };

                var pty_copy = pty;
                const pty_response = pty_copy.handleRequest(.{
                    .method = pty_method,
                    .args = buildPTYArgs(args),
                }) catch |err| {
                    return types.PluginResponse{
                        .success = false,
                        .err = try std.fmt.allocPrint(self.allocator, "PTY plugin request failed: {}", .{err}),
                    };
                };
                return types.PluginResponse.fromPTY(pty_response);
            },
            .table_formatter => {
                const formatter = self.table_formatter orelse return types.PluginResponse{ .success = false, .err = "Table Formatter plugin is not initialized" };
                if (!std.mem.eql(u8, method, "format_tables")) {
                    return types.PluginResponse{ .success = false, .err = "Invalid method for Table Formatter plugin" };
                }

                var formatter_copy = formatter;
                const formatted = formatter_copy.formatMarkdownTables(args.text) catch |err| {
                    return types.PluginResponse{
                        .success = false,
                        .err = try std.fmt.allocPrint(self.allocator, "Table formatting failed: {}", .{err}),
                    };
                };
                return types.PluginResponse{
                    .success = true,
                    .text = formatted,
                    .message = "Markdown tables formatted",
                };
            },
            .notifier => {
                const notifier = self.notifier orelse return types.PluginResponse{ .success = false, .err = "Notifier plugin is not initialized" };
                const event_type = std.meta.stringToEnum(EventType, method) orelse {
                    return types.PluginResponse{ .success = false, .err = "Invalid notifier event type" };
                };

                var notifier_copy = notifier;
                notifier_copy.handleEvent(.{
                    .type = event_type,
                    .session_id = if (@hasField(@TypeOf(args), "session_id")) args.session_id else null,
                    .task_name = if (@hasField(@TypeOf(args), "task_name")) args.task_name else null,
                    .permission = if (@hasField(@TypeOf(args), "permission")) args.permission else null,
                    .permission_granted = if (@hasField(@TypeOf(args), "permission_granted")) args.permission_granted else null,
                    .error_message = if (@hasField(@TypeOf(args), "error_message")) args.error_message else null,
                    .timestamp = std.time.timestamp(),
                }) catch |err| {
                    return types.PluginResponse{
                        .success = false,
                        .err = try std.fmt.allocPrint(self.allocator, "Notifier event handling failed: {}", .{err}),
                    };
                };

                return types.PluginResponse{ .success = true, .message = "Notifier event handled" };
            },
            .shell_strategy => {
                const shell = self.shell_strategy orelse return types.PluginResponse{ .success = false, .err = "Shell Strategy plugin is not initialized" };
                var shell_copy = shell;
                const processed = shell_copy.processCommand(args.command, args.args) catch |err| {
                    return types.PluginResponse{
                        .success = false,
                        .err = try std.fmt.allocPrint(self.allocator, "Shell command processing failed: {}", .{err}),
                    };
                };

                return types.PluginResponse{
                    .success = processed.allowed,
                    .message = if (processed.allowed) "Shell command processed" else processed.reason,
                    .err = if (processed.allowed) null else processed.reason,
                };
            },
        }
    }

    pub fn getPluginStatus(self: *PluginManager, plugin_name: []const u8) !types.PluginStatus {
        if (self.registry.getPlugin(plugin_name)) |plugin| {
            return types.PluginStatus{
                .name = plugin.name,
                .version = plugin.version,
                .description = plugin.description,
                .enabled = self.registry.isPluginEnabled(plugin_name),
                .type = plugin.type,
                .config = self.registry.plugin_configs.get(plugin_name) orelse types.PluginConfig.default(self.allocator),
            };
        }
        return error.PluginNotFound;
    }

    pub fn setPluginEnabled(self: *PluginManager, plugin_name: []const u8, enabled: bool) !void {
        try self.registry.setPluginEnabled(plugin_name, enabled);
    }

    pub fn listPlugins(self: *PluginManager) ![]types.PluginInfo {
        return try self.registry.listPlugins();
    }

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

        var i: usize = 0;
        while (i < data.len and data[i] != '{') : (i += 1) {}
        if (i >= data.len) return;
        i += 1;

        while (i < data.len) {
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] == '}') break;
            if (data[i] != '"') break;

            i += 1;
            const name_start = i;
            while (i < data.len and data[i] != '"') : (i += 1) {}
            const plugin_name = data[name_start..i];
            i += 1;

            while (i < data.len and data[i] != ':') : (i += 1) {}
            i += 1;
            while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
            if (i >= data.len or data[i] != '{') break;

            i += 1;
            var enabled = true;

            while (i < data.len) {
                while (i < data.len and std.mem.indexOfScalar(u8, " \t\n\r", data[i]) != null) : (i += 1) {}
                if (i >= data.len or data[i] == '}') {
                    i += 1;
                    break;
                }
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
                    while (i < data.len and std.mem.indexOfScalar(u8, "0123456789", data[i]) != null) : (i += 1) {}
                } else if (data[i] == '"') {
                    i += 1;
                    while (i < data.len and data[i] != '"') : (i += 1) {}
                    i += 1;
                } else {
                    while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
                }

                while (i < data.len and (data[i] == ',' or data[i] == ' ')) : (i += 1) {}
            }

            if (!enabled) {
                self.setPluginEnabled(plugin_name, false) catch {};
            }

            while (i < data.len and (data[i] == ',' or data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        }

        std.log.info("Loaded plugin configuration from {s}", .{config_path});
    }

    pub fn savePluginConfig(self: *PluginManager, config_path: []const u8) !void {
        const dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
        std.fs.cwd().makePath(dir) catch {};

        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        const writer = file.writer();
        try writer.writeAll("{");

        const plugins = try self.listPlugins();
        defer self.allocator.free(plugins);

        for (plugins, 0..) |info, idx| {
            if (idx > 0) try writer.writeAll(",");
            try writer.print("\"{s}\":{{\"enabled\":{},\"priority\":50}}", .{
                info.name,
                self.registry.isPluginEnabled(info.name),
            });
        }

        try writer.writeAll("}");
        std.log.info("Saved plugin configuration to {s}", .{config_path});
    }
};

fn buildPTYArgs(args: anytype) PTYArgs {
    return PTYArgs{
        .session_id = if (@hasField(@TypeOf(args), "session_id")) args.session_id else null,
        .command = if (@hasField(@TypeOf(args), "command")) args.command else null,
        .command_parts = if (@hasField(@TypeOf(args), "command_parts")) args.command_parts else null,
        .cwd = if (@hasField(@TypeOf(args), "cwd")) args.cwd else null,
        .data = if (@hasField(@TypeOf(args), "data")) args.data else null,
        .rows = if (@hasField(@TypeOf(args), "rows")) args.rows else null,
        .cols = if (@hasField(@TypeOf(args), "cols")) args.cols else null,
        .env = if (@hasField(@TypeOf(args), "env")) args.env else null,
    };
}
