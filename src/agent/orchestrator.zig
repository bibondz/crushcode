/// OrchestrationEngine — top-level API for multi-agent orchestration.
///
/// Fuses:
///   TeamCoordinator (agent/coordinator.zig) — team creation, messaging, task delegation
///   ModelRouter (agent/router.zig) — task→model routing + cost estimation
///   Capability (agent/capability.zig) — multi-step workflow definitions
///   WorkerPool + Worker (agent/worker.zig) — worker management
///
/// Users describe a task, and the engine:
///   1. Parses the task into phases (via Capability)
///   2. Routes each phase to the right model (via ModelRouter)
///   3. Creates a team of workers (via TeamCoordinator)
///   4. Estimates total cost
///   5. Returns a comprehensive plan + cost report

const std = @import("std");
const array_list_compat = @import("array_list_compat");
const file_compat = @import("file_compat");
const worker_mod = @import("worker");
const coordinator_mod = @import("coordinator");
const router_mod = @import("router");
const capability_mod = @import("capability");
const worker_runner_mod = @import("worker_runner");
const checkpoint_mod = @import("checkpoint");

const Allocator = std.mem.Allocator;
const ArrayList = array_list_compat.ArrayList;
const WorkerPool = worker_mod.WorkerPool;
const WorkerSpecialty = worker_mod.WorkerSpecialty;
const TeamCoordinator = coordinator_mod.TeamCoordinator;
const EffortLevel = coordinator_mod.EffortLevel;
const ModelRouter = router_mod.ModelRouter;
const TaskCategory = router_mod.TaskCategory;
const Capability = capability_mod.Capability;
const WorkerRunner = worker_runner_mod.WorkerRunner;
const CheckpointManager = checkpoint_mod.CheckpointManager;
const Checkpoint = checkpoint_mod.Checkpoint;

// ── Task Type Classification ──────────────────────────────────────────────────

const TaskType = enum {
    research,
    dev,
    debug,
    general,
};

// ── Result Types ──────────────────────────────────────────────────────────────

pub const PhasePlan = struct {
    phase_name: []const u8,
    phase_description: []const u8,
    recommended_model: []const u8,
    is_parallel: bool,
    estimated_tokens: u64,
    estimated_cost: f64,
    specialty: WorkerSpecialty,

    pub fn deinit(self: *const PhasePlan, allocator: Allocator) void {
        allocator.free(self.phase_name);
        allocator.free(self.phase_description);
        allocator.free(self.recommended_model);
    }
};

pub const OrchestrationPlan = struct {
    task_description: []const u8,
    total_phases: u32,
    phases: []PhasePlan,
    total_estimated_cost: f64,
    total_estimated_tokens: u64,
    recommended_team_size: u32,

    pub fn deinit(self: *const OrchestrationPlan, allocator: Allocator) void {
        allocator.free(self.task_description);
        for (self.phases) |*phase| {
            phase.deinit(allocator);
        }
        allocator.free(self.phases);
    }
};

pub const TeamSpawnResult = struct {
    pub const AgentSummary = struct {
        agent_id: []const u8,
        agent_name: []const u8,
        specialty: WorkerSpecialty,
        model: []const u8,

        pub fn deinit(self: *const AgentSummary, allocator: Allocator) void {
            allocator.free(self.agent_id);
            allocator.free(self.agent_name);
            allocator.free(self.model);
        }
    };

    team_id: []const u8,
    team_name: []const u8,
    agent_count: u32,
    agents: []AgentSummary,
    total_estimated_cost: f64,
    plan: OrchestrationPlan,

    pub fn deinit(self: *const TeamSpawnResult, allocator: Allocator) void {
        allocator.free(self.team_id);
        allocator.free(self.team_name);
        for (self.agents) |*agent| {
            agent.deinit(allocator);
        }
        allocator.free(self.agents);
        self.plan.deinit(allocator);
    }
};

pub const CostEstimate = struct {
    pub const CostLineItem = struct {
        model: []const u8,
        tokens: u64,
        cost: f64,
    };

    task_category: TaskCategory,
    recommended_model: []const u8,
    estimated_tokens: u64,
    estimated_cost: f64,
    cost_breakdown: []CostLineItem,

    pub fn deinit(self: *const CostEstimate, allocator: Allocator) void {
        allocator.free(self.recommended_model);
        for (self.cost_breakdown) |*item| {
            allocator.free(item.model);
        }
        allocator.free(self.cost_breakdown);
    }
};

pub const OrchestrationEntry = struct {
    timestamp: i64,
    action: []const u8,
    details: []const u8,
};

pub const ExecutionStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,
};

pub const ExecutionResult = struct {
    team_id: []const u8,
    phase_name: []const u8,
    phase_index: u32,
    status: ExecutionStatus,
    output: []const u8,
    duration_ms: u64,
    checkpoint_id: ?[]const u8,

    pub fn deinit(self: *ExecutionResult, allocator: Allocator) void {
        allocator.free(self.team_id);
        allocator.free(self.phase_name);
        allocator.free(self.output);
        if (self.checkpoint_id) |id| allocator.free(id);
    }
};

// ── OrchestrationEngine ──────────────────────────────────────────────────────

pub const OrchestrationEngine = struct {
    allocator: Allocator,
    router: ModelRouter,
    worker_pool: *WorkerPool,
    coordinator: TeamCoordinator,
    capabilities: ArrayList(*Capability),
    orchestration_log: ArrayList(OrchestrationEntry),
    worker_runner: ?WorkerRunner,
    checkpoint_manager: ?CheckpointManager,
    checkpoint_dir: []const u8,
    team_plans: std.StringHashMap(*OrchestrationPlan),

    /// Initialize a new OrchestrationEngine with all sub-components.
    pub fn init(allocator: Allocator) !OrchestrationEngine {
        const pool = try allocator.create(WorkerPool);
        pool.* = WorkerPool.init(allocator);
        errdefer {
            pool.deinit();
            allocator.destroy(pool);
        }

        var router = try ModelRouter.init(allocator);
        errdefer router.deinit();

        // Try to resolve binary path for WorkerRunner
        const binary_path = WorkerRunner.resolveBinaryPath(allocator) catch null;
        errdefer {
            if (binary_path) |path| allocator.free(path);
        }
        const worker_runner = if (binary_path != null)
            WorkerRunner.init(allocator, pool, binary_path.?)
        else
            null;

        // Create checkpoint dir and manager
        const cp_dir = try allocator.dupe(u8, ".crushcode/checkpoints/");
        errdefer allocator.free(cp_dir);
        std.fs.cwd().makePath(".crushcode/checkpoints") catch {};
        const checkpoint_manager = CheckpointManager.init(allocator, cp_dir);

        return OrchestrationEngine{
            .allocator = allocator,
            .router = router,
            .worker_pool = pool,
            .coordinator = TeamCoordinator.init(allocator, pool),
            .capabilities = ArrayList(*Capability).init(allocator),
            .orchestration_log = ArrayList(OrchestrationEntry).init(allocator),
            .worker_runner = worker_runner,
            .checkpoint_manager = checkpoint_manager,
            .checkpoint_dir = cp_dir,
            .team_plans = std.StringHashMap(*OrchestrationPlan).init(allocator),
        };
    }

    /// Free all owned resources.
    pub fn deinit(self: *OrchestrationEngine) void {
        // Clean up team plans (keys and cloned plan values)
        var plan_iter = self.team_plans.iterator();
        while (plan_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.team_plans.deinit();

        // Clean up worker_runner (free the stored binary path)
        if (self.worker_runner) |*wr| {
            self.allocator.free(wr.crushcode_binary);
            wr.deinit();
        }

        // CheckpointManager has no deinit — just stores references
        self.allocator.free(self.checkpoint_dir);

        // Clean up orchestration log entries
        for (self.orchestration_log.items) |entry| {
            self.allocator.free(entry.action);
            self.allocator.free(entry.details);
        }
        self.orchestration_log.deinit();

        // Clean up capabilities
        for (self.capabilities.items) |cap| {
            cap.deinit();
            self.allocator.destroy(cap);
        }
        self.capabilities.deinit();

        // Coordinator references worker_pool but doesn't own it
        self.coordinator.deinit();

        // Worker pool is heap-allocated
        self.worker_pool.deinit();
        self.allocator.destroy(self.worker_pool);

        self.router.deinit();
    }

    /// Core planning method — analyze a task and produce a comprehensive plan.
    ///
    /// Steps:
    ///   1. Classify task by keyword matching
    ///   2. Create a Capability with appropriate phases
    ///   3. Route each phase to a model
    ///   4. Estimate cost per phase
    ///   5. Return OrchestrationPlan
    pub fn planTask(self: *OrchestrationEngine, task_description: []const u8) !OrchestrationPlan {
        const task_type = classifyTask(task_description);

        // Create capability with phases based on task type
        const cap = try self.allocator.create(Capability);
        errdefer {
            cap.deinit();
            self.allocator.destroy(cap);
        }

        const cap_name = try std.fmt.allocPrint(self.allocator, "{s}-workflow", .{@tagName(task_type)});
        defer self.allocator.free(cap_name);

        cap.* = try Capability.init(self.allocator, cap_name, task_description);

        // Add phases based on task type
        switch (task_type) {
            .research => {
                try cap.addPhase("collect", "Gather relevant data and information", false);
                try cap.addPhase("analyze", "Analyze collected data for insights", false);
                try cap.addPhase("synthesize", "Synthesize findings into a coherent report", false);
            },
            .dev => {
                try cap.addPhase("plan", "Plan the implementation approach", false);
                try cap.addPhase("implement", "Implement the planned changes", false);
                try cap.addPhase("test", "Test the implementation for correctness", false);
                try cap.addPhase("review", "Review the implementation for quality", false);
            },
            .debug => {
                try cap.addPhase("reproduce", "Reproduce the reported issue", false);
                try cap.addPhase("diagnose", "Diagnose the root cause of the issue", false);
                try cap.addPhase("fix", "Apply the fix for the identified issue", false);
                try cap.addPhase("verify", "Verify the fix resolves the issue", false);
            },
            .general => {
                try cap.addPhase("understand", "Understand the task requirements", false);
                try cap.addPhase("plan", "Plan the execution strategy", false);
                try cap.addPhase("execute", "Execute the planned actions", false);
                try cap.addPhase("verify", "Verify the results meet expectations", false);
            },
        }

        // Route each phase to a model and estimate cost
        const phase_count = cap.phases.items.len;
        var initialized_phases: usize = 0;
        const phases = try self.allocator.alloc(PhasePlan, phase_count);
        errdefer {
            for (phases[0..initialized_phases]) |*p| p.deinit(self.allocator);
            self.allocator.free(phases);
        }

        var total_cost: f64 = 0.0;
        var total_tokens: u64 = 0;

        for (cap.phases.items, 0..) |cap_phase, i| {
            const category = phaseNameToCategory(cap_phase.name);
            const model_name = self.router.routeForTask(category);
            const estimated_tokens: u64 = 2000;
            const cost = self.router.estimateCost(category, estimated_tokens);

            phases[i] = PhasePlan{
                .phase_name = try self.allocator.dupe(u8, cap_phase.name),
                .phase_description = try self.allocator.dupe(u8, cap_phase.description),
                .recommended_model = try self.allocator.dupe(u8, model_name),
                .is_parallel = cap_phase.is_parallel,
                .estimated_tokens = estimated_tokens,
                .estimated_cost = cost,
                .specialty = phaseNameToSpecialty(cap_phase.name),
            };
            initialized_phases += 1;

            total_cost += cost;
            total_tokens += estimated_tokens;
        }

        // Store capability for later use
        try self.capabilities.append(cap);

        // Log action
        self.logAction("plan_created", task_description) catch {};

        return OrchestrationPlan{
            .task_description = try self.allocator.dupe(u8, task_description),
            .total_phases = @intCast(phase_count),
            .phases = phases,
            .total_estimated_cost = total_cost,
            .total_estimated_tokens = total_tokens,
            .recommended_team_size = @intCast(@min(phase_count, 10)),
        };
    }

    /// Spawn a team of workers for a given task.
    ///
    /// Steps:
    ///   1. Call planTask() to get the plan
    ///   2. Create a team via coordinator
    ///   3. Add agents with appropriate specialties
    ///   4. Return TeamSpawnResult
    pub fn spawnTeam(self: *OrchestrationEngine, task_description: []const u8, agent_count: u32) !TeamSpawnResult {
        const plan = try self.planTask(task_description);
        errdefer plan.deinit(self.allocator);

        // Create team
        const team = try self.coordinator.createTeam(task_description, 10);
        const team_id = try self.allocator.dupe(u8, team.id);
        errdefer self.allocator.free(team_id);
        const team_name = try self.allocator.dupe(u8, team.name);
        errdefer self.allocator.free(team_name);

        // Add agents with specialties from plan phases
        var initialized_agents: usize = 0;
        const agents = try self.allocator.alloc(TeamSpawnResult.AgentSummary, agent_count);
        errdefer {
            for (agents[0..initialized_agents]) |*a| a.deinit(self.allocator);
            self.allocator.free(agents);
        }

        var i: u32 = 0;
        while (i < agent_count) : (i += 1) {
            const phase_idx = i % plan.total_phases;
            const phase = plan.phases[phase_idx];
            const specialty = phase.specialty;
            const effort: EffortLevel = .high;

            const agent = try self.coordinator.addAgentToTeam(team.id, specialty, effort);

            agents[i] = .{
                .agent_id = try self.allocator.dupe(u8, agent.id),
                .agent_name = try self.allocator.dupe(u8, agent.name),
                .specialty = specialty,
                .model = try self.allocator.dupe(u8, phase.recommended_model),
            };
            initialized_agents += 1;
        }

        // Log action
        const log_detail = try std.fmt.allocPrint(self.allocator, "team {s} with {d} agents", .{ team.id, agent_count });
        self.logAction("team_spawned", log_detail) catch {};
        self.allocator.free(log_detail);

        // Store plan copy for phase execution (non-critical)
        storePlanCopy: {
            const pc = clonePlan(self.allocator, &plan) catch break :storePlanCopy;
            errdefer {
                pc.deinit(self.allocator);
                self.allocator.destroy(pc);
            }
            const tid = self.allocator.dupe(u8, team_id) catch break :storePlanCopy;
            errdefer self.allocator.free(tid);
            self.team_plans.put(tid, pc) catch {
                self.allocator.free(tid);
                pc.deinit(self.allocator);
                self.allocator.destroy(pc);
                break :storePlanCopy;
            };
        }

        return TeamSpawnResult{
            .team_id = team_id,
            .team_name = team_name,
            .agent_count = agent_count,
            .agents = agents,
            .total_estimated_cost = plan.total_estimated_cost,
            .plan = plan,
        };
    }

    /// Estimate cost for a task description.
    ///
    /// Steps:
    ///   1. Determine TaskCategory from task description
    ///   2. Get recommended model from router
    ///   3. Estimate tokens (~500 per 100 chars, min 1000)
    ///   4. Calculate cost breakdown
    ///   5. Return CostEstimate
    pub fn estimateCost(self: *OrchestrationEngine, task_description: []const u8) !CostEstimate {
        const category = taskDescriptionToCategory(task_description);
        const model_name = self.router.routeForTask(category);

        // Token estimation: ~500 per 100 chars, minimum 1000
        const char_count: u64 = @intCast(task_description.len);
        const estimated_tokens: u64 = @max(char_count * 5, 1000);

        const cost = self.router.estimateCost(category, estimated_tokens);

        // Build cost breakdown
        const breakdown = try self.allocator.alloc(CostEstimate.CostLineItem, 1);
        breakdown[0] = .{
            .model = try self.allocator.dupe(u8, model_name),
            .tokens = estimated_tokens,
            .cost = cost,
        };

        // Log action
        self.logAction("cost_estimated", task_description) catch {};

        return CostEstimate{
            .task_category = category,
            .recommended_model = try self.allocator.dupe(u8, model_name),
            .estimated_tokens = estimated_tokens,
            .estimated_cost = cost,
            .cost_breakdown = breakdown,
        };
    }

    /// Return registered capabilities.
    pub fn listCapabilities(self: *OrchestrationEngine) []const *Capability {
        return self.capabilities.items;
    }

    /// Register an external capability. Caller transfers ownership.
    pub fn registerCapability(self: *OrchestrationEngine, cap: *Capability) !void {
        try self.capabilities.append(cap);
    }

    /// Get team status by team_id. Returns null if team not found.
    /// Caller owns the returned string and must free it.
    pub fn getTeamStatus(self: *OrchestrationEngine, team_id: []const u8) ?[]const u8 {
        return self.coordinator.getTeamStatus(team_id) catch return null;
    }

    /// Append an action to the orchestration log.
    pub fn logAction(self: *OrchestrationEngine, action: []const u8, details: []const u8) !void {
        try self.orchestration_log.append(.{
            .timestamp = std.time.milliTimestamp(),
            .action = try self.allocator.dupe(u8, action),
            .details = try self.allocator.dupe(u8, details),
        });
    }

    /// Print orchestration engine status to stdout.
    pub fn printStats(self: *OrchestrationEngine) void {
        const stdout = file_compat.File.stdout().writer();

        stdout.print("\n=== Orchestration Engine ===\n", .{}) catch {};
        stdout.print("  Capabilities: {d}\n", .{self.capabilities.items.len}) catch {};
        stdout.print("  Teams:        {d}\n", .{self.coordinator.teams.items.len}) catch {};
        stdout.print("  Log entries:  {d}\n", .{self.orchestration_log.items.len}) catch {};
        stdout.print("  Routing rules: {d}\n", .{self.router.getRules().len}) catch {};
        stdout.print("  WorkerRunner:  {s}\n", .{if (self.worker_runner != null) "available" else "unavailable"}) catch {};
        stdout.print("  Team plans:   {d}\n", .{self.team_plans.count()}) catch {};
        stdout.print("\n", .{}) catch {};
    }

    /// Execute a specific phase of a team's plan.
    ///
    /// If worker_runner is available, delegates to it for subprocess execution.
    /// Otherwise returns a simulated/skipped result.
    /// Saves a checkpoint after each phase attempt.
    pub fn executePhase(self: *OrchestrationEngine, team_id: []const u8, phase_index: u32) !ExecutionResult {
        const start = std.time.milliTimestamp();

        // Get plan for this team
        const plan = self.team_plans.get(team_id) orelse return error.TeamNotFound;
        if (phase_index >= plan.total_phases) return error.InvalidPhaseIndex;
        const phase = plan.phases[phase_index];

        var status: ExecutionStatus = .skipped;
        var output: []const u8 = undefined;

        // Attempt real execution via worker_runner if available
        if (self.worker_runner) |*wr| {
            if (wr.runAndCollect(phase.phase_description, phase.specialty, phase.recommended_model)) |result_val| {
                var result = result_val;
                defer result.deinit(self.allocator);
                output = try self.allocator.dupe(u8, result.output);
                status = if (result.status == .completed) .completed else .failed;
            } else |_| {
                output = std.fmt.allocPrint(self.allocator, "Worker execution failed for phase '{s}'", .{phase.phase_name}) catch
                    try self.allocator.dupe(u8, "Worker failed");
                status = .failed;
            }
        } else {
            output = std.fmt.allocPrint(self.allocator, "Simulated: phase '{s}' (no worker runner)", .{phase.phase_name}) catch
                try self.allocator.dupe(u8, "simulated");
            status = .skipped;
        }

        // Try to save checkpoint
        var checkpoint_id: ?[]const u8 = null;
        if (self.checkpoint_manager != null) {
            var cm = self.checkpoint_manager.?;
            saveCpBlk: {
                const msgs = [_]Checkpoint.CheckpointMessage{
                    .{ .role = "system", .content = "phase execution" },
                };
                var cp = cm.create(&msgs, 0, 0) catch break :saveCpBlk;
                errdefer cp.deinit();
                cm.save(&cp) catch break :saveCpBlk;
                checkpoint_id = self.allocator.dupe(u8, cp.id) catch null;
                cp.deinit();
            }
        }

        const end = std.time.milliTimestamp();
        const duration: u64 = if (end > start) @intCast(end - start) else 0;

        self.logAction("phase_executed", phase.phase_name) catch {};

        return ExecutionResult{
            .team_id = try self.allocator.dupe(u8, team_id),
            .phase_name = try self.allocator.dupe(u8, phase.phase_name),
            .phase_index = phase_index,
            .status = status,
            .output = output,
            .duration_ms = duration,
            .checkpoint_id = checkpoint_id,
        };
    }

    /// Save a checkpoint of the current team state to disk.
    pub fn saveCheckpoint(self: *OrchestrationEngine, team_id: []const u8) !void {
        if (self.checkpoint_manager == null) return error.CheckpointNotAvailable;
        var cm = self.checkpoint_manager.?;

        // Verify team exists
        _ = self.coordinator.findTeam(team_id) orelse return error.TeamNotFound;

        const content = try std.fmt.allocPrint(self.allocator, "team:{s}", .{team_id});
        defer self.allocator.free(content);

        const msgs = [_]Checkpoint.CheckpointMessage{
            .{ .role = "system", .content = content },
        };
        var cp = try cm.create(&msgs, 0, 0);
        try cm.save(&cp);
        cp.deinit();

        self.logAction("checkpoint_saved", team_id) catch {};
    }

    /// Load a checkpoint by ID from disk.
    pub fn loadCheckpoint(self: *OrchestrationEngine, checkpoint_id: []const u8) !Checkpoint {
        if (self.checkpoint_manager == null) return error.CheckpointNotAvailable;
        var cm = self.checkpoint_manager.?;
        return try cm.load(checkpoint_id);
    }

    /// List all available checkpoint IDs.
    pub fn listCheckpoints(self: *OrchestrationEngine) ![][]const u8 {
        if (self.checkpoint_manager != null) {
            var cm = self.checkpoint_manager.?;
            return try cm.list();
        }
        var list = ArrayList([]const u8).init(self.allocator);
        return try list.toOwnedSlice();
    }

    /// Return whether the WorkerRunner is available for subprocess execution.
    pub fn hasWorkerRunner(self: *const OrchestrationEngine) bool {
        return self.worker_runner != null;
    }
};

// ── Internal Helpers ──────────────────────────────────────────────────────────

/// Classify a task description into a TaskType based on keyword matching.
fn classifyTask(task_description: []const u8) TaskType {
    if (containsAnyKeyword(task_description, &.{"analyze", "review", "investigate"})) {
        return .research;
    }
    if (containsAnyKeyword(task_description, &.{"implement", "build", "create", "write"})) {
        return .dev;
    }
    if (containsAnyKeyword(task_description, &.{"fix", "debug", "resolve"})) {
        return .debug;
    }
    return .general;
}

/// Check if the task description contains any of the given keywords (case-insensitive).
fn containsAnyKeyword(task: []const u8, keywords: []const []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (task.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, task);
    for (keywords) |keyword| {
        if (std.mem.indexOf(u8, lower, keyword) != null) return true;
    }
    return false;
}

/// Map a phase name to a TaskCategory for model routing.
fn phaseNameToCategory(phase_name: []const u8) TaskCategory {
    if (std.mem.eql(u8, phase_name, "collect") or std.mem.eql(u8, phase_name, "reproduce")) {
        return .data_collection;
    }
    if (std.mem.eql(u8, phase_name, "analyze") or std.mem.eql(u8, phase_name, "understand")) {
        return .code_analysis;
    }
    if (std.mem.eql(u8, phase_name, "synthesize")) {
        return .synthesis;
    }
    if (std.mem.eql(u8, phase_name, "plan") or std.mem.eql(u8, phase_name, "diagnose")) {
        return .reasoning;
    }
    if (std.mem.eql(u8, phase_name, "implement") or std.mem.eql(u8, phase_name, "fix")) {
        return .code_analysis;
    }
    if (std.mem.eql(u8, phase_name, "test") or std.mem.eql(u8, phase_name, "verify")) {
        return .code_analysis;
    }
    if (std.mem.eql(u8, phase_name, "review") or std.mem.eql(u8, phase_name, "execute")) {
        return .code_analysis;
    }
    return .reasoning;
}

/// Map a phase name to a WorkerSpecialty.
fn phaseNameToSpecialty(phase_name: []const u8) WorkerSpecialty {
    if (std.mem.eql(u8, phase_name, "collect") or std.mem.eql(u8, phase_name, "reproduce")) {
        return .collector;
    }
    if (std.mem.eql(u8, phase_name, "analyze") or std.mem.eql(u8, phase_name, "understand")) {
        return .researcher;
    }
    if (std.mem.eql(u8, phase_name, "synthesize") or std.mem.eql(u8, phase_name, "review")) {
        return .publisher;
    }
    if (std.mem.eql(u8, phase_name, "plan") or std.mem.eql(u8, phase_name, "diagnose")) {
        return .researcher;
    }
    if (std.mem.eql(u8, phase_name, "implement") or std.mem.eql(u8, phase_name, "fix") or std.mem.eql(u8, phase_name, "execute")) {
        return .executor;
    }
    if (std.mem.eql(u8, phase_name, "test") or std.mem.eql(u8, phase_name, "verify")) {
        return .executor;
    }
    return .executor;
}

/// Map a task description to a TaskCategory for cost estimation.
fn taskDescriptionToCategory(task_description: []const u8) TaskCategory {
    const task_type = classifyTask(task_description);
    return switch (task_type) {
        .research => .code_analysis,
        .dev => .reasoning,
        .debug => .reasoning,
        .general => .reasoning,
    };
}

/// Deep-clone an OrchestrationPlan. Caller owns the returned pointer.
fn clonePlan(allocator: Allocator, plan: *const OrchestrationPlan) !*OrchestrationPlan {
    const copy = try allocator.create(OrchestrationPlan);
    errdefer allocator.destroy(copy);

    var phases = try allocator.alloc(PhasePlan, plan.phases.len);
    errdefer {
        for (phases) |*p| p.deinit(allocator);
        allocator.free(phases);
    }

    var initialized: usize = 0;
    for (plan.phases) |phase| {
        phases[initialized] = .{
            .phase_name = try allocator.dupe(u8, phase.phase_name),
            .phase_description = try allocator.dupe(u8, phase.phase_description),
            .recommended_model = try allocator.dupe(u8, phase.recommended_model),
            .is_parallel = phase.is_parallel,
            .estimated_tokens = phase.estimated_tokens,
            .estimated_cost = phase.estimated_cost,
            .specialty = phase.specialty,
        };
        initialized += 1;
    }

    copy.* = .{
        .task_description = try allocator.dupe(u8, plan.task_description),
        .total_phases = plan.total_phases,
        .phases = phases,
        .total_estimated_cost = plan.total_estimated_cost,
        .total_estimated_tokens = plan.total_estimated_tokens,
        .recommended_team_size = plan.recommended_team_size,
    };

    return copy;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "OrchestrationEngine init/deinit" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    try testing.expect(engine.capabilities.items.len == 0);
    try testing.expect(engine.orchestration_log.items.len == 0);
    try testing.expect(engine.coordinator.teams.items.len == 0);
}

test "planTask returns valid plan for analyze task" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var plan = try engine.planTask("Analyze the codebase for performance issues");
    defer plan.deinit(allocator);

    // Research workflow: collect → analyze → synthesize (3 phases)
    try testing.expect(plan.total_phases == 3);
    try testing.expect(plan.phases.len == 3);

    // Verify phase names
    try testing.expectEqualStrings("collect", plan.phases[0].phase_name);
    try testing.expectEqualStrings("analyze", plan.phases[1].phase_name);
    try testing.expectEqualStrings("synthesize", plan.phases[2].phase_name);

    // Verify costs are positive
    try testing.expect(plan.total_estimated_cost > 0.0);
    try testing.expect(plan.total_estimated_tokens == 6000); // 3 * 2000

    // Verify task description preserved
    try testing.expectEqualStrings("Analyze the codebase for performance issues", plan.task_description);

    // Verify capability was registered
    try testing.expect(engine.capabilities.items.len == 1);
}

test "planTask returns valid plan for implement task" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var plan = try engine.planTask("Build a new REST API endpoint");
    defer plan.deinit(allocator);

    // Dev workflow: plan → implement → test → review (4 phases)
    try testing.expect(plan.total_phases == 4);
    try testing.expectEqualStrings("plan", plan.phases[0].phase_name);
    try testing.expectEqualStrings("implement", plan.phases[1].phase_name);
    try testing.expectEqualStrings("test", plan.phases[2].phase_name);
    try testing.expectEqualStrings("review", plan.phases[3].phase_name);

    // Verify routing: plan → reasoning (opus), implement → code_analysis (sonnet)
    try testing.expect(std.mem.indexOf(u8, plan.phases[0].recommended_model, "opus") != null);
    try testing.expect(std.mem.indexOf(u8, plan.phases[1].recommended_model, "sonnet") != null);
}

test "planTask debug workflow" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var plan = try engine.planTask("Fix the memory leak in the worker pool");
    defer plan.deinit(allocator);

    // Debug workflow: reproduce → diagnose → fix → verify (4 phases)
    try testing.expect(plan.total_phases == 4);
    try testing.expectEqualStrings("reproduce", plan.phases[0].phase_name);
    try testing.expectEqualStrings("diagnose", plan.phases[1].phase_name);
    try testing.expectEqualStrings("fix", plan.phases[2].phase_name);
    try testing.expectEqualStrings("verify", plan.phases[3].phase_name);
}

test "planTask general workflow for unclassified tasks" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var plan = try engine.planTask("Do something with the project");
    defer plan.deinit(allocator);

    // General workflow: understand → plan → execute → verify (4 phases)
    try testing.expect(plan.total_phases == 4);
    try testing.expectEqualStrings("understand", plan.phases[0].phase_name);
}

test "spawnTeam creates team with correct agent count" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var result = try engine.spawnTeam("Implement user authentication", 3);
    defer result.deinit(allocator);

    try testing.expect(result.agent_count == 3);
    try testing.expect(result.agents.len == 3);
    try testing.expect(result.team_id.len > 0);
    try testing.expect(result.plan.total_phases == 4); // dev workflow

    // Verify agents have valid IDs and models
    for (result.agents) |agent| {
        try testing.expect(agent.agent_id.len > 0);
        try testing.expect(agent.agent_name.len > 0);
        try testing.expect(agent.model.len > 0);
    }

    // Verify team exists in coordinator
    try testing.expect(engine.coordinator.findTeam(result.team_id) != null);
}

test "estimateCost returns reasonable estimate" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var estimate = try engine.estimateCost("Analyze the codebase for security vulnerabilities");
    defer estimate.deinit(allocator);

    // Should have a category
    try testing.expect(estimate.task_category == .code_analysis);

    // Should have a model recommendation
    try testing.expect(estimate.recommended_model.len > 0);

    // Should have positive tokens (min 1000)
    try testing.expect(estimate.estimated_tokens >= 1000);

    // Should have positive cost
    try testing.expect(estimate.estimated_cost > 0.0);

    // Should have cost breakdown
    try testing.expect(estimate.cost_breakdown.len == 1);
    try testing.expect(estimate.cost_breakdown[0].tokens == estimate.estimated_tokens);
}

test "estimateCost token scaling" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    // Short task — should get minimum 1000 tokens
    var est_short = try engine.estimateCost("fix bug");
    defer est_short.deinit(allocator);
    try testing.expect(est_short.estimated_tokens == 1000);

    // Longer task — should scale with description length
    var est_long = try engine.estimateCost("Create a comprehensive system for managing user authentication with OAuth2 and JWT tokens");
    defer est_long.deinit(allocator);
    try testing.expect(est_long.estimated_tokens > 1000);
}

test "listCapabilities returns empty initially" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    const caps = engine.listCapabilities();
    try testing.expect(caps.len == 0);
}

test "listCapabilities returns capabilities after planTask" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var plan = try engine.planTask("Review the code");
    defer plan.deinit(allocator);

    const caps = engine.listCapabilities();
    try testing.expect(caps.len == 1);
    try testing.expectEqualStrings("research-workflow", caps[0].name);
}

test "registerCapability adds external capability" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    const cap = try allocator.create(Capability);
    cap.* = try Capability.init(allocator, "custom-workflow", "A custom workflow");
    try cap.addPhase("step1", "First step", false);
    try cap.addPhase("step2", "Second step", true);

    try engine.registerCapability(cap);

    const caps = engine.listCapabilities();
    try testing.expect(caps.len == 1);
    try testing.expectEqualStrings("custom-workflow", caps[0].name);
    try testing.expect(caps[0].phases.items.len == 2);
}

test "OrchestrationPlan deinit cleans up" {
    const allocator = std.testing.allocator;
    var plan = OrchestrationPlan{
        .task_description = try allocator.dupe(u8, "test task"),
        .total_phases = 2,
        .phases = try allocator.alloc(PhasePlan, 2),
        .total_estimated_cost = 0.01,
        .total_estimated_tokens = 4000,
        .recommended_team_size = 2,
    };
    plan.phases[0] = .{
        .phase_name = try allocator.dupe(u8, "step1"),
        .phase_description = try allocator.dupe(u8, "First step"),
        .recommended_model = try allocator.dupe(u8, "sonnet"),
        .is_parallel = false,
        .estimated_tokens = 2000,
        .estimated_cost = 0.005,
        .specialty = .researcher,
    };
    plan.phases[1] = .{
        .phase_name = try allocator.dupe(u8, "step2"),
        .phase_description = try allocator.dupe(u8, "Second step"),
        .recommended_model = try allocator.dupe(u8, "opus"),
        .is_parallel = true,
        .estimated_tokens = 2000,
        .estimated_cost = 0.005,
        .specialty = .executor,
    };

    plan.deinit(allocator);
    // No leak detected by GeneralPurposeAllocator
}

test "CostEstimate deinit cleans up" {
    const allocator = std.testing.allocator;

    const breakdown = try allocator.alloc(CostEstimate.CostLineItem, 1);
    breakdown[0] = .{
        .model = try allocator.dupe(u8, "sonnet"),
        .tokens = 2000,
        .cost = 0.01,
    };

    var estimate = CostEstimate{
        .task_category = .code_analysis,
        .recommended_model = try allocator.dupe(u8, "sonnet"),
        .estimated_tokens = 2000,
        .estimated_cost = 0.01,
        .cost_breakdown = breakdown,
    };

    estimate.deinit(allocator);
    // No leak detected by GeneralPurposeAllocator
}

test "logAction records entries" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    try engine.logAction("test_action", "some details");

    try testing.expect(engine.orchestration_log.items.len == 1);
    try testing.expectEqualStrings("test_action", engine.orchestration_log.items[0].action);
    try testing.expectEqualStrings("some details", engine.orchestration_log.items[0].details);
    try testing.expect(engine.orchestration_log.items[0].timestamp > 0);
}

test "printStats does not crash" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    engine.printStats();
}

test "getTeamStatus returns null for nonexistent team" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    const status = engine.getTeamStatus("nonexistent");
    try testing.expect(status == null);
}

test "getTeamStatus returns status for existing team" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    var result = try engine.spawnTeam("Build something", 2);
    defer result.deinit(allocator);

    const status = engine.getTeamStatus(result.team_id);
    try testing.expect(status != null);
    if (status) |s| {
        defer allocator.free(s);
        try testing.expect(s.len > 0);
    }
}

test "spawnTeam agents match phase specialties" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    // Dev workflow: plan → implement → test → review
    var result = try engine.spawnTeam("Write a new module", 4);
    defer result.deinit(allocator);

    // Agents should cycle through phase specialties
    try testing.expect(result.agents[0].specialty == .researcher); // plan
    try testing.expect(result.agents[1].specialty == .executor); // implement
    try testing.expect(result.agents[2].specialty == .executor); // test
    try testing.expect(result.agents[3].specialty == .publisher); // review
}

test "OrchestrationEngine deinit with planTask data" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);

    // Create multiple plans to register multiple capabilities
    var plan1 = try engine.planTask("Analyze the code");
    defer plan1.deinit(allocator);
    var plan2 = try engine.planTask("Build a feature");
    defer plan2.deinit(allocator);

    try testing.expect(engine.capabilities.items.len == 2);

    // Deinit should clean up everything without leaks
    engine.deinit();
}

// ── WorkerRunner + CheckpointManager Integration Tests ──────────────────────────

test "OrchestrationEngine hasWorkerRunner handles missing binary gracefully" {
    const allocator = std.testing.allocator;
    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    // Verify hasWorkerRunner returns a valid bool
    _ = engine.hasWorkerRunner();

    // Simulate missing binary by clearing worker_runner
    if (engine.worker_runner) |*wr| {
        allocator.free(wr.crushcode_binary);
    }
    engine.worker_runner = null;
    try testing.expect(engine.hasWorkerRunner() == false);
}

test "saveCheckpoint and loadCheckpoint" {
    const allocator = std.testing.allocator;
    // Use an isolated test directory
    const test_dir = "/tmp/crushcode_test_orch_checkpoints";
    std.fs.cwd().deleteTree(test_dir) catch {};

    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Override checkpoint dir for test isolation
    if (engine.checkpoint_manager) |*cm| {
        cm.checkpoint_dir = test_dir;
    }

    var spawn_result = try engine.spawnTeam("Build something", 2);
    defer spawn_result.deinit(allocator);

    // Save a checkpoint
    try engine.saveCheckpoint(spawn_result.team_id);

    // List checkpoints — should have exactly 1
    const checkpoints = try engine.listCheckpoints();
    defer {
        for (checkpoints) |cp| allocator.free(cp);
        allocator.free(checkpoints);
    }
    try testing.expect(checkpoints.len == 1);

    // Load the checkpoint and verify it
    var loaded = try engine.loadCheckpoint(checkpoints[0]);
    defer loaded.deinit();
    try testing.expect(loaded.messages.len >= 1);
}

test "listCheckpoints returns empty initially" {
    const allocator = std.testing.allocator;
    // Clean up any previous test artifacts
    std.fs.cwd().deleteTree(".crushcode/checkpoints") catch {};

    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    const checkpoints = try engine.listCheckpoints();
    defer {
        for (checkpoints) |cp| allocator.free(cp);
        allocator.free(checkpoints);
    }
    try testing.expect(checkpoints.len == 0);
}

test "executePhase without worker_runner returns skipped" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree(".crushcode/checkpoints") catch {};

    var engine = try OrchestrationEngine.init(allocator);
    defer engine.deinit();

    // Spawn a team so we have a plan to execute
    var spawn_result = try engine.spawnTeam("Build a REST endpoint", 2);
    defer spawn_result.deinit(allocator);

    // Force no worker_runner to test graceful degradation
    if (engine.worker_runner) |*wr| {
        allocator.free(wr.crushcode_binary);
    }
    engine.worker_runner = null;
    try testing.expect(engine.hasWorkerRunner() == false);

    // Execute first phase — should be skipped
    var result = try engine.executePhase(spawn_result.team_id, 0);
    defer result.deinit(allocator);
    try testing.expect(result.status == .skipped);
    try testing.expect(result.phase_index == 0);
    try testing.expect(result.team_id.len > 0);
    try testing.expect(result.phase_name.len > 0);
    try testing.expect(result.output.len > 0);
}
