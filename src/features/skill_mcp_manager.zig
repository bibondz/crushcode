const std = @import("std");
const array_list_compat = @import("../compat/array_list.zig");
const loader = @import("../skills/loader.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = loader.McpServerConfig;

pub const SkillMcpState = enum {
    stopped,
    starting,
    running,
    failed,
};

pub const SkillMcpEntry = struct {
    skill_name: []const u8,
    server_name: []const u8,
    state: SkillMcpState,
    mcp_type: enum { stdio, http },
    // For stdio: child process handle
    child_process: ?*std.process.Child = null,
    // For HTTP: URL
    url: ?[]const u8 = null,
    // Registered tool names
    registered_tools: array_list_compat.ArrayList([]const u8),
};

pub const SkillMcpManager = struct {
    allocator: Allocator,
    entries: array_list_compat.ArrayList(SkillMcpEntry),

    pub fn init(allocator: Allocator) SkillMcpManager {
        return .{
            .allocator = allocator,
            .entries = array_list_compat.ArrayList(SkillMcpEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SkillMcpManager) void {
        self.stopAll();
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.skill_name);
            self.allocator.free(entry.server_name);
            if (entry.url) |url| self.allocator.free(url);
            for (entry.registered_tools.items) |tool| self.allocator.free(tool);
            entry.registered_tools.deinit();
        }
        self.entries.deinit();
    }

    /// Start MCP servers for a skill
    pub fn startForSkill(self: *SkillMcpManager, skill_name: []const u8, servers: []McpServerConfig) !void {
        for (servers) |server_config| {
            var entry = SkillMcpEntry{
                .skill_name = try self.allocator.dupe(u8, skill_name),
                .server_name = try self.allocator.dupe(u8, server_config.name),
                .state = .starting,
                .mcp_type = switch (server_config.mcp_type) { .stdio => .stdio, .http => .http },
                .registered_tools = array_list_compat.ArrayList([]const u8).init(self.allocator),
            };

            switch (server_config.mcp_type) {
                .stdio => {
                    // Spawn the MCP server process
                    if (server_config.command) |cmd| {
                        // Build args array
                        const args = if (server_config.args) |a| a else &[_][]const u8{};

                        var child = try self.allocator.create(std.process.Child);
                        const full_args = try self.allocator.alloc([]const u8, args.len + 1);
                        full_args[0] = try self.allocator.dupe(u8, cmd);
                        for (args, 1..) |arg, i| {
                            full_args[i] = try self.allocator.dupe(u8, arg);
                        }

                        child.* = std.process.Child.init(full_args, self.allocator);
                        child.stdin_behavior = .Pipe;
                        child.stdout_behavior = .Pipe;
                        child.stderr_behavior = .Pipe;

                        child.spawn() catch {
                            entry.state = .failed;
                            try self.entries.append(entry);

                            // Free allocated args on failure
                            for (full_args) |arg| self.allocator.free(arg);
                            self.allocator.free(full_args);
                            continue;
                        };

                        entry.child_process = child;
                        entry.state = .running;
                    } else {
                        entry.state = .failed;
                        try self.entries.append(entry);
                    }
                },
                .http => {
                    if (server_config.url) |url| {
                        entry.url = try self.allocator.dupe(u8, url);
                        entry.state = .running;
                    } else {
                        entry.state = .failed;
                    }
                    try self.entries.append(entry);
                },
            }
        }
    }

    /// Stop MCP servers for a skill
    pub fn stopForSkill(self: *SkillMcpManager, skill_name: []const u8) void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.skill_name, skill_name)) {
                if (entry.child_process) |child| {
                    _ = child.kill() catch {};
                    child.deinit();
                    self.allocator.destroy(child);
                    entry.child_process = null;
                }
                entry.state = .stopped;
            }
        }
    }

    /// Stop all skill MCPs
    pub fn stopAll(self: *SkillMcpManager) void {
        for (self.entries.items) |*entry| {
            if (entry.child_process) |child| {
                _ = child.kill() catch {};
                child.deinit();
                self.allocator.destroy(child);
                entry.child_process = null;
            }
            entry.state = .stopped;
        }
    }

    /// Check if any MCP is running for a skill
    pub fn isRunning(self: *SkillMcpManager, skill_name: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.skill_name, skill_name) and entry.state == .running) {
                return true;
            }
        }
        return false;
    }

    /// Get running MCP server names for a skill
    pub fn getRunningServers(self: *SkillMcpManager, skill_name: []const u8) ![][]const u8 {
        var servers = array_list_compat.ArrayList([]const u8).init(self.allocator);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.skill_name, skill_name) and entry.state == .running) {
                try servers.append(try self.allocator.dupe(u8, entry.server_name));
            }
        }
        return servers.toOwnedSlice();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "SkillMcpManager - init and deinit" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();
    try testing.expect(manager.entries.items.len == 0);
}

test "SkillMcpManager - startForSkill with HTTP config" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    // Create MCP server config with HTTP type (no process spawn needed)
    var http_config = McpServerConfig{
        .allocator = testing.allocator,
        .name = "my-http-server",
        .command = null,
        .args = null,
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer http_config.deinit();

    try manager.startForSkill("test-skill", &[_]McpServerConfig{http_config});

    try testing.expectEqual(@as(usize, 1), manager.entries.items.len);
    try testing.expectEqual(SkillMcpState.running, manager.entries.items[0].state);
    try testing.expect(std.mem.eql(u8, "test-skill", manager.entries.items[0].skill_name));
    try testing.expect(std.mem.eql(u8, "my-http-server", manager.entries.items[0].server_name));
    try testing.expect(manager.entries.items[0].url != null);
    try testing.expect(std.mem.eql(u8, "http://localhost:3000/mcp", manager.entries.items[0].url.?));
}

test "SkillMcpManager - startForSkill with multiple HTTP configs" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    var config1 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-1",
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer config1.deinit();

    var config2 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-2",
        .url = "http://localhost:4000/mcp",
        .mcp_type = .http,
    };
    defer config2.deinit();

    try manager.startForSkill("multi-skill", &[_]McpServerConfig{ config1, config2 });

    try testing.expectEqual(@as(usize, 2), manager.entries.items.len);
    try testing.expect(manager.isRunning("multi-skill"));
}

test "SkillMcpManager - stopForSkill" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    var config = McpServerConfig{
        .allocator = testing.allocator,
        .name = "test-server",
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer config.deinit();

    try manager.startForSkill("skill-a", &[_]McpServerConfig{config});
    try testing.expect(manager.isRunning("skill-a"));

    manager.stopForSkill("skill-a");
    try testing.expect(!manager.isRunning("skill-a"));
    try testing.expectEqual(SkillMcpState.stopped, manager.entries.items[0].state);
}

test "SkillMcpManager - isRunning" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    var config = McpServerConfig{
        .allocator = testing.allocator,
        .name = "active-server",
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer config.deinit();

    try manager.startForSkill("active-skill", &[_]McpServerConfig{config});

    try testing.expect(manager.isRunning("active-skill"));
    try testing.expect(!manager.isRunning("non-existent-skill"));
}

test "SkillMcpManager - getRunningServers" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    var config1 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-1",
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer config1.deinit();

    var config2 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-2",
        .url = "http://localhost:4000/mcp",
        .mcp_type = .http,
    };
    defer config2.deinit();

    try manager.startForSkill("my-skill", &[_]McpServerConfig{ config1, config2 });

    const servers = try manager.getRunningServers("my-skill");
    defer {
        for (servers) |s| testing.allocator.free(s);
        testing.allocator.free(servers);
    }

    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expect(std.mem.indexOf(u8, servers[0], "server-") != null);
}

test "SkillMcpManager - stopAll" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    var config1 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-a",
        .url = "http://localhost:3000/mcp",
        .mcp_type = .http,
    };
    defer config1.deinit();

    var config2 = McpServerConfig{
        .allocator = testing.allocator,
        .name = "server-b",
        .url = "http://localhost:4000/mcp",
        .mcp_type = .http,
    };
    defer config2.deinit();

    try manager.startForSkill("skill-1", &[_]McpServerConfig{config1});
    try manager.startForSkill("skill-2", &[_]McpServerConfig{config2});

    try testing.expect(manager.isRunning("skill-1"));
    try testing.expect(manager.isRunning("skill-2"));

    manager.stopAll();

    try testing.expect(!manager.isRunning("skill-1"));
    try testing.expect(!manager.isRunning("skill-2"));
    try testing.expectEqual(SkillMcpState.stopped, manager.entries.items[0].state);
    try testing.expectEqual(SkillMcpState.stopped, manager.entries.items[1].state);
}

test "SkillMcpManager - getRunningServers for non-existent skill" {
    var manager = SkillMcpManager.init(testing.allocator);
    defer manager.deinit();

    const servers = try manager.getRunningServers("non-existent");
    defer testing.allocator.free(servers);

    try testing.expectEqual(@as(usize, 0), servers.len);
}
