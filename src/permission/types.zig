const std = @import("std");
const array_list_compat = @import("array_list_compat");
const json = std.json;

const Allocator = std.mem.Allocator;

/// Permission actions (OpenCode pattern)
pub const PermissionAction = enum {
    /// Allow the operation without asking
    allow,
    /// Deny the operation (block)
    deny,
    /// Ask the user for confirmation
    ask,

    pub fn fromString(str: []const u8) ?PermissionAction {
        return std.meta.stringToEnum(PermissionAction, str);
    }

    pub fn toString(self: PermissionAction) []const u8 {
        return @tagName(self);
    }
};

/// Permission mode (Claude Code pattern)
pub const PermissionMode = enum {
    /// Default mode - use permission rules
    default,
    /// Auto-allow all operations
    auto,
    /// Plan mode - read-only (deny all writes)
    plan,
    /// Accept all file edits without asking
    acceptEdits,
    /// Don't ask for any permissions (use default/deny)
    dontAsk,
    /// Bypass all permission checks
    bypassPermissions,

    pub fn fromString(str: []const u8) ?PermissionMode {
        return std.meta.stringToEnum(PermissionMode, str);
    }

    pub fn toString(self: PermissionMode) []const u8 {
        return @tagName(self);
    }
};

/// Permission rule for pattern matching (OpenCode pattern)
pub const PermissionRule = struct {
    /// Pattern to match (supports wildcards * and ?)
    pattern: []const u8,
    /// Action to take for matched patterns
    action: PermissionAction,
    /// Optional description for the rule
    description: ?[]const u8 = null,

    pub fn deinit(self: *PermissionRule, allocator: Allocator) void {
        allocator.free(self.pattern);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }

    pub fn toJson(self: PermissionRule, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("pattern", .{ .string = self.pattern });
        try obj.put("action", .{ .string = @tagName(self.action) });

        if (self.description) |desc| {
            try obj.put("description", .{ .string = desc });
        }

        return .{ .object = obj };
    }

    pub fn fromJson(allocator: Allocator, value: json.Value) !PermissionRule {
        const obj = value.object;

        const pattern_val = obj.get("pattern") orelse return error.MissingPattern;
        if (pattern_val != .string) return error.InvalidPattern;
        const pattern = pattern_val.string;

        const action_val = obj.get("action") orelse return error.MissingAction;
        if (action_val != .string) return error.InvalidAction;
        const action_str = action_val.string;
        const action = PermissionAction.fromString(action_str) orelse return error.InvalidAction;

        var description: ?[]const u8 = null;
        if (obj.get("description")) |desc_val| {
            if (desc_val == .string) {
                description = try allocator.dupe(u8, desc_val.string);
            }
        }

        return PermissionRule{
            .pattern = try allocator.dupe(u8, pattern),
            .action = action,
            .description = description,
        };
    }
};

/// Permission request for tool/operation
pub const PermissionRequest = struct {
    /// Tool name (e.g., "bash", "file.write")
    tool_name: []const u8,
    /// Action being requested (e.g., "execute", "write")
    action: []const u8,
    /// Full permission identifier (tool:action format from Crush)
    permission_id: []const u8,
    /// Description of what's being done
    description: ?[]const u8 = null,
    /// Additional context for the request
    context: ?json.Value = null,

    pub fn init(tool_name: []const u8, action: []const u8, allocator: Allocator) !PermissionRequest {
        const permission_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ tool_name, action });

        return PermissionRequest{
            .tool_name = try allocator.dupe(u8, tool_name),
            .action = try allocator.dupe(u8, action),
            .permission_id = permission_id,
        };
    }

    pub fn deinit(self: *PermissionRequest, allocator: Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.action);
        allocator.free(self.permission_id);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        if (self.context) |*ctx| {
            // json.Value objects/arrays own their allocations — free them
            switch (ctx.*) {
                .object => |*obj| obj.deinit(),
                .array => |*arr| arr.deinit(),
                else => {},
            }
        }
    }

    pub fn toJson(self: PermissionRequest, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("tool_name", .{ .string = self.tool_name });
        try obj.put("action", .{ .string = self.action });
        try obj.put("permission_id", .{ .string = self.permission_id });

        if (self.description) |desc| {
            try obj.put("description", .{ .string = desc });
        }

        if (self.context) |ctx| {
            try obj.put("context", ctx);
        }

        return .{ .object = obj };
    }
};

/// Permission result from evaluation
pub const PermissionResult = struct {
    /// Final decision (allow/deny/ask)
    action: PermissionAction,
    /// Matched rule (if any)
    matched_rule: ?*const PermissionRule = null,
    /// Whether permission was automatically approved
    auto_approved: bool = false,
    /// Error message if denied
    error_message: ?[]const u8 = null,

    pub fn allow() PermissionResult {
        return PermissionResult{ .action = .allow };
    }

    pub fn deny(error_message: ?[]const u8) PermissionResult {
        return PermissionResult{
            .action = .deny,
            .error_message = error_message,
        };
    }

    pub fn ask() PermissionResult {
        return PermissionResult{ .action = .ask };
    }

    pub fn autoAllow() PermissionResult {
        return PermissionResult{
            .action = .allow,
            .auto_approved = true,
        };
    }

    pub fn toJson(self: PermissionResult, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("action", .{ .string = @tagName(self.action) });
        try obj.put("auto_approved", .{ .bool = self.auto_approved });

        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }

        if (self.matched_rule) |rule| {
            try obj.put("matched_rule", try rule.toJson(allocator));
        }

        return .{ .object = obj };
    }
};

/// Configuration for permission system
pub const PermissionConfig = struct {
    /// Default action when no rules match (OpenCode pattern)
    default_action: PermissionAction = .ask,
    /// Current permission mode (Claude Code pattern)
    mode: PermissionMode = .default,
    /// List of permission rules
    rules: array_list_compat.ArrayList(PermissionRule),
    /// Auto-approved sessions (Crush pattern)
    auto_approved_sessions: array_list_compat.ArrayList([]const u8),
    /// Auto-approved operations (session lineage tracking from OpenCode)
    auto_approved_operations: std.StringHashMap(bool),

    pub fn init(allocator: Allocator) PermissionConfig {
        return PermissionConfig{
            .rules = array_list_compat.ArrayList(PermissionRule).init(allocator),
            .auto_approved_sessions = array_list_compat.ArrayList([]const u8).init(allocator),
            .auto_approved_operations = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *PermissionConfig) void {
        for (self.rules.items) |*rule| {
            rule.deinit(self.rules.allocator);
        }
        self.rules.deinit();

        for (self.auto_approved_sessions.items) |session_id| {
            self.auto_approved_sessions.allocator.free(session_id);
        }
        self.auto_approved_sessions.deinit();

        self.auto_approved_operations.deinit();
    }

    pub fn addRule(self: *PermissionConfig, rule: PermissionRule) !void {
        try self.rules.append(rule);
    }

    pub fn addAutoApprovedSession(self: *PermissionConfig, session_id: []const u8) !void {
        const session_copy = try self.auto_approved_sessions.allocator.dupe(u8, session_id);
        try self.auto_approved_sessions.append(session_copy);
    }

    pub fn isSessionAutoApproved(self: *const PermissionConfig, session_id: []const u8) bool {
        for (self.auto_approved_sessions.items) |approved_id| {
            if (std.mem.eql(u8, approved_id, session_id)) {
                return true;
            }
        }
        return false;
    }

    pub fn addAutoApprovedOperation(self: *PermissionConfig, operation_id: []const u8) !void {
        const op_copy = try self.auto_approved_operations.allocator.dupe(u8, operation_id);
        try self.auto_approved_operations.put(op_copy, true);
    }

    pub fn isOperationAutoApproved(self: *const PermissionConfig, operation_id: []const u8) bool {
        return self.auto_approved_operations.contains(operation_id);
    }

    pub fn toJson(self: PermissionConfig, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("default_action", .{ .string = @tagName(self.default_action) });
        try obj.put("mode", .{ .string = @tagName(self.mode) });

        // Serialize rules
        var rules_array = json.Array.init(allocator);
        defer rules_array.deinit();
        for (self.rules.items) |rule| {
            try rules_array.append(try rule.toJson(allocator));
        }
        try obj.put("rules", .{ .array = rules_array });

        // Serialize auto-approved sessions
        var sessions_array = json.Array.init(allocator);
        defer sessions_array.deinit();
        for (self.auto_approved_sessions.items) |session_id| {
            try sessions_array.append(.{ .string = session_id });
        }
        try obj.put("auto_approved_sessions", .{ .array = sessions_array });

        // Serialize auto-approved operations
        var operations_obj = json.ObjectMap.init(allocator);
        defer operations_obj.deinit();
        var iter = self.auto_approved_operations.iterator();
        while (iter.next()) |entry| {
            try operations_obj.put(entry.key_ptr.*, .{ .bool = entry.value_ptr.* });
        }
        try obj.put("auto_approved_operations", .{ .object = operations_obj });

        return .{ .object = obj };
    }

    pub fn fromJson(allocator: Allocator, value: json.Value) !PermissionConfig {
        const obj = value.object;

        var config = PermissionConfig.init(allocator);
        errdefer config.deinit();

        // Parse default action
        if (obj.get("default_action")) |action_val| {
            if (action_val == .string) {
                config.default_action = PermissionAction.fromString(action_val.string) orelse .ask;
            }
        }

        // Parse mode
        if (obj.get("mode")) |mode_val| {
            if (mode_val == .string) {
                config.mode = PermissionMode.fromString(mode_val.string) orelse .default;
            }
        }

        // Parse rules
        if (obj.get("rules")) |rules_val| {
            if (rules_val == .array) {
                for (rules_val.array.items) |rule_val| {
                    const rule = try PermissionRule.fromJson(allocator, rule_val);
                    try config.rules.append(rule);
                }
            }
        }

        // Parse auto-approved sessions
        if (obj.get("auto_approved_sessions")) |sessions_val| {
            if (sessions_val == .array) {
                for (sessions_val.array.items) |session_val| {
                    if (session_val == .string) {
                        const session_copy = try allocator.dupe(u8, session_val.string);
                        try config.auto_approved_sessions.append(session_copy);
                    }
                }
            }
        }

        // Parse auto-approved operations
        if (obj.get("auto_approved_operations")) |ops_val| {
            if (ops_val == .object) {
                var iter = ops_val.object.iterator();
                while (iter.next()) |entry| {
                    const op_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    const approved = if (entry.value_ptr.* == .bool) entry.value_ptr.*.bool else false;
                    try config.auto_approved_operations.put(op_copy, approved);
                }
            }
        }

        return config;
    }

    /// Returns the full file path for the permissions config file.
    /// Caller must free the returned string.
    pub fn getPermissionFilePath(allocator: Allocator, dir_path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/permissions.json", .{dir_path});
    }

    /// Save the permission configuration to a JSON file on disk.
    /// Creates the directory if it doesn't exist. The file is pretty-printed.
    pub fn saveToFile(self: PermissionConfig, allocator: Allocator, dir_path: []const u8) !void {
        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file_path = try getPermissionFilePath(allocator, dir_path);
        defer allocator.free(file_path);

        var json_value = try self.toJson(allocator);
        defer {
            if (json_value == .object) {
                json_value.object.deinit();
            }
        }

        const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();

        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(&write_buffer);
        try std.json.Stringify.value(json_value, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.flush();
    }

    /// Load a permission configuration from a JSON file on disk.
    /// Returns error.FileNotFound if the file doesn't exist.
    /// Caller owns the returned PermissionConfig and must call deinit().
    pub fn loadFromFile(allocator: Allocator, dir_path: []const u8) !PermissionConfig {
        const file_path = try getPermissionFilePath(allocator, dir_path);
        defer allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(contents);

        const parsed = try json.parseFromSlice(json.Value, allocator, contents, .{});
        defer parsed.deinit();

        return PermissionConfig.fromJson(allocator, parsed.value);
    }
};
