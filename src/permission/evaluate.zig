const std = @import("std");
const json = std.json;

const Allocator = std.mem.Allocator;
const PermissionAction = @import("types.zig").PermissionAction;
const PermissionMode = @import("types.zig").PermissionMode;
const PermissionRule = @import("types.zig").PermissionRule;
const PermissionRequest = @import("types.zig").PermissionRequest;
const PermissionResult = @import("types.zig").PermissionResult;
const PermissionConfig = @import("types.zig").PermissionConfig;

/// Permission evaluator implementing OpenCode's pattern matching logic
pub const PermissionEvaluator = struct {
    allocator: Allocator,
    config: PermissionConfig,

    pub fn init(allocator: Allocator, config: PermissionConfig) PermissionEvaluator {
        return PermissionEvaluator{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *PermissionEvaluator) void {
        self.config.deinit();
    }

    /// Evaluate permission request against rules (OpenCode pattern)
    /// Returns the last matching rule's action (last-match-wins)
    pub fn evaluate(self: *const PermissionEvaluator, request: *const PermissionRequest) PermissionResult {
        // Check permission mode first (Claude Code pattern)
        switch (self.config.mode) {
            .bypassPermissions => return PermissionResult.allow(),
            .auto => return PermissionResult.autoAllow(),
            .plan => {
                // Plan mode: allow read operations, deny writes
                if (isReadOperation(request)) {
                    return PermissionResult.allow();
                } else {
                    return PermissionResult.deny("Plan mode: Write operations not allowed");
                }
            },
            .acceptEdits => {
                // Accept edits mode: allow file writes, ask for other operations
                if (isFileWriteOperation(request)) {
                    return PermissionResult.allow();
                }
                // Fall through to normal evaluation
            },
            .dontAsk => {
                // Don't ask mode: use default action or deny
                const action = self.evaluateRules(request);
                if (action == .ask) {
                    return PermissionResult{ .action = self.config.default_action };
                }
                return PermissionResult{ .action = action };
            },
            .default => {
                // Default mode: normal evaluation
            },
        }

        // Check for auto-approval (Crush/OpenCode pattern)
        if (self.isAutoApproved(request)) {
            return PermissionResult.autoAllow();
        }

        // Evaluate against rules (OpenCode pattern matching)
        const final_action = self.evaluateRules(request);

        return PermissionResult{ .action = final_action };
    }

    /// Check if operation is auto-approved
    fn isAutoApproved(self: *const PermissionEvaluator, request: *const PermissionRequest) bool {
        // Check session auto-approval (Crush pattern)
        if (request.context) |ctx| {
            if (ctx.object.get("session_id")) |session_val| {
                if (session_val.string) |session_id| {
                    if (self.config.isSessionAutoApproved(session_id)) {
                        return true;
                    }
                }
            }
        }

        // Check operation auto-approval (OpenCode pattern)
        const operation_id = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ request.tool_name, request.action }) catch return false;
        defer self.allocator.free(operation_id);

        return self.config.isOperationAutoApproved(operation_id);
    }

    /// Evaluate rules and return final action (OpenCode pattern)
    fn evaluateRules(self: *const PermissionEvaluator, request: *const PermissionRequest) PermissionAction {
        var matched_action: PermissionAction = self.config.default_action;
        var matched_rule: ?*const PermissionRule = null;

        // Check all rules, last match wins (OpenCode pattern)
        for (self.config.rules.items) |*rule| {
            if (self.matchesPattern(request, rule)) {
                matched_action = rule.action;
                matched_rule = rule;
            }
        }

        // Create result with matched rule
        var result = PermissionResult{ .action = matched_action };
        if (matched_rule) |rule| {
            result.matched_rule = rule;
        }

        return matched_action;
    }

    /// Check if request matches a rule pattern (OpenCode wildcard matching)
    fn matchesPattern(self: *const PermissionEvaluator, request: *const PermissionRequest, rule: *const PermissionRule) bool {
        _ = self;

        // Match against permission_id (tool:action format)
        if (wildcardMatch(request.permission_id, rule.pattern)) {
            return true;
        }

        // Match against tool name
        if (wildcardMatch(request.tool_name, rule.pattern)) {
            return true;
        }

        // Match against action
        if (wildcardMatch(request.action, rule.pattern)) {
            return true;
        }

        return false;
    }

    /// Apply permission mode to a request (Claude Code pattern)
    pub fn applyMode(self: *const PermissionEvaluator, request: *const PermissionRequest, result: *PermissionResult) void {
        switch (self.config.mode) {
            .plan => {
                // Plan mode overrides: deny all writes
                if (!isReadOperation(request)) {
                    result.action = .deny;
                    result.error_message = "Plan mode: Write operations not allowed";
                }
            },
            .acceptEdits => {
                // Accept edits mode: auto-allow file writes
                if (isFileWriteOperation(request)) {
                    result.action = .allow;
                    result.auto_approved = true;
                }
            },
            else => {
                // Other modes handled in evaluate()
            },
        }
    }

    /// Check if a string matches a wildcard pattern (* and ?)
    pub fn wildcardMatch(str: []const u8, pattern: []const u8) bool {
        var str_idx: usize = 0;
        var pat_idx: usize = 0;
        var star_pos: ?usize = null;
        var str_star_pos: usize = 0;

        while (str_idx < str.len) {
            if (pat_idx < pattern.len and (pattern[pat_idx] == '?' or pattern[pat_idx] == str[str_idx])) {
                // Characters match or '?' wildcard
                str_idx += 1;
                pat_idx += 1;
            } else if (pat_idx < pattern.len and pattern[pat_idx] == '*') {
                // '*' wildcard - remember position and try to match rest
                star_pos = pat_idx;
                str_star_pos = str_idx;
                pat_idx += 1;
            } else if (star_pos != null) {
                // Backtrack to last '*' and try longer match
                pat_idx = star_pos.? + 1;
                str_star_pos += 1;
                str_idx = str_star_pos;
            } else {
                // No match
                return false;
            }
        }

        // Skip remaining '*' in pattern
        while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
            pat_idx += 1;
        }

        return pat_idx == pattern.len;
    }
};

/// Check if operation is read-only (Claude Code pattern)
fn isReadOperation(request: *const PermissionRequest) bool {
    const read_actions = [_][]const u8{
        "read", "list", "search", "query", "get",      "find",
        "glob", "grep", "stat",   "info",  "metadata",
    };

    for (read_actions) |action| {
        if (std.mem.eql(u8, request.action, action)) {
            return true;
        }
    }

    // Also check tool-specific read operations
    if (std.mem.eql(u8, request.tool_name, "file") and std.mem.eql(u8, request.action, "read")) {
        return true;
    }
    if (std.mem.eql(u8, request.tool_name, "directory") and std.mem.eql(u8, request.action, "list")) {
        return true;
    }

    return false;
}

/// Check if operation is file write (Claude Code pattern)
fn isFileWriteOperation(request: *const PermissionRequest) bool {
    const write_actions = [_][]const u8{
        "write",  "edit",   "create",   "delete", "remove", "update",
        "modify", "append", "truncate", "rename", "move",   "copy",
    };

    for (write_actions) |action| {
        if (std.mem.eql(u8, request.action, action)) {
            return true;
        }
    }

    // Tool-specific write operations
    if (std.mem.eql(u8, request.tool_name, "file") and
        (std.mem.eql(u8, request.action, "write") or
            std.mem.eql(u8, request.action, "edit")))
    {
        return true;
    }

    return false;
}

/// Create default permission configuration
pub fn createDefaultConfig(allocator: Allocator) !PermissionConfig {
    var config = PermissionConfig.init(allocator);
    errdefer config.deinit();

    // Default safe rules (OpenCode pattern)
    const default_rules = [_]struct { pattern: []const u8, action: PermissionAction, description: ?[]const u8 }{
        // Safe read operations (always allow)
        .{ .pattern = "*:read", .action = .allow, .description = "Allow all read operations" },
        .{ .pattern = "*:list", .action = .allow, .description = "Allow all list operations" },
        .{ .pattern = "*:search", .action = .allow, .description = "Allow all search operations" },
        .{ .pattern = "*:get", .action = .allow, .description = "Allow all get operations" },

        // File operations
        .{ .pattern = "file:read", .action = .allow, .description = "Allow reading files" },
        .{ .pattern = "directory:list", .action = .allow, .description = "Allow listing directories" },

        // Dangerous operations (ask by default)
        .{ .pattern = "*:execute", .action = .ask, .description = "Ask before executing commands" },
        .{ .pattern = "*:write", .action = .ask, .description = "Ask before write operations" },
        .{ .pattern = "*:delete", .action = .ask, .description = "Ask before delete operations" },

        // Specific dangerous tools
        .{ .pattern = "bash:*", .action = .ask, .description = "Ask before any bash operations" },
        .{ .pattern = "shell:*", .action = .ask, .description = "Ask before any shell operations" },
        .{ .pattern = "process:*", .action = .ask, .description = "Ask before any process operations" },

        // Git operations (usually safe)
        .{ .pattern = "git:status", .action = .allow, .description = "Allow git status" },
        .{ .pattern = "git:log", .action = .allow, .description = "Allow git log" },
        .{ .pattern = "git:diff", .action = .allow, .description = "Allow git diff" },
        .{ .pattern = "git:*", .action = .ask, .description = "Ask before other git operations" },
    };

    for (default_rules) |rule_data| {
        var rule = PermissionRule{
            .pattern = try allocator.dupe(u8, rule_data.pattern),
            .action = rule_data.action,
        };

        if (rule_data.description) |desc| {
            rule.description = try allocator.dupe(u8, desc);
        }

        try config.addRule(rule);
    }

    return config;
}

/// Test the permission evaluator
pub fn runTests() !void {
    const allocator = std.heap.page_allocator;

    // Create default config
    var config = try createDefaultConfig(allocator);
    defer config.deinit();

    var evaluator = PermissionEvaluator.init(allocator, config);
    defer evaluator.deinit();

    // Test cases
    const test_cases = [_]struct {
        tool: []const u8,
        action: []const u8,
        expected: PermissionAction,
    }{
        .{ .tool = "file", .action = "read", .expected = .allow },
        .{ .tool = "directory", .action = "list", .expected = .allow },
        .{ .tool = "bash", .action = "execute", .expected = .ask },
        .{ .tool = "file", .action = "write", .expected = .ask },
        .{ .tool = "unknown", .action = "read", .expected = .allow }, // Matches *:read
        .{ .tool = "git", .action = "status", .expected = .allow },
        .{ .tool = "git", .action = "push", .expected = .ask }, // Matches git:*
    };

    std.debug.print("Testing permission evaluator:\n", .{});
    for (test_cases) |test_case| {
        var request = try PermissionRequest.init(test_case.tool, test_case.action, allocator);
        defer request.deinit(allocator);

        const result = evaluator.evaluate(&request);

        const passed = result.action == test_case.expected;
        const status = if (passed) "✓" else "✗";

        std.debug.print("  {s} {s}:{s} -> {s} (expected: {s})\n", .{
            status,
            test_case.tool,
            test_case.action,
            @tagName(result.action),
            @tagName(test_case.expected),
        });

        if (!passed) {
            return error.TestFailed;
        }
    }

    std.debug.print("All tests passed!\n", .{});
}

/// Export test function for build system
pub const test_runner = struct {
    pub fn run() !void {
        try runTests();
    }
};
