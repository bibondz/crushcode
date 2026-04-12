const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// Tool definition with metadata and execution function
pub const Tool = struct {
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    aliases: [][]const u8,
    category: ToolCategory,
    permissions: []const []const u8,
    feature_flag: ?[]const u8,
    enabled: bool,
    concurrent_safe: bool,

    pub const ToolCategory = enum {
        file_ops,
        shell,
        git,
        network,
        ai,
        mcp,
        system,
        custom,
    };

    pub fn deinit(self: *Tool) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        for (self.aliases) |a| self.allocator.free(a);
        self.allocator.free(self.aliases);
        for (self.permissions) |p| self.allocator.free(p);
        self.allocator.free(self.permissions);
        if (self.feature_flag) |flag| self.allocator.free(flag);
    }
};

/// Feature flags for conditional tool loading
pub const FeatureFlags = struct {
    flags: std.StringHashMap(bool),

    pub fn init(allocator: Allocator) FeatureFlags {
        return FeatureFlags{
            .flags = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *FeatureFlags) void {
        var iter = self.flags.iterator();
        while (iter.next()) |entry| {
            self.flags.allocator.free(entry.key_ptr.*);
        }
        self.flags.deinit();
    }

    /// Set a feature flag
    pub fn set(self: *FeatureFlags, name: []const u8, value: bool) !void {
        const key = try self.flags.allocator.dupe(u8, name);
        try self.flags.put(key, value);
    }

    /// Check if feature flag is enabled (defaults to true if not set)
    pub fn isEnabled(self: *FeatureFlags, name: ?[]const u8) bool {
        const flag_name = name orelse return true;
        return self.flags.get(flag_name) orelse true;
    }

    /// Load feature flags from TOML config
    pub fn loadFromToml(self: *FeatureFlags, content: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
                const enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
                try self.set(key, enabled);
            }
        }
    }
};

/// Tool registry with dynamic loading, aliases, and feature flags
pub const ToolRegistry = struct {
    allocator: Allocator,
    tools: std.StringHashMap(Tool),
    aliases: std.StringHashMap([]const u8),
    feature_flags: FeatureFlags,

    pub fn init(allocator: Allocator) ToolRegistry {
        return ToolRegistry{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .feature_flags = FeatureFlags.init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        // Free tool entries
        var tool_iter = self.tools.iterator();
        while (tool_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var tool = entry.value_ptr.*;
            tool.deinit();
        }
        self.tools.deinit();

        // Free alias entries
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.aliases.deinit();

        self.feature_flags.deinit();
    }

    /// Register a tool in the registry
    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        const key = try self.allocator.dupe(u8, tool.name);

        // Check feature flag
        const enabled = self.feature_flags.isEnabled(tool.feature_flag);

        var registered_tool = tool;
        registered_tool.enabled = enabled;

        try self.tools.put(key, registered_tool);

        // Register aliases
        for (tool.aliases) |alias| {
            const alias_key = try self.allocator.dupe(u8, alias);
            try self.aliases.put(alias_key, tool.name);
        }
    }

    /// Get a tool by name (checks aliases too)
    pub fn get(self: *ToolRegistry, name: []const u8) ?Tool {
        // Direct lookup first
        if (self.tools.get(name)) |tool| {
            return tool;
        }
        // Check aliases
        if (self.aliases.get(name)) |real_name| {
            return self.tools.get(real_name);
        }
        return null;
    }

    /// Check if a tool exists and is enabled
    pub fn isAvailable(self: *ToolRegistry, name: []const u8) bool {
        const tool = self.get(name) orelse return false;
        return tool.enabled;
    }

    /// Enable a tool by name
    pub fn enable(self: *ToolRegistry, name: []const u8) void {
        if (self.tools.getPtr(name)) |tool| {
            tool.enabled = true;
        }
    }

    /// Disable a tool by name
    pub fn disable(self: *ToolRegistry, name: []const u8) void {
        if (self.tools.getPtr(name)) |tool| {
            tool.enabled = false;
        }
    }

    /// Get all available (enabled) tools
    pub fn getAvailableTools(self: *ToolRegistry, allocator: Allocator) ![][]const u8 {
        var available = array_list_compat.ArrayList([]const u8).init(allocator);
        errdefer available.deinit();

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.enabled) {
                try available.append(entry.value_ptr.name);
            }
        }

        return available.toOwnedSlice();
    }

    /// Get tools by category
    pub fn getByCategory(self: *ToolRegistry, allocator: Allocator, category: Tool.ToolCategory) ![][]const u8 {
        var matching = array_list_compat.ArrayList([]const u8).init(allocator);
        errdefer matching.deinit();

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.category == category and entry.value_ptr.enabled) {
                try matching.append(entry.value_ptr.name);
            }
        }

        return matching.toOwnedSlice();
    }

    /// Print all registered tools
    pub fn printTools(self: *ToolRegistry) void {
        std.debug.print("Registered Tools:\n", .{});
        std.debug.print("-----------------\n", .{});

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            const tool = entry.value_ptr;
            const status: []const u8 = if (tool.enabled) "✓" else "✗";
            std.debug.print("  {s} {s} - {s}", .{ status, tool.name, tool.description });

            if (tool.aliases.len > 0) {
                std.debug.print(" (aliases: ", .{});
                for (tool.aliases, 0..) |alias, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{alias});
                }
                std.debug.print(")", .{});
            }

            if (tool.feature_flag) |flag| {
                std.debug.print(" [flag: {s}]", .{flag});
            }

            std.debug.print("\n", .{});
        }
    }

    /// Register built-in tools (file ops, shell, git, etc.)
    pub fn registerBuiltinTools(self: *ToolRegistry) !void {
        // File operations
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "read"),
            .description = try self.allocator.dupe(u8, "Read file contents"),
            .aliases = try self.dupeStringList(&[_][]const u8{"cat"}),
            .category = .file_ops,
            .permissions = try self.dupeStringList(&[_][]const u8{"file:read"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = true,
        });

        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "write"),
            .description = try self.allocator.dupe(u8, "Write content to file"),
            .aliases = &[_][]const u8{},
            .category = .file_ops,
            .permissions = try self.dupeStringList(&[_][]const u8{"file:write"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = false,
        });

        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "edit"),
            .description = try self.allocator.dupe(u8, "Edit existing file"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "patch", "modify" }),
            .category = .file_ops,
            .permissions = try self.dupeStringList(&[_][]const u8{"file:write"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = false,
        });

        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "glob"),
            .description = try self.allocator.dupe(u8, "Find files by pattern"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "find", "search-files" }),
            .category = .file_ops,
            .permissions = try self.dupeStringList(&[_][]const u8{"file:read"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = true,
        });

        // Shell
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "shell"),
            .description = try self.allocator.dupe(u8, "Execute shell commands"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "exec", "run", "bash" }),
            .category = .shell,
            .permissions = try self.dupeStringList(&[_][]const u8{ "shell:execute", "shell:dangerous" }),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = false,
        });

        // Git
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "git"),
            .description = try self.allocator.dupe(u8, "Git version control operations"),
            .aliases = &[_][]const u8{},
            .category = .git,
            .permissions = try self.dupeStringList(&[_][]const u8{"shell:execute"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = false,
        });

        // Network
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "fetch"),
            .description = try self.allocator.dupe(u8, "Fetch URL content"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "curl", "wget", "http" }),
            .category = .network,
            .permissions = try self.dupeStringList(&[_][]const u8{"network:fetch"}),
            .feature_flag = try self.allocator.dupe(u8, "enable_network_tools"),
            .enabled = true,
            .concurrent_safe = true,
        });

        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "web_search"),
            .description = try self.allocator.dupe(u8, "Search the web"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "search", "google" }),
            .category = .network,
            .permissions = try self.dupeStringList(&[_][]const u8{"network:search"}),
            .feature_flag = try self.allocator.dupe(u8, "enable_network_tools"),
            .enabled = true,
            .concurrent_safe = true,
        });

        // AI
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "chat"),
            .description = try self.allocator.dupe(u8, "Send message to AI model"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "ask", "prompt" }),
            .category = .ai,
            .permissions = try self.dupeStringList(&[_][]const u8{"ai:chat"}),
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = true,
        });

        // MCP
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "mcp_call"),
            .description = try self.allocator.dupe(u8, "Call MCP server tool"),
            .aliases = try self.dupeStringList(&[_][]const u8{ "mcp", "tool_call" }),
            .category = .mcp,
            .permissions = try self.dupeStringList(&[_][]const u8{"mcp:call"}),
            .feature_flag = try self.allocator.dupe(u8, "enable_mcp"),
            .enabled = true,
            .concurrent_safe = true,
        });

        // System
        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "list"),
            .description = try self.allocator.dupe(u8, "List providers and models"),
            .aliases = try self.dupeStringList(&[_][]const u8{"ls-providers"}),
            .category = .system,
            .permissions = &[_][]const u8{},
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = true,
        });

        try self.register(Tool{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, "skill"),
            .description = try self.allocator.dupe(u8, "Run built-in skill command"),
            .aliases = &[_][]const u8{},
            .category = .system,
            .permissions = &[_][]const u8{},
            .feature_flag = null,
            .enabled = true,
            .concurrent_safe = true,
        });
    }

    /// Helper to duplicate a string list
    fn dupeStringList(self: *ToolRegistry, items: []const []const u8) ![][]const u8 {
        var list = try self.allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            list[i] = try self.allocator.dupe(u8, item);
        }
        return list;
    }
};

// -- Tests --

test "ToolRegistry - register and get" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tool = Tool{
        .allocator = allocator,
        .name = "test-tool",
        .description = "A test tool",
        .aliases = &.{},
        .category = .custom,
        .permissions = &.{},
        .feature_flag = null,
        .enabled = true,
        .concurrent_safe = true,
    };

    try registry.register(tool);
    const found = registry.get("test-tool");
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.eql(u8, found.?.name, "test-tool"));
}

test "ToolRegistry - alias resolution" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tool = Tool{
        .allocator = allocator,
        .name = "shell",
        .description = "Execute commands",
        .aliases = &.{ "exec", "run" },
        .category = .shell,
        .permissions = &.{},
        .feature_flag = null,
        .enabled = true,
        .concurrent_safe = false,
    };

    try registry.register(tool);

    // Direct lookup
    try std.testing.expect(registry.get("shell") != null);
    // Alias lookup
    try std.testing.expect(registry.get("exec") != null);
    try std.testing.expect(registry.get("run") != null);
    // Non-existent
    try std.testing.expect(registry.get("nonexistent") == null);
}

test "ToolRegistry - feature flags" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.feature_flags.set("enable_experimental", false);

    const tool = Tool{
        .allocator = allocator,
        .name = "experimental-tool",
        .description = "Experimental feature",
        .aliases = &.{},
        .category = .custom,
        .permissions = &.{},
        .feature_flag = "enable_experimental",
        .enabled = true,
        .concurrent_safe = true,
    };

    try registry.register(tool);
    // Tool exists but is disabled due to feature flag
    try std.testing.expect(!registry.isAvailable("experimental-tool"));

    // Enable the flag
    try registry.feature_flags.set("enable_experimental", true);
    registry.enable("experimental-tool");
    try std.testing.expect(registry.isAvailable("experimental-tool"));
}

test "ToolRegistry - builtin tools" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerBuiltinTools();

    // Check core tools exist
    try std.testing.expect(registry.get("read") != null);
    try std.testing.expect(registry.get("write") != null);
    try std.testing.expect(registry.get("shell") != null);
    try std.testing.expect(registry.get("git") != null);
    try std.testing.expect(registry.get("chat") != null);

    // Check aliases
    try std.testing.expect(registry.get("cat") != null);
    try std.testing.expect(registry.get("exec") != null);
    try std.testing.expect(registry.get("bash") != null);
}

test "ToolRegistry - getByCategory" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerBuiltinTools();

    const file_tools = try registry.getByCategory(allocator, .file_ops);
    defer allocator.free(file_tools);

    try std.testing.expect(file_tools.len >= 3); // read, write, edit, glob
}
