/// Plan Mode Handler — propose changes before executing.
///
/// When plan mode is active, the AI proposes changes as numbered steps with
/// risk levels instead of executing tool calls directly. The user can then
/// approve or reject individual steps before execution proceeds.
const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

// ── PlanRisk ──────────────────────────────────────────────────────────────

pub const PlanRisk = enum {
    low,
    medium,
    high,

    pub fn format(self: @This(), writer: anytype) !void {
        const label = switch (self) {
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
        };
        try writer.writeAll(label);
    }
};

// ── PlanStep ──────────────────────────────────────────────────────────────

pub const PlanStep = struct {
    step_number: u32,
    action: []const u8,
    target_file: []const u8,
    risk: PlanRisk,
    description: []const u8,
    tool_name: []const u8,
    tool_args: []const u8,
    approved: bool = false,

    pub fn deinit(self: *PlanStep, allocator: Allocator) void {
        if (self.action.len > 0) allocator.free(self.action);
        if (self.target_file.len > 0) allocator.free(self.target_file);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.tool_args.len > 0) allocator.free(self.tool_args);
    }
};

// ── PlanStatus ────────────────────────────────────────────────────────────

pub const PlanStatus = enum {
    draft,
    approved,
    executing,
    completed,
    cancelled,
};

// ── Plan ──────────────────────────────────────────────────────────────────

pub const Plan = struct {
    allocator: Allocator,
    title: []const u8,
    steps: array_list_compat.ArrayList(PlanStep),
    status: PlanStatus,
    created_at: u64,

    pub fn init(allocator: Allocator, title: []const u8) !Plan {
        return Plan{
            .allocator = allocator,
            .title = try allocator.dupe(u8, title),
            .steps = array_list_compat.ArrayList(PlanStep).init(allocator),
            .status = .draft,
            .created_at = @intCast(std.time.milliTimestamp()),
        };
    }

    pub fn deinit(self: *Plan) void {
        for (self.steps.items) |*step| {
            step.deinit(self.allocator);
        }
        self.steps.deinit();
        self.allocator.free(self.title);
    }

    pub fn addStep(
        self: *Plan,
        action: []const u8,
        target: []const u8,
        risk: PlanRisk,
        desc: []const u8,
        tool: []const u8,
        args: []const u8,
    ) !void {
        const step = PlanStep{
            .step_number = @intCast(self.steps.items.len + 1),
            .action = try self.allocator.dupe(u8, action),
            .target_file = try self.allocator.dupe(u8, target),
            .risk = risk,
            .description = try self.allocator.dupe(u8, desc),
            .tool_name = try self.allocator.dupe(u8, tool),
            .tool_args = try self.allocator.dupe(u8, args),
            .approved = false,
        };
        try self.steps.append(step);
    }

    pub fn approveAll(self: *Plan) void {
        for (self.steps.items) |*step| {
            step.approved = true;
        }
        self.status = .approved;
    }

    pub fn approveStep(self: *Plan, step_num: u32) void {
        for (self.steps.items) |*step| {
            if (step.step_number == step_num) {
                step.approved = true;
                return;
            }
        }
    }

    pub fn rejectStep(self: *Plan, step_num: u32) void {
        for (self.steps.items) |*step| {
            if (step.step_number == step_num) {
                step.approved = false;
                return;
            }
        }
    }

    pub fn getApprovedSteps(self: *Plan) ![]PlanStep {
        var result = array_list_compat.ArrayList(PlanStep).init(self.allocator);
        for (self.steps.items) |step| {
            if (step.approved) {
                try result.append(step);
            }
        }
        return result.toOwnedSlice();
    }

    /// Format the plan as human-readable text
    pub fn format(self: *Plan) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("Plan: {s}\n\n", .{self.title});

        for (self.steps.items) |step| {
            const risk_label: []const u8 = switch (step.risk) {
                .low => "LOW",
                .medium => "MEDIUM",
                .high => "HIGH",
            };
            const status_mark = if (step.approved) "[OK]" else "[  ]";
            try writer.print("Step {d} [{s}] {s} {s}\n", .{ step.step_number, risk_label, status_mark, step.action });
            if (step.target_file.len > 0) {
                try writer.print("  -> {s}\n", .{step.target_file});
            }
            if (step.description.len > 0) {
                try writer.print("  -> {s}\n", .{step.description});
            }
            try writer.print("  Tool: {s}\n\n", .{step.tool_name});
        }

        if (self.status == .draft) {
            try writer.writeAll("Use /plan approve to execute, /plan cancel to discard");
        } else {
            try writer.print("Status: {s}", .{@tagName(self.status)});
        }

        return try buf.toOwnedSlice();
    }
};

// ── PlanMode ──────────────────────────────────────────────────────────────

pub const PlanMode = struct {
    allocator: Allocator,
    active: bool,
    current_plan: ?Plan,
    plans_history: array_list_compat.ArrayList(Plan),

    pub fn init(allocator: Allocator) PlanMode {
        return PlanMode{
            .allocator = allocator,
            .active = false,
            .current_plan = null,
            .plans_history = array_list_compat.ArrayList(Plan).init(allocator),
        };
    }

    pub fn deinit(self: *PlanMode) void {
        if (self.current_plan) |*plan| {
            plan.deinit();
        }
        for (self.plans_history.items) |*plan| {
            plan.deinit();
        }
        self.plans_history.deinit();
    }

    /// Enter plan mode — AI will propose instead of execute
    pub fn enter(self: *PlanMode) void {
        self.active = true;
    }

    /// Exit plan mode
    pub fn exit(self: *PlanMode) void {
        self.active = false;
    }

    /// Create a new plan
    pub fn createPlan(self: *PlanMode, title: []const u8) !*Plan {
        // Archive existing plan if any
        if (self.current_plan) |*existing| {
            try self.plans_history.append(existing.*);
            self.current_plan = null;
        }

        const plan = try Plan.init(self.allocator, title);
        // Store directly — PlanMode doesn't use heap allocation for the plan itself
        self.current_plan = plan;
        return &self.current_plan.?;
    }

    /// Cancel current plan
    pub fn cancelPlan(self: *PlanMode) void {
        if (self.current_plan) |*plan| {
            plan.status = .cancelled;
            plan.deinit();
            self.current_plan = null;
        }
    }

    /// Get status summary for display
    pub fn statusSummary(self: *PlanMode) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        if (self.active) {
            try writer.writeAll("Plan mode: ACTIVE");
        } else {
            try writer.writeAll("Plan mode: OFF");
        }

        if (self.current_plan) |*plan| {
            try writer.print("\nCurrent plan: {s} ({d} steps, {s})", .{
                plan.title,
                plan.steps.items.len,
                @tagName(plan.status),
            });
            // Count approved
            var approved_count: u32 = 0;
            for (plan.steps.items) |step| {
                if (step.approved) approved_count += 1;
            }
            try writer.print("\nApproved: {d}/{d}", .{ approved_count, plan.steps.items.len });
        }

        try writer.print("\nHistory: {d} plans", .{self.plans_history.items.len});

        return try buf.toOwnedSlice();
    }
};

// ── assessRisk ────────────────────────────────────────────────────────────

/// Assess risk level for a tool call based on tool name and arguments.
pub fn assessRisk(tool_name: []const u8, args: []const u8) PlanRisk {
    // Shell commands with destructive keywords → HIGH
    if (std.mem.eql(u8, tool_name, "shell") or std.mem.eql(u8, tool_name, "bash")) {
        const destructive = [_][]const u8{ "rm ", "rm -", "delete", "drop", "rmdir", "truncate", "> /dev/", "mv /tmp" };
        for (destructive) |keyword| {
            if (std.mem.indexOf(u8, args, keyword) != null) {
                return .high;
            }
        }
        return .medium;
    }

    // Write_file (creates new files) → MEDIUM
    if (std.mem.eql(u8, tool_name, "write_file")) {
        return .medium;
    }

    // Edit (modifies existing) → MEDIUM
    if (std.mem.eql(u8, tool_name, "edit")) {
        return .medium;
    }

    // Read-only operations → LOW
    if (std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "glob") or
        std.mem.eql(u8, tool_name, "grep") or
        std.mem.eql(u8, tool_name, "search"))
    {
        return .low;
    }

    // Default to medium for unknown tools
    return .medium;
}

/// Extract a short action description from tool name and arguments.
pub fn extractAction(allocator: Allocator, tool_name: []const u8, args: []const u8) ![]const u8 {
    if (std.mem.eql(u8, tool_name, "edit")) {
        // Try to extract file_path from JSON args
        if (extractJsonStringField(args, "file_path")) |fp| {
            return std.fmt.allocPrint(allocator, "Edit {s}", .{fp});
        }
        if (extractJsonStringField(args, "path")) |fp| {
            return std.fmt.allocPrint(allocator, "Edit {s}", .{fp});
        }
        return allocator.dupe(u8, "Edit file");
    }
    if (std.mem.eql(u8, tool_name, "write_file")) {
        if (extractJsonStringField(args, "path")) |fp| {
            return std.fmt.allocPrint(allocator, "Write {s}", .{fp});
        }
        if (extractJsonStringField(args, "file_path")) |fp| {
            return std.fmt.allocPrint(allocator, "Write {s}", .{fp});
        }
        return allocator.dupe(u8, "Write new file");
    }
    if (std.mem.eql(u8, tool_name, "shell") or std.mem.eql(u8, tool_name, "bash")) {
        // Show first 60 chars of command
        const cmd = if (extractJsonStringField(args, "command")) |cmd| cmd else args;
        const preview = if (cmd.len > 60) cmd[0..60] else cmd;
        return std.fmt.allocPrint(allocator, "Shell: {s}", .{preview});
    }
    if (std.mem.eql(u8, tool_name, "read_file")) {
        if (extractJsonStringField(args, "path")) |fp| {
            return std.fmt.allocPrint(allocator, "Read {s}", .{fp});
        }
        return allocator.dupe(u8, "Read file");
    }
    if (std.mem.eql(u8, tool_name, "glob")) {
        if (extractJsonStringField(args, "pattern")) |pat| {
            return std.fmt.allocPrint(allocator, "Glob: {s}", .{pat});
        }
        return allocator.dupe(u8, "Search files");
    }
    if (std.mem.eql(u8, tool_name, "grep")) {
        if (extractJsonStringField(args, "pattern")) |pat| {
            return std.fmt.allocPrint(allocator, "Grep: {s}", .{pat});
        }
        return allocator.dupe(u8, "Search content");
    }
    return std.fmt.allocPrint(allocator, "{s}", .{tool_name});
}

/// Extract a target file path from tool arguments
pub fn extractTargetFile(args: []const u8) []const u8 {
    if (extractJsonStringField(args, "file_path")) |fp| return fp;
    if (extractJsonStringField(args, "path")) |fp| return fp;
    return "";
}

/// Simple JSON string field extractor — finds "field_name":"value" pattern.
/// Returns the value without quotes. Caller does NOT own the returned slice.
fn extractJsonStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
    // Look for "field_name"
    const full_needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(full_needle);

    const idx = std.mem.indexOf(u8, json, full_needle) orelse return null;
    const rest = json[idx + full_needle.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t' or rest[i] == '\n' or rest[i] == '\r' or rest[i] == ':')) {
        i += 1;
    }
    if (i >= rest.len) return null;

    // Expect opening quote
    if (rest[i] != '"') return null;
    i += 1;

    // Find closing quote (handle escaped quotes)
    const value_start = i;
    while (i < rest.len) {
        if (rest[i] == '"' and (i == 0 or rest[i - 1] != '\\')) {
            break;
        }
        i += 1;
    }
    if (i >= rest.len) return null;

    return rest[value_start..i];
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Plan - init and deinit" {
    var plan = try Plan.init(testing.allocator, "Test plan");
    defer plan.deinit();
    try testing.expectEqualStrings("Test plan", plan.title);
    try testing.expect(plan.steps.items.len == 0);
    try testing.expect(plan.status == .draft);
}

test "Plan - addStep and format" {
    var plan = try Plan.init(testing.allocator, "Refactor auth");
    defer plan.deinit();
    try plan.addStep("Edit src/auth.zig", "src/auth.zig", .medium, "Add error wrapper", "edit", "{}");
    try plan.addStep("Shell: zig build test", "", .low, "Verify tests pass", "shell", "{\"command\":\"zig build test\"}");

    try testing.expectEqual(@as(usize, 2), plan.steps.items.len);
    try testing.expectEqual(@as(u32, 1), plan.steps.items[0].step_number);
    try testing.expectEqual(@as(u32, 2), plan.steps.items[1].step_number);

    const formatted = try plan.format();
    defer testing.allocator.free(formatted);
    try testing.expect(std.mem.indexOf(u8, formatted, "Refactor auth") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Step 1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Step 2") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "MEDIUM") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "LOW") != null);
}

test "Plan - approveAll" {
    var plan = try Plan.init(testing.allocator, "Test");
    defer plan.deinit();
    try plan.addStep("Step 1", "", .low, "", "read_file", "");
    try plan.addStep("Step 2", "", .medium, "", "edit", "");

    plan.approveAll();
    try testing.expect(plan.steps.items[0].approved);
    try testing.expect(plan.steps.items[1].approved);
    try testing.expect(plan.status == .approved);
}

test "Plan - approveStep" {
    var plan = try Plan.init(testing.allocator, "Test");
    defer plan.deinit();
    try plan.addStep("Step 1", "", .low, "", "read_file", "");
    try plan.addStep("Step 2", "", .medium, "", "edit", "");

    plan.approveStep(1);
    try testing.expect(plan.steps.items[0].approved);
    try testing.expect(!plan.steps.items[1].approved);
}

test "Plan - rejectStep" {
    var plan = try Plan.init(testing.allocator, "Test");
    defer plan.deinit();
    try plan.addStep("Step 1", "", .low, "", "read_file", "");

    plan.approveAll();
    plan.rejectStep(1);
    try testing.expect(!plan.steps.items[0].approved);
}

test "Plan - getApprovedSteps returns only approved" {
    var plan = try Plan.init(testing.allocator, "Test");
    defer plan.deinit();
    try plan.addStep("Step 1", "", .low, "", "read_file", "");
    try plan.addStep("Step 2", "", .medium, "", "edit", "");
    try plan.addStep("Step 3", "", .high, "", "shell", "");

    plan.approveStep(1);
    plan.approveStep(3);

    const approved = try plan.getApprovedSteps();
    defer testing.allocator.free(approved);
    try testing.expectEqual(@as(usize, 2), approved.len);
    try testing.expectEqual(@as(u32, 1), approved[0].step_number);
    try testing.expectEqual(@as(u32, 3), approved[1].step_number);
}

test "PlanMode - init and deinit" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();
    try testing.expect(!mode.active);
    try testing.expect(mode.current_plan == null);
}

test "PlanMode - enter and exit" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();

    mode.enter();
    try testing.expect(mode.active);

    mode.exit();
    try testing.expect(!mode.active);
}

test "PlanMode - statusSummary inactive" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();

    const summary = try mode.statusSummary();
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "OFF") != null);
}

test "PlanMode - statusSummary active with plan" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();

    mode.enter();
    var plan = try mode.createPlan("My plan");
    try plan.addStep("Step 1", "", .low, "", "read_file", "");

    const summary = try mode.statusSummary();
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "ACTIVE") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "My plan") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "1 steps") != null);
}

test "PlanMode - createPlan archives existing" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();

    const plan1 = try mode.createPlan("First");
    _ = plan1;
    try testing.expect(mode.plans_history.items.len == 0);

    const plan2 = try mode.createPlan("Second");
    _ = plan2;
    try testing.expect(mode.plans_history.items.len == 1);
    try testing.expectEqualStrings("First", mode.plans_history.items[0].title);
}

test "PlanMode - cancelPlan" {
    var mode = PlanMode.init(testing.allocator);
    defer mode.deinit();

    var plan = try mode.createPlan("To cancel");
    try plan.addStep("Step", "", .low, "", "read", "");
    mode.cancelPlan();
    try testing.expect(mode.current_plan == null);
}

test "assessRisk - shell with rm is high" {
    try testing.expect(assessRisk("shell", "{\"command\":\"rm -rf /tmp/test\"}") == .high);
    try testing.expect(assessRisk("bash", "delete old files") == .high);
    try testing.expect(assessRisk("shell", "ls -la") == .medium);
}

test "assessRisk - write_file is medium" {
    try testing.expect(assessRisk("write_file", "{}") == .medium);
}

test "assessRisk - edit is medium" {
    try testing.expect(assessRisk("edit", "{}") == .medium);
}

test "assessRisk - read operations are low" {
    try testing.expect(assessRisk("read_file", "{}") == .low);
    try testing.expect(assessRisk("glob", "{}") == .low);
    try testing.expect(assessRisk("grep", "{}") == .low);
    try testing.expect(assessRisk("search", "{}") == .low);
}

test "assessRisk - unknown tool is medium" {
    try testing.expect(assessRisk("custom_tool", "{}") == .medium);
}

test "extractJsonStringField - finds value" {
    const result = extractJsonStringField("{\"file_path\": \"/src/main.zig\", \"old\": \"x\"}", "file_path");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/src/main.zig", result.?);
}

test "extractJsonStringField - missing field returns null" {
    const result = extractJsonStringField("{\"other\": \"value\"}", "file_path");
    try testing.expect(result == null);
}

test "extractAction - edit with path" {
    const action = try extractAction(testing.allocator, "edit", "{\"file_path\":\"/src/main.zig\"}");
    defer testing.allocator.free(action);
    try testing.expectEqualStrings("Edit /src/main.zig", action);
}

test "extractAction - shell command" {
    const action = try extractAction(testing.allocator, "shell", "{\"command\":\"zig build test\"}");
    defer testing.allocator.free(action);
    try testing.expect(std.mem.indexOf(u8, action, "Shell:") != null);
    try testing.expect(std.mem.indexOf(u8, action, "zig build test") != null);
}

test "extractTargetFile - finds file_path" {
    const result = extractTargetFile("{\"file_path\":\"/src/foo.zig\"}");
    try testing.expectEqualStrings("/src/foo.zig", result);
}

test "extractTargetFile - finds path" {
    const result = extractTargetFile("{\"path\":\"/src/bar.zig\"}");
    try testing.expectEqualStrings("/src/bar.zig", result);
}

test "extractTargetFile - returns empty when not found" {
    const result = extractTargetFile("{\"command\":\"ls\"}");
    try testing.expectEqualStrings("", result);
}
