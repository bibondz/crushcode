const std = @import("std");
const ai_types = @import("ai_types");
const args_mod = @import("args");
const graph_mod = @import("graph");
const agent_loop_mod = @import("agent_loop");
const workflow_mod = @import("workflow");
const compaction_mod = @import("compaction");
const scaffold_mod = @import("scaffold");
const file_compat = @import("file_compat");

inline fn stdout_print(comptime fmt: []const u8, args: anytype) void {
    file_compat.File.stdout().writer().print(fmt, args) catch {};
}

pub fn handleGraph(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var kg = graph_mod.KnowledgeGraph.init(allocator);
    defer kg.deinit();

    if (args.remaining.len > 0) {
        for (args.remaining) |file_path| {
            stdout_print("Indexing: {s}\n", .{file_path});
            kg.indexFile(file_path) catch |err| {
                stdout_print("  Error indexing {s}: {}\n", .{ file_path, err });
            };
        }
    } else {
        const default_files = [_][]const u8{
            "src/main.zig",
            "src/ai/client.zig",
            "src/ai/registry.zig",
            "src/commands/handlers.zig",
            "src/commands/chat.zig",
            "src/config/config.zig",
            "src/cli/args.zig",
        };
        stdout_print("Indexing default source files...\n\n", .{});
        for (&default_files) |file_path| {
            kg.indexFile(file_path) catch continue;
        }
    }

    kg.detectCommunities() catch {};
    kg.printStats();

    if (kg.nodes.count() > 0) {
        const ctx = kg.toCompressedContext(allocator) catch return;
        defer allocator.free(ctx);
        stdout_print("\n--- Compressed Context Preview ---\n", .{});
        stdout_print("{s}\n", .{ctx});
    }
}

pub fn handleAgentLoop(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var agent = agent_loop_mod.AgentLoop.init(allocator);
    defer agent.deinit();

    var config = agent_loop_mod.LoopConfig.init();
    config.max_iterations = 10;
    config.show_intermediate = false;
    agent.setConfig(config);

    agent.registerTool("read_file", demoReadFileTool) catch {};
    agent.registerTool("search", demoSearchTool) catch {};

    agent.printStatus();

    stdout_print("\n--- Running demo agent loop ---\n", .{});
    var result = agent.run(demoAISend, "Find information about Zig programming language") catch {
        stdout_print("Error: agent loop failed\n", .{});
        return;
    };
    defer result.deinit();

    stdout_print("\n--- Agent Loop Result ---\n", .{});
    stdout_print("  Final response: {s}\n", .{result.final_response});
    stdout_print("  Iterations: {d}\n", .{result.total_iterations});
    stdout_print("  Tool calls: {d}\n", .{result.total_tool_calls});
    stdout_print("  Retries: {d}\n", .{result.total_retries});
    stdout_print("  Steps: {d}\n", .{result.steps.items.len});

    for (result.steps.items, 0..) |step, i| {
        stdout_print("\n  Step {d}:\n", .{i + 1});
        stdout_print("    AI: {s}\n", .{step.ai_response});
        stdout_print("    Finish: {s}\n", .{step.finish_reason});
        if (step.has_tool_calls) {
            for (step.tool_calls.items) |tc| {
                stdout_print("    Tool call: {s}({s})\n", .{ tc.name, tc.arguments });
            }
            for (step.tool_results.items) |tr| {
                const status = if (tr.success) "OK" else "FAIL";
                stdout_print("    Tool result [{s}]: {s}\n", .{ status, tr.output });
            }
        }
    }
}

fn demoReadFileTool(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    _ = call_id;
    _ = arguments;
    return agent_loop_mod.ToolResult.init(allocator, "demo-read", "File content: Zig is a systems programming language...", true);
}

fn demoSearchTool(allocator: std.mem.Allocator, call_id: []const u8, arguments: []const u8) anyerror!agent_loop_mod.ToolResult {
    _ = call_id;
    _ = arguments;
    return agent_loop_mod.ToolResult.init(allocator, "demo-search", "Search results: Zig homepage, Zig learn, Zig standard library docs", true);
}

var demo_ai_call_count: u32 = 0;

fn demoAISend(allocator: std.mem.Allocator, messages: []const agent_loop_mod.LoopMessage) anyerror!agent_loop_mod.AIResponse {
    _ = allocator;
    _ = messages;
    demo_ai_call_count += 1;
    if (demo_ai_call_count == 1) {
        return agent_loop_mod.AIResponse{
            .content = "Let me search for information.",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]ai_types.ToolCallInfo{
                .{ .id = "call-1", .name = "search", .arguments = "Zig programming language" },
            },
        };
    }
    if (demo_ai_call_count == 2) {
        return agent_loop_mod.AIResponse{
            .content = "Let me read more details.",
            .finish_reason = .tool_calls,
            .tool_calls = &[_]ai_types.ToolCallInfo{
                .{ .id = "call-2", .name = "read_file", .arguments = "zig_intro.md" },
            },
        };
    }
    return agent_loop_mod.AIResponse{
        .content = "Based on my research: Zig is a modern systems programming language designed to be a better alternative to C. It offers compile-time code execution, no hidden control flow, and optional types.",
        .finish_reason = .stop,
        .tool_calls = &.{},
    };
}

pub fn handleWorkflow(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var workflow = workflow_mod.PhaseWorkflow.init(allocator, "crushcode") catch return;
    defer workflow.deinit();

    const phase_names = [_][]const u8{ "Core Infrastructure", "Shell Execution", "AI File Ops", "Skills System", "Terminal UI", "MCP Integration" };
    for (&phase_names, 1..) |name, i| {
        const phase = allocator.create(workflow_mod.WorkflowPhase) catch continue;
        phase.* = workflow_mod.WorkflowPhase.init(allocator, @floatFromInt(i), name, "Phase goal") catch continue;
        if (i > 1) phase.addDependency(@floatFromInt(i - 1)) catch {};
        workflow.addPhase(phase) catch {};
    }

    workflow.completePhase(1.0) catch {};
    workflow.completePhase(2.0) catch {};
    workflow.completePhase(3.0) catch {};
    workflow.completePhase(4.0) catch {};
    workflow.completePhase(5.0) catch {};
    workflow.completePhase(6.0) catch {};

    if (args.remaining.len > 0 and std.mem.eql(u8, args.remaining[0], "--xml")) {
        const xml = workflow.toXml(allocator) catch return;
        defer allocator.free(xml);
        stdout_print("{s}\n", .{xml});
    } else {
        workflow.printProgress();
    }
}

pub fn handleCompact(_: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    var compactor = compaction_mod.ContextCompactor.init(allocator, 128000);
    defer compactor.deinit();

    compactor.preserveTopic("architecture") catch {};
    compactor.preserveTopic("decisions") catch {};

    const sample_messages = [_]compaction_mod.CompactMessage{
        .{ .role = "user", .content = "I want to implement a new authentication system using OAuth 2.0", .timestamp = null },
        .{ .role = "assistant", .content = "I'll help you implement OAuth 2.0 authentication. We decided to use the authorization code flow with PKCE for security. This approach supports both web and mobile clients.", .timestamp = null },
        .{ .role = "user", .content = "What about token refresh?", .timestamp = null },
        .{ .role = "assistant", .content = "We should implement automatic token refresh using a background timer. The refresh token will be stored securely in an httpOnly cookie.", .timestamp = null },
        .{ .role = "user", .content = "Great, let's implement it", .timestamp = null },
        .{ .role = "assistant", .content = "Here's the implementation plan for the OAuth 2.0 system with PKCE and token refresh...", .timestamp = null },
        .{ .role = "user", .content = "How do we test this?", .timestamp = null },
        .{ .role = "assistant", .content = "We chose to use integration tests with a mock OAuth server. This will let us test the full flow without external dependencies.", .timestamp = null },
        .{ .role = "user", .content = "What about the latest changes?", .timestamp = null },
        .{ .role = "assistant", .content = "Based on our recent discussion, we approved the token rotation strategy and will use short-lived access tokens (15 min) with longer refresh tokens (7 days).", .timestamp = null },
        .{ .role = "user", .content = "Show me the current implementation status", .timestamp = null },
        .{ .role = "assistant", .content = "Current status: OAuth flow implemented, token refresh working, PKCE challenge generation done. Remaining: CSRF state validation and error handling.", .timestamp = null },
    };

    var estimated_tokens: u64 = 0;
    for (&sample_messages) |msg| {
        estimated_tokens += compaction_mod.ContextCompactor.estimateTokens(msg.content);
    }

    compactor.printStatus(estimated_tokens);

    var result = compactor.compact(&sample_messages) catch return;
    defer result.deinit();
    stdout_print("\nCompaction Result:\n", .{});
    stdout_print("  Messages summarized: {d}\n", .{result.messages_summarized});
    stdout_print("  Tokens saved: {d}\n", .{result.tokens_saved});
    stdout_print("  Recent messages preserved: {d}\n", .{result.messages.len});
    if (result.summary.len > 0) {
        stdout_print("\n--- Generated Summary ---\n{s}\n", .{result.summary});
    }
}

pub fn handleScaffold(args: args_mod.Args) !void {
    const allocator = std.heap.page_allocator;

    const name = if (args.remaining.len > 0) args.remaining[0] else "my-project";
    const desc = if (args.remaining.len > 1) args.remaining[1] else "A new project scaffolded by Crushcode";

    var scaffolder = scaffold_mod.ProjectScaffolder.init(allocator, name, desc) catch return;
    defer scaffolder.deinit();

    scaffolder.addTech("Zig") catch {};
    scaffolder.addTech("Zig stdlib") catch {};

    const req1 = allocator.create(scaffold_mod.Requirement) catch return;
    req1.* = scaffold_mod.Requirement.init(allocator, "REQ-01", "Core CLI interface", .critical) catch return;
    req1.setDescription("Users can run the CLI and see help output") catch {};
    req1.setCategory("CLI") catch {};
    req1.addCriterion("CLI starts and shows help") catch {};
    req1.addCriterion("Version flag works") catch {};
    scaffolder.addRequirement(req1) catch {};

    const req2 = allocator.create(scaffold_mod.Requirement) catch return;
    req2.* = scaffold_mod.Requirement.init(allocator, "REQ-02", "AI chat integration", .critical) catch return;
    req2.setDescription("Users can chat with AI providers") catch {};
    req2.setCategory("AI") catch {};
    req2.addCriterion("Chat sends messages to provider") catch {};
    req2.addCriterion("Responses display correctly") catch {};
    scaffolder.addRequirement(req2) catch {};

    const req3 = allocator.create(scaffold_mod.Requirement) catch return;
    req3.* = scaffold_mod.Requirement.init(allocator, "REQ-03", "Configuration management", .high) catch return;
    req3.setDescription("Users can configure providers and API keys") catch {};
    req3.setCategory("Config") catch {};
    scaffolder.addRequirement(req3) catch {};

    const ph1 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph1.* = scaffold_mod.ScaffoldPhase.init(allocator, 1, "Core Setup") catch return;
    ph1.addRequirement("REQ-01") catch {};
    ph1.addRequirement("REQ-03") catch {};
    scaffolder.addPhase(ph1) catch {};

    const ph2 = allocator.create(scaffold_mod.ScaffoldPhase) catch return;
    ph2.* = scaffold_mod.ScaffoldPhase.init(allocator, 2, "AI Integration") catch return;
    ph2.addRequirement("REQ-02") catch {};
    scaffolder.addPhase(ph2) catch {};

    scaffolder.printSummary();

    stdout_print("\n--- Generated PROJECT.md ---\n", .{});
    const project_md = scaffolder.generateProjectMd() catch return;
    defer allocator.free(project_md);
    stdout_print("{s}\n", .{project_md});

    stdout_print("\n--- Generated REQUIREMENTS.md ---\n", .{});
    const reqs_md = scaffolder.generateRequirementsMd() catch return;
    defer allocator.free(reqs_md);
    stdout_print("{s}\n", .{reqs_md});

    stdout_print("\n--- Generated ROADMAP.md ---\n", .{});
    const roadmap_md = scaffolder.generateRoadmapMd() catch return;
    defer allocator.free(roadmap_md);
    stdout_print("{s}\n", .{roadmap_md});
}
