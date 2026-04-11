const std = @import("std");

const Allocator = std.mem.Allocator;

/// Hook tier — determines when and how hooks execute
pub const HookTier = enum {
    core, // 43 core hooks — always active
    continuation, // 7 continuation hooks — task continuation
    skill, // 2 skill hooks — skill-specific
};

/// Hook execution phase
pub const HookPhase = enum {
    pre_request, // Before AI request is sent
    post_request, // After AI response is received
    pre_tool, // Before tool execution
    post_tool, // After tool execution
    pre_edit, // Before file edit
    post_edit, // After file edit
    session_start, // When chat session starts
    session_end, // When chat session ends
    on_error, // On any error
    on_stream_token, // On each streaming token
};

/// Hook context — data available to hook handlers
pub const HookContext = struct {
    phase: HookPhase,
    provider: []const u8,
    model: []const u8,
    tool_name: ?[]const u8,
    file_path: ?[]const u8,
    error_message: ?[]const u8,
    token_count: u32,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) HookContext {
        return HookContext{
            .phase = .pre_request,
            .provider = "",
            .model = "",
            .tool_name = null,
            .file_path = null,
            .error_message = null,
            .token_count = 0,
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HookContext) void {
        self.metadata.deinit();
    }
};

/// Hook handler function type
pub const HookHandler = *const fn (*HookContext) anyerror!void;

/// A registered hook
pub const Hook = struct {
    name: []const u8,
    tier: HookTier,
    phase: HookPhase,
    handler: ?HookHandler,
    enabled: bool,
    priority: u32,
};

/// Lifecycle hooks system with three tiers
///
/// Core hooks (43): pre_request, post_request, pre_tool, post_tool, etc.
/// Continuation hooks (7): session_start, session_end, on_stream_token, etc.
/// Skill hooks (2): skill_pre_execute, skill_post_execute
///
/// Reference: oh-my-openagent 52 lifecycle hooks in 3 tiers
pub const LifecycleHooks = struct {
    allocator: Allocator,
    hooks: std.ArrayList(Hook),

    pub fn init(allocator: Allocator) LifecycleHooks {
        return LifecycleHooks{
            .allocator = allocator,
            .hooks = std.ArrayList(Hook).init(allocator),
        };
    }

    /// Register a new hook
    pub fn register(
        self: *LifecycleHooks,
        name: []const u8,
        tier: HookTier,
        phase: HookPhase,
        handler: ?HookHandler,
        priority: u32,
    ) !void {
        try self.hooks.append(Hook{
            .name = try self.allocator.dupe(u8, name),
            .tier = tier,
            .phase = phase,
            .handler = handler,
            .enabled = true,
            .priority = priority,
        });
    }

    /// Execute all hooks for a given phase, sorted by priority
    pub fn execute(self: *LifecycleHooks, phase: HookPhase, ctx: *HookContext) !void {
        // Sort by priority (lower = runs first)
        // Simple bubble sort for small hook counts
        const items = self.hooks.items;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < items.len) : (j += 1) {
                if (items[j].priority < items[i].priority) {
                    const tmp = items[i];
                    items[i] = items[j];
                    items[j] = tmp;
                }
            }
        }

        for (items) |hook| {
            if (!hook.enabled) continue;
            if (hook.phase != phase) continue;
            if (hook.handler) |handler| {
                handler(ctx) catch |err| {
                    std.debug.print("Hook '{s}' error: {}\n", .{ hook.name, err });
                };
            }
        }
    }

    /// Enable a hook by name
    pub fn enable(self: *LifecycleHooks, name: []const u8) void {
        for (self.hooks.items) |*hook| {
            if (std.mem.eql(u8, hook.name, name)) {
                hook.enabled = true;
                return;
            }
        }
    }

    /// Disable a hook by name
    pub fn disable(self: *LifecycleHooks, name: []const u8) void {
        for (self.hooks.items) |*hook| {
            if (std.mem.eql(u8, hook.name, name)) {
                hook.enabled = false;
                return;
            }
        }
    }

    /// Get hooks by tier
    pub fn getByTier(self: *LifecycleHooks, tier: HookTier) ![]const Hook {
        var result = std.ArrayList(Hook).init(self.allocator);
        for (self.hooks.items) |hook| {
            if (hook.tier == tier) {
                try result.append(hook);
            }
        }
        return result.toOwnedSlice();
    }

    /// Print all registered hooks
    pub fn printHooks(self: *LifecycleHooks) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\n=== Lifecycle Hooks ({d} registered) ===\n", .{self.hooks.items.len}) catch {};

        for (self.hooks.items) |hook| {
            const tier_label = switch (hook.tier) {
                .core => "CORE",
                .continuation => "CONT",
                .skill => "SKILL",
            };
            const phase_label = @tagName(hook.phase);
            const status = if (hook.enabled) "ON" else "OFF";

            stdout.print("  [{s}] {s} ({s}) pri={d} {s}\n", .{
                tier_label,
                hook.name,
                phase_label,
                hook.priority,
                status,
            }) catch {};
        }
    }

    pub fn deinit(self: *LifecycleHooks) void {
        for (self.hooks.items) |hook| {
            self.allocator.free(hook.name);
        }
        self.hooks.deinit();
    }
};
