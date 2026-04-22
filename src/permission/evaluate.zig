const std = @import("std");
const json = std.json;

const Allocator = std.mem.Allocator;
pub const PermissionAction = @import("types.zig").PermissionAction;
pub const PermissionMode = @import("types.zig").PermissionMode;
pub const PermissionRule = @import("types.zig").PermissionRule;
pub const PermissionRequest = @import("types.zig").PermissionRequest;
pub const PermissionResult = @import("types.zig").PermissionResult;
pub const PermissionConfig = @import("types.zig").PermissionConfig;
pub const SecurityChecker = @import("security.zig").SecurityChecker;
pub const PermissionPrompt = @import("prompt.zig").PermissionPrompt;
pub const PromptResponse = @import("prompt.zig").PromptResponse;
pub const PromptHandler = @import("prompt.zig").PromptHandler;
const tool_classifier = @import("tool_classifier.zig");
const auto_classifier_mod = @import("auto_classifier.zig");
pub const AutoClassifier = auto_classifier_mod.AutoClassifier;
pub const RiskTier = auto_classifier_mod.RiskTier;

/// Permission evaluator implementing OpenCode's pattern matching logic
pub const PermissionEvaluator = struct {
    allocator: Allocator,
    config: PermissionConfig,
    auto_classifier: ?*AutoClassifier = null,

    pub fn init(allocator: Allocator, config: PermissionConfig) PermissionEvaluator {
        return PermissionEvaluator{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *PermissionEvaluator) void {
        self.config.deinit();
    }

    /// Attach an auto-classifier for enhanced auto mode decisions.
    pub fn setAutoClassifier(self: *PermissionEvaluator, classifier: *AutoClassifier) void {
        self.auto_classifier = classifier;
    }

    /// Evaluate permission request against rules (OpenCode pattern)
    /// Returns the last matching rule's action (last-match-wins)
    pub fn evaluate(self: *const PermissionEvaluator, request: *const PermissionRequest) PermissionResult {
        // Check permission mode first (Claude Code pattern)
        switch (self.config.mode) {
            .bypassPermissions => return PermissionResult.allow(),
            .auto => {
                // Auto-classifier check (enhanced auto mode): if the
                // classifier is attached and considers this operation safe
                // based on transcript history, auto-approve.
                if (self.auto_classifier) |classifier| {
                    const args = request.description orelse "";
                    if (classifier.shouldAutoApprove(request.tool_name, args)) {
                        return PermissionResult.autoAllow();
                    }
                }
                // Fallback: blanket auto-allow for plain auto mode.
                return PermissionResult.autoAllow();
            },
            .plan => {
                // Plan mode: strict read-only — block ALL write operations.
                if (isReadOperation(request)) {
                    return PermissionResult.allow();
                }
                // Build a descriptive denial message.
                const msg = std.fmt.allocPrint(self.allocator, "Plan mode: '{s}' is a write operation. Switch modes with /mode default", .{request.tool_name}) catch
                    "Plan mode: Write operations not allowed";
                return PermissionResult{ .action = .deny, .error_message = msg };
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

        // Check always-allow tools (session memory)
        if (self.config.isToolAlwaysAllowed(request.tool_name)) {
            return PermissionResult.autoAllow();
        }

        // Get tool risk tier for graduated permissions
        const tier = tool_classifier.classifyTool(request.tool_name);

        // Classification provides baseline action (rules override below)
        const classification_action: PermissionAction = switch (tier) {
            .read => .allow,
            .write, .destructive => .ask,
        };

        // Evaluate against rules (last-match-wins, overrides classification)
        var final_action: PermissionAction = classification_action;
        for (self.config.rules.items) |*rule| {
            if (self.matchesPattern(request, rule)) {
                final_action = rule.action;
            }
        }

        var result = PermissionResult{ .action = final_action };

        // Enhanced warning for destructive tier tools
        if (tier == .destructive and final_action == .ask) {
            result.error_message = "Destructive operation: proceed with caution";
        }

        return result;
    }

    /// Check if operation is auto-approved
    fn isAutoApproved(self: *const PermissionEvaluator, request: *const PermissionRequest) bool {
        // Check session auto-approval (Crush pattern)
        if (request.context) |ctx| {
            if (ctx.object.get("session_id")) |session_val| {
                if (session_val == .string) {
                    const session_id = session_val.string;
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
                // Plan mode overrides: deny all writes with descriptive message
                if (!isReadOperation(request)) {
                    result.action = .deny;
                    const msg = std.fmt.allocPrint(self.allocator, "Plan mode: '{s}' is a write operation. Switch modes with /mode default", .{request.tool_name}) catch
                        "Plan mode: Write operations not allowed";
                    result.error_message = msg;
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
    // Use tool classifier for known read-only tools
    if (tool_classifier.isReadOnlyTool(request.tool_name)) {
        return true;
    }

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
    // Use tool classifier for write-tier tools
    const tier = tool_classifier.classifyTool(request.tool_name);
    if (tier == .write) {
        return true;
    }

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

        // Tool classification rules (16 builtin tools)
        // Read tools: always allow
        .{ .pattern = "read_file:*", .action = .allow, .description = "Allow read_file tool" },
        .{ .pattern = "glob:*", .action = .allow, .description = "Allow glob tool" },
        .{ .pattern = "grep:*", .action = .allow, .description = "Allow grep tool" },
        .{ .pattern = "list_directory:*", .action = .allow, .description = "Allow list_directory tool" },
        .{ .pattern = "file_info:*", .action = .allow, .description = "Allow file_info tool" },
        .{ .pattern = "git_status:*", .action = .allow, .description = "Allow git_status tool" },
        .{ .pattern = "git_diff:*", .action = .allow, .description = "Allow git_diff tool" },
        .{ .pattern = "git_log:*", .action = .allow, .description = "Allow git_log tool" },
        .{ .pattern = "search_files:*", .action = .allow, .description = "Allow search_files tool" },

        // Write tools: ask user
        .{ .pattern = "write_file:*", .action = .ask, .description = "Ask before write_file" },
        .{ .pattern = "create_file:*", .action = .ask, .description = "Ask before create_file" },
        .{ .pattern = "edit:*", .action = .ask, .description = "Ask before edit" },
        .{ .pattern = "move_file:*", .action = .ask, .description = "Ask before move_file" },
        .{ .pattern = "copy_file:*", .action = .ask, .description = "Ask before copy_file" },

        // Destructive tools: ask with warning
        .{ .pattern = "delete_file:*", .action = .ask, .description = "Ask before delete_file" },
        .{ .pattern = "shell:*", .action = .ask, .description = "Ask before shell" },
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

    std.log.info("Testing permission evaluator:", .{});
    for (test_cases) |test_case| {
        var request = try PermissionRequest.init(test_case.tool, test_case.action, allocator);
        defer request.deinit(allocator);

        const result = evaluator.evaluate(&request);

        const passed = result.action == test_case.expected;
        const status = if (passed) "✓" else "✗";

        std.log.info("  {s} {s}:{s} -> {s} (expected: {s})", .{
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

    std.log.info("All tests passed!", .{});
}

/// Test classification-based evaluation
pub fn runClassificationTests() !void {
    const allocator = std.heap.page_allocator;

    // Test 1: Read-tier tools are auto-allowed via classification
    {
        var config = try createDefaultConfig(allocator);
        defer config.deinit();
        var evaluator = PermissionEvaluator.init(allocator, config);
        defer evaluator.deinit();

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

        std.log.info("Testing classification-based read tool evaluation:", .{});
        for (read_tools) |tool| {
            var request = try PermissionRequest.init(tool, "execute", allocator);
            defer request.deinit(allocator);

            const result = evaluator.evaluate(&request);
            if (result.action != .allow) {
                std.log.err("  Expected allow for read tool '{s}', got {s}", .{ tool, @tagName(result.action) });
                return error.TestFailed;
            }
            std.log.info("  ✓ {s}:execute -> allow (classification)", .{tool});
        }
    }

    // Test 2: Write-tier tools ask via classification
    {
        var config = try createDefaultConfig(allocator);
        defer config.deinit();
        var evaluator = PermissionEvaluator.init(allocator, config);
        defer evaluator.deinit();

        const write_tools = [_][]const u8{
            "write_file",
            "create_file",
            "edit",
            "move_file",
            "copy_file",
        };

        std.log.info("Testing classification-based write tool evaluation:", .{});
        for (write_tools) |tool| {
            var request = try PermissionRequest.init(tool, "execute", allocator);
            defer request.deinit(allocator);

            const result = evaluator.evaluate(&request);
            if (result.action != .ask) {
                std.log.err("  Expected ask for write tool '{s}', got {s}", .{ tool, @tagName(result.action) });
                return error.TestFailed;
            }
            std.log.info("  ✓ {s}:execute -> ask (classification)", .{tool});
        }
    }

    // Test 3: Destructive-tier tools ask with warning
    {
        var config = try createDefaultConfig(allocator);
        defer config.deinit();
        var evaluator = PermissionEvaluator.init(allocator, config);
        defer evaluator.deinit();

        const destructive_tools = [_][]const u8{
            "delete_file",
            "shell",
        };

        std.log.info("Testing classification-based destructive tool evaluation:", .{});
        for (destructive_tools) |tool| {
            var request = try PermissionRequest.init(tool, "execute", allocator);
            defer request.deinit(allocator);

            const result = evaluator.evaluate(&request);
            if (result.action != .ask) {
                std.log.err("  Expected ask for destructive tool '{s}', got {s}", .{ tool, @tagName(result.action) });
                return error.TestFailed;
            }
            // Verify enhanced warning for destructive tools
            if (result.error_message == null) {
                std.log.err("  Expected error_message for destructive tool '{s}'", .{tool});
                return error.TestFailed;
            }
            std.log.info("  ✓ {s}:execute -> ask with warning (classification)", .{tool});
        }
    }

    // Test 4: Always-allow session memory
    {
        var config = try createDefaultConfig(allocator);
        defer config.deinit();

        // Add write_file to always-allow list
        try config.addAlwaysAllowTool("write_file");
        try std.testing.expect(config.isToolAlwaysAllowed("write_file") == true);
        try std.testing.expect(config.isToolAlwaysAllowed("shell") == false);

        var evaluator = PermissionEvaluator.init(allocator, config);
        defer evaluator.deinit();

        var request = try PermissionRequest.init("write_file", "write", allocator);
        defer request.deinit(allocator);

        const result = evaluator.evaluate(&request);
        if (result.action != .allow or !result.auto_approved) {
            std.log.err("  Expected auto-allow for always-allowed tool, got {s} auto_approved={}", .{ @tagName(result.action), result.auto_approved });
            return error.TestFailed;
        }
        std.log.info("  ✓ write_file:write -> auto-allow (always-allow session memory)", .{});
    }

    // Test 5: Rules can override classification
    {
        var config = PermissionConfig.init(allocator);
        defer config.deinit();

        // Add a rule that explicitly denies a read tool
        const pattern = try allocator.dupe(u8, "read_file:*");
        try config.addRule(.{
            .pattern = pattern,
            .action = .deny,
            .description = try allocator.dupe(u8, "Deny read_file for testing"),
        });

        var evaluator = PermissionEvaluator.init(allocator, config);
        defer evaluator.deinit();

        var request = try PermissionRequest.init("read_file", "read", allocator);
        defer request.deinit(allocator);

        const result = evaluator.evaluate(&request);
        if (result.action != .deny) {
            std.log.err("  Expected deny (rule override), got {s}", .{@tagName(result.action)});
            return error.TestFailed;
        }
        std.log.info("  ✓ read_file:read -> deny (rule overrides classification)", .{});
    }

    std.log.info("All classification tests passed!", .{});
}

/// Export test function for build system
pub const test_runner = struct {
    pub fn run() !void {
        try runTests();
    }
};
