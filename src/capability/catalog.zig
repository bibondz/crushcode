const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const Allocator = std.mem.Allocator;

/// Kind of capability registered in the catalog
pub const CapabilityKind = enum {
    tool,
    plugin,
    skill,
    mcp_tool,
    builtin,
};

/// Read-only descriptor for a registered capability
/// Does NOT own any memory — references point back to source registries
pub const CapabilityDescriptor = struct {
    name: []const u8,
    kind: CapabilityKind,
    enabled: bool,
    description: []const u8,

    /// Optional source identifier (e.g., "mcp:github/tools" for MCP tools)
    source: ?[]const u8 = null,
};

/// Thin read-only catalog indexing descriptors from all registries
///
/// This is NOT an owning registry — it provides a unified lookup/list
/// over the existing tool, plugin, skill, and MCP registries without
/// replacing their individual storage or lifecycle management.
///
/// Design: Oracle-validated (session bg_cbadb477)
/// Reference: open-claude-code tool-search, OpenCode skill discovery
pub const CapabilityCatalog = struct {
    allocator: Allocator,
    capabilities: std.StringHashMap(CapabilityDescriptor),

    pub fn init(allocator: Allocator) CapabilityCatalog {
        return .{
            .allocator = allocator,
            .capabilities = std.StringHashMap(CapabilityDescriptor).init(allocator),
        };
    }

    pub fn deinit(self: *CapabilityCatalog) void {
        // Descriptors reference external memory, only free the map structure
        self.capabilities.deinit();
    }

    /// Register a capability descriptor (called by individual registries)
    pub fn register(self: *CapabilityCatalog, descriptor: CapabilityDescriptor) !void {
        try self.capabilities.put(descriptor.name, descriptor);
    }

    /// Register an MCP tool with namespaced ID
    /// Format: "mcp:<server>/<tool>"
    pub fn registerMcpTool(self: *CapabilityCatalog, server: []const u8, tool_name: []const u8, description: []const u8) !void {
        const namespaced_id = try std.fmt.allocPrint(self.allocator, "mcp:{s}/{s}", .{ server, tool_name });
        try self.register(.{
            .name = namespaced_id,
            .kind = .mcp_tool,
            .enabled = true,
            .description = description,
            .source = server,
        });
    }

    /// Remove a capability by name
    pub fn unregister(self: *CapabilityCatalog, name: []const u8) void {
        if (self.capabilities.fetchRemove(name)) |entry| {
            // Free namespaced IDs we allocated
            if (entry.value.kind == .mcp_tool) {
                self.allocator.free(entry.value.name);
            }
        }
    }

    /// Find a capability by exact name
    pub fn find(self: *const CapabilityCatalog, name: []const u8) ?CapabilityDescriptor {
        return self.capabilities.get(name);
    }

    /// Check if a capability exists and is enabled
    pub fn isEnabled(self: *const CapabilityCatalog, name: []const u8) bool {
        if (self.capabilities.get(name)) |desc| {
            return desc.enabled;
        }
        return false;
    }

    /// List all capabilities of a specific kind
    pub fn listByKind(self: *const CapabilityCatalog, allocator: Allocator, kind: CapabilityKind) ![]CapabilityDescriptor {
        var list = array_list_compat.ArrayList(CapabilityDescriptor).init(allocator);
        errdefer list.deinit();

        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.kind == kind) {
                try list.append(entry.value_ptr.*);
            }
        }
        return list.toOwnedSlice();
    }

    /// List all registered capabilities
    pub fn listAll(self: *const CapabilityCatalog, allocator: Allocator) ![]CapabilityDescriptor {
        var list = array_list_compat.ArrayList(CapabilityDescriptor).init(allocator);
        errdefer list.deinit();

        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            try list.append(entry.value_ptr.*);
        }
        return list.toOwnedSlice();
    }

    /// Print catalog summary
    pub fn printSummary(self: *const CapabilityCatalog) void {
        const stdout = file_compat.File.stdout().writer();

        var counts = [_]u32{0} ** 5; // tool, plugin, skill, mcp_tool, builtin
        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            counts[@intFromEnum(entry.value_ptr.kind)] += 1;
        }

        stdout.print("\n  Capability Catalog ({} total)\n", .{self.capabilities.unmanaged.size}) catch {};
        stdout.print("    Tools: {}  Plugins: {}  Skills: {}  MCP: {}  Builtins: {}\n", .{
            counts[0], counts[1], counts[2], counts[3], counts[4],
        }) catch {};
    }
};
