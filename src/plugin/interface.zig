const std = @import("std");
const registry_mod = @import("../ai/registry.zig");
const error_handler = @import("../ai/error_handler.zig");

/// Plugin interface for external tool integration
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    capabilities: []const Capability,

    // Plugin process handle
    process: ?std.process.Child,
    socket: ?std.net.Stream,

    // Lifecycle methods
    init_fn: fn () !void,
    deinit_fn: fn () void,
    handle_fn: fn (request: Request) !Response,
    health_fn: fn () HealthStatus,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .name = "",
            .version = "",
            .capabilities = &[_]Capability{},
            .process = null,
            .socket = null,
            .init_fn = defaultInit,
            .deinit_fn = defaultDeinit,
            .handle_fn = defaultHandle,
            .health_fn = defaultHealth,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.process) |proc| {
            proc.kill() catch {};
            proc.wait() catch {};
        }
        if (self.socket) |stream| {
            stream.close();
        }
    }

    pub fn start(self: *Self, plugin_path: []const u8) !void {
        // Start plugin process
        var proc = try std.process.Child.init(&[_][]const u8{plugin_path}, self.allocator);
        proc.stdin_behavior = .Pipe;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Inherit;

        try proc.spawn();
        self.process = proc;

        // Initialize plugin
        try self.init_fn();
    }

    pub fn sendRequest(self: *Self, request: Request) !Response {
        if (self.process) |proc| {
            // Send JSON-RPC request via stdin
            const request_json = try std.json.stringifyAlloc(self.allocator, request, .{});
            defer self.allocator.free(request_json);

            _ = try proc.stdin.?.write(request_json);
            _ = try proc.stdin.?.write("\n");

            // Read response from stdout
            var buffer: [4096]u8 = undefined;
            const bytes_read = try proc.stdout.?.read(&buffer);
            const response_str = buffer[0..bytes_read];

            var response = Response{};
            try std.json.parseFromSliceLeaky(Response, self.allocator, response_str, .{});
            return response;
        }
        return error.PluginNotRunning;
    }

    pub fn checkHealth(self: Self) HealthStatus {
        return self.health_fn();
    }

    // Default implementations
    fn defaultInit() !void {}
    fn defaultDeinit() void {}
    fn defaultHandle(request: Request) !Response {
        _ = request;
        return Response{
            .id = "",
            .result = null,
            .@"error" = PluginError{
                .code = -32601,
                .message = "Method not found",
                .data = null,
            },
        };
    }
    fn defaultHealth() HealthStatus {
        return HealthStatus{
            .status = .unknown,
            .message = "Plugin not initialized",
        };
    }
};

pub const Capability = struct {
    name: []const u8,
    version: []const u8,
    input_schema: []const u8,
    output_schema: []const u8,
    description: []const u8,
};

pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: []const u8,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: []const u8,
    result: ?std.json.Value = null,
    @"error": ?PluginError = null,
};

pub const PluginError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const HealthStatus = struct {
    status: Status,
    message: []const u8,

    pub const Status = enum {
        healthy,
        unhealthy,
        unknown,
    };
};

/// Plugin manager for lifecycle and discovery
pub const PluginManager = struct {
    plugins: std.StringHashMap(Plugin),
    plugin_dir: []const u8,
    auto_load: bool,
    health_check_interval: u32,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, plugin_dir: []const u8) Self {
        return Self{
            .plugins = std.StringHashMap(Plugin).init(allocator),
            .plugin_dir = plugin_dir,
            .auto_load = true,
            .health_check_interval = 30,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.plugins.deinit();
    }

    pub fn discoverPlugins(self: *Self) !void {
        if (!self.auto_load) return;

        const dir = std.fs.cwd().openDir(self.plugin_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("Plugin directory not found: {s}", .{self.plugin_dir});
                return;
            },
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .File and std.mem.endsWith(u8, entry.name, ".json")) {
                try self.loadPlugin(entry.name);
            }
        }
    }

    pub fn loadPlugin(self: *Self, config_file: []const u8) !void {
        const config_path = try std.fs.path.join(self.allocator, &.{ self.plugin_dir, config_file });
        defer self.allocator.free(config_path);

        const file = try std.fs.cwd().openFile(config_path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        var parsed = try std.json.parseFromSlice(struct {
            name: []const u8,
            version: []const u8,
            executable: []const u8,
            capabilities: []const Capability,
        }, self.allocator, contents, .{});
        defer parsed.deinit();

        const plugin = try self.allocator.create(Plugin);
        plugin.* = Plugin.init(self.allocator);
        plugin.name = self.allocator.dupe(u8, parsed.value.name);
        plugin.version = self.allocator.dupe(u8, parsed.value.version);
        plugin.capabilities = try self.allocator.dupe(Capability, parsed.value.capabilities);

        const exec_path = try std.fs.path.join(self.allocator, &.{ self.plugin_dir, parsed.value.executable });
        try plugin.start(exec_path);

        try self.plugins.put(plugin.name, plugin.*);

        std.log.info("Loaded plugin: {s} v{s}", .{ plugin.name, plugin.version });
    }

    pub fn getPlugin(self: Self, name: []const u8) ?Plugin {
        return self.plugins.get(name);
    }

    pub fn getAllPlugins(self: Self) []const []const u8 {
        var plugin_names = std.ArrayList([]const u8).init(self.allocator);

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            plugin_names.append(self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
        }

        return plugin_names.toOwnedSlice() catch &[_][]const u8{};
    }

    pub fn unloadPlugin(self: *Self, name: []const u8) void {
        if (self.plugins.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.version);
            self.allocator.free(entry.value.capabilities);
            std.log.info("Unloaded plugin: {s}", .{name});
        }
    }
};
