const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

// Recover terminal state on panic so the user's shell isn't left broken
pub const panic = vaxis.panic_handler;

const core = @import("core_api");
const config_mod = @import("config");
const fallback_mod = @import("fallback");
const graph_mod = @import("graph");
const registry_mod = @import("registry");
const session_mod = @import("session");
const diff = @import("diff");
const markdown = @import("markdown");
const theme_mod = @import("theme");
const usage_pricing = @import("usage_pricing");
const usage_budget = @import("usage_budget");
const widget_types = @import("widget_types");
const widget_helpers = @import("widget_helpers");
const widget_messages = @import("widget_messages");
const widget_header = @import("widget_header");
const widget_input = @import("widget_input");
const widget_sidebar = @import("widget_sidebar");
const widget_palette = @import("widget_palette");
const widget_permission = @import("widget_permission");
const widget_setup = @import("widget_setup");
const widget_spinner = @import("widget_spinner");
const widget_gradient = @import("widget_gradient");
const widget_toast = @import("widget_toast");
const widget_typewriter = @import("widget_typewriter");
const tool_executors = @import("chat_tool_executors");
const mcp_bridge_mod = @import("mcp_bridge");
const mcp_client_mod = @import("mcp_client");
const hybrid_bridge_mod = @import("hybrid_bridge");
const array_list_compat = @import("array_list_compat");
const compaction_mod = @import("compaction");
const project_mod = @import("project");
const lifecycle_mod = @import("lifecycle_hooks");
const memory_mod = @import("memory");
const parallel_mod = @import("parallel");
const plugin_mod = @import("plugin_manager");

// Types from widget_types
pub const WorkerStatus = widget_types.WorkerStatus;
pub const WorkerItem = widget_types.WorkerItem;
pub const Options = widget_types.Options;
pub const Message = widget_types.Message;
const ToolCallStatus = widget_types.ToolCallStatus;
const PermissionMode = widget_types.PermissionMode;
const PermissionDecision = widget_types.PermissionDecision;
const ToolPermission = widget_types.ToolPermission;
const FallbackProvider = widget_types.FallbackProvider;
const InterruptedSessionCandidate = widget_types.InterruptedSessionCandidate;
const app_version = widget_types.app_version;
const setup_provider_data = widget_types.setup_provider_data;
const recent_files_max = widget_types.recent_files_max;
const recent_files_display_max = widget_types.recent_files_display_max;
const tool_diff_max_lines = widget_types.tool_diff_max_lines;
const session_row_display_max = widget_types.session_row_display_max;
const recent_file_tool_names = widget_types.recent_file_tool_names;
const context_source_files = widget_types.context_source_files;
const builtin_tool_schemas = widget_types.builtin_tool_schemas;

threadlocal var active_stream_model: ?*Model = null;

// Widgets from widget_messages
const RoleLabelWidget = widget_messages.RoleLabelWidget;
const MessageContentWidget = widget_messages.MessageContentWidget;
const ToolCallWidget = widget_messages.ToolCallWidget;
const DiffWidget = widget_messages.DiffWidget;
const MessageGapWidget = widget_messages.MessageGapWidget;
const SeparatorWidget = widget_messages.SeparatorWidget;

// MessageWidget wrapper — bridges *Model to concrete data
const MessageWidget = struct {
    model: *const Model,
    message_index: usize,

    fn widget(self: *const MessageWidget) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = typeErasedDrawFn };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const MessageWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const MessageWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Determine if this is the streaming assistant message
        const is_streaming_target = (self.message_index == self.model.messages.items.len - 1 and
            self.model.assistant_stream_index != null and
            std.mem.eql(u8, self.model.messages.items[self.message_index].role, "assistant"));

        // Pass typewriter only for the actively streaming message
        const tw: ?*widget_typewriter.TypewriterState = if (is_streaming_target and self.model.typewriter != null)
            @constCast(&self.model.typewriter.?)
        else
            null;

        const inner = widget_messages.MessageWidget{
            .messages = self.model.messages.items,
            .message_index = self.message_index,
            .theme = self.model.current_theme,
            .typewriter = tw,
            .awaiting_first_token = if (is_streaming_target) self.model.awaiting_first_token else false,
        };
        return inner.draw(ctx);
    }
};

const HeaderWidget = widget_header.HeaderWidget;

const SurfaceWidget = struct {
    surface: vxfw.Surface,

    fn widget(self: *const SurfaceWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = ctx;
        const self: *const SurfaceWidget = @ptrCast(@alignCast(ptr));
        return self.surface;
    }
};

const FilesWidget = widget_sidebar.FilesWidget;

const SidebarWidget = widget_sidebar.SidebarWidget;
const SidebarContext = widget_sidebar.SidebarContext;

const InputWidget = widget_input.InputWidget;
const MultiLineInputWidget = widget_input.MultiLineInputWidget;

const Command = widget_palette.Command;
const palette_command_data = widget_palette.palette_command_data;
const CommandRowWidget = widget_palette.CommandRowWidget;
const SessionListRowWidget = widget_palette.SessionListRowWidget;
const SessionListWidget = widget_palette.SessionListWidget;
const ResumePromptWidget = widget_palette.ResumePromptWidget;
const CommandPaletteWidget = widget_palette.CommandPaletteWidget;
const collectFilteredCommandIndices = widget_palette.collectFilteredCommandIndices;
const commandDescriptionGap = widget_palette.commandDescriptionGap;
const formatSessionTimestamp = widget_palette.formatSessionTimestamp;

/// Slash command names used for autocomplete suggestions in the input field.
const slash_command_names = [_][]const u8{
    "/clear",
    "/sessions",
    "/ls",
    "/exit",
    "/model",
    "/thinking",
    "/compact",
    "/theme dark",
    "/theme light",
    "/theme mono",
    "/workers",
    "/kill",
    "/memory",
    "/plugins",
    "/help",
};

const PermissionContext = widget_permission.PermissionContext;
const PermissionDialogWidget = widget_permission.PermissionDialogWidget;

const SetupContext = widget_setup.SetupContext;
const SetupProviderRowWidget = widget_setup.SetupProviderRowWidget;
const SetupWizardWidget = widget_setup.SetupWizardWidget;
const appendSetupText = widget_setup.appendSetupText;
const setupProviderIndex = widget_setup.setupProviderIndex;
const setupProviderAllowsEmptyKey = widget_setup.setupProviderAllowsEmptyKey;
const setupDefaultModel = widget_setup.setupDefaultModel;
const setupConfigPath = widget_setup.setupConfigPath;
const isSupportedSlashCommand = widget_setup.isSupportedSlashCommand;

/// Core hook: tracks token usage after each AI request
fn hookTokenTracker(ctx: *lifecycle_mod.HookContext) anyerror!void {
    std.log.info("[hook:token_tracker] tokens={} provider={s} model={s}", .{ ctx.token_count, ctx.provider, ctx.model });
}

/// Core hook: logs errors
fn hookErrorLogger(ctx: *lifecycle_mod.HookContext) anyerror!void {
    const err_msg = ctx.error_message orelse "unknown error";
    std.log.warn("[hook:error_logger] {s}", .{err_msg});
}

/// Core hook: tracks tool execution timing (logged after tool completes)
fn hookToolTimer(ctx: *lifecycle_mod.HookContext) anyerror!void {
    const tool = ctx.tool_name orelse "unknown";
    std.log.info("[hook:tool_timer] tool={s}", .{tool});
}

pub const Model = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    model_name: []const u8,
    api_key: []const u8,
    system_prompt: ?[]const u8,
    effective_system_prompt: ?[]const u8,
    codebase_context: ?[]const u8,
    context_file_count: u32,
    knowledge_graph: ?*graph_mod.KnowledgeGraph,
    compactor: compaction_mod.ContextCompactor,
    context_tokens: u64,
    last_compaction_summary: []const u8,
    cached_project_info: ?project_mod.ProjectInfo,
    max_tokens: u32,
    temperature: f32,
    override_url: ?[]const u8,
    thinking: bool,
    app: *vxfw.App,
    registry: registry_mod.ProviderRegistry,
    client: ?core.AIClient,
    messages: std.ArrayList(Message),
    history: std.ArrayList(core.ChatMessage),
    input: widget_input.MultiLineInputState,
    show_palette: bool,
    palette_input: vxfw.TextField,
    palette_commands: []const Command,
    palette_selected: usize,
    palette_filter: []const u8,
    scroll_view: vxfw.ScrollView,
    scroll_bars: vxfw.ScrollBars,
    recent_files: std.ArrayList([]const u8),
    fallback_chain: fallback_mod.FallbackChain,
    fallback_providers: std.ArrayList(FallbackProvider),
    active_provider_index: usize,
    max_iterations: u32,
    permission_mode: PermissionMode,
    pending_permission: ?ToolPermission,
    always_allow_tools: std.ArrayList([]const u8),
    permission_mutex: std.Thread.Mutex,
    permission_condition: std.Thread.Condition,
    permission_decision: ?PermissionDecision,
    status_message: []const u8,
    current_theme: *const theme_mod.Theme,
    lock: std.Thread.Mutex,
    worker: ?std.Thread,
    request_active: bool,
    request_done: bool,
    awaiting_first_token: bool,
    assistant_stream_index: ?usize,
    should_quit: bool,
    total_input_tokens: u64,
    total_output_tokens: u64,
    request_count: u32,
    session_start: i128,
    pricing_table: usage_pricing.PricingTable,
    budget_mgr: usage_budget.BudgetManager,
    setup_phase: u8,
    setup_provider_index: usize,
    setup_feedback: []const u8,
    setup_feedback_is_error: bool,
    session_dir: []const u8,
    current_session: ?session_mod.Session,
    session_path: []const u8,
    show_session_list: bool,
    session_list: []session_mod.Session,
    session_list_selected: usize,
    resume_prompt_session: ?session_mod.Session,
    resume_prompt_path: ?[]const u8,
    sidebar_visible: bool = false,
    scroll_mode: bool = false,
    show_help: bool = false,
    auto_scroll: bool = true,
    selected_message_index: ?usize = null,
    workers: std.ArrayList(WorkerItem),
    next_worker_id: u32 = 0,
    spinner: ?widget_spinner.AnimatedSpinner = null,
    toast_stack: widget_toast.ToastStack,
    typewriter: ?widget_typewriter.TypewriterState = null,
    mcp_bridge: ?*mcp_bridge_mod.Bridge = null,
    hybrid_bridge: ?*hybrid_bridge_mod.HybridBridge = null,
    plugin_manager: plugin_mod.runtime.ExternalPluginManager,
    lifecycle_hooks: lifecycle_mod.LifecycleHooks,
    memory: memory_mod.Memory,
    parallel_executor: parallel_mod.ParallelExecutor,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);

        // Initialize vxfw.App manually to avoid the dangling pointer bug in
        // vxfw.App.init() (issue #311). That function creates App on the
        // stack, passes &app.buffer to Tty.init(), then returns by value —
        // the tty_writer ends up pointing to freed stack memory. By
        // constructing App directly on the heap, &app.buffer is stable.
        const app = try allocator.create(vxfw.App);
        errdefer allocator.destroy(app);
        app.* = .{
            .allocator = allocator,
            .tty = undefined,
            .vx = try vaxis.init(allocator, .{
                .system_clipboard_allocator = allocator,
                .kitty_keyboard_flags = .{
                    .report_events = true,
                },
            }),
            .timers = std.ArrayList(vxfw.Tick){},
            .wants_focus = null,
            .buffer = undefined,
        };
        // Init Tty with heap buffer — pointer is stable for the lifetime of app
        app.tty = try vaxis.Tty.init(&app.buffer);
        errdefer app.deinit();

        model.* = .{
            .allocator = allocator,
            .provider_name = try allocator.dupe(u8, options.provider_name),
            .model_name = try allocator.dupe(u8, options.model_name),
            .api_key = try allocator.dupe(u8, options.api_key),
            .system_prompt = if (options.system_prompt) |system_prompt| try allocator.dupe(u8, system_prompt) else null,
            .effective_system_prompt = null,
            .codebase_context = null,
            .context_file_count = 0,
            .knowledge_graph = null,
            .compactor = compaction_mod.ContextCompactor.init(allocator, 128000),
            .context_tokens = 0,
            .last_compaction_summary = "",
            .cached_project_info = project_mod.detectProject(allocator),
            .max_tokens = options.max_tokens,
            .temperature = options.temperature,
            .override_url = if (options.override_url) |override_url| try allocator.dupe(u8, override_url) else null,
            .thinking = false,
            .app = app,
            .registry = registry_mod.ProviderRegistry.init(allocator),
            .client = null,
            .messages = std.ArrayList(Message).empty,
            .history = std.ArrayList(core.ChatMessage).empty,
            .input = widget_input.MultiLineInputState.init(allocator),
            .show_palette = false,
            .palette_input = vxfw.TextField.init(allocator),
            .palette_commands = &palette_command_data,
            .palette_selected = 0,
            .palette_filter = "",
            .scroll_view = .{
                .children = .{ .slice = &.{} },
                .draw_cursor = false,
                .wheel_scroll = 3,
            },
            .scroll_bars = undefined,
            .recent_files = try std.ArrayList([]const u8).initCapacity(allocator, 5),
            .fallback_chain = fallback_mod.FallbackChain.init(allocator),
            .fallback_providers = std.ArrayList(FallbackProvider).empty,
            .active_provider_index = 0,
            .max_iterations = 10,
            .permission_mode = .default,
            .pending_permission = null,
            .always_allow_tools = std.ArrayList([]const u8).empty,
            .permission_mutex = .{},
            .permission_condition = .{},
            .permission_decision = null,
            .status_message = "",
            .current_theme = theme_mod.defaultTheme(),
            .lock = .{},
            .worker = null,
            .request_active = false,
            .request_done = false,
            .awaiting_first_token = false,
            .assistant_stream_index = null,
            .should_quit = false,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .request_count = 0,
            .session_start = std.time.nanoTimestamp(),
            .pricing_table = try usage_pricing.PricingTable.init(allocator),
            .budget_mgr = usage_budget.BudgetManager.init(allocator, .{}),
            .setup_phase = if (options.api_key.len == 0) 1 else 0,
            .setup_provider_index = setupProviderIndex(options.provider_name),
            .setup_feedback = "",
            .setup_feedback_is_error = false,
            .session_dir = try session_mod.defaultSessionDir(allocator),
            .current_session = null,
            .session_path = "",
            .show_session_list = false,
            .session_list = &.{},
            .session_list_selected = 0,
            .resume_prompt_session = null,
            .resume_prompt_path = null,
            .sidebar_visible = false,
            .workers = std.ArrayList(WorkerItem).empty,
            .spinner = null,
            .toast_stack = undefined,
            .typewriter = null,
            .lifecycle_hooks = lifecycle_mod.LifecycleHooks.init(allocator),
            .memory = memory_mod.Memory.init(allocator, "", 100),
            .parallel_executor = parallel_mod.ParallelExecutor.init(allocator, 3),
            .plugin_manager = plugin_mod.runtime.ExternalPluginManager.init(allocator, ""),
        };
        errdefer model.destroy();

        model.messages = try std.ArrayList(Message).initCapacity(allocator, 8);
        model.history = try std.ArrayList(core.ChatMessage).initCapacity(allocator, 8);
        model.fallback_providers = try std.ArrayList(FallbackProvider).initCapacity(allocator, setup_provider_data.len);
        model.always_allow_tools = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        model.workers = try std.ArrayList(WorkerItem).initCapacity(allocator, 4);
        model.spinner = null;
        model.toast_stack = widget_toast.ToastStack.init(allocator, model.current_theme);
        model.typewriter = null;

        // Initialize MCP bridge (non-fatal if it fails)
        {
            var mcp_client = allocator.create(mcp_client_mod.MCPClient) catch null;
            if (mcp_client) |mc| {
                mc.* = mcp_client_mod.MCPClient.init(allocator);
                var bridge = allocator.create(mcp_bridge_mod.Bridge) catch null;
                if (bridge) |b| {
                    b.* = mcp_bridge_mod.Bridge.init(allocator, mc) catch {
                        allocator.destroy(b);
                        allocator.destroy(mc);
                        bridge = null;
                        mcp_client = null;
                    };
                    if (bridge != null) {
                        model.mcp_bridge = bridge;
                    }
                } else {
                    allocator.destroy(mc);
                }
            }
            if (model.mcp_bridge == null) {
                std.log.warn("MCP bridge initialization skipped (non-fatal)", .{});
            }
        }

        // Initialize plugin manager with plugin directory (non-fatal)
        {
            const plugin_dir = try std.fmt.allocPrint(allocator, "{s}/plugins", .{model.session_dir});
            model.plugin_manager = plugin_mod.runtime.ExternalPluginManager.init(allocator, plugin_dir);
            model.plugin_manager.discoverPlugins() catch {}; // non-fatal
        }

        // Initialize HybridBridge for unified tool dispatch
        {
            const hb = allocator.create(hybrid_bridge_mod.HybridBridge) catch null;
            if (hb) |h| {
                h.* = hybrid_bridge_mod.HybridBridge.init(allocator, model.mcp_bridge, &model.plugin_manager);
                model.hybrid_bridge = hb;
            }
        }
        model.applyThemeStyles();
        model.input.userdata = model;
        model.input.onSubmit = onSubmit;
        model.input.prompt = "❯ ";
        model.input.suggestion_list = &slash_command_names;
        model.palette_input.userdata = model;
        model.palette_input.onChange = onPaletteChange;
        model.palette_input.onSubmit = onPaletteSubmit;

        // Register core lifecycle hooks
        try model.lifecycle_hooks.register("token_tracker", .core, .post_request, hookTokenTracker, 10);
        try model.lifecycle_hooks.register("error_logger", .core, .on_error, hookErrorLogger, 10);
        try model.lifecycle_hooks.register("tool_timer", .core, .post_tool, hookToolTimer, 10);

        // Execute session_start lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .session_start;
            model.lifecycle_hooks.execute(.session_start, &hook_ctx) catch {};
        }

        try model.registry.registerAllProviders();
        try model.buildCodebaseContext();
        try model.loadFallbackProviders();
        try std.fs.cwd().makePath(model.session_dir);

        // Initialize cross-session memory with proper path
        {
            const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.json", .{model.session_dir});
            model.memory = memory_mod.Memory.init(allocator, memory_path, 100);
            model.memory.load() catch {}; // non-fatal
        }

        try model.prepareStartupSessionState();
        if (model.setup_phase != 0) {
            const selected_provider = setup_provider_data[model.setup_provider_index];
            if (model.provider_name.len == 0) {
                model.allocator.free(model.provider_name);
                model.provider_name = try model.allocator.dupe(u8, selected_provider);
            }
        } else {
            try model.addMessageUnlocked("assistant", "TUI chat ready. Type a message and press Enter.");
            try model.initializeClient();
        }
        return model;
    }

    pub fn destroy(self: *Model) void {
        self.resolvePendingPermission(.no);
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
        for (self.workers.items) |*w| {
            if (w.task.len > 0) self.allocator.free(w.task);
            if (w.result) |r| self.allocator.free(r);
            if (w.@"error") |e| self.allocator.free(e);
        }
        self.workers.deinit(self.allocator);
        if (self.client) |*client| {
            client.deinit();
        }
        self.input.deinit();
        self.palette_input.deinit();
        for (self.messages.items) |message| {
            freeDisplayMessage(self.allocator, message);
        }
        self.messages.deinit(self.allocator);
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.deinit(self.allocator);
        self.registry.deinit();
        self.toast_stack.deinit();
        self.pricing_table.deinit();
        self.budget_mgr.deinit();
        if (self.system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.effective_system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.codebase_context) |codebase_context| self.allocator.free(codebase_context);
        if (self.knowledge_graph) |kg| {
            kg.deinit();
            self.allocator.destroy(kg);
        }
        if (self.override_url) |override_url| self.allocator.free(override_url);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        if (self.setup_feedback.len > 0) self.allocator.free(self.setup_feedback);
        if (self.current_session) |*session| session_mod.deinitSession(self.allocator, session);
        self.clearSessionListOwned();
        if (self.resume_prompt_session) |*session| session_mod.deinitSession(self.allocator, session);
        if (self.resume_prompt_path) |path| self.allocator.free(path);
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.allocator.free(self.session_dir);
        self.allocator.free(self.provider_name);
        self.allocator.free(self.model_name);
        self.compactor.deinit();
        if (self.last_compaction_summary.len > 0) self.allocator.free(self.last_compaction_summary);
        self.allocator.free(self.api_key);
        if (self.mcp_bridge) |bridge| {
            bridge.deinit();
            self.allocator.destroy(bridge);
        }
        if (self.hybrid_bridge) |hb| {
            hb.deinit();
            self.allocator.destroy(hb);
        }
        // Clean up plugin manager
        self.plugin_manager.deinit();
        // Clean up parallel executor
        self.parallel_executor.waitForAll();
        self.parallel_executor.deinit();
        // Clean up memory
        self.memory.deinit();
        // Execute session_end lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .session_end;
            self.lifecycle_hooks.execute(.session_end, &hook_ctx) catch {};
        }
        self.lifecycle_hooks.deinit();
        self.app.deinit();
        self.allocator.destroy(self.app);
        self.allocator.destroy(self);
    }

    pub fn run(self: *Model) !void {
        // Ensure the screen has a valid size before entering the render loop.
        // App.run() will call doLayout which divides width_pix / width —
        // a division-by-zero if the screen hasn't been resized yet or if
        // the terminal reports zero dimensions.
        const app = self.app;
        const tty = &app.tty;
        const vx = &app.vx;
        var ws: vaxis.Winsize = vaxis.Tty.getWinsize(app.tty.fd) catch
            .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 384 };
        // Clamp to sane minimums — some terminals report 0 for some fields
        if (ws.cols == 0) ws.cols = 80;
        if (ws.rows == 0) ws.rows = 24;
        if (ws.x_pixel == 0) ws.x_pixel = ws.cols * 8;
        if (ws.y_pixel == 0) ws.y_pixel = ws.rows * 16;
        try vx.resize(self.allocator, tty.writer(), ws);

        try self.app.run(self.widget(), .{ .framerate = 30 });
    }

    fn prepareStartupSessionState(self: *Model) !void {
        const interrupted = try self.findInterruptedSessionCandidate();
        errdefer if (interrupted) |candidate| {
            var session = candidate.session;
            session_mod.deinitSession(self.allocator, &session);
            self.allocator.free(candidate.path);
        };

        try self.beginNewSessionUnlocked();
        if (interrupted) |candidate| {
            self.resume_prompt_session = candidate.session;
            self.resume_prompt_path = candidate.path;
        }
    }

    fn beginNewSessionUnlocked(self: *Model) !void {
        const now = std.time.timestamp();
        var session = session_mod.Session{
            .id = try session_mod.generateSessionId(self.allocator),
            .created_at = now,
            .updated_at = now,
            .title = try self.allocator.dupe(u8, "New session"),
            .messages = try self.allocator.alloc(session_mod.Message, 0),
            .model = try self.allocator.dupe(u8, self.model_name),
            .provider = try self.allocator.dupe(u8, self.provider_name),
            .total_tokens = 0,
            .total_cost = 0,
            .turn_count = 0,
            .duration_seconds = 0,
        };
        errdefer session_mod.deinitSession(self.allocator, &session);

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
        errdefer self.allocator.free(path);

        try session_mod.saveSession(self.allocator, self.session_dir, &session);

        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = session;
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.session_path = path;
        self.session_start = std.time.nanoTimestamp();
    }

    fn findInterruptedSessionCandidate(self: *Model) !?InterruptedSessionCandidate {
        const sessions = try session_mod.listSessions(self.allocator, self.session_dir);
        defer self.allocator.free(sessions);

        const now = std.time.timestamp();
        for (sessions, 0..) |session, index| {
            if (session.updated_at + 300 >= now) continue;
            if (!session_mod.isInterrupted(&session)) continue;

            const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session.id);
            for (sessions, 0..) |*other, other_index| {
                if (other_index == index) continue;
                session_mod.deinitSession(self.allocator, other);
            }
            return .{ .session = session, .path = path };
        }

        for (sessions) |*session| session_mod.deinitSession(self.allocator, session);
        return null;
    }

    fn clearRecentFilesUnlocked(self: *Model) void {
        for (self.recent_files.items) |file| self.allocator.free(file);
        self.recent_files.clearRetainingCapacity();
    }

    fn clearSessionListOwned(self: *Model) void {
        if (self.session_list.len == 0) {
            self.session_list = &.{};
            self.session_list_selected = 0;
            self.show_session_list = false;
            return;
        }
        for (self.session_list) |*session| session_mod.deinitSession(self.allocator, session);
        self.allocator.free(self.session_list);
        self.session_list = &.{};
        self.session_list_selected = 0;
        self.show_session_list = false;
    }

    fn clearResumePromptOwned(self: *Model) void {
        if (self.resume_prompt_session) |*session| {
            session_mod.deinitSession(self.allocator, session);
            self.resume_prompt_session = null;
        }
        if (self.resume_prompt_path) |path| {
            self.allocator.free(path);
            self.resume_prompt_path = null;
        }
    }

    fn saveSessionSnapshotUnlocked(self: *Model) !void {
        const current = self.current_session orelse return;
        var snapshot = session_mod.Session{
            .id = try self.allocator.dupe(u8, current.id),
            .created_at = current.created_at,
            .updated_at = std.time.timestamp(),
            .title = try self.allocator.dupe(u8, current.title),
            .messages = try self.buildSessionMessagesUnlocked(),
            .model = try self.allocator.dupe(u8, self.model_name),
            .provider = try self.allocator.dupe(u8, self.provider_name),
            .total_tokens = self.total_input_tokens + self.total_output_tokens,
            .total_cost = self.estimatedCostUsd(),
            .turn_count = self.request_count,
            .duration_seconds = @intCast(@min(self.sessionElapsedSeconds(), std.math.maxInt(u32))),
        };
        errdefer session_mod.deinitSession(self.allocator, &snapshot);

        try session_mod.saveSession(self.allocator, self.session_dir, &snapshot);
        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = snapshot;
    }

    fn buildSessionMessagesUnlocked(self: *Model) ![]session_mod.Message {
        const copied = try self.allocator.alloc(session_mod.Message, self.messages.items.len);
        errdefer self.allocator.free(copied);

        for (self.messages.items, 0..) |message, index| {
            copied[index] = .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = try self.allocator.dupe(u8, message.content),
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            };
        }
        return copied;
    }

    fn restoreSessionUnlocked(self: *Model, session: session_mod.Session, path: []const u8) !void {
        var owned_session = session;
        errdefer session_mod.deinitSession(self.allocator, &owned_session);

        self.clearMessagesUnlocked();
        self.clearHistoryUnlocked();
        self.clearRecentFilesUnlocked();
        self.assistant_stream_index = null;
        self.awaiting_first_token = false;
        self.request_active = false;
        self.request_done = false;

        for (owned_session.messages) |message| {
            try self.messages.append(self.allocator, .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = if (message.content) |content| try self.allocator.dupe(u8, content) else try self.allocator.dupe(u8, ""),
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            });
            try self.history.append(self.allocator, .{
                .role = try self.allocator.dupe(u8, message.role),
                .content = if (message.content) |content| try self.allocator.dupe(u8, content) else null,
                .tool_call_id = if (message.tool_call_id) |tool_call_id| try self.allocator.dupe(u8, tool_call_id) else null,
                .tool_calls = try cloneToolCallInfos(self.allocator, message.tool_calls),
            });
            if (message.tool_calls) |tool_calls| {
                try self.trackToolCallFilesUnlocked(tool_calls);
            }
        }

        try self.replaceOwnedString(&self.provider_name, owned_session.provider);
        try self.replaceOwnedString(&self.model_name, owned_session.model);
        self.resetFallbackProviders();
        try self.loadFallbackProviders();
        try self.refreshClientForSessionResumeUnlocked();

        self.total_input_tokens = owned_session.total_tokens;
        self.total_output_tokens = 0;
        self.request_count = owned_session.turn_count;
        self.session_start = std.time.nanoTimestamp() - (@as(i128, owned_session.duration_seconds) * std.time.ns_per_s);

        if (self.current_session) |*existing| session_mod.deinitSession(self.allocator, existing);
        self.current_session = owned_session;
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.session_path = try self.allocator.dupe(u8, path);

        const status = try std.fmt.allocPrint(self.allocator, "Resumed session {s}", .{owned_session.id});
        defer self.allocator.free(status);
        try self.setStatusMessageUnlocked(status);
    }

    fn refreshClientForSessionResumeUnlocked(self: *Model) !void {
        var config = config_mod.Config.init(self.allocator);
        defer config.deinit();

        config.loadDefault() catch |err| switch (err) {
            error.ConfigNotFound, error.FileNotFound => {},
            else => return err,
        };

        if (config.getApiKey(self.provider_name)) |api_key| {
            try self.replaceOwnedString(&self.api_key, api_key);
        } else if (setupProviderAllowsEmptyKey(self.provider_name)) {
            try self.replaceOwnedString(&self.api_key, "");
        }

        if (self.override_url) |override_url| {
            self.allocator.free(override_url);
            self.override_url = null;
        }
        if (config.getProviderOverrideUrl(self.provider_name)) |override_url| {
            self.override_url = try self.allocator.dupe(u8, override_url);
        }

        if (self.client) |*existing_client| {
            existing_client.deinit();
            self.client = null;
        }

        const provider = self.registry.getProvider(self.provider_name) orelse {
            try self.setStatusMessageUnlocked("Resumed session provider is not registered.");
            return;
        };
        if (self.api_key.len == 0 and !provider.config.is_local) {
            try self.setStatusMessageUnlocked("Missing API key for resumed session provider.");
            return;
        }

        var client = try core.AIClient.init(self.allocator, provider, self.model_name, self.api_key);
        client.max_tokens = self.max_tokens;
        client.temperature = self.temperature;
        client.setTools(&builtin_tool_schemas);
        if (self.override_url) |value| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, value);
        }
        try self.refreshEffectiveSystemPrompt();
        if (self.effective_system_prompt) |system_prompt| {
            client.setSystemPrompt(system_prompt);
        }
        self.client = client;
    }

    fn openSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
        self.clearSessionListOwned();
        const loaded = try session_mod.listSessions(self.allocator, self.session_dir);
        if (loaded.len == 0) {
            self.allocator.free(loaded);
            self.session_list = &.{};
        } else {
            self.session_list = loaded;
        }
        self.show_session_list = true;
        self.session_list_selected = 0;
        // NOTE: No requestFocus — Model stays focused, keys forwarded manually
        ctx.redraw = true;
    }

    fn closeSessionList(self: *Model, ctx: *vxfw.EventContext) !void {
        self.clearSessionListOwned();
        // NOTE: No requestFocus — Model stays focused, keys forwarded manually
        ctx.redraw = true;
    }

    fn moveSessionListSelection(self: *Model, delta: isize) void {
        if (self.session_list.len == 0) {
            self.session_list_selected = 0;
            return;
        }
        const current: isize = @intCast(self.session_list_selected);
        const max_index: isize = @intCast(self.session_list.len - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.session_list_selected = @intCast(next);
    }

    fn executeSessionSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.session_list.len == 0) {
            try self.closeSessionList(ctx);
            return;
        }

        const session_id = try self.allocator.dupe(u8, self.session_list[self.session_list_selected].id);
        defer self.allocator.free(session_id);
        try self.closeSessionList(ctx);
        try self.resumeSessionByIdUnlocked(session_id);
        ctx.redraw = true;
    }

    fn resumeSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
        if (self.request_active) {
            try self.addMessageUnlocked("error", "Cannot resume a session while a response is still streaming.");
            return;
        }

        try self.saveSessionSnapshotUnlocked();

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
        defer self.allocator.free(path);
        const loaded = try session_mod.loadSession(self.allocator, path);
        try self.restoreSessionUnlocked(loaded, path);
    }

    fn deleteSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
        defer self.allocator.free(path);

        const deleting_current = if (self.current_session) |session|
            std.mem.eql(u8, session.id, session_id)
        else
            false;

        try session_mod.deleteSession(self.allocator, path);
        if (deleting_current) {
            self.clearMessagesUnlocked();
            self.clearHistoryUnlocked();
            self.clearRecentFilesUnlocked();
            self.total_input_tokens = 0;
            self.total_output_tokens = 0;
            self.request_count = 0;
            self.assistant_stream_index = null;
            self.awaiting_first_token = false;
            try self.beginNewSessionUnlocked();
        }
    }

    fn handleResumePromptDecision(self: *Model, should_resume: bool) !void {
        if (!should_resume) {
            if (self.resume_prompt_path) |path| {
                session_mod.deleteSession(self.allocator, path) catch {};
            }
            self.clearResumePromptOwned();
            return;
        }

        const prompt_session = self.resume_prompt_session orelse return;
        const prompt_path = self.resume_prompt_path orelse return;

        if (self.session_path.len > 0) {
            session_mod.deleteSession(self.allocator, self.session_path) catch {};
            self.allocator.free(self.session_path);
            self.session_path = "";
        }
        if (self.current_session) |*existing| {
            session_mod.deinitSession(self.allocator, existing);
            self.current_session = null;
        }

        self.resume_prompt_session = null;
        self.resume_prompt_path = null;
        try self.restoreSessionUnlocked(prompt_session, prompt_path);
        self.allocator.free(prompt_path);
    }

    fn initializeClient(self: *Model) !void {
        return self.initializeClientFor(self.provider_name, self.model_name, self.api_key, self.override_url);
    }

    fn initializeClientFor(self: *Model, provider_name: []const u8, model_name: []const u8, api_key: []const u8, override_url: ?[]const u8) !void {
        if (provider_name.len == 0) {
            try self.addMessageUnlocked("error", "No provider configured. Set one in ~/.crushcode/config.toml or use a profile.");
            return;
        }

        const provider = self.registry.getProvider(provider_name) orelse {
            const text = try std.fmt.allocPrint(self.allocator, "Provider '{s}' is not registered. Run 'crushcode list --providers' to see available providers.", .{provider_name});
            defer self.allocator.free(text);
            try self.addMessageUnlocked("error", text);
            return;
        };

        if (api_key.len == 0 and !provider.config.is_local) {
            try self.addMessageUnlocked("error", "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml");
            return;
        }

        if (self.client) |*existing_client| {
            existing_client.deinit();
            self.client = null;
        }

        var client = try core.AIClient.init(self.allocator, provider, model_name, api_key);
        client.max_tokens = self.max_tokens;
        client.temperature = self.temperature;
        client.setTools(&builtin_tool_schemas);
        if (override_url) |value| {
            self.allocator.free(client.provider.config.base_url);
            client.provider.config.base_url = try self.allocator.dupe(u8, value);
        }
        try self.refreshEffectiveSystemPrompt();
        if (self.effective_system_prompt) |system_prompt| {
            client.setSystemPrompt(system_prompt);
        }
        self.client = client;
    }

    fn buildCodebaseContext(self: *Model) !void {
        // Clean up any previous knowledge graph
        if (self.knowledge_graph) |kg| {
            kg.deinit();
            self.allocator.destroy(kg);
            self.knowledge_graph = null;
        }

        const kg_ptr = try self.allocator.create(graph_mod.KnowledgeGraph);
        kg_ptr.* = graph_mod.KnowledgeGraph.init(self.allocator);
        errdefer {
            kg_ptr.deinit();
            self.allocator.destroy(kg_ptr);
        }

        // Dynamic file discovery with fallback to hardcoded list
        const discovered = widget_types.discoverSourceFiles(self.allocator) catch null;
        const source_files: []const []const u8 = discovered orelse &context_source_files;
        defer {
            if (discovered) |files| {
                for (files) |f| self.allocator.free(f);
                self.allocator.free(files);
            }
        }

        var indexed_count: u32 = 0;
        for (source_files) |file_path| {
            kg_ptr.indexFile(file_path) catch continue;
            indexed_count += 1;
        }
        kg_ptr.detectCommunities() catch {};

        if (indexed_count == 0) {
            kg_ptr.deinit();
            self.allocator.destroy(kg_ptr);
            return;
        }

        // Store knowledge graph persistently for query-based refresh
        self.knowledge_graph = kg_ptr;
        self.codebase_context = try kg_ptr.toCompressedContext(self.allocator);
        self.context_file_count = indexed_count;
    }

    /// Refresh codebase context filtered by query relevance.
    /// Uses the stored KnowledgeGraph to pick only relevant nodes.
    fn refreshContextForQuery(self: *Model, query: []const u8) void {
        const kg = self.knowledge_graph orelse return;
        if (query.len == 0) return;

        // Skip very short queries (likely slash commands or single chars)
        if (query.len < 3) return;

        // Allocate a fresh relevant context, limited to 4000 tokens
        const relevant = kg.toRelevantContext(self.allocator, query, 4000) catch return;
        errdefer self.allocator.free(relevant);

        // Only replace if we got something useful
        if (relevant.len == 0) {
            self.allocator.free(relevant);
            return;
        }

        // Swap the context
        if (self.codebase_context) |old| {
            self.allocator.free(old);
        }
        self.codebase_context = relevant;

        // Rebuild system prompt with the new filtered context
        self.refreshEffectiveSystemPrompt() catch {};
    }

    fn refreshEffectiveSystemPrompt(self: *Model) !void {
        if (self.effective_system_prompt) |existing| {
            self.allocator.free(existing);
            self.effective_system_prompt = null;
        }

        const base_prompt = if (self.system_prompt) |prompt|
            if (prompt.len > 0) prompt else null
        else
            null;

        // Build rich base prompt with project info and instructions
        var rich_buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer rich_buf.deinit();
        const rw = rich_buf.writer();

        if (base_prompt) |user_prompt| {
            rw.print("{s}", .{user_prompt}) catch {};
        } else {
            rw.print(
                \\You are Crushcode, an expert AI coding assistant with access to the user's codebase.
                \\
                \\## Guidelines
                \\- Read files before editing to understand context
                \\- Make minimal, focused changes — don't refactor unless asked
                \\- Use the edit tool for surgical changes, write_file only for new files
                \\- Verify your changes by reading the file after editing
                \\- Follow existing code patterns and conventions in the project
                \\- When running commands, prefer non-destructive operations first
            , .{}) catch {};
        }

        // Inject project info if detected
        if (self.cached_project_info) |project| {
            rw.print(
                \\
                \\## Project: {s} ({s})
                \\Build: `{s}`
                \\Test: `{s}`
                \\{s}
            , .{ project.language, project.build_system, project.build_command, project.test_command, project.tips }) catch {};

            if (project.framework) |fw| {
                rw.print("\nFramework: {s}", .{fw}) catch {};
            }
        }

        // Load AGENTS.md project instructions
        if (project_mod.loadAgentsMd(self.allocator) catch null) |agents_content| {
            defer self.allocator.free(agents_content);
            if (agents_content.len > 0) {
                rw.print(
                    \\
                    \\## Project Instructions (AGENTS.md)
                    \\{s}
                , .{agents_content}) catch {};
            }
        }

        // Load .crushcode/instructions.md
        if (project_mod.loadInstructionsMd(self.allocator) catch null) |instructions| {
            defer self.allocator.free(instructions);
            if (instructions.len > 0) {
                rw.print(
                    \\
                    \\## Custom Instructions
                    \\{s}
                , .{instructions}) catch {};
            }
        }

        const final_base = rich_buf.items;

        if (self.codebase_context) |raw_context| {
            const system_prompt_token_budget: u64 = 8000;

            // Estimate tokens for base prompt + tool section (~500 tokens overhead)
            var base_buf = array_list_compat.ArrayList(u8).init(self.allocator);
            defer base_buf.deinit();
            const bw = base_buf.writer();
            bw.print(
                \\{s}
                \\
                \\## Codebase Context
                \\
            , .{final_base}) catch {};
            const base_tokens = compaction_mod.ContextCompactor.estimateTokens(base_buf.items);
            const tool_overhead: u64 = 500;
            const remaining_budget = if (system_prompt_token_budget > base_tokens + tool_overhead)
                system_prompt_token_budget - base_tokens - tool_overhead
            else
                @as(u64, 1000);

            const context_tokens = compaction_mod.ContextCompactor.estimateTokens(raw_context);
            const context_to_use: []const u8 = if (context_tokens > remaining_budget) blk: {
                // Truncate context to fit budget
                const max_chars = remaining_budget * 4;
                const trunc_len = @min(max_chars, raw_context.len);
                break :blk raw_context[0..trunc_len];
            } else raw_context;

            var buf = array_list_compat.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            const w = buf.writer();
            w.print(
                \\{s}
                \\
                \\## Codebase Context
                \\{s}
            , .{ final_base, context_to_use }) catch {};

            if (context_tokens > remaining_budget) {
                w.print("\n[Context truncated: {d}/{d} tokens used in budget]\n", .{ remaining_budget, context_tokens }) catch {};
            }

            w.print(
                \\
                \\## Available Tools
                \\- read_file(path)
                \\- shell(command)
                \\- write_file(path, content)
                \\- glob(pattern)
                \\- grep(pattern)
                \\- edit(file_path, old_string, new_string)
            , .{}) catch {};
            if (self.hybrid_bridge) |hb| {
                const all_schemas = hb.getAllToolSchemas() catch null;
                if (all_schemas) |schemas| {
                    defer {
                        for (schemas) |s| {
                            self.allocator.free(s.name);
                            self.allocator.free(s.description);
                            self.allocator.free(s.parameters);
                        }
                        self.allocator.free(schemas);
                    }
                    // Count MCP tools (schemas beyond the 6 builtins)
                    const builtin_count = builtin_tool_schemas.len;
                    const mcp_count = if (schemas.len > builtin_count) schemas.len - builtin_count else 0;
                    if (mcp_count > 0) {
                        w.print("\n\n## MCP Tools ({d} available)\n", .{mcp_count}) catch {};
                        for (schemas[builtin_count..]) |schema| {
                            w.print("- {s}\n", .{schema.description}) catch {};
                        }
                    }
                }
            }
            self.effective_system_prompt = try buf.toOwnedSlice();
            return;
        }

        // No codebase context — just base prompt + tools if available
        if (self.hybrid_bridge) |hb| {
            const stats = hb.getStats();
            if (stats.mcp_count > 0) {
                var buf = array_list_compat.ArrayList(u8).init(self.allocator);
                defer buf.deinit();
                const w = buf.writer();
                w.print("{s}\n\n## MCP Tools ({d} available)\n", .{ final_base, stats.mcp_count }) catch {};
                const all_schemas = hb.getAllToolSchemas() catch null;
                if (all_schemas) |schemas| {
                    defer {
                        for (schemas) |s| {
                            self.allocator.free(s.name);
                            self.allocator.free(s.description);
                            self.allocator.free(s.parameters);
                        }
                        self.allocator.free(schemas);
                    }
                    const builtin_count = builtin_tool_schemas.len;
                    for (schemas[builtin_count..]) |schema| {
                        w.print("- {s}\n", .{schema.description}) catch {};
                    }
                }
                self.effective_system_prompt = try buf.toOwnedSlice();
                return;
            }
        }

        self.effective_system_prompt = try self.allocator.dupe(u8, final_base);
    }

    fn loadFallbackProviders(self: *Model) !void {
        var config = config_mod.Config.init(self.allocator);
        defer config.deinit();

        config.loadDefault() catch |err| switch (err) {
            error.ConfigNotFound, error.FileNotFound => {},
            else => return err,
        };

        try self.appendFallbackProvider(self.provider_name, self.api_key, self.model_name, self.override_url);

        for (setup_provider_data) |provider_name| {
            if (std.mem.eql(u8, provider_name, self.provider_name)) continue;
            const provider = self.registry.getProvider(provider_name) orelse continue;
            const api_key = config.getApiKey(provider_name) orelse "";
            if (api_key.len == 0 and !provider.config.is_local) continue;
            const model_name = self.fallbackModelForProvider(provider_name);
            try self.appendFallbackProvider(provider_name, api_key, model_name, config.getProviderOverrideUrl(provider_name));
        }

        self.active_provider_index = self.findFallbackProviderIndex(self.provider_name) orelse 0;
    }

    fn resetFallbackProviders(self: *Model) void {
        self.fallback_chain.deinit();
        self.fallback_chain = fallback_mod.FallbackChain.init(self.allocator);
        for (self.fallback_providers.items) |provider| self.freeFallbackProvider(provider);
        self.fallback_providers.clearRetainingCapacity();
        self.active_provider_index = 0;
    }

    fn appendFallbackProvider(self: *Model, provider_name: []const u8, api_key: []const u8, model_name: []const u8, override_url: ?[]const u8) !void {
        if (self.findFallbackProviderIndex(provider_name) != null) return;

        try self.fallback_chain.addEntry(provider_name, model_name);
        try self.fallback_providers.append(self.allocator, .{
            .provider_name = try self.allocator.dupe(u8, provider_name),
            .api_key = try self.allocator.dupe(u8, api_key),
            .model_name = try self.allocator.dupe(u8, model_name),
            .override_url = if (override_url) |url| try self.allocator.dupe(u8, url) else null,
        });
    }

    fn fallbackModelForProvider(self: *const Model, provider_name: []const u8) []const u8 {
        if (std.mem.eql(u8, provider_name, self.provider_name)) return self.model_name;
        if (std.mem.indexOfScalar(u8, self.model_name, '/') == null) return self.model_name;
        return setupDefaultModel(provider_name);
    }

    fn findFallbackProviderIndex(self: *const Model, provider_name: []const u8) ?usize {
        for (self.fallback_providers.items, 0..) |provider, index| {
            if (std.mem.eql(u8, provider.provider_name, provider_name)) return index;
        }
        return null;
    }

    fn freeFallbackProvider(self: *Model, provider: FallbackProvider) void {
        self.allocator.free(provider.provider_name);
        self.allocator.free(provider.api_key);
        self.allocator.free(provider.model_name);
        if (provider.override_url) |override_url| self.allocator.free(override_url);
    }

    fn freePendingPermission(self: *Model, pending: ToolPermission) void {
        self.allocator.free(pending.tool_name);
        self.allocator.free(pending.arguments);
        if (pending.preview_diff) |d| self.allocator.free(d);
    }

    fn setStatusMessage(self: *Model, text: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.setStatusMessageUnlocked(text);
    }

    fn setStatusMessageUnlocked(self: *Model, text: []const u8) !void {
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.status_message = if (text.len == 0) "" else try self.allocator.dupe(u8, text);
    }

    fn clearStatusMessage(self: *Model) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.status_message = "";
    }

    fn applyThemeStyles(self: *Model) void {
        self.input.style = .{ .fg = self.current_theme.header_fg };
        self.input.prompt = "❯ ";
        self.palette_input.style = .{ .fg = self.current_theme.header_fg };
        self.scroll_bars = .{
            .scroll_view = self.scroll_view,
            .draw_horizontal_scrollbar = false,
            .draw_vertical_scrollbar = true,
            .vertical_scrollbar_thumb = .{ .char = .{ .grapheme = "▐", .width = 1 }, .style = .{ .fg = self.current_theme.dimmed, .dim = true } },
            .vertical_scrollbar_hover_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = self.current_theme.border } },
            .vertical_scrollbar_drag_thumb = .{ .char = .{ .grapheme = "█", .width = 1 }, .style = .{ .fg = self.current_theme.accent } },
        };
    }

    fn resolvePendingPermission(self: *Model, decision: PermissionDecision) void {
        self.permission_mutex.lock();
        self.permission_decision = decision;
        self.permission_condition.signal();
        self.permission_mutex.unlock();
    }

    fn needsPermission(self: *const Model, tool_name: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, tool_name, "shell")) return true;
        if (std.mem.eql(u8, tool_name, "write_file")) return true;
        if (std.mem.eql(u8, tool_name, "edit")) return true;
        return false;
    }

    fn isAlwaysAllowed(self: *const Model, tool_name: []const u8) bool {
        for (self.always_allow_tools.items) |allowed_tool| {
            if (std.mem.eql(u8, allowed_tool, tool_name)) return true;
        }
        return false;
    }

    fn requestToolPermission(self: *Model, tool_name: []const u8, arguments: []const u8, preview_diff: ?[]const u8) !bool {
        if (self.permission_mode == .auto or !self.needsPermission(tool_name) or self.isAlwaysAllowed(tool_name)) {
            return true;
        }

        self.permission_mutex.lock();
        defer self.permission_mutex.unlock();
        self.permission_decision = null;

        self.lock.lock();
        if (self.pending_permission) |pending| self.freePendingPermission(pending);
        self.pending_permission = .{
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .arguments = try self.allocator.dupe(u8, arguments),
            .preview_diff = if (preview_diff) |d| try self.allocator.dupe(u8, d) else null,
        };
        self.lock.unlock();

        while (self.permission_decision == null) {
            self.permission_condition.wait(&self.permission_mutex);
        }

        const decision = self.permission_decision.?;
        self.permission_decision = null;

        self.lock.lock();
        defer self.lock.unlock();
        if (decision == .always and !self.isAlwaysAllowed(tool_name)) {
            self.always_allow_tools.append(self.allocator, try self.allocator.dupe(u8, tool_name)) catch {};
        }
        if (self.pending_permission) |pending| {
            self.freePendingPermission(pending);
            self.pending_permission = null;
        }
        return decision != .no;
    }

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn handleEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        self.reapWorkerIfDone();

        switch (event) {
            .init => {
                try ctx.setTitle("Crushcode TUI Chat");
                // NOTE: Do NOT requestFocus — the Model (root widget) stays as
                // the permanent focused widget. Key events are forwarded manually
                // to input/palette_input in the key_press handler below.
                ctx.redraw = true;
            },
            .focus_in => {
                // Keep focus on Model (root). Keys forwarded manually.
            },
            .key_press => |key| {
                if (self.resume_prompt_session != null) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        try self.handleResumePromptDecision(true);
                    } else if (key.matches('n', .{}) or key.matches('N', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        try self.handleResumePromptDecision(false);
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (self.pending_permission != null) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        self.resolvePendingPermission(.yes);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('n', .{}) or key.matches('N', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        self.resolvePendingPermission(.no);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('a', .{}) or key.matches('A', .{})) {
                        self.resolvePendingPermission(.always);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    ctx.consumeEvent();
                    return;
                }

                if (self.show_session_list) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        try self.closeSessionList(ctx);
                    } else if (key.matches(vaxis.Key.up, .{})) {
                        self.moveSessionListSelection(-1);
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        self.moveSessionListSelection(1);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try self.executeSessionSelection(ctx);
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    self.resolvePendingPermission(.no);
                    self.should_quit = true;
                    ctx.quit = true;
                    ctx.consumeEvent();
                    return;
                }

                if (key.matches('p', .{ .ctrl = true })) {
                    if (self.setup_phase != 0) {
                        ctx.consumeEvent();
                        return;
                    }
                    if (self.show_palette) {
                        try self.closePalette(ctx);
                    } else {
                        try self.openPalette(ctx);
                    }
                    ctx.consumeEvent();
                    return;
                }

                if (key.matches('b', .{ .ctrl = true })) {
                    self.sidebar_visible = !self.sidebar_visible;
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                // Ctrl+H or ? toggles help overlay
                if (key.matches('h', .{ .ctrl = true })) {
                    self.show_help = !self.show_help;
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                // Scroll mode: Ctrl+N toggles scroll mode for message navigation
                if (key.matches('n', .{ .ctrl = true })) {
                    if (self.setup_phase == 0 and !self.show_palette) {
                        self.scroll_mode = !self.scroll_mode;
                        if (self.scroll_mode) {
                            self.auto_scroll = false;
                        }
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                // Escape exits scroll mode or help overlay (when not in palette/session list)
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.show_help) {
                        self.show_help = false;
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (self.scroll_mode) {
                        self.scroll_mode = false;
                        self.auto_scroll = true;
                        self.selected_message_index = null;
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                }

                // Scroll mode navigation keys
                if (self.scroll_mode and self.setup_phase == 0 and !self.show_palette) {
                    const viewport_height = @max(self.scroll_view.last_height, 1);
                    const half_page = @max(viewport_height / 2, 1);

                    // j / Down — scroll down one line
                    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                        _ = self.scroll_view.scroll.linesDown(1);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // k / Up — scroll up one line
                    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                        _ = self.scroll_view.scroll.linesUp(1);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // Ctrl+D / PgDn — scroll down half page
                    if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
                        _ = self.scroll_view.scroll.linesDown(half_page);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // Ctrl+U / PgUp — scroll up half page
                    if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
                        _ = self.scroll_view.scroll.linesUp(half_page);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // G (shift+g) — scroll to bottom, exit scroll mode
                    if (key.matches('G', .{})) {
                        const count = self.scroll_view.item_count orelse 0;
                        if (count > 0) {
                            self.scroll_view.cursor = count - 1;
                            self.scroll_view.ensureScroll();
                        }
                        self.scroll_mode = false;
                        self.auto_scroll = true;
                        self.selected_message_index = null;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // g — scroll to top
                    if (key.matches('g', .{})) {
                        self.scroll_view.cursor = 0;
                        self.scroll_view.scroll.top = 0;
                        self.scroll_view.scroll.vertical_offset = 0;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // q — exit scroll mode
                    if (key.matches('q', .{})) {
                        self.scroll_mode = false;
                        self.auto_scroll = true;
                        self.selected_message_index = null;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // Enter — select/deselect message under cursor
                    if (key.matches(vaxis.Key.enter, .{})) {
                        try self.selectMessageAtCursor(ctx);
                        return;
                    }
                    // y — yank (copy with role label) to clipboard
                    if (key.matches('y', .{})) {
                        try self.copySelectedMessage(ctx, false);
                        return;
                    }
                    // c — copy content only to clipboard
                    if (key.matches('c', .{})) {
                        try self.copySelectedMessage(ctx, true);
                        return;
                    }
                    // e — edit: copy message to input field
                    if (key.matches('e', .{})) {
                        try self.editSelectedMessage(ctx);
                        return;
                    }
                }

                if (self.setup_phase == 1) {
                    if (key.matches(vaxis.Key.up, .{})) {
                        self.moveSetupProviderSelection(-1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        self.moveSetupProviderSelection(1);
                        ctx.consumeEvent();
                        return;
                    }
                }

                if (self.show_palette) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        try self.closePalette(ctx);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.up, .{})) {
                        self.movePaletteSelection(-1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        self.movePaletteSelection(1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.enter, .{})) {
                        // Execute palette selection
                        try self.executePaletteSelection(ctx);
                        ctx.consumeEvent();
                        return;
                    }
                    // Forward all other keys (typing, backspace, etc.) to palette_input
                    try self.palette_input.handleEvent(ctx, event);
                    ctx.redraw = true;
                    return;
                }

                // Forward unmatched key events to the main input widget.
                // Model (root) stays focused; we dispatch manually instead of
                // relying on vaxis focus-path tracking which breaks when
                // requestFocus targets a widget whose draw-time userdata
                // doesn't match (userdata pointer mismatch → empty path → crash).
                if (!self.scroll_mode) {
                    try self.input.handleEvent(ctx, event);
                    return;
                }
            },
            .paste => {
                // Forward paste events to the active input
                if (self.show_palette) {
                    try self.palette_input.handleEvent(ctx, event);
                    ctx.redraw = true;
                    return;
                }
                if (!self.scroll_mode) {
                    try self.input.handleEvent(ctx, event);
                    return;
                }
            },
            else => {},
        }

        ctx.redraw = true;
    }

    fn draw(self: *Model, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.reapWorkerIfDone();

        // Tick spinner each frame for animation
        if (self.spinner) |*spinner| {
            spinner.tick();
        }
        // Tick toast stack each frame for auto-expiration
        self.toast_stack.tick();
        // Tick typewriter each frame for character reveal
        if (self.typewriter) |*tw| {
            tw.tick();
        }
        // Clean up typewriter once animation finishes after streaming ends
        if (self.typewriter != null and self.request_done and self.typewriter.?.complete) {
            self.typewriter = null;
        }

        self.lock.lock();
        defer self.lock.unlock();

        const max = ctx.max.size();
        const sidebar_width: u16 = 30;
        const main_width: u16 = if (self.sidebar_visible) max.width -| sidebar_width else max.width;
        const header_height: u16 = 1;
        const status_height: u16 = 1;
        // Dynamic input height: compute based on content and available width
        const input_prompt_width: u16 = 4; // "❯ " display width
        const input_text_width: u16 = max.width -| input_prompt_width;
        const input_height: u16 = self.input.currentDisplayRows(input_text_width);
        const body_height = max.height -| (header_height + status_height + input_height);
        // Ensure body has at least 1 row — otherwise child widgets will
        // receive a zero-height constraint and assert in ctx.max.size()
        const safe_body_height: u16 = if (body_height > 0) body_height else 1;

        const full_title = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | setup", .{app_version})
        else
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | {s}/{s} | thinking:{s} | ctx: {d} files indexed | usage:{d}%", .{
                app_version,
                self.provider_name,
                self.model_name,
                if (self.thinking) "on" else "off",
                self.context_file_count,
                self.contextPercent(),
            });

        const header = HeaderWidget{ .title = full_title, .theme = self.current_theme, .context_pct = self.contextPercent(), .file_count = self.context_file_count };
        const header_surface = try header.draw(ctx.withConstraints(
            .{ .width = main_width, .height = header_height },
            .{ .width = main_width, .height = header_height },
        ));

        const body_surface = blk: {
            if (self.setup_phase != 0) {
                const setup_context = SetupContext{
                    .setup_phase = self.setup_phase,
                    .provider_name = self.provider_name,
                    .model_name = self.model_name,
                    .setup_provider_index = self.setup_provider_index,
                    .setup_feedback = self.setup_feedback,
                    .setup_feedback_is_error = self.setup_feedback_is_error,
                    .theme = self.current_theme,
                };
                const wizard = SetupWizardWidget{ .context = &setup_context };
                break :blk try wizard.draw(ctx.withConstraints(
                    .{ .width = main_width, .height = safe_body_height },
                    .{ .width = main_width, .height = safe_body_height },
                ));
            } else {
                var message_widgets = std.ArrayList(vxfw.Widget).empty;
                defer message_widgets.deinit(ctx.arena);
                try message_widgets.ensureTotalCapacity(ctx.arena, @max(self.messages.items.len * 3, 1));
                var visible_count: usize = 0;
                for (self.messages.items, 0..) |message, idx| {
                    if (message.tool_call_id != null and findToolCallBefore(self.messages.items, idx, message.tool_call_id.?) != null) {
                        continue;
                    }
                    // Heap-allocate to avoid dangling stack pointers — .widget() captures
                    // the address via @constCast, so locals would be overwritten each iteration.
                    const mw = try ctx.arena.create(MessageWidget);
                    mw.* = .{ .model = self, .message_index = idx };
                    try message_widgets.append(ctx.arena, mw.widget());
                    visible_count += 1;
                    if (visible_count < visibleMessageCount(self.messages.items)) {
                        const gap = try ctx.arena.create(MessageGapWidget);
                        gap.* = .{};
                        try message_widgets.append(ctx.arena, gap.widget());
                        const sep = try ctx.arena.create(SeparatorWidget);
                        sep.* = .{ .theme = self.current_theme };
                        try message_widgets.append(ctx.arena, sep.widget());
                    }
                }

                self.scroll_view.children = .{ .slice = message_widgets.items };
                if (self.auto_scroll and message_widgets.items.len > 0) {
                    self.scroll_view.item_count = @intCast(message_widgets.items.len);
                    self.scroll_view.cursor = @intCast(message_widgets.items.len - 1);
                    self.scroll_view.ensureScroll();
                } else if (message_widgets.items.len > 0) {
                    self.scroll_view.item_count = @intCast(message_widgets.items.len);
                } else {
                    self.scroll_view.item_count = 0;
                    self.scroll_view.cursor = 0;
                }
                self.scroll_bars.scroll_view = self.scroll_view;
                self.scroll_bars.estimated_content_height = estimateContentHeight(self);

                const surface = try self.scroll_bars.draw(ctx.withConstraints(
                    .{ .width = main_width, .height = safe_body_height },
                    .{ .width = main_width, .height = safe_body_height },
                ));
                self.scroll_view = self.scroll_bars.scroll_view;
                break :blk surface;
            }
        };

        const scroll_indicator = if (self.scroll_mode) blk: {
            if (self.selected_message_index) |msg_idx| {
                break :blk std.fmt.allocPrint(ctx.arena, " │ SELECTED msg #{d} (y/c/e)", .{msg_idx + 1}) catch " │ SELECTED";
            } else {
                break :blk " │ SCROLL (j/k/↑↓ PgUp/PgDn g/G Enter q/Esc)";
            }
        } else "";
        const status_text = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Setup {d}/4 | {s}", .{
                @min(self.setup_phase, @as(u8, 4)),
                if (self.setup_phase == 1) "Choose a provider" else if (self.setup_phase == 2) "Enter your API key" else if (self.setup_phase == 3) "Choose a default model" else "Press Enter to continue",
            })
        else if (self.status_message.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s} | Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s{s}", .{
                self.status_message,
                self.total_input_tokens,
                self.total_output_tokens,
                self.estimatedCostUsd(),
                self.request_count,
                self.sessionMinutes(),
                self.sessionSecondsPart(),
                scroll_indicator,
            })
        else
            try std.fmt.allocPrint(ctx.arena, "Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s{s}", .{
                self.total_input_tokens,
                self.total_output_tokens,
                self.estimatedCostUsd(),
                self.request_count,
                self.sessionMinutes(),
                self.sessionSecondsPart(),
                scroll_indicator,
            });
        const status_widget = vxfw.Text{
            .text = if (status_text.len > main_width) blk: {
                const trunc_len = if (main_width > 1) main_width - 1 else 0;
                const truncated = try std.fmt.allocPrint(ctx.arena, "{s}…", .{if (status_text.len > trunc_len) status_text[0..trunc_len] else status_text});
                break :blk truncated;
            } else status_text,
            .style = .{ .fg = self.current_theme.status_fg, .bg = self.current_theme.status_bg },
            .softwrap = false,
            .width_basis = .parent,
        };
        const status_surface = try status_widget.draw(ctx.withConstraints(
            .{ .width = main_width, .height = status_height },
            .{ .width = main_width, .height = status_height },
        ));

        const ml_input_widget = MultiLineInputWidget{ .prompt = self.currentInputPrompt(), .state = &self.input, .theme = self.current_theme };
        const input_surface = try ml_input_widget.draw(ctx.withConstraints(
            .{ .width = max.width, .height = input_height },
            .{ .width = max.width, .height = input_height },
        ));

        var child_list = std.ArrayList(vxfw.SubSurface).empty;
        defer child_list.deinit(ctx.arena);
        try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = header_surface });
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height), .col = 0 }, .surface = body_surface });
        // Input first (above status bar)
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + safe_body_height), .col = 0 }, .surface = input_surface });
        // Status bar at the very bottom
        try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + safe_body_height + input_height), .col = 0 }, .surface = status_surface });

        if (self.sidebar_visible) {
            const mcp_status = self.getMCPServerStatus(ctx.arena);
            const sidebar_context = SidebarContext{
                .recent_files = self.recent_files.items,
                .request_count = self.request_count,
                .total_input_tokens = self.total_input_tokens,
                .total_output_tokens = self.total_output_tokens,
                .estimated_cost_usd = self.estimatedCostUsd(),
                .session_minutes = @intCast(self.sessionMinutes()),
                .session_seconds_part = @intCast(self.sessionSecondsPart()),
                .workers = self.workers.items,
                .theme_name = self.current_theme.name,
                .current_theme = self.current_theme,
                .mcp_servers = mcp_status,
            };
            const sidebar = SidebarWidget{ .context = &sidebar_context, .width = sidebar_width };
            const sidebar_height: u16 = header_height + safe_body_height;
            const sidebar_surface = try sidebar.draw(ctx.withConstraints(
                .{ .width = sidebar_width, .height = sidebar_height },
                .{ .width = sidebar_width, .height = sidebar_height },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(main_width) }, .surface = sidebar_surface });
        }

        if (self.show_palette) {
            const palette = CommandPaletteWidget{
                .field = &self.palette_input,
                .commands = self.palette_commands,
                .filter = self.palette_filter,
                .selected = self.palette_selected,
                .theme = self.current_theme,
            };
            const palette_surface = try palette.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| palette_surface.size.height) / 2),
                    .col = @intCast((max.width -| palette_surface.size.width) / 2),
                },
                .surface = palette_surface,
            });
        }

        if (self.pending_permission != null) {
            const perm_context = PermissionContext{
                .pending = self.pending_permission,
                .theme = self.current_theme,
            };
            const permission_dialog = PermissionDialogWidget{ .context = &perm_context };
            const permission_surface = try permission_dialog.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| permission_surface.size.height) / 2),
                    .col = @intCast((max.width -| permission_surface.size.width) / 2),
                },
                .surface = permission_surface,
            });
        }

        if (self.show_session_list) {
            const session_list = SessionListWidget{
                .sessions = self.session_list,
                .selected = self.session_list_selected,
                .theme = self.current_theme,
            };
            const session_surface = try session_list.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| session_surface.size.height) / 2),
                    .col = @intCast((max.width -| session_surface.size.width) / 2),
                },
                .surface = session_surface,
            });
        }

        if (self.resume_prompt_session) |*prompt_session| {
            const prompt = ResumePromptWidget{ .session = prompt_session, .theme = self.current_theme };
            const prompt_surface = try prompt.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| prompt_surface.size.height) / 2),
                    .col = @intCast((max.width -| prompt_surface.size.width) / 2),
                },
                .surface = prompt_surface,
            });
        }

        if (self.recent_files.items.len > 0) {
            const visible_files = recentFilesVisibleCount(self.recent_files.items);
            const files_widget = FilesWidget{ .files = self.recent_files.items[0..visible_files], .theme = self.current_theme };
            const files_surface = try files_widget.draw(ctx.withConstraints(
                .{ .width = main_width, .height = 1 },
                .{ .width = main_width, .height = 1 },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = @intCast(header_height + safe_body_height), .col = 0 }, .surface = files_surface });
        }

        // Render toast notifications
        if (self.toast_stack.isActive()) {
            const toast_widget = widget_toast.ToastStackWidget{ .stack = &self.toast_stack };
            const toast_surface = try toast_widget.draw(ctx.withConstraints(
                .{ .width = main_width, .height = 0 },
                .{ .width = main_width, .height = max.height },
            ));
            if (toast_surface.size.height > 0) {
                try child_list.append(ctx.arena, .{
                    .origin = .{ .row = max.height -| toast_surface.size.height - 1, .col = 0 },
                    .surface = toast_surface,
                });
            }
        }

        // Render help overlay
        if (self.show_help) {
            const help_width: u16 = @min(max.width -| 4, @as(u16, 48));
            const help_rows = [_][]const u8{
                "Keyboard Shortcuts",
                "",
                "Ctrl+N    Scroll mode",
                "  j/k      Scroll line",
                "  PgDn/PgUp Half page",
                "  G/g      Bottom/Top",
                "  Enter    Select message",
                "  y        Copy (yank)",
                "  e        Edit to input",
                "  q/Esc    Exit scroll",
                "",
                "Ctrl+P    Command palette",
                "Ctrl+B    Toggle sidebar",
                "Ctrl+H    This help",
                "Ctrl+C    Quit",
                "",
                "Enter     Send message",
                "Shift+Enter New line",
                "/         Command input",
                "Tab       Accept suggest",
                "Esc       Close overlay",
            };
            const help_height: u16 = help_rows.len + 2; // +2 border
            const help_origin_row: u16 = if (max.height > help_height) (max.height - help_height) / 2 else 0;
            const help_origin_col: u16 = if (max.width > help_width) (max.width - help_width) / 2 else 0;

            var help_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = help_width, .height = help_height });
            @memset(help_surface.buffer, .{ .style = .{ .bg = self.current_theme.header_bg } });
            const help_border: vaxis.Style = .{ .fg = self.current_theme.border };
            widget_helpers.drawBorder(&help_surface, help_border);

            for (help_rows, 0..) |row_text, i| {
                if (i == 0) {
                    // Title
                    const title_text = vxfw.Text{
                        .text = row_text,
                        .style = .{ .fg = self.current_theme.header_fg, .bold = true },
                        .softwrap = false,
                        .width_basis = .parent,
                    };
                    const title_surface = try title_text.draw(ctx.withConstraints(.{ .width = help_width - 4, .height = 1 }, .{ .width = help_width - 4, .height = 1 }));
                    try child_list.append(ctx.arena, .{ .origin = .{ .row = help_origin_row + 1 + @as(u16, @intCast(i)), .col = help_origin_col + 2 }, .surface = title_surface });
                } else if (row_text.len > 0) {
                    const is_key = row_text[0] != ' ';
                    const row_style: vaxis.Style = if (is_key) .{ .fg = self.current_theme.accent } else .{ .fg = self.current_theme.dimmed };
                    const text_widget = vxfw.Text{
                        .text = row_text,
                        .style = row_style,
                        .softwrap = false,
                        .width_basis = .parent,
                    };
                    const row_surface = try text_widget.draw(ctx.withConstraints(.{ .width = help_width - 4, .height = 1 }, .{ .width = help_width - 4, .height = 1 }));
                    try child_list.append(ctx.arena, .{ .origin = .{ .row = help_origin_row + 1 + @as(u16, @intCast(i)), .col = help_origin_col + 2 }, .surface = row_surface });
                }
            }
            try child_list.append(ctx.arena, .{ .origin = .{ .row = help_origin_row, .col = help_origin_col }, .surface = help_surface });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_list.items.len);
        @memcpy(children, child_list.items);

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Map the scroll_view cursor position to the actual message index in
    /// self.messages. The scroll children list interleaves MessageWidget,
    /// MessageGapWidget, SeparatorWidget — only every 3rd slot (at indices
    /// 0, 3, 6, …) is a MessageWidget. The last visible message has no
    /// trailing gap/sep. Returns null if cursor is not on a MessageWidget or
    /// the index is out of range.
    fn scrollCursorToMessageIndex(self: *const Model) ?usize {
        const cursor = self.scroll_view.cursor;
        // Only cursor positions divisible by 3 point at a MessageWidget
        if (cursor % 3 != 0) return null;
        const visible_idx = cursor / 3;

        const messages = self.messages.items;
        var count: usize = 0;
        for (messages, 0..) |message, idx| {
            if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
            if (count == visible_idx) return idx;
            count += 1;
        }
        return null;
    }

    /// Select the message currently under the scroll cursor.
    fn selectMessageAtCursor(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.scrollCursorToMessageIndex()) |msg_idx| {
            if (self.selected_message_index) |prev| {
                if (prev == msg_idx) {
                    // Toggle off if already selected
                    self.selected_message_index = null;
                    ctx.consumeAndRedraw();
                    return;
                }
            }
            self.selected_message_index = msg_idx;
        }
        ctx.consumeAndRedraw();
    }

    /// Copy selected message content to system clipboard.
    fn copySelectedMessage(self: *Model, ctx: *vxfw.EventContext, content_only: bool) !void {
        const msg_idx = self.selected_message_index orelse return;
        if (msg_idx >= self.messages.items.len) return;

        const message = self.messages.items[msg_idx];
        const text = if (content_only)
            message.content
        else
            try std.fmt.allocPrint(self.allocator, "[{s}]\n{s}", .{ message.role, message.content });

        try ctx.copyToClipboard(text);
        if (!content_only) self.allocator.free(text);

        self.toast_stack.push("Copied to clipboard", .success) catch {};
        ctx.consumeAndRedraw();
    }

    /// Copy selected message content into the input field for re-editing.
    fn editSelectedMessage(self: *Model, ctx: *vxfw.EventContext) !void {
        const msg_idx = self.selected_message_index orelse return;
        if (msg_idx >= self.messages.items.len) return;

        const content = self.messages.items[msg_idx].content;
        try self.input.insertSliceAtCursor(content);

        // Exit scroll mode and focus the input
        self.scroll_mode = false;
        self.auto_scroll = true;
        self.selected_message_index = null;
        self.toast_stack.push("Message copied to input", .info) catch {};
        // NOTE: No requestFocus — Model stays focused, keys forwarded manually
        ctx.consumeAndRedraw();
    }

    fn handleSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        self.reapWorkerIfDone();

        // Reset scroll state on any user input submission
        self.scroll_mode = false;
        self.auto_scroll = true;

        if (self.setup_phase != 0) {
            try self.handleSetupSubmit(value, ctx);
            return;
        }

        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (std.mem.eql(u8, trimmed, "/exit")) {
            self.resolvePendingPermission(.no);
            self.should_quit = true;
            ctx.quit = true;
            return;
        }
        if (isSupportedSlashCommand(trimmed)) {
            try self.executePaletteCommand(trimmed, ctx);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (self.request_active) {
            try self.addMessageUnlocked("error", "Still waiting for the current response. Please wait for it to finish.");
            ctx.redraw = true;
            return;
        }

        if (self.client == null) {
            const text = if (self.api_key.len == 0)
                "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"
            else
                "Chat client is not ready. Fix the configuration shown above and restart the TUI.";
            try self.addMessageUnlocked("error", text);
            ctx.redraw = true;
            return;
        }

        try self.addMessageUnlocked("user", trimmed);
        try self.appendHistoryMessageUnlocked("user", trimmed);
        // Persist to cross-session memory
        self.memory.addMessage("user", trimmed) catch {};
        self.memory.save() catch {};
        try self.addMessageUnlocked("assistant", "Thinking...");
        self.assistant_stream_index = self.messages.items.len - 1;
        self.spinner = widget_spinner.AnimatedSpinner.init(self.current_theme);
        self.typewriter = widget_typewriter.TypewriterState.init(self.current_theme);
        self.request_active = true;
        self.request_done = false;
        self.awaiting_first_token = true;
        try self.saveSessionSnapshotUnlocked();

        self.resetInputField();
        self.worker = try std.Thread.spawn(.{}, requestThreadMain, .{self});
        ctx.redraw = true;
    }

    fn resetInputField(self: *Model) void {
        self.input.deinit();
        self.input = widget_input.MultiLineInputState.init(self.allocator);
        self.input.style = .{ .fg = self.current_theme.header_fg };
        self.input.userdata = self;
        self.input.onSubmit = onSubmit;
        self.input.prompt = "❯ ";
        self.input.suggestion_list = &slash_command_names;
    }

    fn currentInputPrompt(self: *const Model) []const u8 {
        return switch (self.setup_phase) {
            1 => "Select: ",
            2 => "API key: ",
            3 => "Model: ",
            4 => "Continue: ",
            else => "❯ ",
        };
    }

    fn moveSetupProviderSelection(self: *Model, delta: isize) void {
        const current: isize = @intCast(self.setup_provider_index);
        const max_index: isize = @intCast(setup_provider_data.len - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.setup_provider_index = @intCast(next);
    }

    fn setSetupFeedback(self: *Model, text: []const u8, is_error: bool) !void {
        if (self.setup_feedback.len > 0) {
            self.allocator.free(self.setup_feedback);
        }
        self.setup_feedback = try self.allocator.dupe(u8, text);
        self.setup_feedback_is_error = is_error;
    }

    fn clearSetupFeedback(self: *Model) void {
        if (self.setup_feedback.len > 0) {
            self.allocator.free(self.setup_feedback);
        }
        self.setup_feedback = "";
        self.setup_feedback_is_error = false;
    }

    fn replaceOwnedString(self: *Model, slot: *[]const u8, value: []const u8) !void {
        const updated = try self.allocator.dupe(u8, value);
        self.allocator.free(slot.*);
        slot.* = updated;
    }

    fn handleSetupSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        switch (self.setup_phase) {
            1 => {
                try self.replaceOwnedString(&self.provider_name, setup_provider_data[self.setup_provider_index]);
                self.clearSetupFeedback();
                self.setup_phase = 2;
                self.resetInputField();
            },
            2 => {
                if (trimmed.len == 0 and !setupProviderAllowsEmptyKey(self.provider_name)) {
                    try self.setSetupFeedback("API key cannot be empty for this provider.", true);
                    ctx.redraw = true;
                    return;
                }
                try self.replaceOwnedString(&self.api_key, trimmed);
                self.clearSetupFeedback();
                self.setup_phase = 3;
                self.resetInputField();
            },
            3 => {
                const resolved_model = if (trimmed.len > 0) trimmed else setupDefaultModel(self.provider_name);
                try self.replaceOwnedString(&self.model_name, resolved_model);
                try self.saveSetupConfig();
                self.resetFallbackProviders();
                try self.loadFallbackProviders();
                try self.initializeClient();
                self.clearSetupFeedback();
                self.setup_phase = 4;
                self.resetInputField();
            },
            4 => {
                self.clearSetupFeedback();
                self.setup_phase = 0;
                try self.addMessageUnlocked("assistant", "TUI chat ready. Type a message and press Enter.");
                self.resetInputField();
            },
            else => {},
        }
        // NOTE: No requestFocus — Model stays focused, keys forwarded manually
        ctx.redraw = true;
    }

    fn saveSetupConfig(self: *Model) !void {
        const config_path = try setupConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(config_dir);

        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        const escaped_model = self.model_name;
        const escaped_key = self.api_key;

        const content = try std.fmt.allocPrint(
            self.allocator,
            "default_provider = \"{s}\"\ndefault_model = \"{s}\"\n\n[api_keys]\n{s} = \"{s}\"\n",
            .{ self.provider_name, escaped_model, self.provider_name, escaped_key },
        );
        defer self.allocator.free(content);

        try file.writeAll(content);
    }

    fn resetPaletteInputField(self: *Model) void {
        // Clear text content WITHOUT destroying the TextField widget.
        // deinit+reinit breaks vaxis focus path tracking: the new widget
        // instance won't be found in the surface tree, causing
        //   assert(path.len > 0)  in App.zig FocusHandler.handleEvent
        const alloc = self.palette_input.buf.allocator;
        if (self.palette_input.previous_val.len > 0) {
            alloc.free(self.palette_input.previous_val);
        }
        self.palette_input.previous_val = "";
        self.palette_input.buf.clearAndFree();
        self.palette_input.reset();
    }

    fn clearPaletteFilter(self: *Model) void {
        if (self.palette_filter.len > 0) {
            self.allocator.free(self.palette_filter);
        }
        self.palette_filter = "";
        self.palette_selected = 0;
    }

    fn setPaletteFilter(self: *Model, value: []const u8) !void {
        if (self.palette_filter.len > 0) {
            self.allocator.free(self.palette_filter);
        }
        self.palette_filter = if (value.len == 0) "" else try self.allocator.dupe(u8, value);
        self.clampPaletteSelection();
    }

    fn openPalette(self: *Model, ctx: *vxfw.EventContext) !void {
        self.show_palette = true;
        self.clearPaletteFilter();
        self.resetPaletteInputField();
        // NOTE: Do NOT requestFocus on palette_input — it's buried inside
        // FlexRow → InputWidget → CommandPaletteWidget, so vaxis focus path
        // tracking can never find it. Instead, we forward key events manually
        // in handleEvent when show_palette is true.
        ctx.redraw = true;
    }

    fn closePalette(self: *Model, ctx: *vxfw.EventContext) !void {
        self.show_palette = false;
        self.clearPaletteFilter();
        self.resetPaletteInputField();
        ctx.redraw = true;
    }

    fn clampPaletteSelection(self: *Model) void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            self.palette_selected = 0;
            return;
        }
        if (self.palette_selected >= filtered_count) {
            self.palette_selected = filtered_count - 1;
        }
    }

    fn movePaletteSelection(self: *Model, delta: isize) void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            self.palette_selected = 0;
            return;
        }

        const current: isize = @intCast(self.palette_selected);
        const max_index: isize = @intCast(filtered_count - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.palette_selected = @intCast(next);
    }

    fn executePaletteSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        var filtered_indices: [palette_command_data.len]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_commands, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            return;
        }

        const command = self.palette_commands[filtered_indices[self.palette_selected]];
        try self.closePalette(ctx);
        try self.executePaletteCommand(command.name, ctx);
    }

    fn executePaletteCommand(self: *Model, name: []const u8, ctx: *vxfw.EventContext) !void {
        if (std.mem.eql(u8, name, "/exit")) {
            self.should_quit = true;
            ctx.quit = true;
            ctx.redraw = true;
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (try self.handleThemeCommandUnlocked(name)) {
            ctx.redraw = true;
            return;
        }

        if (std.mem.eql(u8, name, "/clear")) {
            if (self.request_active) {
                try self.addMessageUnlocked("error", "Cannot clear the chat while a response is still streaming.");
            } else {
                try self.saveSessionSnapshotUnlocked();
                self.clearMessagesUnlocked();
                self.clearHistoryUnlocked();
                self.clearRecentFilesUnlocked();
                self.total_input_tokens = 0;
                self.total_output_tokens = 0;
                self.request_count = 0;
                self.assistant_stream_index = null;
                self.awaiting_first_token = false;
                try self.beginNewSessionUnlocked();
            }
        } else if (std.mem.eql(u8, name, "/sessions") or std.mem.eql(u8, name, "/ls")) {
            try self.openSessionList(ctx);
            return;
        } else if (std.mem.startsWith(u8, name, "/resume")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try self.addMessageUnlocked("assistant", "Usage: /resume <id>");
            } else {
                try self.resumeSessionByIdUnlocked(session_id);
            }
        } else if (std.mem.startsWith(u8, name, "/delete")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try self.addMessageUnlocked("assistant", "Usage: /delete <id>");
            } else {
                try self.deleteSessionByIdUnlocked(session_id);
                const text = try std.fmt.allocPrint(self.allocator, "Deleted session {s}", .{session_id});
                defer self.allocator.free(text);
                try self.addMessageUnlocked("assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/thinking")) {
            self.thinking = !self.thinking;
            const text = if (self.thinking) "Thinking enabled." else "Thinking disabled.";
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/help")) {
            try self.addMessageUnlocked("assistant", "/clear — Clear conversation history\n/sessions — Browse saved sessions\n/ls — Alias for /sessions\n/resume <id> — Resume a saved session\n/delete <id> — Delete a saved session\n/exit — Exit crushcode\n/model — Show current model\n/thinking — Toggle thinking mode\n/compact — Compact conversation context\n/theme dark — Switch to dark theme\n/theme light — Switch to light theme\n/theme mono — Switch to monochrome theme\n/workers — List active workers\n/kill <id> — Cancel a worker\n/memory — Show cross-session memory stats\n/plugins — List loaded runtime plugins\n/help — Show available commands");
        } else if (std.mem.eql(u8, name, "/compact")) {
            try self.performCompaction();
        } else if (std.mem.eql(u8, name, "/model")) {
            const text = try std.fmt.allocPrint(self.allocator, "Current model: {s}/{s}", .{ self.provider_name, self.model_name });
            defer self.allocator.free(text);
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/workers")) {
            self.parallel_executor.reapCompleted();
            const parallel_running = self.parallel_executor.runningCount();
            if (self.workers.items.len == 0 and parallel_running == 0) {
                try self.addMessageUnlocked("assistant", "No active workers.");
            } else {
                var buf: [1024]u8 = undefined;
                var offset: usize = 0;
                const head_result = std.fmt.bufPrint(&buf, "Active workers:\n", .{});
                if (head_result) |written| {
                    offset = written.len;
                } else |_| {}
                for (self.workers.items) |w| {
                    const status_str = switch (w.status) {
                        .pending => "pending",
                        .running => "running",
                        .done => "done",
                        .@"error" => "error",
                        .cancelled => "cancelled",
                    };
                    const result_preview = if (w.result) |r| if (r.len > 30) r[0..30] else r else "(none)";
                    const line_result = std.fmt.bufPrint(buf[offset..], "#{d} [{s}] {s} → {s}\n", .{ w.id, status_str, w.task, result_preview });
                    if (line_result) |written| {
                        offset += written.len;
                    } else |_| {}
                }
                if (parallel_running > 0) {
                    const line_result = std.fmt.bufPrint(buf[offset..], "Parallel executor: {d} running\n", .{parallel_running});
                    if (line_result) |written| {
                        offset += written.len;
                    } else |_| {}
                }
                const text = try self.allocator.dupe(u8, buf[0..offset]);
                try self.addMessageUnlocked("assistant", text);
            }
        } else if (std.mem.startsWith(u8, name, "/kill ")) {
            const id_str = name[6..];
            const id = std.fmt.parseInt(u32, id_str, 10) catch {
                try self.addMessageUnlocked("assistant", "Invalid worker ID. Usage: /kill <id>");
                ctx.redraw = true;
                return;
            };
            var found = false;
            for (self.workers.items) |*w| {
                if (w.id == id) {
                    w.status = .cancelled;
                    const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} cancelled.", .{id});
                    try self.addMessageUnlocked("assistant", text);
                    found = true;
                    break;
                }
            }
            // Also try cancelling from parallel executor
            if (self.parallel_executor.cancel(id_str)) {
                if (!found) {
                    const text = try std.fmt.allocPrint(self.allocator, "Parallel task {s} cancelled.", .{id_str});
                    try self.addMessageUnlocked("assistant", text);
                    found = true;
                }
            }
            if (!found) {
                const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} not found.", .{id});
                try self.addMessageUnlocked("assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/memory")) {
            const count = self.memory.count();
            const tokens = self.memory.estimateTokens();
            const text = try std.fmt.allocPrint(self.allocator, "Memory: {d} messages, ~{d} tokens", .{ count, tokens });
            defer self.allocator.free(text);
            try self.addMessageUnlocked("assistant", text);
        } else if (std.mem.eql(u8, name, "/plugins")) {
            const plugin_names = self.plugin_manager.getAllPlugins();
            if (plugin_names.len == 0) {
                try self.addMessageUnlocked("assistant", "No plugins loaded.");
            } else {
                var buf: [2048]u8 = undefined;
                var offset: usize = 0;
                if (std.fmt.bufPrint(&buf, "Loaded plugins ({d}):\n", .{plugin_names.len})) |written| {
                    offset = written.len;
                } else |_| {}
                for (plugin_names) |pname| {
                    if (std.fmt.bufPrint(buf[offset..], "  • {s}\n", .{pname})) |written| {
                        offset += written.len;
                    } else |_| {}
                }
                const text = try self.allocator.dupe(u8, buf[0..offset]);
                try self.addMessageUnlocked("assistant", text);
            }
        }

        ctx.redraw = true;
    }

    fn handleThemeCommandUnlocked(self: *Model, name: []const u8) !bool {
        if (!std.mem.startsWith(u8, name, "/theme")) return false;

        const rest = std.mem.trim(u8, name[6..], " \t\r\n");
        if (rest.len == 0) {
            try self.addMessageUnlocked("system", "Available themes: dark, light, mono");
            return true;
        }

        if (theme_mod.getTheme(rest)) |theme| {
            self.current_theme = theme;
            self.applyThemeStyles();
            const text = try std.fmt.allocPrint(self.allocator, "Theme switched to {s}.", .{theme.name});
            defer self.allocator.free(text);
            try self.addMessageUnlocked("system", text);
            return true;
        }

        const text = try std.fmt.allocPrint(self.allocator, "Unknown theme: {s}", .{rest});
        defer self.allocator.free(text);
        try self.addMessageUnlocked("system", text);
        return true;
    }

    fn reapWorkerIfDone(self: *Model) void {
        var thread_to_join: ?std.Thread = null;
        self.lock.lock();
        if (self.request_done and self.worker != null) {
            thread_to_join = self.worker;
            self.worker = null;
            self.request_done = false;
        }
        self.lock.unlock();

        if (thread_to_join) |thread| {
            thread.join();
        }
    }

    fn addMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
        try self.addMessageWithToolsUnlocked(role, content, null, null);
    }

    fn addMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
            .tool_calls = try cloneToolCallInfos(self.allocator, tool_calls),
        });
    }

    fn clearMessagesUnlocked(self: *Model) void {
        for (self.messages.items) |message| {
            freeDisplayMessage(self.allocator, message);
        }
        self.messages.clearRetainingCapacity();
    }

    fn clearHistoryUnlocked(self: *Model) void {
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.clearRetainingCapacity();
    }

    fn appendHistoryMessageUnlocked(self: *Model, role: []const u8, content: []const u8) !void {
        try self.appendHistoryMessageWithToolsUnlocked(role, content, null, null);
    }

    fn appendHistoryMessageWithToolsUnlocked(self: *Model, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        try self.history.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null,
            .tool_calls = try cloneToolCallInfos(self.allocator, tool_calls),
        });
    }

    fn replaceMessageUnlocked(self: *Model, index: usize, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        var message = &self.messages.items[index];
        self.allocator.free(message.role);
        self.allocator.free(message.content);
        if (message.tool_call_id) |value| self.allocator.free(value);
        freeToolCallInfos(self.allocator, message.tool_calls);
        message.role = try self.allocator.dupe(u8, role);
        message.content = try self.allocator.dupe(u8, content);
        message.tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
        message.tool_calls = try cloneToolCallInfos(self.allocator, tool_calls);
    }

    fn appendToMessageUnlocked(self: *Model, index: usize, suffix: []const u8) !void {
        var message = &self.messages.items[index];
        const updated = try self.allocator.alloc(u8, message.content.len + suffix.len);
        @memcpy(updated[0..message.content.len], message.content);
        @memcpy(updated[message.content.len..], suffix);
        self.allocator.free(message.content);
        message.content = updated;
    }

    fn trackToolCallFilesUnlocked(self: *Model, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        const calls = tool_calls orelse return;
        for (calls) |tool_call| {
            if (!isRecentFileTool(tool_call.name)) continue;
            if (extractToolFilePath(tool_call.arguments)) |path| {
                try self.addRecentFileUnlocked(path);
            }
        }
    }

    fn addRecentFileUnlocked(self: *Model, file_path: []const u8) !void {
        var found_index: ?usize = null;
        for (self.recent_files.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, file_path)) {
                found_index = idx;
                break;
            }
        }
        if (found_index) |idx| {
            self.allocator.free(self.recent_files.items[idx]);
            _ = self.recent_files.orderedRemove(idx);
        }
        const owned = try self.allocator.dupe(u8, file_path);
        try self.recent_files.append(self.allocator, owned);
        if (self.recent_files.items.len > recent_files_max) {
            self.allocator.free(self.recent_files.orderedRemove(0));
        }
    }

    fn requestThreadMain(self: *Model) void {
        active_stream_model = self;
        defer active_stream_model = null;
        self.runStreamingRequest() catch |err| {
            self.finishRequestWithCaughtError(err);
        };
    }

    fn runStreamingRequest(self: *Model) !void {
        self.budget_mgr.checkAndResetPeriods();
        if (self.budget_mgr.isOverBudget()) {
            self.finishRequestWithErrorText("Budget limit reached. Increase limits or start a new session.");
            return;
        }

        // Refresh context based on user's latest message (relevance-filtered)
        if (self.history.items.len > 0) {
            const last_msg = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last_msg.role, "user")) {
                const user_content = last_msg.content orelse "";
                if (user_content.len > 0) {
                    self.refreshContextForQuery(user_content);

                    // Update the AI client with the refreshed system prompt
                    if (self.client) |*client| {
                        if (self.effective_system_prompt) |prompt| {
                            client.setSystemPrompt(prompt);
                        }
                    }
                }
            }
        }

        var total_input_tokens: u64 = 0;
        var total_output_tokens: u64 = 0;
        var iteration: u32 = 0;

        while (iteration < self.max_iterations) : (iteration += 1) {
            total_input_tokens += estimateMessageTokens(self.history.items);

            // Execute pre_request lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .pre_request;
                hook_ctx.provider = self.provider_name;
                hook_ctx.model = self.model_name;
                hook_ctx.token_count = @intCast(estimateMessageTokens(self.history.items));
                self.lifecycle_hooks.execute(.pre_request, &hook_ctx) catch {};
            }

            var response = try self.sendChatStreamingWithFallback();
            defer freeChatResponse(self.allocator, &response);

            if (response.choices.len == 0) {
                // Execute on_error lifecycle hook
                {
                    var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                    defer hook_ctx.deinit();
                    hook_ctx.phase = .on_error;
                    hook_ctx.error_message = "No response received from provider";
                    self.lifecycle_hooks.execute(.on_error, &hook_ctx) catch {};
                }
                self.finishRequestWithErrorText("No response received from provider");
                return;
            }

            const content = response.choices[0].message.content orelse "";
            const tool_calls = response.choices[0].message.tool_calls;
            if (content.len == 0 and tool_calls == null) {
                // Execute on_error lifecycle hook
                {
                    var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                    defer hook_ctx.deinit();
                    hook_ctx.phase = .on_error;
                    hook_ctx.error_message = "No response received from provider";
                    self.lifecycle_hooks.execute(.on_error, &hook_ctx) catch {};
                }
                self.finishRequestWithErrorText("No response received from provider");
                return;
            }

            total_output_tokens += estimateResponseOutputTokens(content, tool_calls);
            try self.applyAssistantResponse(content, tool_calls);

            // Execute post_request lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .post_request;
                hook_ctx.token_count = @intCast(total_input_tokens + total_output_tokens);
                self.lifecycle_hooks.execute(.post_request, &hook_ctx) catch {};
            }

            if (tool_calls) |calls| {
                try self.executeToolCalls(calls);
                if (iteration + 1 >= self.max_iterations) {
                    self.finishRequestWithErrorText("Stopped after reaching max tool iterations.");
                    return;
                }
                try self.startNextAssistantPlaceholder();
                continue;
            }

            self.finishRequestSuccess(total_input_tokens, total_output_tokens);
            return;
        }

        self.finishRequestWithErrorText("Stopped after reaching max tool iterations.");
    }

    fn activateFallbackProvider(self: *Model, index: usize) !void {
        const provider = self.fallback_providers.items[index];

        self.lock.lock();
        defer self.lock.unlock();
        try self.replaceOwnedString(&self.provider_name, provider.provider_name);
        try self.replaceOwnedString(&self.model_name, provider.model_name);
        try self.replaceOwnedString(&self.api_key, provider.api_key);
        if (self.override_url) |current_override_url| self.allocator.free(current_override_url);
        self.override_url = if (provider.override_url) |override_url| try self.allocator.dupe(u8, override_url) else null;
        self.active_provider_index = index;
        try self.initializeClientFor(self.provider_name, self.model_name, self.api_key, self.override_url);
    }

    fn sendChatStreamingWithFallback(self: *Model) !core.ChatResponse {
        var index = self.active_provider_index;
        while (index < self.fallback_providers.items.len) : (index += 1) {
            try self.activateFallbackProvider(index);
            const response = self.client.?.sendChatStreaming(self.history.items, streamCallback) catch |err| {
                if (!isRetryableProviderError(err) or index + 1 >= self.fallback_providers.items.len) {
                    return err;
                }
                const next_provider = self.fallback_providers.items[index + 1];
                const status_text = try std.fmt.allocPrint(self.allocator, "⚠ {s} failed, trying {s}/{s}...", .{
                    self.fallback_providers.items[index].provider_name,
                    next_provider.provider_name,
                    next_provider.model_name,
                });
                defer self.allocator.free(status_text);
                try self.setStatusMessage(status_text);
                try self.resetActiveAssistantPlaceholderForRetry();
                continue;
            };
            self.clearStatusMessage();
            return response;
        }
        return error.NetworkError;
    }

    fn resetActiveAssistantPlaceholderForRetry(self: *Model) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.assistant_stream_index) |index| {
            try self.replaceMessageUnlocked(index, "assistant", "Thinking...", null, null);
        }
        self.awaiting_first_token = true;
    }

    fn applyAssistantResponse(self: *Model, content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (tool_calls) |_| {
            try self.trackToolCallFilesUnlocked(tool_calls);
        }

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
            } else {
                try self.addMessageWithToolsUnlocked("assistant", content, null, tool_calls);
                self.assistant_stream_index = self.messages.items.len - 1;
            }
            self.awaiting_first_token = false;
        } else if (self.assistant_stream_index) |index| {
            try self.replaceMessageUnlocked(index, "assistant", content, null, tool_calls);
        }

        try self.appendHistoryMessageWithToolsUnlocked("assistant", content, null, tool_calls);
        // Persist to cross-session memory
        self.memory.addMessage("assistant", content) catch {};
        self.memory.save() catch {};
        try self.saveSessionSnapshotUnlocked();

        self.context_tokens = self.estimateContextTokens();
        if (self.compactor.needsCompaction(self.context_tokens)) {
            self.performCompactionAuto() catch {};
        }
    }

    fn executeToolCalls(self: *Model, tool_calls: []const core.client.ToolCallInfo) !void {
        for (tool_calls) |tool_call| {
            // Execute pre_tool lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .pre_tool;
                hook_ctx.tool_name = tool_call.name;
                self.lifecycle_hooks.execute(.pre_tool, &hook_ctx) catch {};
            }

            // Compute diff preview for edit/write_file tools
            var preview_diff: ?[]const u8 = null;
            if (std.mem.eql(u8, tool_call.name, "edit") or std.mem.eql(u8, tool_call.name, "write_file")) {
                preview_diff = self.computeEditPreview(tool_call) catch null;
            }

            const allowed = try self.requestToolPermission(tool_call.name, tool_call.arguments, preview_diff);
            if (preview_diff) |d| self.allocator.free(d);
            const result_text = if (!allowed)
                try self.allocator.dupe(u8, "error: tool execution denied by user")
            else blk: {
                // Use HybridBridge for unified tool dispatch (builtin + MCP)
                const parsed_tool_call = core.ParsedToolCall{
                    .id = tool_call.id,
                    .name = tool_call.name,
                    .arguments = tool_call.arguments,
                };
                if (self.hybrid_bridge) |hb| {
                    if (hb.executeTool(parsed_tool_call)) |result|
                        break :blk result
                    else |_|
                        break :blk try std.fmt.allocPrint(self.allocator, "error: unsupported tool '{s}'", .{tool_call.name});
                }
                break :blk try self.allocator.dupe(u8, "error: tool dispatch unavailable");
            };
            defer self.allocator.free(result_text);

            // Execute post_tool lifecycle hook
            {
                var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
                defer hook_ctx.deinit();
                hook_ctx.phase = .post_tool;
                hook_ctx.tool_name = tool_call.name;
                self.lifecycle_hooks.execute(.post_tool, &hook_ctx) catch {};
            }

            self.lock.lock();
            errdefer self.lock.unlock();
            try self.addMessageWithToolsUnlocked("tool", result_text, tool_call.id, null);
            try self.appendHistoryMessageWithToolsUnlocked("tool", result_text, tool_call.id, null);
            try self.saveSessionSnapshotUnlocked();
            self.lock.unlock();
        }
    }

    /// Compute a unified diff preview for edit/write_file tool calls without applying them.
    fn computeEditPreview(self: *Model, tool_call: core.client.ToolCallInfo) !?[]const u8 {
        if (std.mem.eql(u8, tool_call.name, "edit")) {
            const parsed = std.json.parseFromSlice(
                struct { file_path: ?[]const u8 = null, path: ?[]const u8 = null, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null },
                self.allocator,
                tool_call.arguments,
                .{ .ignore_unknown_fields = true },
            ) catch return null;
            defer parsed.deinit();
            const fp = parsed.value.file_path orelse parsed.value.path orelse return null;
            const old_s = parsed.value.old_string orelse return null;
            const new_s = parsed.value.new_string orelse "";
            return try tool_executors.previewEditDiff(self.allocator, fp, old_s, new_s);
        }

        if (std.mem.eql(u8, tool_call.name, "write_file")) {
            const parsed = std.json.parseFromSlice(
                struct { path: ?[]const u8 = null, file_path: ?[]const u8 = null, content: ?[]const u8 = null },
                self.allocator,
                tool_call.arguments,
                .{ .ignore_unknown_fields = true },
            ) catch return null;
            defer parsed.deinit();
            const fp = parsed.value.path orelse parsed.value.file_path orelse return null;
            const content = parsed.value.content orelse return null;
            return try tool_executors.previewWriteDiff(self.allocator, fp, content);
        }

        return null;
    }

    fn startNextAssistantPlaceholder(self: *Model) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.addMessageUnlocked("assistant", "Thinking...");
        self.assistant_stream_index = self.messages.items.len - 1;
        self.awaiting_first_token = true;
        try self.saveSessionSnapshotUnlocked();
    }

    fn finishRequestSuccess(self: *Model, input_tokens: u64, output_tokens: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.total_input_tokens += input_tokens;
        self.total_output_tokens += output_tokens;
        self.request_count += 1;
        const cost = self.pricing_table.estimateCostSimple(self.provider_name, resolvedPricingModel(self), @intCast(@min(input_tokens, std.math.maxInt(u32))), @intCast(@min(output_tokens, std.math.maxInt(u32))));
        self.budget_mgr.recordCost(cost);
        if (self.budget_mgr.shouldAlert()) {
            const status = self.budget_mgr.checkBudget();
            const severity: widget_toast.Severity = if (status.isOverBudget()) .err else .warning;
            const message = if (status.isOverBudget())
                std.fmt.allocPrint(self.allocator, "Budget exceeded: ${d:.2}", .{self.budget_mgr.session_spent}) catch "Budget exceeded"
            else
                std.fmt.allocPrint(self.allocator, "Budget alert: ${d:.2} ({d:.0}% used)", .{ self.budget_mgr.session_spent, status.percent_used * 100.0 }) catch "Budget alert";
            self.toast_stack.push(message, severity) catch {};
        }
        self.request_active = false;
        self.request_done = true;
        self.spinner = null;
        // Keep typewriter alive so animation can finish naturally
        self.saveSessionSnapshotUnlocked() catch {};
    }

    fn finishRequestWithCaughtError(self: *Model, err: anyerror) void {
        switch (err) {
            error.AuthenticationError => self.finishRequestWithErrorText("No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"),
            error.NetworkError => self.finishRequestWithErrorText("Network error while contacting provider. Check your connection and try again."),
            error.TimeoutError => self.finishRequestWithErrorText("Request timed out. Please try again."),
            error.ServerError => self.finishRequestWithErrorText("Provider returned an error. Please try again in a moment."),
            error.InvalidResponse => self.finishRequestWithErrorText("Provider returned an invalid response."),
            error.ConfigurationError => self.finishRequestWithErrorText("Chat client is not configured correctly. Run crushcode setup or edit ~/.crushcode/config.toml"),
            else => {
                const text = std.fmt.allocPrint(self.allocator, "Request failed: {s}", .{@errorName(err)}) catch return;
                defer self.allocator.free(text);
                self.finishRequestWithErrorText(text);
            },
        }
    }

    fn finishRequestWithErrorText(self: *Model, text: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.awaiting_first_token) {
            if (self.assistant_stream_index) |index| {
                self.replaceMessageUnlocked(index, "error", text, null, null) catch {
                    self.addMessageUnlocked("error", text) catch {};
                };
            } else {
                self.addMessageUnlocked("error", text) catch {};
            }
            self.awaiting_first_token = false;
        } else {
            self.addMessageUnlocked("error", text) catch {};
        }

        self.request_active = false;
        self.request_done = true;
        self.spinner = null;
        // Reveal typewriter immediately on error so the error text is fully visible
        if (self.typewriter) |*tw| {
            tw.revealAll();
        }
        self.saveSessionSnapshotUnlocked() catch {};
    }

    fn handleStreamToken(self: *Model, token: []const u8, done: bool) void {
        _ = done;
        if (token.len == 0) {
            return;
        }

        // Feed token to spinner for animation + stalled detection
        if (self.spinner) |*spinner| {
            spinner.feedToken();
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.assistant_stream_index orelse return;
        if (self.awaiting_first_token) {
            self.replaceMessageUnlocked(index, "assistant", token, null, null) catch {};
            self.awaiting_first_token = false;
        } else {
            self.appendToMessageUnlocked(index, token) catch {};
        }

        // Feed updated text to typewriter for progressive reveal
        if (self.typewriter) |*tw| {
            const msg = &self.messages.items[index];
            tw.updateText(msg.content);
        }
    }

    fn estimatedCostUsd(self: *const Model) f64 {
        const input_tokens: u32 = @intCast(@min(self.total_input_tokens, std.math.maxInt(u32)));
        const output_tokens: u32 = @intCast(@min(self.total_output_tokens, std.math.maxInt(u32)));
        return self.pricing_table.estimateCostSimple(self.provider_name, resolvedPricingModel(self), input_tokens, output_tokens);
    }

    fn estimateContextTokens(self: *const Model) u64 {
        var total: u64 = 0;
        if (self.effective_system_prompt) |prompt| {
            total += compaction_mod.ContextCompactor.estimateTokens(prompt);
        }
        for (self.history.items) |msg| {
            if (msg.content) |content| {
                total += compaction_mod.ContextCompactor.estimateTokens(content);
            }
        }
        return total;
    }

    fn performCompaction(self: *Model) !void {
        if (self.history.items.len <= self.compactor.recent_window) {
            try self.addMessageUnlocked("assistant", "Not enough messages to compact (need more than recent window).");
            return;
        }

        // Build CompactMessage slice from history
        const compact_messages = try self.allocator.alloc(compaction_mod.CompactMessage, self.history.items.len);
        defer self.allocator.free(compact_messages);
        for (self.history.items, 0..) |msg, i| {
            compact_messages[i] = .{
                .role = msg.role,
                .content = msg.content orelse "",
                .timestamp = null,
            };
        }

        var result = try self.compactor.compactWithSummary(compact_messages, self.last_compaction_summary);
        defer result.deinit();

        if (result.messages_summarized == 0) {
            try self.addMessageUnlocked("assistant", "No messages were compacted.");
            return;
        }

        // Store summary (dupe before result.deinit frees it)
        if (self.last_compaction_summary.len > 0) self.allocator.free(self.last_compaction_summary);
        self.last_compaction_summary = if (result.summary.len > 0) try self.allocator.dupe(u8, result.summary) else "";

        // Remove old messages from history — result.messages_summarized were compacted
        const remove_count = result.messages_summarized;
        for (self.history.items[0..remove_count]) |msg| {
            freeChatMessage(self.allocator, msg);
        }
        const remaining = self.history.items[remove_count..];
        std.mem.copyForwards(core.ChatMessage, self.history.items, remaining);
        self.history.shrinkRetainingCapacity(self.history.items.len - remove_count);

        self.context_tokens = self.estimateContextTokens();

        const text = try std.fmt.allocPrint(self.allocator, "Compacted {d} messages. Saved ~{d} tokens. Context: {d}%", .{
            result.messages_summarized,
            result.tokens_saved,
            self.contextPercent(),
        });
        try self.addMessageUnlocked("assistant", text);
    }

    fn performCompactionAuto(self: *Model) !void {
        if (self.history.items.len <= self.compactor.recent_window) return;

        const compact_messages = try self.allocator.alloc(compaction_mod.CompactMessage, self.history.items.len);
        defer self.allocator.free(compact_messages);
        for (self.history.items, 0..) |msg, i| {
            compact_messages[i] = .{
                .role = msg.role,
                .content = msg.content orelse "",
                .timestamp = null,
            };
        }

        var result = try self.compactor.compactLight(compact_messages);
        defer result.deinit();

        if (result.messages_summarized == 0) return;

        // Store summary
        if (self.last_compaction_summary.len > 0) self.allocator.free(self.last_compaction_summary);
        self.last_compaction_summary = if (result.summary.len > 0) try self.allocator.dupe(u8, result.summary) else "";

        const remove_count = result.messages_summarized;
        for (self.history.items[0..remove_count]) |msg| {
            freeChatMessage(self.allocator, msg);
        }
        const remaining = self.history.items[remove_count..];
        std.mem.copyForwards(core.ChatMessage, self.history.items, remaining);
        self.history.shrinkRetainingCapacity(self.history.items.len - remove_count);

        self.context_tokens = self.estimateContextTokens();
    }

    fn contextPercent(self: *const Model) u8 {
        const total_tokens = self.total_input_tokens + self.total_output_tokens;
        const percent = @min((total_tokens * 100) / 128_000, 100);
        return @intCast(percent);
    }

    fn getMCPServerStatus(self: *const Model, allocator: std.mem.Allocator) []const widget_sidebar.MCPServerStatus {
        const bridge = self.mcp_bridge orelse return &.{};
        var statuses = std.ArrayList(widget_sidebar.MCPServerStatus).initCapacity(allocator, bridge.servers.items.len) catch return &.{};
        for (bridge.servers.items) |server| {
            statuses.append(allocator, .{
                .name = server.name,
                .connected = server.connected,
                .tool_count = @intCast(server.tools.len),
            }) catch break;
        }
        return statuses.toOwnedSlice(allocator) catch return &.{};
    }

    fn sessionElapsedSeconds(self: *const Model) u64 {
        const elapsed_ns = @max(std.time.nanoTimestamp() - self.session_start, 0);
        return @intCast(@divFloor(elapsed_ns, std.time.ns_per_s));
    }

    fn sessionMinutes(self: *const Model) u64 {
        return @divFloor(self.sessionElapsedSeconds(), 60);
    }

    fn sessionSecondsPart(self: *const Model) u64 {
        return @mod(self.sessionElapsedSeconds(), 60);
    }
};

fn onSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.handleSubmit(value, ctx);
}

fn onPaletteChange(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.setPaletteFilter(value);
    ctx.redraw = true;
}

fn onPaletteSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));

    // If user typed text and pressed Enter, check if it matches any command exactly
    if (value.len > 0) {
        var filtered_indices: [widget_palette.palette_command_data.len]usize = undefined;
        const filtered_count = widget_palette.collectFilteredCommandIndices(model.palette_commands, value, filtered_indices[0..]);

        // If there's exactly one match and it's an exact name match, execute it
        if (filtered_count == 1) {
            const command = model.palette_commands[filtered_indices[0]];
            if (std.mem.eql(u8, command.name, value)) {
                try model.closePalette(ctx);
                try model.executePaletteCommand(command.name, ctx);
                return;
            }
        }

        // If it's not an exact match, treat it as filter text and don't execute
        // User can continue typing or use arrow keys to select
        return;
    }

    // If no text was typed (user navigated with arrows and pressed Enter), execute selection
    try model.executePaletteSelection(ctx);
}

fn streamCallback(token: []const u8, done: bool) void {
    const model = active_stream_model orelse return;
    model.handleStreamToken(token, done);
}

fn shouldRenderMessageContent(message: *const Message) bool {
    return message.content.len > 0 or message.tool_calls == null;
}

fn toolCallStatusIcon(status: ToolCallStatus) []const u8 {
    return switch (status) {
        .pending => "●",
        .success => "✓",
        .failed => "×",
    };
}

fn toolCallStatusStyle(theme: *const theme_mod.Theme, status: ToolCallStatus) vaxis.Style {
    return switch (status) {
        .pending => .{ .fg = theme.tool_pending, .bold = true },
        .success => .{ .fg = theme.tool_success, .bold = true },
        .failed => .{ .fg = theme.tool_error, .bold = true },
    };
}

fn toolCallStatusForMessage(message: ?*const Message) ToolCallStatus {
    const result = message orelse return .pending;
    if (std.mem.eql(u8, result.role, "error")) return .failed;

    const trimmed = std.mem.trim(u8, result.content, " \t\r\n");
    if (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "error:")) {
        return .failed;
    }
    return .success;
}

fn toolCallOutputText(allocator: std.mem.Allocator, output: ?[]const u8, status: ToolCallStatus) ![]const u8 {
    const text = output orelse {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    };
    if (text.len == 0) {
        if (status == .pending) return allocator.dupe(u8, "  running...");
        return allocator.dupe(u8, "");
    }

    var builder = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    var remaining: usize = 0;
    while (lines.next()) |line| {
        if (line_count < 5) {
            if (line_count > 0) try builder.append(allocator, '\n');
            try builder.appendSlice(allocator, "  ");
            try builder.appendSlice(allocator, line);
        } else {
            remaining += 1;
        }
        line_count += 1;
    }
    if (remaining > 0) {
        if (builder.items.len > 0) try builder.append(allocator, '\n');
        try builder.writer(allocator).print("  and {d} more lines...", .{remaining});
    }
    return builder.toOwnedSlice(allocator);
}

fn findToolCallBefore(messages: []const Message, before_index: usize, tool_call_id: []const u8) ?core.client.ToolCallInfo {
    var idx = before_index;
    while (idx > 0) {
        idx -= 1;
        if (messages[idx].tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.id, tool_call_id)) return tool_call;
            }
        }
    }
    return null;
}

fn findToolResultMessageAfter(messages: []const Message, after_index: usize, tool_call_id: []const u8) ?*const Message {
    var idx = after_index + 1;
    while (idx < messages.len) : (idx += 1) {
        const message = &messages[idx];
        if (message.tool_call_id) |message_tool_call_id| {
            if (std.mem.eql(u8, message_tool_call_id, tool_call_id)) return message;
        }
    }
    return null;
}

fn visibleMessageCount(messages: []const Message) usize {
    var count: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;
        count += 1;
    }
    return count;
}

fn messageRoleStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.assistant_fg, .bold = true };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .bold = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .bold = true };
    }
    return .{ .fg = theme.dimmed, .bold = true };
}

fn messageBodyStyle(theme: *const theme_mod.Theme, role: []const u8) vaxis.Style {
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .fg = theme.header_fg };
    }
    if (std.mem.eql(u8, role, "user")) {
        return .{ .fg = theme.user_fg };
    }
    if (std.mem.eql(u8, role, "error")) {
        return .{ .fg = theme.error_fg };
    }
    if (std.mem.eql(u8, role, "system")) {
        return .{ .fg = theme.tool_pending, .dim = true };
    }
    if (std.mem.eql(u8, role, "tool")) {
        return .{ .fg = theme.accent, .dim = true };
    }
    return .{ .fg = theme.dimmed, .dim = true };
}

fn messageRoleLabel(theme: *const theme_mod.Theme, role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return theme.user_label;
    if (std.mem.eql(u8, role, "assistant")) return theme.assistant_label;
    if (std.mem.eql(u8, role, "error")) return "Error";
    if (std.mem.eql(u8, role, "system")) return "System";
    if (std.mem.eql(u8, role, "tool")) return "Tool";
    return role;
}

fn estimateContentHeight(model: *const Model) ?u32 {
    var total: u32 = 0;
    const messages = model.messages.items;
    const visible_count = visibleMessageCount(messages);
    var visible_index: usize = 0;
    for (messages, 0..) |message, idx| {
        if (message.tool_call_id != null and findToolCallBefore(messages, idx, message.tool_call_id.?) != null) continue;

        if (shouldRenderMessageContent(&message)) {
            total += @intCast(1 + std.mem.count(u8, message.content, "\n"));
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += 1;
                if (tool_call.arguments.len > 0) total += @intCast(std.mem.count(u8, tool_call.arguments, "\n"));
                const result = findToolResultMessageAfter(messages, idx, tool_call.id);
                const output = result orelse null;
                const output_text = if (output) |message_result| message_result.content else if (toolCallStatusForMessage(result) == .pending) "running..." else "";
                if (isDiffRenderableTool(tool_call.name) and extractToolDiffText(output_text) != null) {
                    total += @as(u32, @intCast(@min(std.mem.count(u8, output_text, "\n") + 4, tool_diff_max_lines + 4)));
                } else if (output_text.len > 0) {
                    total += @intCast(@min(std.mem.count(u8, output_text, "\n") + 1, 6));
                }
            }
        }

        visible_index += 1;
        if (visible_index < visible_count) total += 2;
    }
    return total;
}

fn drawBorder(surface: *vxfw.Surface, style: vaxis.Style) void {
    const width = surface.size.width;
    const height = surface.size.height;
    if (width == 0 or height == 0) return;

    const horizontal: vaxis.Cell = .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style };
    const vertical: vaxis.Cell = .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style };
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    surface.writeCell(0, height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(width - 1, height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });

    if (width > 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), 0, horizontal);
            surface.writeCell(@intCast(col), height - 1, horizontal);
        }
    }
    if (height > 2) {
        for (1..height - 1) |row| {
            surface.writeCell(0, @intCast(row), vertical);
            surface.writeCell(width - 1, @intCast(row), vertical);
        }
    }
}

fn estimateTextTokens(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return @intCast(@divFloor(text.len + 3, 4));
}

fn estimateMessageTokens(messages: []const core.ChatMessage) u64 {
    var total: u64 = 0;
    for (messages) |message| {
        total += estimateTextTokens(message.role);
        if (message.content) |content| {
            total += estimateTextTokens(content);
        }
        if (message.tool_call_id) |tool_call_id| {
            total += estimateTextTokens(tool_call_id);
        }
        if (message.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                total += estimateTextTokens(tool_call.id);
                total += estimateTextTokens(tool_call.name);
                total += estimateTextTokens(tool_call.arguments);
            }
        }
    }
    return total;
}

fn repeated(allocator: std.mem.Allocator, token: []const u8, count: u16) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try buffer.ensureTotalCapacity(allocator, token.len * count);
    for (0..count) |_| {
        try buffer.appendSlice(allocator, token);
    }
    return buffer.toOwnedSlice(allocator);
}

fn recentFilesDisplay(files: []const []const u8) []const []const u8 {
    return files[0..@min(files.len, recent_files_display_max)];
}

fn isRecentFileTool(name: []const u8) bool {
    for (recent_file_tool_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isDiffRenderableTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit");
}

fn extractToolDiffText(output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "```diff")) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "@@")) return trimmed;
    return null;
}

fn extractToolFilePath(arguments: []const u8) ?[]const u8 {
    inline for (.{ "path", "file_path" }) |key| {
        if (std.mem.indexOf(u8, arguments, std.fmt.comptimePrint("\"{s}\"", .{key}))) |key_index| {
            const colon = std.mem.indexOfPos(u8, arguments, key_index, ":") orelse return null;
            var start = colon + 1;
            while (start < arguments.len and std.ascii.isWhitespace(arguments[start])) : (start += 1) {}
            if (start >= arguments.len or arguments[start] != '"') return null;
            start += 1;
            const end = std.mem.indexOfScalarPos(u8, arguments, start, '"') orelse return null;
            return arguments[start..end];
        }
    }
    return null;
}

fn recentFilesVisibleCount(files: []const []const u8) usize {
    return @min(files.len, recent_files_display_max);
}

fn contentSurfaceWidget(allocator: std.mem.Allocator, surface: vxfw.Surface) !vxfw.Widget {
    const widget_holder = try allocator.create(SurfaceWidget);
    widget_holder.* = .{ .surface = surface };
    return widget_holder.widget();
}

fn resolvedPricingModel(model: *const Model) []const u8 {
    if (model.pricing_table.getPrice(model.provider_name, model.model_name) != null) {
        return model.model_name;
    }
    return "default";
}

fn spinnerFrame() []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const tick = @divFloor(std.time.milliTimestamp(), 120);
    return frames[@as(usize, @intCast(@mod(tick, frames.len)))];
}

fn estimateResponseOutputTokens(content: []const u8, tool_calls: ?[]const core.client.ToolCallInfo) u64 {
    var total = estimateTextTokens(content);
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            total += estimateTextTokens(tool_call.name);
            total += estimateTextTokens(tool_call.arguments);
        }
    }
    return total;
}

fn isRetryableProviderError(err: anyerror) bool {
    return switch (err) {
        error.NetworkError, error.TimeoutError, error.ServerError, error.RetryExhausted => true,
        else => false,
    };
}

fn executeInlineTool(allocator: std.mem.Allocator, tool_call: core.client.ToolCallInfo) ![]const u8 {
    const parsed = core.ParsedToolCall{
        .id = tool_call.id,
        .name = tool_call.name,
        .arguments = tool_call.arguments,
    };
    const execution = try tool_executors.executeBuiltinTool(allocator, parsed);
    defer allocator.free(execution.display);
    return allocator.dupe(u8, execution.result);
}

fn freeToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) void {
    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        }
        allocator.free(calls);
    }
}

fn cloneToolCallInfos(allocator: std.mem.Allocator, tool_calls: ?[]const core.client.ToolCallInfo) !?[]const core.client.ToolCallInfo {
    const source = tool_calls orelse return null;
    const copied = try allocator.alloc(core.client.ToolCallInfo, source.len);
    for (source, 0..) |tool_call, i| {
        copied[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
    return copied;
}

fn freeDisplayMessage(allocator: std.mem.Allocator, message: Message) void {
    allocator.free(message.role);
    allocator.free(message.content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

fn freeChatMessage(allocator: std.mem.Allocator, message: core.ChatMessage) void {
    allocator.free(message.role);
    if (message.content) |content| allocator.free(content);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    freeToolCallInfos(allocator, message.tool_calls);
}

fn freeChatResponse(allocator: std.mem.Allocator, response: *core.ChatResponse) void {
    allocator.free(response.id);
    allocator.free(response.object);
    allocator.free(response.model);
    for (response.choices) |choice| {
        freeChatMessage(allocator, choice.message);
        if (choice.finish_reason) |finish_reason| allocator.free(finish_reason);
    }
    allocator.free(response.choices);
    if (response.provider) |provider| allocator.free(provider);
    if (response.cost) |cost| allocator.free(cost);
    if (response.system_fingerprint) |system_fingerprint| allocator.free(system_fingerprint);
}

pub fn run(allocator: std.mem.Allocator, provider_name: []const u8, model_name: []const u8, api_key: []const u8) !void {
    try runWithOptions(allocator, .{
        .provider_name = provider_name,
        .model_name = model_name,
        .api_key = api_key,
    });
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var model = try Model.create(allocator, options);
    defer model.destroy();
    try model.run();
}
