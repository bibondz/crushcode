/// TodoWrite tool — manages a session-scoped todo list for the AI agent.
///
/// Provides create, update, remove, and list operations on todo items.
/// Items have status (pending/in_progress/completed/cancelled) and
/// priority (high/medium/low) tracking.
const std = @import("std");
const json_helpers = @import("json_helpers");
const array_list_compat = @import("array_list_compat");
const core = @import("core_api");

const Allocator = std.mem.Allocator;

pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,
    cancelled,
};

pub const TodoPriority = enum {
    high,
    medium,
    low,
};

pub const TodoItem = struct {
    id: []const u8,
    content: []const u8,
    status: TodoStatus = .pending,
    priority: TodoPriority = .medium,
};

pub const TodoState = struct {
    allocator: Allocator,
    items: array_list_compat.ArrayList(TodoItem),
    initialized: bool = true,
    next_id: u32 = 1,

    pub fn init(allocator: Allocator) TodoState {
        return .{
            .allocator = allocator,
            .items = array_list_compat.ArrayList(TodoItem).init(allocator),
        };
    }

    pub fn deinit(self: *TodoState) void {
        for (self.items.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.content);
        }
        self.items.deinit();
        self.initialized = false;
    }

    pub fn addItem(self: *TodoState, item: TodoItem) !void {
        const owned_id = try self.allocator.dupe(u8, item.id);
        const owned_content = try self.allocator.dupe(u8, item.content);
        try self.items.append(.{
            .id = owned_id,
            .content = owned_content,
            .status = item.status,
            .priority = item.priority,
        });
    }

    pub fn updateItem(self: *TodoState, id: []const u8, status: ?TodoStatus, priority: ?TodoPriority) !void {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) {
                if (status) |s| item.status = s;
                if (priority) |p| item.priority = p;
                return;
            }
        }
        return error.NotFound;
    }

    pub fn removeItem(self: *TodoState, id: []const u8) !void {
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.id, id)) {
                self.allocator.free(item.id);
                self.allocator.free(item.content);
                _ = self.items.orderedRemove(i);
                return;
            }
        }
        return error.NotFound;
    }

    pub fn listItems(self: *const TodoState) []const TodoItem {
        return self.items.items;
    }

    pub fn generateId(self: *TodoState) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "todo_{d}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    pub fn findItem(self: *const TodoState, id: []const u8) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.id, id)) return i;
        }
        return null;
    }
};

/// Global singleton todo state for the session.
var g_todo_state: ?TodoState = null;

pub fn initTodoState(allocator: Allocator) void {
    if (g_todo_state == null) {
        g_todo_state = TodoState.init(allocator);
    }
}

pub fn deinitTodoState() void {
    if (g_todo_state) |*state| {
        state.deinit();
        g_todo_state = null;
    }
}

fn getOrCreateState(allocator: Allocator) *TodoState {
    if (g_todo_state) |*state| return state;
    initTodoState(allocator);
    return &g_todo_state.?;
}

/// Parse a status string into TodoStatus enum.
fn parseStatus(str: []const u8) ?TodoStatus {
    if (std.mem.eql(u8, str, "pending")) return .pending;
    if (std.mem.eql(u8, str, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, str, "completed")) return .completed;
    if (std.mem.eql(u8, str, "cancelled")) return .cancelled;
    return null;
}

/// Parse a priority string into TodoPriority enum.
fn parsePriority(str: []const u8) ?TodoPriority {
    if (std.mem.eql(u8, str, "high")) return .high;
    if (std.mem.eql(u8, str, "medium")) return .medium;
    if (std.mem.eql(u8, str, "low")) return .low;
    return null;
}

const extractJsonStringField = json_helpers.extractJsonStringField;

/// Format status indicator for display.
fn statusIndicator(status: TodoStatus) []const u8 {
    return switch (status) {
        .completed => "\xe2\x9c\x85", // ✅
        .in_progress => "\xf0\x9f\x94\x84", // 🔄
        .pending => "\xe2\xac\x9c", // ⬜
        .cancelled => "\xe2\x9d\x8c", // ❌
    };
}

/// Format priority label for display.
fn priorityLabel(priority: TodoPriority) []const u8 {
    return switch (priority) {
        .high => "high",
        .medium => "medium",
        .low => "low",
    };
}

/// Execute the TodoWrite tool.
pub fn executeTodoWriteTool(allocator: Allocator, parsed: core.ParsedToolCall) anyerror!struct { display: []const u8, result: []const u8 } {
    const args = parsed.arguments;
    const state = getOrCreateState(allocator);

    // Find the "todos" array in the arguments JSON
    const todos_key = "\"todos\"";
    const todos_pos = std.mem.indexOf(u8, args, todos_key) orelse
        return error.InvalidJson;

    const after_key = args[todos_pos + todos_key.len ..];

    // Find opening [
    var bracket_pos: usize = 0;
    while (bracket_pos < after_key.len and after_key[bracket_pos] != '[') bracket_pos += 1;
    if (bracket_pos >= after_key.len) return error.InvalidJson;

    const array_content = after_key[bracket_pos + 1 ..];

    // Parse each { ... } block
    var i: usize = 0;
    var processed: u32 = 0;
    while (i < array_content.len) {
        // Find next {
        while (i < array_content.len and array_content[i] != '{') {
            if (array_content[i] == ']') break;
            i += 1;
        }
        if (i >= array_content.len or array_content[i] == ']') break;

        const block_start = i;
        var depth: u32 = 1;
        i += 1;
        while (i < array_content.len and depth > 0) {
            if (array_content[i] == '{') depth += 1;
            if (array_content[i] == '}') depth -= 1;
            if (array_content[i] == '"') {
                i += 1;
                while (i < array_content.len and array_content[i] != '"') {
                    if (array_content[i] == '\\' and i + 1 < array_content.len) i += 1;
                    i += 1;
                }
            }
            i += 1;
        }
        const block = array_content[block_start..i];

        // Extract fields
        const content_str = extractJsonStringField(block, "content") orelse continue;
        const id_str = extractJsonStringField(block, "id");
        const status_str = extractJsonStringField(block, "status");
        const priority_str = extractJsonStringField(block, "priority");

        const status = if (status_str) |s| parseStatus(s) orelse .pending else .pending;
        const priority = if (priority_str) |p| parsePriority(p) orelse .medium else .medium;

        if (id_str) |existing_id| {
            // Update existing item if found
            if (state.findItem(existing_id)) |_| {
                state.updateItem(existing_id, status, priority) catch {};
            } else {
                // ID not found — create new with that ID
                try state.addItem(.{
                    .id = existing_id,
                    .content = content_str,
                    .status = status,
                    .priority = priority,
                });
            }
        } else {
            // Create new item with auto-generated ID
            const new_id = try state.generateId();
            try state.addItem(.{
                .id = new_id,
                .content = content_str,
                .status = status,
                .priority = priority,
            });
        }

        processed += 1;
    }

    // Build formatted summary of all current items
    var buf = array_list_compat.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    const items = state.listItems();
    try writer.print("Todo list updated ({d} items):\n", .{items.len});

    // Sort by priority for display: high first, then medium, then low
    // Build sorted indices
    const priority_order = [_]TodoPriority{ .high, .medium, .low };
    for (&priority_order) |prio| {
        for (items) |item| {
            if (item.priority == prio) {
                try writer.print("{s} [{s}] {s}\n", .{
                    statusIndicator(item.status),
                    priorityLabel(item.priority),
                    item.content,
                });
            }
        }
    }

    const summary = try allocator.dupe(u8, buf.items);
    const display = try std.fmt.allocPrint(allocator, "\xf0\x9f\x93\x8b todo_write → {d} items processed, {d} total\n", .{ processed, items.len });

    return .{
        .display = display,
        .result = summary,
    };
}
