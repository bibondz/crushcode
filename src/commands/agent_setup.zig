const std = @import("std");
const agent_loop_mod = @import("agent_loop");
const tool_executors = @import("chat_tool_executors");
const usage_budget_mod = @import("usage_budget");

const AgentLoop = agent_loop_mod.AgentLoop;

/// InteractiveContext holds shared state for an interactive chat session.
/// This struct bundles all the resources needed for agent loop execution.
pub const InteractiveContext = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    provider_name: []const u8,
    model_name: []const u8,
    client: *AIClient,
    messages: *std.ArrayList(ChatMessage),
    hooks: *LifecycleHooks,
    agent_loop: *AgentLoop,
    budget_manager: ?*usage_budget_mod.BudgetManager,
    json_out: JsonOutput,

    /// Initialize an InteractiveContext with all required components.
    pub fn init(
        allocator: std.mem.Allocator,
        config: *Config,
        provider_name: []const u8,
        model_name: []const u8,
        client: *AIClient,
        messages: *std.ArrayList(ChatMessage),
        hooks: *LifecycleHooks,
        agent_loop: *AgentLoop,
        json_out: JsonOutput,
    ) InteractiveContext {
        return .{
            .allocator = allocator,
            .config = config,
            .provider_name = provider_name,
            .model_name = model_name,
            .client = client,
            .messages = messages,
            .hooks = hooks,
            .agent_loop = agent_loop,
            .budget_manager = null,
            .json_out = json_out,
        };
    }

    /// Set the budget manager for session cost tracking.
    pub fn setBudgetManager(self: *InteractiveContext, manager: ?*usage_budget_mod.BudgetManager) void {
        self.budget_manager = manager;
        self.agent_loop.budget_manager = manager;
    }
};

/// Create and configure an AgentLoop for interactive chat.
/// Returns an initialized AgentLoop with tools registered.
pub fn createAgentLoop(allocator: std.mem.Allocator, builtin_tool_schemas: []const ToolSchema) !*AgentLoop {
    var agent_loop = try allocator.create(AgentLoop);
    agent_loop.* = AgentLoop.init(allocator);
    errdefer {
        agent_loop.deinit();
        allocator.destroy(agent_loop);
    }

    var loop_config = agent_loop_mod.LoopConfig.init();
    loop_config.show_intermediate = false;
    agent_loop.setConfig(loop_config);

    try tool_executors.registerBuiltinAgentTools(agent_loop, builtin_tool_schemas);

    return agent_loop;
}

/// Destroy an AgentLoop created by createAgentLoop.
pub fn destroyAgentLoop(allocator: std.mem.Allocator, agent_loop: *AgentLoop) void {
    agent_loop.deinit();
    allocator.destroy(agent_loop);
}

/// Configure an AgentLoop with the specified agent mode.
pub fn configureAgentMode(agent_loop: *AgentLoop, mode: agent_loop_mod.AgentMode) void {
    agent_loop.config.agent_mode = mode;
}

/// Get the current loop configuration from an AgentLoop.
pub fn getLoopConfig(agent_loop: *AgentLoop) agent_loop_mod.LoopConfig {
    return agent_loop.config;
}

/// Type aliases for convenience (must match imports from chat.zig)
pub const Config = @import("config").Config;
pub const AIClient = @import("core_api").AIClient;
pub const ChatMessage = @import("core_api").ChatMessage;
pub const LifecycleHooks = @import("lifecycle_hooks").LifecycleHooks;
pub const ToolSchema = @import("tool_types").ToolSchema;
pub const JsonOutput = @import("json_output").JsonOutput;
