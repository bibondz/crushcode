const std = @import("std");

pub const PermissionAction = @import("types.zig").PermissionAction;

/// Risk tiers for tool classification in the graduated permission system.
/// Tools are grouped by the impact they can have on the user's system.
pub const ToolRiskTier = enum {
    /// Read-only operations: safe to auto-approve
    read,
    /// Write operations: may modify files, prompt user before proceeding
    write,
    /// Destructive operations: can cause irreversible changes, prompt with warning
    destructive,

    pub fn fromString(str: []const u8) ?ToolRiskTier {
        return std.meta.stringToEnum(ToolRiskTier, str);
    }

    pub fn toString(self: ToolRiskTier) []const u8 {
        return @tagName(self);
    }
};

/// Static entry mapping a tool name to its risk tier.
const ToolTierEntry = struct {
    name: []const u8,
    tier: ToolRiskTier,
};

/// Known tool-to-tier mappings covering all 16 builtin tools.
/// Unknown tools default to `.destructive` (fail-safe).
const tool_tier_map = [_]ToolTierEntry{
    // READ tools (9)
    .{ .name = "read_file", .tier = .read },
    .{ .name = "glob", .tier = .read },
    .{ .name = "grep", .tier = .read },
    .{ .name = "list_directory", .tier = .read },
    .{ .name = "file_info", .tier = .read },
    .{ .name = "git_status", .tier = .read },
    .{ .name = "git_diff", .tier = .read },
    .{ .name = "git_log", .tier = .read },
    .{ .name = "search_files", .tier = .read },

    // WRITE tools (5)
    .{ .name = "write_file", .tier = .write },
    .{ .name = "create_file", .tier = .write },
    .{ .name = "edit", .tier = .write },
    .{ .name = "move_file", .tier = .write },
    .{ .name = "copy_file", .tier = .write },

    // DESTRUCTIVE tools (2)
    .{ .name = "delete_file", .tier = .destructive },
    .{ .name = "shell", .tier = .destructive },
};

/// Classifies a tool into its risk tier.
/// Returns `.destructive` for any unknown tool name (fail-safe default).
pub fn classifyTool(tool_name: []const u8) ToolRiskTier {
    for (tool_tier_map) |entry| {
        if (std.mem.eql(u8, entry.name, tool_name)) {
            return entry.tier;
        }
    }
    // Fail-safe: unknown tools are treated as destructive
    return .destructive;
}

/// Returns the default permission action for a tool+action pair based on risk tier.
/// - `.read` tier → `.allow` (auto-approve)
/// - `.write` tier → `.ask` (prompt user)
/// - `.destructive` tier → `.ask` (prompt user, with warning)
pub fn classifyToolAction(tool_name: []const u8, action: []const u8) PermissionAction {
    _ = action;
    const tier = classifyTool(tool_name);
    return switch (tier) {
        .read => .allow,
        .write => .ask,
        .destructive => .ask,
    };
}

/// Returns true if the tool is classified as read-only (`.read` tier).
pub fn isReadOnlyTool(tool_name: []const u8) bool {
    return classifyTool(tool_name) == .read;
}

/// Returns a human-readable description for a risk tier.
pub fn getToolTierDescription(tier: ToolRiskTier) []const u8 {
    return switch (tier) {
        .read => "Read-only: safe to auto-approve",
        .write => "Write: may modify files, requires confirmation",
        .destructive => "Destructive: can cause irreversible changes, requires confirmation with warning",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classifyTool returns correct tier for all read tools" {
    const read_tools = [_][]const u8{
        "read_file",
        "glob",
        "grep",
        "list_directory",
        "file_info",
        "git_status",
        "git_diff",
        "git_log",
        "search_files",
    };
    for (read_tools) |tool| {
        try std.testing.expect(classifyTool(tool) == .read);
    }
}

test "classifyTool returns correct tier for all write tools" {
    const write_tools = [_][]const u8{
        "write_file",
        "create_file",
        "edit",
        "move_file",
        "copy_file",
    };
    for (write_tools) |tool| {
        try std.testing.expect(classifyTool(tool) == .write);
    }
}

test "classifyTool returns correct tier for all destructive tools" {
    const destructive_tools = [_][]const u8{
        "delete_file",
        "shell",
    };
    for (destructive_tools) |tool| {
        try std.testing.expect(classifyTool(tool) == .destructive);
    }
}

test "classifyTool returns destructive for unknown tools (fail-safe)" {
    try std.testing.expect(classifyTool("unknown_tool") == .destructive);
    try std.testing.expect(classifyTool("") == .destructive);
    try std.testing.expect(classifyTool("rm_rf") == .destructive);
    try std.testing.expect(classifyTool("exec") == .destructive);
}

test "classifyToolAction returns allow for read tools" {
    try std.testing.expect(classifyToolAction("read_file", "read") == .allow);
    try std.testing.expect(classifyToolAction("glob", "search") == .allow);
    try std.testing.expect(classifyToolAction("git_status", "status") == .allow);
}

test "classifyToolAction returns ask for write tools" {
    try std.testing.expect(classifyToolAction("write_file", "write") == .ask);
    try std.testing.expect(classifyToolAction("create_file", "create") == .ask);
    try std.testing.expect(classifyToolAction("edit", "edit") == .ask);
    try std.testing.expect(classifyToolAction("move_file", "move") == .ask);
    try std.testing.expect(classifyToolAction("copy_file", "copy") == .ask);
}

test "classifyToolAction returns ask for destructive tools" {
    try std.testing.expect(classifyToolAction("delete_file", "delete") == .ask);
    try std.testing.expect(classifyToolAction("shell", "execute") == .ask);
}

test "classifyToolAction returns ask for unknown tools (fail-safe)" {
    try std.testing.expect(classifyToolAction("unknown", "anything") == .ask);
}

test "isReadOnlyTool returns true for read tools only" {
    try std.testing.expect(isReadOnlyTool("read_file") == true);
    try std.testing.expect(isReadOnlyTool("glob") == true);
    try std.testing.expect(isReadOnlyTool("grep") == true);
    try std.testing.expect(isReadOnlyTool("list_directory") == true);
    try std.testing.expect(isReadOnlyTool("file_info") == true);
    try std.testing.expect(isReadOnlyTool("git_status") == true);
    try std.testing.expect(isReadOnlyTool("git_diff") == true);
    try std.testing.expect(isReadOnlyTool("git_log") == true);
    try std.testing.expect(isReadOnlyTool("search_files") == true);
}

test "isReadOnlyTool returns false for write and destructive tools" {
    try std.testing.expect(isReadOnlyTool("write_file") == false);
    try std.testing.expect(isReadOnlyTool("create_file") == false);
    try std.testing.expect(isReadOnlyTool("edit") == false);
    try std.testing.expect(isReadOnlyTool("move_file") == false);
    try std.testing.expect(isReadOnlyTool("copy_file") == false);
    try std.testing.expect(isReadOnlyTool("delete_file") == false);
    try std.testing.expect(isReadOnlyTool("shell") == false);
    try std.testing.expect(isReadOnlyTool("unknown") == false);
}

test "getToolTierDescription returns non-empty descriptions" {
    const read_desc = getToolTierDescription(.read);
    const write_desc = getToolTierDescription(.write);
    const destructive_desc = getToolTierDescription(.destructive);

    try std.testing.expect(read_desc.len > 0);
    try std.testing.expect(write_desc.len > 0);
    try std.testing.expect(destructive_desc.len > 0);

    // Descriptions should be distinct
    try std.testing.expect(!std.mem.eql(u8, read_desc, write_desc));
    try std.testing.expect(!std.mem.eql(u8, write_desc, destructive_desc));
    try std.testing.expect(!std.mem.eql(u8, read_desc, destructive_desc));
}

test "ToolRiskTier fromString and toString roundtrip" {
    try std.testing.expect(ToolRiskTier.fromString("read").? == .read);
    try std.testing.expect(ToolRiskTier.fromString("write").? == .write);
    try std.testing.expect(ToolRiskTier.fromString("destructive").? == .destructive);
    try std.testing.expect(ToolRiskTier.fromString("unknown") == null);

    try std.testing.expect(std.mem.eql(u8, ToolRiskTier.read.toString(), "read"));
    try std.testing.expect(std.mem.eql(u8, ToolRiskTier.write.toString(), "write"));
    try std.testing.expect(std.mem.eql(u8, ToolRiskTier.destructive.toString(), "destructive"));
}
