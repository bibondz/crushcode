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

/// Granular risk tier used for finer-grained classification of shell
/// commands and individual tool invocations.
pub const RiskTier = enum {
    low,
    medium,
    high,
    critical,

    pub fn fromString(str: []const u8) ?RiskTier {
        return std.meta.stringToEnum(RiskTier, str);
    }

    pub fn toString(self: RiskTier) []const u8 {
        return @tagName(self);
    }
};

/// Static entry mapping a tool name to its risk tier.
const ToolTierEntry = struct {
    name: []const u8,
    tier: ToolRiskTier,
};

/// Known tool-to-tier mappings covering all 16 builtin tools plus
/// additional safe-read tools.  Unknown tools default to `.destructive`
/// (fail-safe).
const tool_tier_map = [_]ToolTierEntry{
    // READ tools (9 core + 6 extended)
    .{ .name = "read_file", .tier = .read },
    .{ .name = "glob", .tier = .read },
    .{ .name = "grep", .tier = .read },
    .{ .name = "list_directory", .tier = .read },
    .{ .name = "file_info", .tier = .read },
    .{ .name = "git_status", .tier = .read },
    .{ .name = "git_diff", .tier = .read },
    .{ .name = "git_log", .tier = .read },
    .{ .name = "search_files", .tier = .read },
    .{ .name = "web_fetch", .tier = .read },
    .{ .name = "web_search", .tier = .read },
    .{ .name = "image_display", .tier = .read },
    .{ .name = "todo_write", .tier = .read },
    .{ .name = "question", .tier = .read },
    // LSP tools are all read-only; matched by prefix in isReadOnlyTool().
    .{ .name = "lsp_diagnostics", .tier = .read },
    .{ .name = "lsp_goto_definition", .tier = .read },
    .{ .name = "lsp_find_references", .tier = .read },
    .{ .name = "lsp_symbols", .tier = .read },
    .{ .name = "lsp_rename", .tier = .read },

    // WRITE tools (5 core + 1 extended)
    .{ .name = "write_file", .tier = .write },
    .{ .name = "create_file", .tier = .write },
    .{ .name = "edit", .tier = .write },
    .{ .name = "edit_batch", .tier = .write },
    .{ .name = "apply_patch", .tier = .write },
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
/// Also handles `lsp_*` tools by prefix.
pub fn isReadOnlyTool(tool_name: []const u8) bool {
    // Fast-path: check the static map first.
    if (classifyTool(tool_name) == .read) return true;

    // LSP tools are all read-only by convention.
    if (std.mem.startsWith(u8, tool_name, "lsp_")) return true;

    return false;
}

/// Returns a human-readable description for a risk tier.
pub fn getToolTierDescription(tier: ToolRiskTier) []const u8 {
    return switch (tier) {
        .read => "Read-only: safe to auto-approve",
        .write => "Write: may modify files, requires confirmation",
        .destructive => "Destructive: can cause irreversible changes, requires confirmation with warning",
    };
}

/// Returns a human-readable description for a granular risk tier.
pub fn getRiskTierDescription(tier: RiskTier) []const u8 {
    return switch (tier) {
        .low => "Low risk: safe to auto-approve",
        .medium => "Medium risk: requires confirmation on first use",
        .high => "High risk: always requires confirmation",
        .critical => "Critical: destructive operation, always requires explicit approval",
    };
}

// ---------------------------------------------------------------------------
// Shell command classification
// ---------------------------------------------------------------------------

/// A shell command prefix matched to a granular risk tier.
const ShellTierEntry = struct {
    prefix: []const u8,
    tier: RiskTier,
};

/// Known shell command prefixes and their risk tiers.
const shell_tier_map = [_]ShellTierEntry{
    // Low — pure read commands.
    .{ .prefix = "ls", .tier = .low },
    .{ .prefix = "cat", .tier = .low },
    .{ .prefix = "head", .tier = .low },
    .{ .prefix = "tail", .tier = .low },
    .{ .prefix = "pwd", .tier = .low },
    .{ .prefix = "echo", .tier = .low },
    .{ .prefix = "which", .tier = .low },
    .{ .prefix = "env", .tier = .low },
    .{ .prefix = "printenv", .tier = .low },
    .{ .prefix = "type", .tier = .low },
    .{ .prefix = "whoami", .tier = .low },
    .{ .prefix = "date", .tier = .low },
    .{ .prefix = "uname", .tier = .low },
    .{ .prefix = "df", .tier = .low },
    .{ .prefix = "du", .tier = .low },
    .{ .prefix = "find", .tier = .low },
    .{ .prefix = "wc", .tier = .low },
    .{ .prefix = "sort", .tier = .low },
    .{ .prefix = "diff", .tier = .low },
    .{ .prefix = "file", .tier = .low },
    .{ .prefix = "stat", .tier = .low },
    .{ .prefix = "tree", .tier = .low },

    // Low — read-only git commands.
    .{ .prefix = "git status", .tier = .low },
    .{ .prefix = "git diff", .tier = .low },
    .{ .prefix = "git log", .tier = .low },
    .{ .prefix = "git branch", .tier = .low },
    .{ .prefix = "git show", .tier = .low },
    .{ .prefix = "git remote", .tier = .low },
    .{ .prefix = "git stash list", .tier = .low },
    .{ .prefix = "git tag", .tier = .low },

    // Medium — build/test commands.
    .{ .prefix = "npm test", .tier = .medium },
    .{ .prefix = "npm run", .tier = .medium },
    .{ .prefix = "zig build", .tier = .medium },
    .{ .prefix = "cargo test", .tier = .medium },
    .{ .prefix = "cargo build", .tier = .medium },
    .{ .prefix = "make", .tier = .medium },
    .{ .prefix = "cmake", .tier = .medium },
    .{ .prefix = "go test", .tier = .medium },
    .{ .prefix = "go build", .tier = .medium },
    .{ .prefix = "pytest", .tier = .medium },
    .{ .prefix = "jest", .tier = .medium },
    .{ .prefix = "vitest", .tier = .medium },

    // Critical — destructive commands.
    .{ .prefix = "rm -rf", .tier = .critical },
    .{ .prefix = "rm -r", .tier = .critical },
    .{ .prefix = "rm -f", .tier = .critical },
    .{ .prefix = "git push --force", .tier = .critical },
    .{ .prefix = "git push -f", .tier = .critical },
    .{ .prefix = "sudo", .tier = .critical },
    .{ .prefix = "mkfs", .tier = .critical },
    .{ .prefix = "dd", .tier = .critical },
    .{ .prefix = "format", .tier = .critical },
    .{ .prefix = "shutdown", .tier = .critical },
    .{ .prefix = "reboot", .tier = .critical },
    .{ .prefix = "init 0", .tier = .critical },
    .{ .prefix = "init 6", .tier = .critical },
};

/// Classify a shell command into a granular risk tier.
/// Matches the command against known prefixes; returns `.high` for any
/// unknown command (conservative default).
pub fn classifyShellCommand(cmd: []const u8) RiskTier {
    // Trim leading whitespace.
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
    if (trimmed.len == 0) return .low;

    // Check against the known prefix map (longer prefixes first for
    // specificity — the map is ordered so that specific prefixes like
    // "rm -rf" come before shorter ones like "rm").
    for (shell_tier_map) |entry| {
        if (std.mem.startsWith(u8, trimmed, entry.prefix)) {
            // Ensure the match ends at a word boundary (space, end of
            // string, or a flag character) to avoid false positives like
            // "lsblk" matching "ls".
            const end = entry.prefix.len;
            if (end >= trimmed.len) return entry.tier;
            const next_char = trimmed[end];
            if (next_char == ' ' or next_char == '\t' or next_char == '-' or next_char == ';' or next_char == '&' or next_char == '|') {
                return entry.tier;
            }
        }
    }

    // Default: unknown commands are high risk.
    return .high;
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

test "classifyShellCommand returns low for safe read commands" {
    try std.testing.expect(classifyShellCommand("ls") == .low);
    try std.testing.expect(classifyShellCommand("ls -la /tmp") == .low);
    try std.testing.expect(classifyShellCommand("cat README.md") == .low);
    try std.testing.expect(classifyShellCommand("head -n 10 file.txt") == .low);
    try std.testing.expect(classifyShellCommand("pwd") == .low);
    try std.testing.expect(classifyShellCommand("echo hello") == .low);
    try std.testing.expect(classifyShellCommand("which zig") == .low);
    try std.testing.expect(classifyShellCommand("git status") == .low);
    try std.testing.expect(classifyShellCommand("git diff HEAD~1") == .low);
    try std.testing.expect(classifyShellCommand("git log --oneline") == .low);
}

test "classifyShellCommand returns medium for build/test commands" {
    try std.testing.expect(classifyShellCommand("npm test") == .medium);
    try std.testing.expect(classifyShellCommand("zig build") == .medium);
    try std.testing.expect(classifyShellCommand("cargo test") == .medium);
    try std.testing.expect(classifyShellCommand("make") == .medium);
}

test "classifyShellCommand returns critical for destructive commands" {
    try std.testing.expect(classifyShellCommand("rm -rf /") == .critical);
    try std.testing.expect(classifyShellCommand("rm -rf .") == .critical);
    try std.testing.expect(classifyShellCommand("rm -f file.txt") == .critical);
    try std.testing.expect(classifyShellCommand("sudo apt install") == .critical);
    try std.testing.expect(classifyShellCommand("git push --force origin main") == .critical);
    try std.testing.expect(classifyShellCommand("git push -f") == .critical);
}

test "classifyShellCommand returns high for unknown commands" {
    try std.testing.expect(classifyShellCommand("docker run") == .high);
    try std.testing.expect(classifyShellCommand("python3 script.py") == .high);
    try std.testing.expect(classifyShellCommand("node server.js") == .high);
    try std.testing.expect(classifyShellCommand("unknown-command") == .high);
}

test "classifyShellCommand handles edge cases" {
    try std.testing.expect(classifyShellCommand("") == .low);
    try std.testing.expect(classifyShellCommand("  ") == .low);
    try std.testing.expect(classifyShellCommand("  ls") == .low);
}

test "RiskTier fromString and toString roundtrip" {
    try std.testing.expect(RiskTier.fromString("low").? == .low);
    try std.testing.expect(RiskTier.fromString("medium").? == .medium);
    try std.testing.expect(RiskTier.fromString("high").? == .high);
    try std.testing.expect(RiskTier.fromString("critical").? == .critical);
    try std.testing.expect(RiskTier.fromString("unknown") == null);

    try std.testing.expect(std.mem.eql(u8, RiskTier.low.toString(), "low"));
    try std.testing.expect(std.mem.eql(u8, RiskTier.medium.toString(), "medium"));
    try std.testing.expect(std.mem.eql(u8, RiskTier.high.toString(), "high"));
    try std.testing.expect(std.mem.eql(u8, RiskTier.critical.toString(), "critical"));
}

test "classifyTool returns correct tier for extended read tools" {
    try std.testing.expect(classifyTool("web_fetch") == .read);
    try std.testing.expect(classifyTool("web_search") == .read);
    try std.testing.expect(classifyTool("image_display") == .read);
    try std.testing.expect(classifyTool("todo_write") == .read);
    try std.testing.expect(classifyTool("question") == .read);
    try std.testing.expect(classifyTool("lsp_diagnostics") == .read);
    try std.testing.expect(classifyTool("edit_batch") == .write);
    try std.testing.expect(classifyTool("apply_patch") == .write);
}

test "isReadOnlyTool returns true for lsp_ prefixed tools" {
    try std.testing.expect(isReadOnlyTool("lsp_diagnostics") == true);
    try std.testing.expect(isReadOnlyTool("lsp_goto_definition") == true);
    try std.testing.expect(isReadOnlyTool("lsp_find_references") == true);
    try std.testing.expect(isReadOnlyTool("lsp_symbols") == true);
    try std.testing.expect(isReadOnlyTool("lsp_rename") == true);
    try std.testing.expect(isReadOnlyTool("lsp_custom_tool") == true);
}

test "getRiskTierDescription returns non-empty descriptions" {
    try std.testing.expect(getRiskTierDescription(.low).len > 0);
    try std.testing.expect(getRiskTierDescription(.medium).len > 0);
    try std.testing.expect(getRiskTierDescription(.high).len > 0);
    try std.testing.expect(getRiskTierDescription(.critical).len > 0);
}
