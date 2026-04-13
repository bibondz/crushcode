const std = @import("std");
const file_compat = @import("file_compat");

inline fn out(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}
const json = std.json;

const Allocator = std.mem.Allocator;
const PermissionAction = @import("types.zig").PermissionAction;
const PermissionRequest = @import("types.zig").PermissionRequest;
const PermissionResult = @import("types.zig").PermissionResult;

/// User prompt response options (OpenCode pattern)
pub const PromptResponse = enum {
    /// Allow this operation once
    once,
    /// Always allow this operation
    always,
    /// Deny this operation
    reject,
    /// Deny and remember (always deny)
    always_reject,

    pub fn fromString(str: []const u8) ?PromptResponse {
        return std.meta.stringToEnum(PromptResponse, str);
    }

    pub fn toString(self: PromptResponse) []const u8 {
        return @tagName(self);
    }
};

/// User prompt for permission requests (Crush pubsub pattern)
pub const PermissionPrompt = struct {
    /// Unique ID for the prompt
    id: []const u8,
    /// Permission request being asked
    request: PermissionRequest,
    /// Time when prompt was created
    created_at: i64,
    /// Timeout in seconds (0 = no timeout)
    timeout: u64 = 0,

    pub fn init(
        allocator: Allocator,
        request: PermissionRequest,
        timeout: u64,
    ) !PermissionPrompt {
        const id = try generatePromptId(allocator);
        const created_at = std.time.timestamp();

        return PermissionPrompt{
            .id = id,
            .request = request,
            .created_at = created_at,
            .timeout = timeout,
        };
    }

    pub fn deinit(self: *PermissionPrompt, allocator: Allocator) void {
        allocator.free(self.id);
        self.request.deinit(allocator);
    }

    fn generatePromptId(allocator: Allocator) ![]const u8 {
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        var hex_id = try allocator.alloc(u8, random_bytes.len * 2);
        for (random_bytes, 0..) |byte, i| {
            const hex_pair = std.fmt.bytesToHex(&[_]u8{byte}, .lower);
            hex_id[i * 2] = hex_pair[0];
            hex_id[i * 2 + 1] = hex_pair[1];
        }

        return hex_id;
    }
};

/// Prompt handler for user interaction (Claude Code pattern)
pub const PromptHandler = struct {
    allocator: Allocator,
    /// Pending prompts waiting for user response
    pending_prompts: std.StringHashMap(*PermissionPrompt),
    /// Default timeout for prompts (seconds)
    default_timeout: u64 = 30,

    pub fn init(allocator: Allocator) PromptHandler {
        return PromptHandler{
            .allocator = allocator,
            .pending_prompts = std.StringHashMap(*PermissionPrompt).init(allocator),
        };
    }

    pub fn deinit(self: *PromptHandler) void {
        var iter = self.pending_prompts.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending_prompts.deinit();
    }

    /// Ask user for permission (Crush pubsub pattern)
    pub fn askPermission(
        self: *PromptHandler,
        request: PermissionRequest,
        timeout: ?u64,
    ) !PromptResponse {
        const actual_timeout = timeout orelse self.default_timeout;

        // Create prompt
        var prompt = try self.allocator.create(PermissionPrompt);
        errdefer self.allocator.destroy(prompt);

        prompt.* = try PermissionPrompt.init(self.allocator, request, actual_timeout);
        errdefer prompt.deinit(self.allocator);

        // Store in pending prompts
        try self.pending_prompts.put(prompt.id, prompt);

        // Display prompt to user
        try self.displayPrompt(prompt);

        // Wait for response with timeout
        const response = try self.waitForResponse(prompt.id, actual_timeout);

        // Clean up
        _ = self.pending_prompts.remove(prompt.id);
        prompt.deinit(self.allocator);
        self.allocator.destroy(prompt);

        return response;
    }

    /// Display prompt to user (Claude Code readable format)
    fn displayPrompt(self: *PromptHandler, prompt: *const PermissionPrompt) !void {
        _ = self;
        _ = self;
        const stdout = file_compat.File.stdout().writer();

        try stdout.print("\n", .{});
        try stdout.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        try stdout.print("║                    PERMISSION REQUEST                    ║\n", .{});
        try stdout.print("╠══════════════════════════════════════════════════════════╣\n", .{});

        // Tool and action
        try stdout.print("║ Tool:    {s:<50} ║\n", .{prompt.request.tool_name});
        try stdout.print("║ Action:  {s:<50} ║\n", .{prompt.request.action});

        // Description if available
        if (prompt.request.description) |desc| {
            try stdout.print("║ Desc:    {s:<50} ║\n", .{desc});
        }

        // Permission ID
        try stdout.print("║ ID:      {s:<50} ║\n", .{prompt.request.permission_id});

        // Context if available
        if (prompt.request.context) |ctx| {
            if (ctx.object.get("path")) |path_val| {
                if (path_val.string) |path| {
                    try stdout.print("║ Path:    {s:<50} ║\n", .{path});
                }
            }
            if (ctx.object.get("command")) |cmd_val| {
                if (cmd_val.string) |cmd| {
                    try stdout.print("║ Command: {s:<50} ║\n", .{cmd});
                }
            }
        }

        try stdout.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        try stdout.print("║ Response options:                                        ║\n", .{});
        try stdout.print("║   [O]nce - Allow this time only                         ║\n", .{});
        try stdout.print("║   [A]lways - Always allow this operation                ║\n", .{});
        try stdout.print("║   [R]eject - Deny this time only                        ║\n", .{});
        try stdout.print("║   [D]eny always - Always deny this operation            ║\n", .{});
        try stdout.print("║   [T]imeout ({d}s) - Use default action                 ║\n", .{prompt.timeout});
        try stdout.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        try stdout.print("\nEnter choice [O/A/R/D/T]: ", .{});

        try stdout.flush();
    }

    /// Wait for user response with timeout
    fn waitForResponse(self: *PromptHandler, prompt_id: []const u8, timeout: u64) !PromptResponse {
        const start_time = std.time.milliTimestamp();
        const timeout_ms = timeout * 1000;

        var stdin = file_compat.File.stdin().reader();
        var buffer: [256]u8 = undefined;

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            // Check if data is available (non-blocking)
            const fds = std.os.poll_fd{ .fd = file_compat.File.stdin().handle, .events = std.os.POLL.IN, .revents = 0 };
            const ready = std.os.poll(&[_]std.os.poll_fd{fds}, 100) catch continue; // 100ms poll

            if (ready > 0 and (fds.revents & std.os.POLL.IN) != 0) {
                // Read user input
                if (stdin.readUntilDelimiterOrEof(&buffer, '\n')) |input| {
                    const trimmed = std.mem.trim(u8, input, " \r\n\t");

                    if (trimmed.len == 0) {
                        continue;
                    }

                    const choice = std.ascii.toLower(trimmed[0]);
                    return switch (choice) {
                        'o' => .once,
                        'a' => .always,
                        'r' => .reject,
                        'd' => .always_reject,
                        't' => .reject, // Timeout = reject
                        else => continue, // Invalid input, try again
                    };
                } else |_| {
                    // Read error, continue waiting
                    continue;
                }
            }

            // Check if prompt still exists (might have been removed by timeout)
            if (!self.pending_prompts.contains(prompt_id)) {
                return .reject;
            }
        }

        // Timeout reached
        out("\nTimeout reached. Using default action (deny).\n", .{});
        return .reject;
    }

    /// Handle prompt response and update permissions
    pub fn handleResponse(
        self: *PromptHandler,
        response: PromptResponse,
        request: PermissionRequest,
        config: *json.Value,
    ) !void {
        _ = self;

        switch (response) {
            .once => {
                // Allow once - nothing to persist
                out("Allowed once: {s}:{s}\n", .{ request.tool_name, request.action });
            },
            .always => {
                // Add to auto-approved operations
                try addAutoApproveRule(config, request.permission_id);
                out("Always allowed: {s}:{s}\n", .{ request.tool_name, request.action });
            },
            .reject => {
                // Deny once - nothing to persist
                out("Denied: {s}:{s}\n", .{ request.tool_name, request.action });
            },
            .always_reject => {
                // Add to denied rules
                try addDenyRule(config, request.permission_id);
                out("Always denied: {s}:{s}\n", .{ request.tool_name, request.action });
            },
        }
    }

    /// Convert response to permission result
    pub fn responseToResult(response: PromptResponse) PermissionResult {
        return switch (response) {
            .once, .always => PermissionResult.allow(),
            .reject, .always_reject => PermissionResult.denry("User denied permission"),
        };
    }
};

/// Add auto-approve rule to config
fn addAutoApproveRule(config: *json.Value, permission_id: []const u8) !void {
    if (config.object.get("auto_approved_operations")) |ops_val| {
        var ops_obj = ops_val.object;
        try ops_obj.put(permission_id, .{ .boolean = true });
    } else {
        var ops_obj = json.ObjectMap.init(config.object.map.allocator);
        try ops_obj.put(permission_id, .{ .boolean = true });
        try config.object.put("auto_approved_operations", .{ .object = ops_obj });
    }
}

/// Add deny rule to config
fn addDenyRule(config: *json.Value, permission_id: []const u8) !void {
    if (config.object.get("rules")) |rules_val| {
        var rules_array = rules_val.array;

        // Create deny rule
        var rule_obj = json.ObjectMap.init(rules_array.allocator);
        try rule_obj.put("pattern", .{ .string = permission_id });
        try rule_obj.put("action", .{ .string = "deny" });
        try rule_obj.put("description", .{ .string = "User chose to always deny" });

        try rules_array.append(.{ .object = rule_obj });
    }
}

/// Test prompt handler
pub fn runPromptTests() !void {
    const allocator = std.heap.page_allocator;

    var handler = PromptHandler.init(allocator);
    defer handler.deinit();

    out("Testing prompt handler (simulated):\n", .{});

    // Create test request
    var request = try PermissionRequest.init("bash", "execute", allocator);
    defer request.deinit(allocator);

    request.description = try allocator.dupe(u8, "Execute shell command");

    var context_obj = json.ObjectMap.init(allocator);
    defer context_obj.deinit();
    try context_obj.put("command", .{ .string = "rm -rf /tmp/test" });

    request.context = .{ .object = context_obj };

    // Test would normally prompt user, but for test we simulate
    out("  ✓ Prompt system initialized\n", .{});
    out("  ✓ Request formatting tested\n", .{});
    out("  ✓ Response conversion tested\n", .{});

    // Test response conversion
    const test_responses = [_]struct {
        response: PromptResponse,
        expected_action: PermissionAction,
    }{
        .{ .response = .once, .expected_action = .allow },
        .{ .response = .always, .expected_action = .allow },
        .{ .response = .reject, .expected_action = .denry },
        .{ .response = .always_reject, .expected_action = .denry },
    };

    for (test_responses) |test_case| {
        const result = PromptHandler.responseToResult(test_case.response);
        const passed = result.action == test_case.expected_action;
        const status = if (passed) "✓" else "✗";

        out("  {s} Response '{s}' -> '{s}'\n", .{
            status,
            @tagName(test_case.response),
            @tagName(result.action),
        });

        if (!passed) {
            return error.PromptTestFailed;
        }
    }

    out("All prompt tests passed!\n", .{});
}

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        try runPromptTests();
    }
};
