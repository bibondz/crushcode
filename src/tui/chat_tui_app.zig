const file_compat = @import("file_compat");
const overlay = @import("overlay");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const http_client = @import("http_client");

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
const widget_diff_preview = @import("widget_diff_preview");
const tool_executors = @import("chat_tool_executors");
const mcp_bridge_mod = @import("mcp_bridge");
const mcp_client_mod = @import("mcp_client");
const myers = @import("myers");
const hybrid_bridge_mod = @import("hybrid_bridge");
const array_list_compat = @import("array_list_compat");
const compaction_mod = @import("compaction");
const context_limits = @import("context_limits");
const project_mod = @import("project");
const file_watcher_mod = @import("file_watcher");
const lifecycle_mod = @import("lifecycle_hooks");
const memory_mod = @import("memory");
const parallel_mod = @import("parallel");
const plugin_mod = @import("plugin_manager");
const guardian_mod = @import("guardian");
const cognition_mod = @import("cognition");
const autopilot_mod = @import("autopilot");
const crush_mode_mod = @import("crush_mode");
const phase_runner_mod = @import("phase_runner");
const orchestration_mod = @import("orchestration");
const slash_commands_mod = @import("slash_commands");
const user_model_mod = @import("user_model");
const auto_gen_mod = @import("auto_gen");
const plan_mod = @import("plan_handler");
const feedback_mod = @import("feedback");
const delegate_mod = @import("delegate");
const lsp_manager_mod = @import("lsp_manager");
const cost_dashboard_mod = @import("cost_dashboard");
const session_db_mod = @import("session_db");
const fork_mod = @import("fork");
const team_coordinator_lib = @import("team_coordinator");
const safety_checkpoint_mod = @import("safety_checkpoint");
const session_tree_mod = @import("session_tree");
const semantic_compressor_mod = @import("semantic_compressor");
const doctor_mod = @import("doctor");
const review_mod = @import("review");
const commit_mod = @import("commit");
const hooks_mod = @import("hooks_registry");
const hooks_config_mod = @import("hooks_config");
const notifier_plugin = @import("notifier_plugin");
const model_palette = @import("model/palette.zig");
const input_handling = @import("model/input_handling.zig");
const navigation = @import("model/navigation.zig");
const model_fallback = @import("model/fallback.zig");
const permissions_mod = @import("model/permissions.zig");
const history_mod = @import("model/history.zig");
const session_time_mod = @import("model/session_time.zig");
const mcp_status_mod = @import("model/mcp_status.zig");
const notifications_mod = @import("model/notifications.zig");
const token_tracking_mod = @import("model/token_tracking.zig");
const session_mgmt = @import("model/session_mgmt.zig");
const status_mod = @import("model/status.zig");
const streaming = @import("model/streaming.zig");

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

/// Builder data for ScrollView's .builder source — avoids creating all message
/// widgets every frame; only visible items are built on demand.
const MessageListBuilderData = struct {
    model: *const Model,
    visible_indices: []const usize,
    theme: *const theme_mod.Theme,
    arena: std.mem.Allocator,
};

/// ScrollView builder function. Maps a flat widget index to the appropriate
/// widget using the same 3-widget-per-message layout as the original slice:
///   idx % 3 == 0 → MessageWidget for visible message at idx / 3
///   idx % 3 == 1 → MessageGapWidget (between messages)
///   idx % 3 == 2 → SeparatorWidget  (between messages)
/// The last visible message has no trailing gap/sep, so we return null for
/// indices beyond the last message slot.
fn messageListBuildFn(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const data: *const MessageListBuilderData = @ptrCast(@alignCast(ptr));
    const vis_count = data.visible_indices.len;
    if (vis_count == 0) return null;

    const total_widgets: usize = if (vis_count == 0) 0 else vis_count * 3 - 2;
    if (idx >= total_widgets) return null;

    const slot = idx % 3;
    const vis_idx = idx / 3;

    if (slot == 0) {
        // MessageWidget
        if (vis_idx >= vis_count) return null;
        const mw = data.arena.create(MessageWidget) catch return null;
        mw.* = .{ .model = data.model, .message_index = data.visible_indices[vis_idx] };
        return mw.widget();
    }

    // Gap + Separator slots only exist between messages (vis_idx < vis_count - 1)
    if (vis_idx >= vis_count - 1) return null;

    if (slot == 1) {
        const gap = data.arena.create(MessageGapWidget) catch return null;
        gap.* = .{};
        return gap.widget();
    }

    // slot == 2
    const sep = data.arena.create(SeparatorWidget) catch return null;
    sep.* = .{ .theme = data.theme };
    return sep.widget();
}

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

const PaletteItem = widget_palette.PaletteItem;
const PaletteCategory = widget_palette.PaletteCategory;
const palette_command_data = widget_palette.palette_command_data;
const CommandRowWidget = widget_palette.CommandRowWidget;
const SessionListRowWidget = widget_palette.SessionListRowWidget;
const SessionListWidget = widget_palette.SessionListWidget;
const ResumePromptWidget = widget_palette.ResumePromptWidget;
const CommandPaletteWidget = widget_palette.CommandPaletteWidget;
const collectFilteredCommandIndices = widget_palette.collectFilteredCommandIndices;
const formatSessionTimestamp = widget_palette.formatSessionTimestamp;

/// Slash command names used for autocomplete suggestions in the input field.
/// Single source of truth: src/core/slash_commands.zig
const slash_command_names = slash_commands_mod.all_slash_command_names;

const PermissionContext = widget_permission.PermissionContext;
const PermissionDialogWidget = widget_permission.PermissionDialogWidget;

const DiffPreviewContext = widget_diff_preview.DiffPreviewContext;
const DiffPreviewWidget = widget_diff_preview.DiffPreviewWidget;

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
    context_watcher: file_watcher_mod.FileWatcher,
    system_prompt_dirty: bool = false,
    knowledge_graph: ?*graph_mod.KnowledgeGraph,
    compactor: compaction_mod.ContextCompactor,
    context_tokens: u64,
    last_compaction_summary: []const u8,
    cached_project_info: ?project_mod.ProjectInfo,
    cached_repo_map: ?[]const u8,
    auto_commit_edits: bool = false, // toggle with /autocommit
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
    palette_items: []const PaletteItem,
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
    diff_preview_active: bool = false,
    diff_preview_hunks: []const myers.DiffHunk = &.{},
    diff_preview_decisions: []widget_diff_preview.HunkDecision = &.{},
    diff_preview_current: usize = 0,
    diff_preview_file_path: []const u8 = "",
    diff_preview_original: []const u8 = "",
    diff_preview_new_content: []const u8 = "",
    diff_preview_tool_call_id: []const u8 = "",
    diff_preview_tool_name: []const u8 = "",
    diff_preview_tool_arguments: []const u8 = "",
    request_start_time: i64 = 0,
    crush_active: bool = false,
    crush_engine: ?crush_mode_mod.CrushEngine = null,
    crush_progress: []const u8 = "",
    /// Live agent team for parallel AI execution via /team commands
    live_team: ?team_coordinator_lib.LiveAgentTeam = null,
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
    turn_token_history: array_list_compat.ArrayList(u32),
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
    right_pane_visible: bool = false,
    right_pane_content: ?[]const u8 = null,
    right_pane_title: ?[]const u8 = null,
    right_pane_width: u16 = 60,
    /// SplitView drag state — mouse-resizable pane dividers
    dragging_sidebar_divider: bool = false,
    dragging_right_pane_divider: bool = false,
    sidebar_drag_width: u16 = 25, // user-adjusted sidebar width (default 25)
    drag_start_col: u16 = 0, // mouse col when drag started
    drag_start_width: u16 = 0, // pane width when drag started
    /// Last known terminal dimensions (set during draw, read during handleEvent)
    last_screen_width: u16 = 120,
    last_screen_height: u16 = 40,
    cwd_files: std.ArrayList([]const u8),
    scroll_mode: bool = false,
    show_help: bool = false,
    /// Unified overlay state manager — tracks which overlay is active
    overlay_manager: overlay.OverlayManager = .{},
    auto_scroll: bool = true,
    selected_message_index: ?usize = null,
    /// Input history for Up/Down arrow navigation and Ctrl+S reverse-i-search
    input_history: std.ArrayList([]const u8),
    input_history_index: usize = 0, // 0 = not navigating, 1..N = browsing history
    input_history_draft: []const u8 = "", // saved current input when entering history
    /// Reverse-i-search state
    isearch_active: bool = false,
    isearch_query: array_list_compat.ArrayList(u8),
    isearch_match_index: ?usize = null,
    workers: std.ArrayList(WorkerItem),
    next_worker_id: u32 = 0,
    spinner: ?widget_spinner.AnimatedSpinner = null,
    toast_stack: widget_toast.ToastStack,
    typewriter: ?widget_typewriter.TypewriterState = null,
    mcp_bridge: ?*mcp_bridge_mod.Bridge = null,
    hybrid_bridge: ?*hybrid_bridge_mod.HybridBridge = null,
    plugin_manager: plugin_mod.runtime.ExternalPluginManager,
    lifecycle_hooks: lifecycle_mod.LifecycleHooks,
    hook_registry: ?*hooks_mod.HookRegistry,
    memory: memory_mod.Memory,
    parallel_executor: parallel_mod.ParallelExecutor,
    guardian: ?guardian_mod.Guardian = null,
    pipeline: ?*cognition_mod.KnowledgePipeline = null,
    pipeline_initialized: bool = false,
    user_model: ?user_model_mod.UserModel = null,
    auto_gen: ?auto_gen_mod.AutoSkillGenerator = null,
    feedback: ?feedback_mod.FeedbackStore = null,
        plan_mode: plan_mod.PlanMode,
        delegator: delegate_mod.SubAgentDelegator,
        delegate_mode: bool = false,
        context_total_files: u32 = 0,
    context_scored_files: u32 = 0,
    lsp_manager: lsp_manager_mod.LSPManager,
    session_tree: session_tree_mod.SessionTreeWidget,
    /// Desktop notification plugin — opt-in via notifications_enabled config or CRUSHCODE_NOTIFY=1
    notifier: ?notifier_plugin.NotifierPlugin,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Model {
        http_client.initSharedClient(allocator);

        // Pre-flight: check if /dev/tty is accessible.
        // vaxis.Tty.init() will dump a stack trace on failure, which is noisy.
        // Detect early and return a clean error instead.
        // Windows doesn't have /dev/tty — skip check; vaxis handles ConPTY internally.
        if (@import("builtin").os.tag != .windows) {
            const fd = std.c.open("/dev/tty", .{ .ACCMODE = .RDWR });
            if (fd < 0) return error.NoTTyAvailable;
            _ = std.c.close(fd);
        }

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
            .context_watcher = file_watcher_mod.FileWatcher.init(allocator),
            .knowledge_graph = null,
            .compactor = compaction_mod.ContextCompactor.init(allocator, context_limits.getContextWindow(options.provider_name, options.model_name)),
            .context_tokens = 0,
            .last_compaction_summary = "",
            .cached_project_info = project_mod.detectProject(allocator),
        .cached_repo_map = null,
            .max_tokens = options.max_tokens,
            .temperature = options.temperature,
            .override_url = if (options.override_url) |override_url| try allocator.dupe(u8, override_url) else null,
            .thinking = false,
            .app = app,
            .registry = registry_mod.ProviderRegistry.init(allocator),
            .client = null,
            .messages = std.ArrayList(Message).empty,
            .history = std.ArrayList(core.ChatMessage).empty,
            .turn_token_history = undefined, // initialized below
            .input = widget_input.MultiLineInputState.init(allocator),
            .show_palette = false,
            .palette_input = vxfw.TextField.init(allocator),
            .palette_items = &palette_command_data,
            .palette_selected = 0,
            .palette_filter = "",
            .scroll_view = .{
                .children = .{ .builder = .{ .userdata = undefined, .buildFn = messageListBuildFn } },
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
            .right_pane_visible = false,
            .right_pane_content = null,
            .input_history = std.ArrayList([]const u8).empty,
            .input_history_index = 0,
            .input_history_draft = "",
            .isearch_active = false,
            .isearch_query = array_list_compat.ArrayList(u8).init(allocator),
            .right_pane_title = null,
            .right_pane_width = 60,
            .workers = std.ArrayList(WorkerItem).empty,
            .cwd_files = std.ArrayList([]const u8).empty,
            .spinner = null,
            .toast_stack = undefined,
            .typewriter = null,
            .lifecycle_hooks = lifecycle_mod.LifecycleHooks.init(allocator),
            .hook_registry = null,
            .memory = memory_mod.Memory.init(allocator, "", 100),
            .parallel_executor = parallel_mod.ParallelExecutor.init(allocator, 3),
            .plugin_manager = plugin_mod.runtime.ExternalPluginManager.init(allocator, ""),
            .plan_mode = plan_mod.PlanMode.init(allocator),
            .delegator = delegate_mod.SubAgentDelegator.init(allocator, delegate_mod.DelegationConfig.init(allocator)),
            .lsp_manager = lsp_manager_mod.LSPManager.init(allocator),
            .session_tree = session_tree_mod.SessionTreeWidget.init(allocator),
            .notifier = if (options.notifications_enabled) notifier_plugin.NotifierPlugin.init(allocator) else null,
        };
        errdefer model.destroy();

        // Initialize cognition pipeline (non-fatal)
        {
            const p = cognition_mod.KnowledgePipeline.init(model.allocator, model.session_dir) catch null;
            if (p) |pl| {
                model.pipeline = pl;
                model.pipeline_initialized = true;
            }
        }
        // Initialize user model (non-fatal)
        {
            var um = user_model_mod.UserModel.init(model.allocator) catch null;
            if (um) |*m| {
                m.load() catch {};
                model.user_model = m.*;
            }
        }
        // Initialize auto-skill generator (non-fatal)
        {
            const home = file_compat.getEnv("HOME") orelse "";
            if (home.len > 0) {
                const skills_dir = std.fmt.allocPrint(model.allocator, "{s}/.crushcode/skills/auto", .{home}) catch null;
                if (skills_dir) |dir| {
                    var gen = auto_gen_mod.AutoSkillGenerator.init(model.allocator, dir) catch null;
                    if (gen) |*g| {
                        model.auto_gen = g.*;
                    }
                    model.allocator.free(dir);
                }
            }
        }
        // Initialize feedback store (non-fatal)
        {
            var fb = feedback_mod.FeedbackStore.init(model.allocator) catch null;
            if (fb) |*f| {
                f.load() catch {};
                model.feedback = f.*;
            }
        }
        // Initialize guardian (non-fatal)
        model.guardian = guardian_mod.Guardian.init(model.allocator) catch null;

        model.messages = try std.ArrayList(Message).initCapacity(allocator, 8);
        model.history = try std.ArrayList(core.ChatMessage).initCapacity(allocator, 8);
        model.turn_token_history = array_list_compat.ArrayList(u32).init(allocator);
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

        // Initialize hook registry and load hooks from config (non-fatal)
        {
            const hr = allocator.create(hooks_mod.HookRegistry) catch null;
            if (hr) |reg| {
                reg.* = hooks_mod.HookRegistry.init(allocator);
                _ = hooks_config_mod.loadAllHooks(allocator, reg) catch 0;
                model.hook_registry = reg;

                // Wire the hook registry into tool executors
                tool_executors.setHookRegistry(reg);
            }
        }

        // Execute session_start lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .session_start;
            model.lifecycle_hooks.execute(.session_start, &hook_ctx) catch {};
        }

        // Fire SessionStart hook via hook registry
        if (model.hook_registry) |registry| {
            var ctx = hooks_mod.HookContext{
                .hook_type = .SessionStart,
                .timestamp = std.time.milliTimestamp(),
            };
            const results = registry.executeHooks(&ctx) catch &.{};
            defer {
                for (results) |*r| r.deinit(allocator);
                if (results.len > 0) allocator.free(results);
            }
        }

        try model.registry.registerAllProviders();
        try model.buildCodebaseContext();
        try model_fallback.loadFallbackProviders(model);
        try std.fs.cwd().makePath(model.session_dir);

        // Initialize cross-session memory with proper path
        {
            const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.json", .{model.session_dir});
            model.memory = memory_mod.Memory.init(allocator, memory_path, 100);
            model.memory.load() catch {}; // non-fatal
        }

        try session_mgmt.prepareStartupSessionState(model);
        if (model.setup_phase != 0) {
            const selected_provider = setup_provider_data[model.setup_provider_index];
            if (model.provider_name.len == 0) {
                model.allocator.free(model.provider_name);
                model.provider_name = try model.allocator.dupe(u8, selected_provider);
            }
        } else {
            try history_mod.addMessageUnlocked(model, "assistant", "TUI chat ready. Type a message and press Enter.");
            try model.initializeClient();
            model.refreshCwdListing();
        }
        return model;
    }

    pub fn destroy(self: *Model) void {
        // Cleanup cognition pipeline and guardian
        if (self.pipeline) |p| p.deinit();
        if (self.right_pane_content) |c| self.allocator.free(c);
        if (self.right_pane_title) |t| self.allocator.free(t);
        if (self.user_model) |*um| um.deinit();
        if (self.auto_gen) |*ag| ag.deinit();
        if (self.feedback) |*fb| fb.deinit();
        if (self.guardian) |*g| g.deinit();
        if (self.notifier) |*n| n.deinit();

        permissions_mod.resolvePendingPermission(self, .no);
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
        for (self.cwd_files.items) |f| self.allocator.free(f);
        self.cwd_files.deinit(self.allocator);
        if (self.client) |*client| {
            client.deinit();
        }
        self.input.deinit();
        self.palette_input.deinit();
        // Free dynamic palette items (if not pointing to static default)
        if (self.palette_items.ptr != @as([*]const PaletteItem, @ptrCast(&palette_command_data))) {
            for (self.palette_items) |*it| {
                if (it.category != .command) {
                    self.allocator.free(it.label);
                    self.allocator.free(it.description);
                    self.allocator.free(it.action);
                }
            }
            self.allocator.free(self.palette_items);
        }
        for (self.messages.items) |message| {
            freeDisplayMessage(self.allocator, message);
        }
        self.messages.deinit(self.allocator);
        for (self.history.items) |message| {
            freeChatMessage(self.allocator, message);
        }
        self.history.deinit(self.allocator);
        self.turn_token_history.deinit();
        // Clean up input history
        for (self.input_history.items) |item| self.allocator.free(item);
        self.input_history.deinit(self.allocator);
        if (self.input_history_draft.len > 0) self.allocator.free(self.input_history_draft);
        self.isearch_query.deinit();
        self.registry.deinit();
        self.toast_stack.deinit();
        self.pricing_table.deinit();
        self.budget_mgr.deinit();
        if (self.system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.effective_system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.codebase_context) |codebase_context| self.allocator.free(codebase_context);
        if (self.cached_repo_map) |repo_map| self.allocator.free(repo_map);
        if (self.knowledge_graph) |kg| {
            kg.deinit();
            self.allocator.destroy(kg);
        }
        if (self.override_url) |override_url| self.allocator.free(override_url);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        if (self.setup_feedback.len > 0) self.allocator.free(self.setup_feedback);
        if (self.current_session) |*session| session_mod.deinitSession(self.allocator, session);
        session_mgmt.clearSessionListOwned(self);
        if (self.resume_prompt_session) |*session| session_mod.deinitSession(self.allocator, session);
        if (self.resume_prompt_path) |path| self.allocator.free(path);
        if (self.session_path.len > 0) self.allocator.free(self.session_path);
        self.allocator.free(self.session_dir);
        self.allocator.free(self.provider_name);
        self.allocator.free(self.model_name);
        self.compactor.deinit();
        self.context_watcher.deinit();
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
        // Clean up plan mode
        self.plan_mode.deinit();
        // Clean up sub-agent delegator
        self.delegator.deinit();
        // Clean up LSP manager
        self.lsp_manager.deinit();
        // Clean up session tree
        self.session_tree.deinit();
        // Clean up memory
        self.memory.deinit();
        // Clean up crush engine
        if (self.crush_engine) |*engine| {
            engine.deinit();
        }
        // Execute session_end lifecycle hook
        {
            var hook_ctx = lifecycle_mod.HookContext.init(self.allocator);
            defer hook_ctx.deinit();
            hook_ctx.phase = .session_end;
            self.lifecycle_hooks.execute(.session_end, &hook_ctx) catch {};
        }
        // Fire SessionEnd hook via hook registry
        if (self.hook_registry) |registry| {
            var ctx = hooks_mod.HookContext{
                .hook_type = .SessionEnd,
                .timestamp = std.time.milliTimestamp(),
            };
            const results = registry.executeHooks(&ctx) catch &.{};
            defer {
                for (results) |*r| r.deinit(self.allocator);
                if (results.len > 0) self.allocator.free(results);
            }
            registry.deinit();
            self.allocator.destroy(registry);
            self.hook_registry = null;
        }
        self.lifecycle_hooks.deinit();
        self.app.deinit();
        self.allocator.destroy(self.app);
        http_client.deinitSharedClient();
        self.allocator.destroy(self);
    }

    /// Refresh the CWD file listing shown in the sidebar.
    /// Walks the current working directory (depth 1) and populates `cwd_files`
    /// with sorted, relative paths capped at 50 entries.
    pub fn refreshCwdListing(self: *Model) void {
        // Clear old entries
        for (self.cwd_files.items) |f| self.allocator.free(f);
        self.cwd_files.clearRetainingCapacity();

        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();

        var walker = dir.walk(self.allocator) catch return;
        defer walker.deinit();

        var count: usize = 0;
        while (walker.next() catch null) |entry| {
            if (count >= 50) break;
            // Skip hidden files/dirs and common noise
            if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
            if (std.mem.eql(u8, entry.basename, "zig-out") or
                std.mem.eql(u8, entry.basename, "zig-cache") or
                std.mem.eql(u8, entry.basename, ".git"))
                continue;

            const kind = entry.kind;
            if (kind != .file and kind != .directory) continue;

            const prefix: []const u8 = if (kind == .directory) "📁 " else "  ";
            const full = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.path }) catch continue;
            self.cwd_files.append(self.allocator, full) catch {
                self.allocator.free(full);
                continue;
            };
            count += 1;
        }

        // Sort alphabetically (directories first via 📁 prefix)
        const lessThan = struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan;
        std.sort.insertion([]const u8, self.cwd_files.items, {}, lessThan);
    }

    pub fn run(self: *Model) !void {
        // Ensure the screen has a valid size before entering the render loop.
        // App.run() will call doLayout which divides width_pix / width —
        // a division-by-zero if the screen hasn't been resized yet or if
        // the terminal reports zero dimensions.
        const app = self.app;
        const tty = &app.tty;
        const vx = &app.vx;
        // getWinsize is POSIX-only; on Windows vaxis uses ConPTY which handles sizing via events
        if (@import("builtin").os.tag != .windows) {
            var ws: vaxis.Winsize = vaxis.Tty.getWinsize(app.tty.fd) catch
                .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 384 };
            if (ws.cols == 0) ws.cols = 80;
            if (ws.rows == 0) ws.rows = 24;
            if (ws.x_pixel == 0) ws.x_pixel = ws.cols * 8;
            if (ws.y_pixel == 0) ws.y_pixel = ws.rows * 16;
            try vx.resize(self.allocator, tty.writer(), ws);
        }

        try self.app.run(self.widget(), .{ .framerate = 30 });
    }

    fn restoreSessionUnlocked(self: *Model, session: session_mod.Session, path: []const u8) !void {
        var owned_session = session;
        errdefer session_mod.deinitSession(self.allocator, &owned_session);

        history_mod.clearMessagesUnlocked(self);
        history_mod.clearHistoryUnlocked(self);
        session_mgmt.clearRecentFilesUnlocked(self);
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
                try history_mod.trackToolCallFilesUnlocked(self, tool_calls);
            }
        }

        try input_handling.replaceOwnedString(self,&self.provider_name, owned_session.provider);
        try input_handling.replaceOwnedString(self,&self.model_name, owned_session.model);
        model_fallback.resetFallbackProviders(self);
        try model_fallback.loadFallbackProviders(self);
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
        try status_mod.setStatusMessageUnlocked(self, status);
    }

    fn refreshClientForSessionResumeUnlocked(self: *Model) !void {
        var config = config_mod.Config.init(self.allocator);
        defer config.deinit();

        config.loadDefault() catch |err| switch (err) {
            error.ConfigNotFound, error.FileNotFound => {},
            else => return err,
        };

        if (config.getApiKey(self.provider_name)) |api_key| {
            try input_handling.replaceOwnedString(self,&self.api_key, api_key);
        } else if (setupProviderAllowsEmptyKey(self.provider_name)) {
            try input_handling.replaceOwnedString(self,&self.api_key, "");
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
            try status_mod.setStatusMessageUnlocked(self, "Resumed session provider is not registered.");
            return;
        };
        if (self.api_key.len == 0 and !provider.config.is_local) {
            try status_mod.setStatusMessageUnlocked(self, "Missing API key for resumed session provider.");
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

    fn executeSessionSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.session_list.len == 0) {
            try session_mgmt.closeSessionList(self, ctx);
            return;
        }

        const session_id = try self.allocator.dupe(u8, self.session_list[self.session_list_selected].id);
        defer self.allocator.free(session_id);
        try session_mgmt.closeSessionList(self, ctx);
        try self.resumeSessionByIdUnlocked(session_id);
        ctx.redraw = true;
    }

    fn resumeSessionByIdUnlocked(self: *Model, session_id: []const u8) !void {
        if (self.request_active) {
            try history_mod.addMessageUnlocked(self, "error", "Cannot resume a session while a response is still streaming.");
            return;
        }

        try session_mgmt.saveSessionSnapshotUnlocked(self);

        const path = try session_mod.sessionFilePath(self.allocator, self.session_dir, session_id);
        defer self.allocator.free(path);
        const loaded = try session_mod.loadSession(self.allocator, path);
        try self.restoreSessionUnlocked(loaded, path);
    }

    fn handleResumePromptDecision(self: *Model, should_resume: bool) !void {
        if (!should_resume) {
            if (self.resume_prompt_path) |path| {
                session_mod.deleteSession(self.allocator, path) catch {};
            }
            session_mgmt.clearResumePromptOwned(self);
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

    pub fn initializeClientFor(self: *Model, provider_name: []const u8, model_name: []const u8, api_key: []const u8, override_url: ?[]const u8) !void {
        if (provider_name.len == 0) {
            try history_mod.addMessageUnlocked(self, "error", "No provider configured. Set one in ~/.crushcode/config.toml or use a profile.");
            return;
        }

        const provider = self.registry.getProvider(provider_name) orelse {
            const text = try std.fmt.allocPrint(self.allocator, "Provider '{s}' is not registered. Run 'crushcode list --providers' to see available providers.", .{provider_name});
            defer self.allocator.free(text);
            try history_mod.addMessageUnlocked(self, "error", text);
            return;
        };

        if (api_key.len == 0 and !provider.config.is_local) {
            try history_mod.addMessageUnlocked(self, "error", "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml");
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
        // Clean up any previous knowledge graph (owned fallback)
        if (self.knowledge_graph) |kg| {
            kg.deinit();
            self.allocator.destroy(kg);
            self.knowledge_graph = null;
        }

        // Prefer pipeline-based context if available
        if (self.pipeline_initialized) {
            if (self.pipeline) |p| {
                p.scanProject("src", 50) catch {};
                p.indexGraphToVault() catch {};

                // Build initial context (no query = overview)
                const ctx = p.buildSmartContext("overview", .normal) catch null;
                if (ctx) |c| {
                    if (self.codebase_context) |old| self.allocator.free(old);
                    self.codebase_context = c;
                }
                self.context_file_count = p.pipeline_stats.files_indexed;
                self.context_total_files = p.pipeline_stats.files_indexed;
                // Pipeline's kg is embedded — no separate knowledge_graph to set
                return;
            }
        }

        // Fallback: raw KnowledgeGraph (original approach)
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
    /// Uses the KnowledgePipeline scoring chain when available,
    /// falls back to the raw KnowledgeGraph otherwise.
    pub fn refreshContextForQuery(self: *Model, query: []const u8) void {
        if (query.len == 0) return;
        if (query.len < 3) return;

        // Prefer pipeline-based scoring
        if (self.pipeline_initialized) {
            if (self.pipeline) |p| {
                const scored_opt = p.buildSmartContext(query, .normal) catch return;
                const scored_ctx = scored_opt orelse return;
                errdefer self.allocator.free(scored_ctx);

                if (scored_ctx.len == 0) {
                    self.allocator.free(scored_ctx);
                    return;
                }

                if (self.codebase_context) |old| self.allocator.free(old);
                self.codebase_context = scored_ctx;

                // Count scored files from graph relevance
                const scores = p.kg.scoreRelevance(self.allocator, query, 50) catch return;
                defer {
                    for (scores) |*s| self.allocator.free(s.node_id);
                    self.allocator.free(scores);
                }
                self.context_scored_files = @intCast(scores.len);

                self.refreshEffectiveSystemPrompt() catch {};
                return;
            }
        }

        // Fallback: use raw knowledge graph
        const kg = self.knowledge_graph orelse return;
        const relevant = kg.toRelevantContext(self.allocator, query, 4000) catch return;
        errdefer self.allocator.free(relevant);
        if (relevant.len == 0) {
            self.allocator.free(relevant);
            return;
        }
        if (self.codebase_context) |old| self.allocator.free(old);
        self.codebase_context = relevant;
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
                \\## Core Principles
                \\- Read files thoroughly before editing to understand full context
                \\- Make minimal, focused changes — never refactor unless explicitly asked
                \\- Follow existing code patterns, naming conventions, and style in the project
                \\- Verify changes by reading the file after editing
                \\
                \\## Editing Guidelines
                \\- Use the edit tool for surgical changes to existing files
                \\- Use write_file only for creating new files
                \\- Preserve existing indentation and formatting exactly
                \\- When replacing code, include enough surrounding context to be unambiguous
                \\- Never suppress errors or warnings — fix the root cause
                \\
                \\## Communication
                \\- Be concise — skip preamble and status updates
                \\- Explain your reasoning only when asked or when the change is non-obvious
                \\- Report what changed, where, and why after edits
                \\- If something seems wrong with the user's approach, say so concisely
                \\
                \\## Safety
                \\- Prefer non-destructive operations first (read before write)
                \\- Never delete files unless explicitly asked
                \\- When running shell commands, show the command before executing
                \\- Back up awareness: warn if editing files with uncommitted changes
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

        // Inject repository map (computed once, cached)
        if (self.cached_repo_map == null) {
            const repo_map_mod = @import("repo_map");
            const map_result = repo_map_mod.generateWithStats(self.allocator, 60) catch null;
            if (map_result) |mr| {
                if (mr.file_count >= 3 and mr.map_text.len > 0) {
                    self.cached_repo_map = mr.map_text;
                } else {
                    mr.deinit(self.allocator);
                    self.cached_repo_map = "";
                }
            }
        }
        if (self.cached_repo_map) |repo_map| {
            if (repo_map.len > 0) {
                rw.print(
                    \\
                    \\## Repository Map
                    \\{s}
                , .{repo_map}) catch {};
            }
        }

        // Load all context files (AGENTS.md, instructions.md, CLAUDE.md, etc.) via unified loader
        if (@hasDecl(project_mod, "loadContextFiles")) {
            const maybe_ctx = project_mod.loadContextFiles(self.allocator) catch null;
            if (maybe_ctx) |ctx_set_val| {
                var ctx_set = ctx_set_val;
                defer ctx_set.deinit(self.allocator);
                if (ctx_set.files.items.len > 0) {
                    rw.print("\n\n<memory>\n", .{}) catch {};
                    for (ctx_set.files.items) |f| {
                        const escaped = project_mod.escapeXml(self.allocator, f.content) catch f.content;
                        defer if (escaped.ptr != f.content.ptr) self.allocator.free(escaped);
                        rw.print("<file path=\"{s}\">\n{s}\n</file>\n", .{ f.path, escaped }) catch {};
                        // Register with file watcher for hot-reload
                        self.context_watcher.addFile(f.path);
                    }
                    rw.print("</memory>", .{}) catch {};
                }
            }
        } else {
            // Fallback: load individual context files separately and wrap in XML
            var has_any = false;
            if (project_mod.loadAgentsMd(self.allocator) catch null) |agents_content| {
                defer self.allocator.free(agents_content);
                if (agents_content.len > 0) {
                    if (!has_any) {
                        rw.print("\n\n<memory>\n", .{}) catch {};
                        has_any = true;
                    }
                    const escaped = project_mod.escapeXml(self.allocator, agents_content) catch agents_content;
                    defer if (escaped.ptr != agents_content.ptr) self.allocator.free(escaped);
                    rw.print("<file path=\"AGENTS.md\">\n{s}\n</file>\n", .{escaped}) catch {};
                }
            }
            if (project_mod.loadInstructionsMd(self.allocator) catch null) |instructions| {
                defer self.allocator.free(instructions);
                if (instructions.len > 0) {
                    if (!has_any) {
                        rw.print("\n\n<memory>\n", .{}) catch {};
                        has_any = true;
                    }
                    const escaped = project_mod.escapeXml(self.allocator, instructions) catch instructions;
                    defer if (escaped.ptr != instructions.ptr) self.allocator.free(escaped);
                    rw.print("<file path=\"instructions.md\">\n{s}\n</file>\n", .{escaped}) catch {};
                }
            }
            if (has_any) {
                rw.print("</memory>", .{}) catch {};
            }
        }

        // Inject user preferences
        if (self.user_model) |*um| {
            if (um.toPromptSection() catch null) |section| {
                defer self.allocator.free(section);
                rw.print(
                    \\
                    \\## User Preferences
                    \\{s}
                , .{section}) catch {};
            }
        }

        // Inject learned feedback
        if (self.feedback) |*fb| {
            if (fb.toPromptSection() catch null) |section| {
                defer self.allocator.free(section);
                rw.print(
                    \\
                    \\## Learned Feedback
                    \\{s}
                , .{section}) catch {};
            }
        }

        // Inject plan mode instruction
        if (self.plan_mode.active) {
            rw.print(
                \\
                \\## Plan Mode Active
                \\You are in PLAN MODE. Instead of executing tools directly, propose what you would do as a structured plan. List the files you would modify and why. Do NOT make changes — only propose them.
            , .{}) catch {};
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
                \\- list_directory(path)
                \\- create_file(path, content)
                \\- move_file(source, destination)
                \\- copy_file(source, destination)
                \\- delete_file(path)
                \\- file_info(path)
                \\- git_status()
                \\- git_diff(target?, file_path?, staged?)
                \\- git_log(count?, oneline?, file_path?)
                \\- search_files(pattern, directory?, max_results?)
                \\- run_tests(filter?)
                \\- create_pr(title, body?, base?, draft?)
                \\- analyze_image(path, prompt?)
                \\- semantic_search(query, top_k?, path?)
            , .{}) catch {};
            // Add project-specific tool usage tips
            if (self.cached_project_info) |project| {
                w.print("\n\n## Tool Usage Tips ({s})\n", .{project.language}) catch {};
                if (std.mem.eql(u8, project.language, "Zig")) {
                    w.print(
                        \\- Use `zig build` to compile, `zig build test` to run tests
                        \\- Use `zig fmt` to check/format code
                        \\- Zig uses `defer` for cleanup, `errdefer` for rollback
                        \\- Error unions with `try`/`catch`, optionals with `orelse`
                    , .{}) catch {};
                } else if (std.mem.eql(u8, project.language, "Rust")) {
                    w.print(
                        \\- Use `cargo build` to compile, `cargo test` to run tests
                        \\- Use `cargo clippy` for linting, `cargo fmt` for formatting
                        \\- Prefer `Result<T,E>` over panics for error handling
                    , .{}) catch {};
                } else if (std.mem.eql(u8, project.language, "Go")) {
                    w.print(
                        \\- Use `go build` to compile, `go test ./...` to run all tests
                        \\- Use `go vet` for static analysis, `gofmt` for formatting
                        \\- Use `defer` for cleanup, multiple return values for errors
                    , .{}) catch {};
                } else if (std.mem.eql(u8, project.language, "JavaScript/TypeScript")) {
                    w.print(
                        \\- Use `npm run build` to compile, `npm test` to run tests
                        \\- Check package.json for available scripts
                        \\- Use `npx` for one-off tool execution
                    , .{}) catch {};
                } else if (std.mem.eql(u8, project.language, "Python")) {
                    w.print(
                        \\- Use `pytest` to run tests, `pip install -e .` for development
                        \\- Follow PEP 8 style, use type hints
                        \\- Use virtual environments (venv) for isolation
                    , .{}) catch {};
                } else if (std.mem.eql(u8, project.language, "C/C++")) {
                    w.print(
                        \\- Use cmake/make for building, ctest for testing
                        \\- Check CMakeLists.txt or Makefile for available targets
                    , .{}) catch {};
                }
            }
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
                    // Count MCP tools (schemas beyond the 12 builtins)
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
        streaming.reapWorkerIfDone(self);

        switch (event) {
            .init => {
                try ctx.setTitle("Crushcode TUI Chat");
                // NOTE: Do NOT requestFocus — the Model (root widget) stays as
                // the permanent focused widget. Key events are forwarded manually
                // to input/palette_input in the key_press handler below.
                ctx.redraw = true;
                
                // Register tick timer for 30fps rendering during streaming
                try ctx.cmds.append(self.allocator, .{ .tick = .{ .deadline_ms = 33 + @as(i64, @intCast(std.time.milliTimestamp())), .widget = self.widget() } });
            },
            .tick => {
                // Force redraw during streaming to show AI response
                ctx.redraw = true;
                // Re-register tick timer for continuous rendering
                try ctx.cmds.append(self.allocator, .{ .tick = .{ .deadline_ms = 33 + @as(i64, @intCast(std.time.milliTimestamp())), .widget = self.widget() } });
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

                // Diff preview mode: intercept all keys
                if (self.diff_preview_active) {
                    _ = streaming.handleDiffPreviewKey(self, key);
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (self.pending_permission != null) {
                    if (key.matches('y', .{}) or key.matches('Y', .{})) {
                        permissions_mod.resolvePendingPermission(self, .yes);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('n', .{}) or key.matches('N', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        permissions_mod.resolvePendingPermission(self, .no);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches('a', .{}) or key.matches('A', .{})) {
                        permissions_mod.resolvePendingPermission(self, .always);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    ctx.consumeEvent();
                    return;
                }

                if (self.show_session_list) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        try session_mgmt.closeSessionList(self, ctx);
                    } else if (key.matches(vaxis.Key.up, .{})) {
                        session_mgmt.moveSessionListSelection(self,-1);
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        session_mgmt.moveSessionListSelection(self,1);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try self.executeSessionSelection(ctx);
                    }
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    permissions_mod.resolvePendingPermission(self, .no);
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
                        try model_palette.closePalette(self, ctx);
                    } else {
                        try model_palette.openPalette(self, ctx);
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

                if (key.matches('\\', .{ .ctrl = true })) {
                    self.right_pane_visible = !self.right_pane_visible;
                    ctx.consumeEvent();
                    ctx.redraw = true;
                    return;
                }

                if (key.matches('r', .{ .ctrl = true })) {
                    // Ctrl+R: reverse-i-search through input history
                    if (self.isearch_active) {
                        // Already searching — find next match
                        isearchNext(self);
                    } else if (self.setup_phase == 0 and !self.show_palette and !self.scroll_mode) {
                        startISearch(self);
                    } else {
                        // In scroll mode or palette — fall back to refresh
                        self.refreshCwdListing();
                    }
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

                // Input history: Up/Down arrows when NOT in scroll mode
                if (!self.scroll_mode and self.setup_phase == 0 and !self.show_palette and !self.isearch_active) {
                    if (key.matches(vaxis.Key.up, .{})) {
                        inputHistoryUp(self);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        inputHistoryDown(self);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                }

                // Reverse-i-search: handle printable characters, backspace, escape, enter
                if (self.isearch_active) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        // Cancel isearch, restore draft
                        stopISearch(self);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches(vaxis.Key.enter, .{})) {
                        // Accept match and submit (or just accept)
                        self.isearch_active = false;
                        self.isearch_query.clearRetainingCapacity();
                        self.isearch_match_index = null;
                        // Stop isearch — user can press Enter again to submit
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.isearch_query.items.len > 0) {
                            _ = self.isearch_query.pop();
                            updateISearch(self);
                        } else {
                            stopISearch(self);
                        }
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
                    // Printable character: append to search query
                    if (key.text) |text| {
                        if (text.len > 0) {
                            self.isearch_query.appendSlice(text) catch {};
                            updateISearch(self);
                            ctx.consumeEvent();
                            ctx.redraw = true;
                            return;
                        }
                    }
                    // Any other key in isearch mode: consume and ignore
                    ctx.consumeEvent();
                    return;
                }

                // Escape exits scroll mode, isearch, or help overlay (when not in palette/session list)
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.isearch_active) {
                        stopISearch(self);
                        ctx.consumeEvent();
                        ctx.redraw = true;
                        return;
                    }
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
                        try navigation.selectMessageAtCursor(self, ctx);
                        return;
                    }
                    // y — yank (copy with role label) to clipboard
                    if (key.matches('y', .{})) {
                        try navigation.copySelectedMessage(self, ctx, false);
                        return;
                    }
                    // c — copy content only to clipboard
                    if (key.matches('c', .{})) {
                        try navigation.copySelectedMessage(self, ctx, true);
                        return;
                    }
                    // e — edit: copy message to input field
                    if (key.matches('e', .{})) {
                        try navigation.editSelectedMessage(self, ctx);
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
                        try model_palette.closePalette(self, ctx);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.up, .{})) {
                        model_palette.movePaletteSelection(self, -1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.down, .{})) {
                        model_palette.movePaletteSelection(self, 1);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.enter, .{})) {
                        // Execute palette selection
                        try self.executePaletteSelection(ctx);
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.tab, .{})) {
                        // Tab completion — fill input with best matching command
                        const filter_text = self.palette_filter;
                        var filtered_indices: [widget_palette.max_palette_items]usize = undefined;
                        const count = widget_palette.collectFilteredCommandIndices(self.palette_items, filter_text, filtered_indices[0..]);
                        if (count > 0) {
                            const best = self.palette_items[filtered_indices[0]];
                            try model_palette.setPaletteFilter(self, best.label);
                            self.palette_selected = 0;
                        }
                        ctx.consumeEvent();
                        ctx.redraw = true;
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
            .mouse => |mouse| {
                // SplitView: handle pane divider drags
                if (mouse.button == .left) {
                    const mouse_col: u16 = @intCast(@max(mouse.col, @as(i16, 0)));

                    // Compute current layout for divider hit-testing
                    const sv: bool = self.sidebar_visible and self.last_screen_width >= 80;
                    const cur_sidebar_w: u16 = if (sv) @min(self.sidebar_drag_width, @max(@as(u16, 20), @as(u16, @intCast(self.last_screen_width / 4)))) else 0;
                    const cur_right_w: u16 = if (self.right_pane_visible and self.right_pane_content != null) self.right_pane_width else 0;
                    const cur_main_w: u16 = self.last_screen_width -| cur_sidebar_w -| cur_right_w;

                    if (mouse.type == .press) {
                        // Check if click is on sidebar divider (between main and sidebar)
                        if (sv and mouse_col >= cur_main_w -| 1 and mouse_col <= cur_main_w + 1) {
                            self.dragging_sidebar_divider = true;
                            self.drag_start_col = mouse_col;
                            self.drag_start_width = cur_sidebar_w;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // Check if click is on right pane divider (between sidebar and right pane)
                        if (cur_right_w > 0) {
                            const right_edge: u16 = self.last_screen_width -| cur_right_w;
                            if (mouse_col >= right_edge -| 1 and mouse_col <= right_edge + 1) {
                                self.dragging_right_pane_divider = true;
                                self.drag_start_col = mouse_col;
                                self.drag_start_width = cur_right_w;
                                ctx.consumeAndRedraw();
                                return;
                            }
                        }
                    }

                    if (mouse.type == .drag or mouse.type == .motion) {
                        // Dragging sidebar divider
                        if (self.dragging_sidebar_divider) {
                            const delta: i16 = @as(i16, @intCast(mouse_col)) - @as(i16, @intCast(self.drag_start_col));
                            const new_w: u16 = @intCast(std.math.clamp(@as(i16, @intCast(self.drag_start_width)) + delta, 15, @as(i16, @intCast(self.last_screen_width / 2))));
                            self.sidebar_drag_width = new_w;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // Dragging right pane divider
                        if (self.dragging_right_pane_divider) {
                            const delta: i16 = @as(i16, @intCast(self.drag_start_col)) - @as(i16, @intCast(mouse_col));
                            const new_w: u16 = @intCast(std.math.clamp(@as(i16, @intCast(self.drag_start_width)) + delta, 30, @as(i16, @intCast(self.last_screen_width / 2))));
                            self.right_pane_width = new_w;
                            ctx.consumeAndRedraw();
                            return;
                        }
                    }
                }

                // Release: stop any active drag
                if (mouse.type == .release) {
                    if (self.dragging_sidebar_divider or self.dragging_right_pane_divider) {
                        self.dragging_sidebar_divider = false;
                        self.dragging_right_pane_divider = false;
                        ctx.consumeAndRedraw();
                        return;
                    }
                }

                // Left click in message area: scan recent messages for file paths
                if (mouse.button == .left and mouse.type == .press) {
                    // Skip when overlays are active
                    if (self.show_palette or self.diff_preview_active or
                        self.show_session_list or self.pending_permission != null or
                        self.show_help or self.setup_phase != 0)
                    {
                        return;
                    }

                    if (self.previewMostRecentFilePath()) {
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
            },
            else => {},
        }

        ctx.redraw = true;
    }

    fn draw(self: *Model, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        streaming.reapWorkerIfDone(self);

        // Tick spinner each frame for animation
        if (self.spinner) |*spinner| {
            spinner.tick();
        }
        // Tick toast stack each frame for auto-expiration
        self.toast_stack.tick();

        // Poll context file watcher — reload system prompt if files changed
        {
            const changed = self.context_watcher.poll();
            if (changed.len > 0) {
                // Context files changed — rebuild system prompt on next request
                self.system_prompt_dirty = true;
            }
        }
        // Rebuild system prompt if context files changed on disk
        if (self.system_prompt_dirty) {
            self.system_prompt_dirty = false;
            self.refreshEffectiveSystemPrompt() catch {};
        }

        self.lock.lock();
        defer self.lock.unlock();

        // Tick typewriter each frame for character reveal (must be under lock —
        // worker thread calls tw.updateText() under the same lock)
        if (self.typewriter) |*tw| {
            tw.tick();
        }
        // Clean up typewriter once animation finishes after streaming ends
        if (self.typewriter != null and self.request_done and self.typewriter.?.complete) {
            self.typewriter = null;
        }

        const max = ctx.max.size();
        // Store screen dimensions for mouse handler access
        self.last_screen_width = @intCast(max.width);
        self.last_screen_height = @intCast(max.height);
        // Responsive sidebar: use user-adjusted width (via drag), clamped to 15..width/2
        // Auto-hide when terminal is too narrow (< 80 chars)
        const sidebar_visible_effective = self.sidebar_visible and max.width >= 80;
        const sidebar_width: u16 = if (sidebar_visible_effective)
            @min(self.sidebar_drag_width, @max(@as(u16, 15), @as(u16, @intCast(max.width / 2))))
        else
            0;
        const right_pane_w: u16 = if (self.right_pane_visible and self.right_pane_content != null) self.right_pane_width else 0;
        const main_width: u16 = max.width -| if (sidebar_visible_effective) sidebar_width else 0 -| right_pane_w;
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

        const ctx_label = if (self.context_scored_files > 0)
            try std.fmt.allocPrint(ctx.arena, "ctx: {d}/{d} files (scored)", .{ self.context_scored_files, self.context_total_files })
        else
            try std.fmt.allocPrint(ctx.arena, "ctx: {d} files indexed", .{self.context_file_count});

        const full_title = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | setup", .{app_version})
        else
            try std.fmt.allocPrint(ctx.arena, "Crushcode v{s} | {s}/{s} | thinking:{s} | {s} | usage:{d}%", .{
                app_version,
                self.provider_name,
                self.model_name,
                if (self.thinking) "on" else "off",
                ctx_label,
                token_tracking_mod.contextPercent(self),
            });

        const header = HeaderWidget{ .title = full_title, .theme = self.current_theme, .context_pct = token_tracking_mod.contextPercent(self), .file_count = self.context_file_count, .scored_count = self.context_scored_files, .total_count = self.context_total_files };
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
                // Precompute visible message indices (skipping duplicate tool_call_id results)
                const total_msgs = self.messages.items.len;
                var visible_indices = std.ArrayList(usize).empty;
                defer visible_indices.deinit(ctx.arena);
                try visible_indices.ensureTotalCapacity(ctx.arena, @max(total_msgs, 1));
                for (self.messages.items, 0..) |message, idx| {
                    if (message.tool_call_id != null and findToolCallBefore(self.messages.items, idx, message.tool_call_id.?) != null) {
                        continue;
                    }
                    try visible_indices.append(ctx.arena, idx);
                }
                const vis_count = visible_indices.items.len;
                // Widget layout: each visible message = 1 MessageWidget. Between messages,
                // 2 more widgets (Gap + Separator). So total = vis_count + (vis_count - 1) * 2
                // = vis_count * 3 - 2 (for vis_count >= 1). This preserves the cursor mapping
                // used by scrollCursorToMessageIndex (cursor % 3 == 0 → message at cursor / 3).
                const total_widgets: usize = if (vis_count == 0) 0 else vis_count * 3 - 2;

                const builder_data = try ctx.arena.create(MessageListBuilderData);
                builder_data.* = .{
                    .model = self,
                    .visible_indices = visible_indices.items,
                    .theme = self.current_theme,
                    .arena = ctx.arena,
                };

                self.scroll_view.children = .{ .builder = .{
                    .userdata = builder_data,
                    .buildFn = messageListBuildFn,
                } };

                if (self.auto_scroll and total_widgets > 0) {
                    self.scroll_view.item_count = @intCast(total_widgets);
                    self.scroll_view.cursor = @intCast(total_widgets - 1);
                    self.scroll_view.ensureScroll();
                } else if (total_widgets > 0) {
                    self.scroll_view.item_count = @intCast(total_widgets);
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
        // Mode indicator: show active mode tags at the end of the status bar
        const mode_tag: []const u8 = blk: {
            if (self.crush_active) break :blk " [CRUSH]";
            if (self.delegate_mode) break :blk " [DELEGATE]";
            if (self.scroll_mode) break :blk " [SCROLL]";
            break :blk "";
        };
        // Provider/model prefix for the status bar
        const provider_prefix = try std.fmt.allocPrint(ctx.arena, "{s}/{s} │ ", .{ self.provider_name, self.model_name });
        const status_text_inner = if (self.setup_phase != 0)
            try std.fmt.allocPrint(ctx.arena, "Setup {d}/4 | {s}", .{
                @min(self.setup_phase, @as(u8, 4)),
                if (self.setup_phase == 1) "Choose a provider" else if (self.setup_phase == 2) "Enter your API key" else if (self.setup_phase == 3) "Choose a default model" else "Press Enter to continue",
            })
        else if (self.status_message.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s}{s} | Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s{s}{s}", .{
                provider_prefix,
                self.status_message,
                self.total_input_tokens,
                self.total_output_tokens,
                token_tracking_mod.estimatedCostUsd(self),
                self.request_count,
                session_time_mod.sessionMinutes(self),
                session_time_mod.sessionSecondsPart(self),
                scroll_indicator,
                mode_tag,
            })
        else
            try std.fmt.allocPrint(ctx.arena, "{s}Tokens: {d} in / {d} out | Cost: ${d:.4} | Turn {d} | {d}m{d}s{s}{s}", .{
                provider_prefix,
                self.total_input_tokens,
                self.total_output_tokens,
                token_tracking_mod.estimatedCostUsd(self),
                self.request_count,
                session_time_mod.sessionMinutes(self),
                session_time_mod.sessionSecondsPart(self),
                scroll_indicator,
                mode_tag,
            });
        // Override status bar with isearch prompt when active
        const status_text = if (self.isearch_active) blk: {
            const query = self.isearch_query.items;
            const match_label: []const u8 = if (self.isearch_match_index != null) "" else " (no match)";
            const prompt = try std.fmt.allocPrint(ctx.arena, "reverse-i-search{s}: {s}_", .{ match_label, query });
            break :blk prompt;
        } else if (status_text_inner.len > main_width) blk: {
            const trunc_len = if (main_width > 1) main_width - 1 else 0;
            const truncated = try std.fmt.allocPrint(ctx.arena, "{s}…", .{if (status_text_inner.len > trunc_len) status_text_inner[0..trunc_len] else status_text_inner});
            break :blk truncated;
        } else status_text_inner;
        const status_widget = vxfw.Text{
            .text = if (status_text.len > main_width) blk: {
                const trunc_len = if (main_width > 1) main_width - 1 else 0;
                break :blk try std.fmt.allocPrint(ctx.arena, "{s}…", .{if (status_text.len > trunc_len) status_text[0..trunc_len] else status_text});
            } else status_text,
            .style = .{ .fg = self.current_theme.status_fg, .bg = self.current_theme.status_bg },
            .softwrap = false,
            .width_basis = .parent,
        };
        const status_surface = try status_widget.draw(ctx.withConstraints(
            .{ .width = main_width, .height = status_height },
            .{ .width = main_width, .height = status_height },
        ));

        const ml_input_widget = MultiLineInputWidget{ .prompt = input_handling.currentInputPrompt(self), .state = &self.input, .theme = self.current_theme };
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

        if (sidebar_visible_effective) {
            // Refresh LSP diagnostics before displaying (non-blocking drain)
            self.lsp_manager.refreshDiagnostics();
            const mcp_status = mcp_status_mod.getMCPServerStatus(self, ctx.arena);
            const diag = self.lsp_manager.getDiagnostics();
            var diag_errors: u32 = 0;
            var diag_warnings: u32 = 0;
            for (diag) |d| {
                diag_errors += d.errors;
                diag_warnings += d.warnings;
            }
            const sidebar_context = SidebarContext{
                .recent_files = self.recent_files.items,
                .cwd_files = self.cwd_files.items,
                .request_count = self.request_count,
                .total_input_tokens = self.total_input_tokens,
                .total_output_tokens = self.total_output_tokens,
                .turn_token_history = self.turn_token_history.items,
                .estimated_cost_usd = token_tracking_mod.estimatedCostUsd(self),
                .session_minutes = @intCast(session_time_mod.sessionMinutes(self)),
                .session_seconds_part = @intCast(session_time_mod.sessionSecondsPart(self)),
                .workers = self.workers.items,
                .theme_name = self.current_theme.name,
                .current_theme = self.current_theme,
                .mcp_servers = mcp_status,
                .diag_error_count = diag_errors,
                .diag_warning_count = diag_warnings,
            };
            const sidebar = SidebarWidget{ .context = &sidebar_context, .width = sidebar_width };
            const sidebar_height: u16 = header_height + safe_body_height;
            const sidebar_surface = try sidebar.draw(ctx.withConstraints(
                .{ .width = sidebar_width, .height = sidebar_height },
                .{ .width = sidebar_width, .height = sidebar_height },
            ));
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(main_width) }, .surface = sidebar_surface });

            // SplitView: draw sidebar divider column (visual separator + drag handle)
            const div_style: vaxis.Style = if (self.dragging_sidebar_divider)
                .{ .fg = self.current_theme.accent, .bold = true }
            else
                .{ .fg = self.current_theme.border };
            const div_col: u16 = if (main_width > 0) main_width -| 1 else 0;
            if (main_width > 1) {
                const div_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 1, .height = sidebar_height });
                var row_i: u16 = 0;
                while (row_i < sidebar_height) : (row_i += 1) {
                    div_surface.writeCell(0, row_i, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = div_style });
                }
                try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(div_col) }, .surface = div_surface });
            }
        }

        // Right pane — file preview
        if (self.right_pane_visible and self.right_pane_content != null) {
            const content = self.right_pane_content.?;
            const title = self.right_pane_title orelse "Preview";
            const pane_height: u16 = header_height + safe_body_height;

            // Build right pane surface with title bar + content
            var pane_segs = std.ArrayList(vaxis.Segment).empty;
            defer pane_segs.deinit(ctx.arena);

            // Title bar
            const title_bar = try std.fmt.allocPrint(ctx.arena, " {s} ", .{title});
            try pane_segs.append(ctx.arena, .{
                .text = title_bar,
                .style = .{ .fg = self.current_theme.accent, .bold = true },
            });
            // Separator
            try pane_segs.append(ctx.arena, .{
                .text = "\n",
                .style = .{ .fg = self.current_theme.border },
            });

            // Detect language from file extension
            const lang = markdown.parseCodeLanguage(title);

            // Content with line numbers and syntax highlighting
            var line_num: usize = 1;
            var line_iter = std.mem.splitScalar(u8, content, '\n');
            var content_lines = std.ArrayList(vaxis.Segment).empty;
            defer content_lines.deinit(ctx.arena);

            const max_lines: usize = if (pane_height > 2) @intCast(pane_height -| 2) else 0;
            const theme = self.current_theme;
            while (line_iter.next()) |line| : (line_num += 1) {
                if (line_num > max_lines) break;
                
                // Line number prefix
                const prefix = try std.fmt.allocPrint(ctx.arena, "{d:>4}│ ", .{line_num});
                try content_lines.append(ctx.arena, .{
                    .text = prefix,
                    .style = .{ .fg = theme.dimmed },
                });
                
                // Syntax-highlighted code line
                try markdown.appendHighlightedCodeLine(
                    &content_lines,
                    ctx.arena,
                    line,
                    lang,
                    .{ .fg = theme.md_code_fg },         // default code style
                    .{ .fg = theme.md_keyword_fg },       // keywords
                    .{ .fg = theme.md_string_fg },        // strings
                    .{ .fg = theme.md_comment_fg },       // comments
                    .{ .fg = theme.md_number_fg },        // numbers
                    .{ .fg = theme.md_type_fg },          // types
                    .{ .fg = theme.md_function_fg },       // functions
                    .{ .fg = theme.md_operator_fg },      // operators
                );
                
                // Newline after each line
                try content_lines.append(ctx.arena, .{
                    .text = "\n",
                    .style = .{ .fg = theme.md_code_fg },
                });
            }

            // Combine title + content into rich text
            var all_segs = std.ArrayList(vaxis.Segment).empty;
            defer all_segs.deinit(ctx.arena);
            try all_segs.appendSlice(ctx.arena, pane_segs.items);
            try all_segs.appendSlice(ctx.arena, content_lines.items);

            const rich = vxfw.RichText{
                .text = all_segs.items,
                .softwrap = false,
                .width_basis = .longest_line,
            };
            const right_surface = try rich.draw(ctx.withConstraints(
                .{ .width = right_pane_w, .height = pane_height },
                .{ .width = right_pane_w, .height = pane_height },
            ));
            const right_col: u16 = max.width -| right_pane_w;
            try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(right_col) }, .surface = right_surface });

            // SplitView: draw right pane divider column (visual separator + drag handle)
            if (right_col > 1) {
                const rp_div_style: vaxis.Style = if (self.dragging_right_pane_divider)
                    .{ .fg = self.current_theme.accent, .bold = true }
                else
                    .{ .fg = self.current_theme.border };
                const rp_div_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 1, .height = pane_height });
                var rp_row: u16 = 0;
                while (rp_row < pane_height) : (rp_row += 1) {
                    rp_div_surface.writeCell(0, rp_row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = rp_div_style });
                }
                try child_list.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(right_col -| 1) }, .surface = rp_div_surface });
            }
        }

        // Check if any overlay is active for backdrop rendering
         // Use overlay_manager for centralized check, falling back to
         // pending_permission / resume_prompt which are data-driven overlays
         const any_overlay_active = self.overlay_manager.anyActive() or
             self.pending_permission != null or
             self.resume_prompt_session != null;

        // Dimmed backdrop behind overlays
        if (any_overlay_active) {
            const backdrop = try vxfw.Surface.init(
                ctx.arena,
                self.widget(),
                .{ .width = max.width, .height = max.height },
            );
            const backdrop_style: vaxis.Style = .{
                .bg = self.current_theme.header_bg,
                .dim = true,
            };
            @memset(backdrop.buffer, .{ .style = backdrop_style });
            try child_list.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = backdrop,
            });
        }

        if (self.show_palette) {
            const palette = CommandPaletteWidget{
                .field = &self.palette_input,
                .items = self.palette_items,
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

        // Diff preview overlay
        if (self.diff_preview_active and self.diff_preview_hunks.len > 0) {
            // Cast widget_diff_preview.HunkDecision slice is already the correct type
            // (both are enum { pending, applied, rejected } — ABI-compatible)
            const widget_decisions: []widget_diff_preview.HunkDecision = @as(
                [*]widget_diff_preview.HunkDecision,
                @ptrCast(self.diff_preview_decisions.ptr),
            )[0..self.diff_preview_decisions.len];
            var dp_ctx = DiffPreviewContext{
                .hunks = self.diff_preview_hunks,
                .file_path = self.diff_preview_file_path,
                .tool_name = self.diff_preview_tool_name,
                .theme = self.current_theme,
                .current_hunk = self.diff_preview_current,
                .decisions = widget_decisions,
                .completed = false,
            };
            const dp_widget = DiffPreviewWidget{ .context = &dp_ctx };
            const dp_surface = try dp_widget.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height },
            ));
            try child_list.append(ctx.arena, .{
                .origin = .{
                    .row = @intCast((max.height -| dp_surface.size.height) / 2),
                    .col = @intCast((max.width -| dp_surface.size.width) / 2),
                },
                .surface = dp_surface,
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
                "Ctrl+\\    Toggle file preview",
"Ctrl+R    Reverse-i-search input history",
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

    fn handleSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        streaming.reapWorkerIfDone(self);

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
            permissions_mod.resolvePendingPermission(self, .no);
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
            try history_mod.addMessageUnlocked(self, "error", "Still waiting for the current response. Please wait for it to finish.");
            ctx.redraw = true;
            return;
        }

        if (self.client == null) {
            const text = if (self.api_key.len == 0)
                "No API key configured. Run crushcode setup or edit ~/.crushcode/config.toml"
            else
                "Chat client is not ready. Fix the configuration shown above and restart the TUI.";
            try history_mod.addMessageUnlocked(self, "error", text);
            ctx.redraw = true;
            return;
        }

        try history_mod.addMessageUnlocked(self, "user", trimmed);
        try history_mod.appendHistoryMessageUnlocked(self, "user", trimmed);
        // Save to input history for Up/Down navigation and reverse-i-search
        saveInputHistory(self, trimmed);
        // Persist to cross-session memory
        self.memory.addMessage("user", trimmed) catch {};
        self.memory.save() catch {};
        try history_mod.addMessageUnlocked(self, "assistant", "Thinking...");
        self.assistant_stream_index = self.messages.items.len - 1;
        var spinner = widget_spinner.AnimatedSpinner.init(self.current_theme);
        spinner.setContextPhrase("Thinking...");
        self.spinner = spinner;
        self.typewriter = widget_typewriter.TypewriterState.init(self.current_theme);
        self.request_active = true;
        self.request_done = false;
        self.awaiting_first_token = true;
        try session_mgmt.saveSessionSnapshotUnlocked(self);

        input_handling.resetInputField(self);
        self.worker = try std.Thread.spawn(.{}, streaming.requestThreadMain, .{self});
        ctx.redraw = true;
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

    fn handleSetupSubmit(self: *Model, value: []const u8, ctx: *vxfw.EventContext) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        switch (self.setup_phase) {
            1 => {
                try input_handling.replaceOwnedString(self,&self.provider_name, setup_provider_data[self.setup_provider_index]);
                self.clearSetupFeedback();
                self.setup_phase = 2;
                input_handling.resetInputField(self);
            },
            2 => {
                if (trimmed.len == 0 and !setupProviderAllowsEmptyKey(self.provider_name)) {
                    try self.setSetupFeedback("API key cannot be empty for this provider.", true);
                    ctx.redraw = true;
                    return;
                }
                try input_handling.replaceOwnedString(self,&self.api_key, trimmed);
                self.clearSetupFeedback();
                self.setup_phase = 3;
                input_handling.resetInputField(self);
            },
            3 => {
                const resolved_model = if (trimmed.len > 0) trimmed else setupDefaultModel(self.provider_name);
                try input_handling.replaceOwnedString(self,&self.model_name, resolved_model);
                try self.saveSetupConfig();
                model_fallback.resetFallbackProviders(self);
                try model_fallback.loadFallbackProviders(self);
                try self.initializeClient();
                self.clearSetupFeedback();
                self.setup_phase = 4;
                input_handling.resetInputField(self);
            },
            4 => {
                self.clearSetupFeedback();
                self.setup_phase = 0;
                try history_mod.addMessageUnlocked(self, "assistant", "TUI chat ready. Type a message and press Enter.");
                input_handling.resetInputField(self);
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

    /// Build dynamic palette items: commands + models from registry + files from cwd_files.
    /// Called each time the palette opens so the list is always fresh.
    pub fn buildPaletteItems(self: *Model) !void {
        var items = std.ArrayList(PaletteItem).empty;
        errdefer {
            // On error, free only dynamically allocated items (skip static commands)
            for (items.items) |*it| {
                if (it.category != .command) {
                    self.allocator.free(it.label);
                    self.allocator.free(it.description);
                    self.allocator.free(it.action);
                }
            }
            items.deinit(self.allocator);
        }

        // 1. Add static commands from palette_command_data (comptime strings, no alloc)
        for (palette_command_data) |cmd| {
            try items.append(self.allocator, cmd);
        }

        // 2. Add models from provider registry (dynamically allocated)
        var provider_iter = self.registry.providers.iterator();
        while (provider_iter.next()) |entry| {
            const provider_name = entry.key_ptr.*;
            const provider = entry.value_ptr.*;
            for (provider.config.models) |model_name| {
                const label = try std.fmt.allocPrint(self.allocator, "{s}", .{model_name});
                const description = try std.fmt.allocPrint(self.allocator, "{s}", .{provider_name});
                const action = try std.fmt.allocPrint(self.allocator, "/model {s} {s}", .{ provider_name, model_name });
                try items.append(self.allocator, .{
                    .category = .model,
                    .label = label,
                    .description = description,
                    .shortcut = "",
                    .icon = "\xF0\x9F\xA4\x96",
                    .action = action,
                });
            }
        }

        // 3. Add files from cwd_files (dynamically allocated)
        for (self.cwd_files.items) |file_entry| {
            // Strip 📁 prefix (4 bytes UTF-8 + space) and "  " prefix (2 bytes for files)
            const path = if (std.mem.startsWith(u8, file_entry, "\xF0\x9F\x93\x81 ")) blk: {
                break :blk file_entry[5..];
            } else if (std.mem.startsWith(u8, file_entry, "  ")) blk: {
                break :blk file_entry[2..];
            } else blk: {
                break :blk file_entry;
            };
            const label = try std.fmt.allocPrint(self.allocator, "{s}", .{path});
            const action = try std.fmt.allocPrint(self.allocator, "/preview {s}", .{path});
            try items.append(self.allocator, .{
                .category = .file,
                .label = label,
                .description = "Open in preview",
                .shortcut = "",
                .icon = "\xF0\x9F\x93\x84",
                .action = action,
            });
        }

        // Free previous dynamic items if they were allocated (not the static default)
        if (self.palette_items.ptr != @as([*]const PaletteItem, @ptrCast(&palette_command_data))) {
            for (self.palette_items) |*it| {
                if (it.category != .command) {
                    self.allocator.free(it.label);
                    self.allocator.free(it.description);
                    self.allocator.free(it.action);
                }
            }
            self.allocator.free(self.palette_items);
        }

        self.palette_items = try items.toOwnedSlice(self.allocator);
    }

    fn executePaletteSelection(self: *Model, ctx: *vxfw.EventContext) !void {
        var filtered_indices: [widget_palette.max_palette_items]usize = undefined;
        const filtered_count = collectFilteredCommandIndices(self.palette_items, self.palette_filter, filtered_indices[0..]);
        if (filtered_count == 0) {
            return;
        }

        const item = self.palette_items[filtered_indices[self.palette_selected]];
        try model_palette.closePalette(self, ctx);
        try self.executePaletteCommand(item.action, ctx);
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
                try history_mod.addMessageUnlocked(self, "error", "Cannot clear the chat while a response is still streaming.");
            } else {
                try session_mgmt.saveSessionSnapshotUnlocked(self);
                history_mod.clearMessagesUnlocked(self);
                history_mod.clearHistoryUnlocked(self);
                session_mgmt.clearRecentFilesUnlocked(self);
                self.total_input_tokens = 0;
                self.total_output_tokens = 0;
                self.request_count = 0;
                self.assistant_stream_index = null;
                self.awaiting_first_token = false;
                try session_mgmt.beginNewSessionUnlocked(self);
            }
        } else if (std.mem.eql(u8, name, "/sessions") or std.mem.eql(u8, name, "/ls")) {
            try session_mgmt.openSessionList(self, ctx);
            return;
        } else if (std.mem.startsWith(u8, name, "/resume")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /resume <id>");
            } else {
                try self.resumeSessionByIdUnlocked(session_id);
            }
        } else if (std.mem.startsWith(u8, name, "/delete")) {
            const session_id = std.mem.trim(u8, name[7..], " \t\r\n");
            if (session_id.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /delete <id>");
            } else {
                try session_mgmt.deleteSessionByIdUnlocked(self, session_id);
                const text = try std.fmt.allocPrint(self.allocator, "Deleted session {s}", .{session_id});
                defer self.allocator.free(text);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.startsWith(u8, name, "/plan")) {
            const plan_sub = std.mem.trim(u8, name[5..], " ");
            if (plan_sub.len == 0 or std.mem.eql(u8, plan_sub, "status")) {
                // /plan or /plan status — show current plan mode status
                const summary = self.plan_mode.statusSummary() catch "Plan mode: error";
                defer self.allocator.free(summary);
                try history_mod.addMessageUnlocked(self, "assistant", summary);
            } else if (std.mem.eql(u8, plan_sub, "on")) {
                self.plan_mode.enter();
                try history_mod.addMessageUnlocked(self, "assistant", "Plan mode enabled. AI will propose changes before executing.");
                self.refreshEffectiveSystemPrompt() catch {};
            } else if (std.mem.eql(u8, plan_sub, "off")) {
                self.plan_mode.exit();
                try history_mod.addMessageUnlocked(self, "assistant", "Plan mode disabled. Changes will be executed directly.");
                self.refreshEffectiveSystemPrompt() catch {};
            } else if (std.mem.eql(u8, plan_sub, "approve")) {
                if (self.plan_mode.current_plan) |*plan| {
                    plan.approveAll();
                    const formatted = plan.format() catch "Plan approved.";
                    defer self.allocator.free(formatted);
                    try history_mod.addMessageUnlocked(self, "assistant", formatted);
                    // Execute approved steps
                    const approved = plan.getApprovedSteps() catch &.{};
                    if (approved.len > 0) {
                        self.allocator.free(approved);
                        // Build tool calls from approved steps and execute
                        var tc_list = array_list_compat.ArrayList(core.client.ToolCallInfo).init(self.allocator);
                        defer tc_list.deinit();
                        for (plan.steps.items) |step| {
                            if (step.approved) {
                                try tc_list.append(.{
                                    .id = "",
                                    .name = step.tool_name,
                                    .arguments = step.tool_args,
                                });
                            }
                        }
                        self.plan_mode.exit();
                        self.refreshEffectiveSystemPrompt() catch {};
                        // Execute the tool calls outside plan mode
                        try streaming.executeToolCalls(self, tc_list.items);
                    } else {
                        self.allocator.free(approved);
                    }
                    // Clear the plan after execution
                    self.plan_mode.cancelPlan();
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No plan to approve. Ask the AI to propose changes first.");
                }
            } else if (std.mem.eql(u8, plan_sub, "cancel")) {
                self.plan_mode.cancelPlan();
                self.plan_mode.exit();
                try history_mod.addMessageUnlocked(self, "assistant", "Plan cancelled and discarded.");
                self.refreshEffectiveSystemPrompt() catch {};
            } else {
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Plan Mode Commands:
                    \\  /plan         — Show plan mode status
                    \\  /plan on      — Enable plan mode (AI proposes instead of executing)
                    \\  /plan off     — Disable plan mode
                    \\  /plan approve — Approve and execute the current plan
                    \\  /plan cancel  — Cancel and discard the current plan
                );
            }
        } else if (std.mem.eql(u8, name, "/cognition")) {
            if (!self.pipeline_initialized) {
                try history_mod.addMessageUnlocked(self, "assistant", "Pipeline not initialized.");
            } else if (self.pipeline) |p| {
                const s = p.stats();
                const text = try std.fmt.allocPrint(self.allocator,
                    \\Cognition Pipeline:
                    \\  Files indexed:   {d}
                    \\  Graph nodes:     {d}
                    \\  Graph edges:     {d}
                    \\  Communities:     {d}
                    \\  Vault nodes:     {d}
                    \\  Memory entries:  {d}
                    \\  Insights:        {d}
                    \\  Source tokens:   {d}
                , .{ s.files_indexed, s.graph_nodes, s.graph_edges, s.communities, s.vault_nodes, s.memory_entries, s.insights_count, s.total_source_tokens });
                defer self.allocator.free(text);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/user")) {
            if (self.user_model) |*um| {
                const prefs = um.toPromptSection() catch null;
                if (prefs) |p| {
                    defer self.allocator.free(p);
                    try history_mod.addMessageUnlocked(self, "assistant", p);
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No user preferences recorded yet.");
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "User model not initialized.");
            }
        } else if (std.mem.eql(u8, name, "/feedback") or std.mem.startsWith(u8, name, "/feedback ")) {
            const fb_sub = std.mem.trim(u8, name["/feedback".len..], " ");
            if (self.feedback) |*fb| {
                if (fb_sub.len == 0) {
                    // Show stats
                    const stats = fb.formatStats() catch "Error getting feedback stats";
                    defer self.allocator.free(stats);
                    try history_mod.addMessageUnlocked(self, "assistant", stats);
                } else if (std.mem.eql(u8, fb_sub, "recent")) {
                    const recent = fb.formatRecent(10) catch "Error getting recent feedback";
                    defer self.allocator.free(recent);
                    try history_mod.addMessageUnlocked(self, "assistant", recent);
                } else if (std.mem.startsWith(u8, fb_sub, "rate ")) {
                    // /feedback rate <task_id> <1-5>
                    const rate_args = std.mem.trim(u8, fb_sub["rate ".len..], " ");
                    // Split into task_id and rating
                    const space_idx = std.mem.indexOfScalar(u8, rate_args, ' ');
                    if (space_idx) |si| {
                        const tid = rate_args[0..si];
                        const rating_str = std.mem.trim(u8, rate_args[si + 1 ..], " ");
                        const rating = std.fmt.parseInt(u8, rating_str, 10) catch {
                            try history_mod.addMessageUnlocked(self, "assistant", "Invalid rating. Use a number 1-5.");
                            ctx.redraw = true;
                            return;
                        };
                        fb.rateTask(tid, rating) catch |err| {
                            const err_text = std.fmt.allocPrint(self.allocator, "Failed to rate task: {}", .{err}) catch "Error";
                            defer self.allocator.free(err_text);
                            try history_mod.addMessageUnlocked(self, "assistant", err_text);
                            ctx.redraw = true;
                            return;
                        };
                        const success_text = std.fmt.allocPrint(self.allocator, "Rated task {s} as {d}/5", .{ tid, rating }) catch "Rated";
                        defer self.allocator.free(success_text);
                        try history_mod.addMessageUnlocked(self, "assistant", success_text);
                    } else {
                        try history_mod.addMessageUnlocked(self, "assistant", "Usage: /feedback rate <task_id> <1-5>");
                    }
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant",
                        \\Feedback Commands:
                        \\  /feedback              — show statistics
                        \\  /feedback recent       — show last 10 entries
                        \\  /feedback rate <id> <1-5> — rate a specific task
                    );
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Feedback store not initialized.");
            }
        } else if (std.mem.eql(u8, name, "/delegate") or std.mem.startsWith(u8, name, "/delegate ")) {
            const del_sub = std.mem.trim(u8, name["/delegate".len..], " ");
            if (del_sub.len == 0 or std.mem.eql(u8, del_sub, "status")) {
                const stats = self.delegator.getStats(self.allocator) catch "Error getting delegation stats";
                defer self.allocator.free(stats);
                const mode_str: []const u8 = if (self.delegate_mode) "ON" else "OFF";
                const text = try std.fmt.allocPrint(self.allocator, "{s}\n  Delegate mode: {s}", .{ stats, mode_str });
                defer self.allocator.free(text);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else if (std.mem.eql(u8, del_sub, "on")) {
                self.delegate_mode = true;
                try history_mod.addMessageUnlocked(self, "assistant", "Delegate mode enabled. Multiple tool calls will be batched through sub-agents.");
            } else if (std.mem.eql(u8, del_sub, "off")) {
                self.delegate_mode = false;
                try history_mod.addMessageUnlocked(self, "assistant", "Delegate mode disabled. Tool calls execute sequentially.");
            } else {
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Delegate Commands:
                    \\  /delegate          — show delegation stats and mode
                    \\  /delegate on       — enable delegation mode (batch tool calls)
                    \\  /delegate off      — disable delegation mode
                );
            }
        } else if (std.mem.eql(u8, name, "/autopilot") or std.mem.startsWith(u8, name, "/autopilot ")) {
            const auto_sub = std.mem.trim(u8, name["/autopilot".len..], " ");
            if (auto_sub.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Autopilot Engine:
                    \\  /autopilot run <agent-id>  — run a specific agent
                    \\  /autopilot status [agent]  — show agent status
                    \\  /autopilot schedule        — run all scheduled agents
                    \\  /autopilot list            — list all agents
                );
            } else if (std.mem.startsWith(u8, auto_sub, "run ")) {
                const agent_id = std.mem.trim(u8, auto_sub["run ".len..], " ");
                if (agent_id.len == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Usage: /autopilot run <agent-id>");
                } else if (!self.pipeline_initialized) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Pipeline not initialized — cannot run autopilot.");
                } else if (self.pipeline) |p| {
                    const guardian_ptr: ?*guardian_mod.Guardian = if (self.guardian) |*g| g else null;
                    var engine = autopilot_mod.AutopilotEngine.init(self.allocator, p, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Failed to initialize autopilot engine.");
                        ctx.redraw = true;
                        return;
                    };
                    defer engine.deinit();
                    const result = engine.runAgentWork(agent_id) catch |err| {
                        const err_text = try std.fmt.allocPrint(self.allocator, "Agent '{s}' failed: {}", .{ agent_id, err });
                        defer self.allocator.free(err_text);
                        try history_mod.addMessageUnlocked(self, "assistant", err_text);
                        ctx.redraw = true;
                        return;
                    };
                    defer result.deinit(self.allocator);
                    const text = try std.fmt.allocPrint(self.allocator,
                        \\Agent: {s} ({s})
                        \\Status: {s}
                        \\Summary: {s}
                        \\Files scanned: {d} | Indexed: {d} | Vault: {d} | Graph: {d}
                    , .{
                        result.agent_id,
                        @tagName(result.agent_kind),
                        @tagName(result.status),
                        result.work_summary,
                        result.files_scanned,
                        result.files_indexed,
                        result.vault_nodes,
                        result.graph_nodes,
                    });
                    defer self.allocator.free(text);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                }
            } else if (std.mem.startsWith(u8, auto_sub, "status")) {
                const status_arg = std.mem.trim(u8, auto_sub["status".len..], " ");
                if (!self.pipeline_initialized) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Pipeline not initialized.");
                } else if (self.pipeline) |p| {
                    const guardian_ptr: ?*guardian_mod.Guardian = if (self.guardian) |*g| g else null;
                    var engine = autopilot_mod.AutopilotEngine.init(self.allocator, p, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Failed to initialize autopilot engine.");
                        ctx.redraw = true;
                        return;
                    };
                    defer engine.deinit();
                    if (status_arg.len > 0) {
                        const status_text = engine.getAgentStatus(status_arg);
                        if (status_text) |stext| {
                            defer self.allocator.free(stext);
                            try history_mod.addMessageUnlocked(self, "assistant", stext);
                        } else {
                            const not_found = try std.fmt.allocPrint(self.allocator, "Agent '{s}' not found.", .{status_arg});
                            defer self.allocator.free(not_found);
                            try history_mod.addMessageUnlocked(self, "assistant", not_found);
                        }
                    } else {
                        engine.printStats();
                        try history_mod.addMessageUnlocked(self, "assistant", "Autopilot stats printed to log.");
                    }
                }
            } else if (std.mem.eql(u8, auto_sub, "schedule")) {
                if (!self.pipeline_initialized) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Pipeline not initialized — cannot run schedule.");
                } else if (self.pipeline) |p| {
                    const guardian_ptr: ?*guardian_mod.Guardian = if (self.guardian) |*g| g else null;
                    var engine = autopilot_mod.AutopilotEngine.init(self.allocator, p, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Failed to initialize autopilot engine.");
                        ctx.redraw = true;
                        return;
                    };
                    defer engine.deinit();
                    engine.runScheduledWork() catch {};
                    engine.printStats();
                    try history_mod.addMessageUnlocked(self, "assistant", "Scheduled agents executed. Stats printed to log.");
                }
            } else if (std.mem.eql(u8, auto_sub, "list")) {
                if (!self.pipeline_initialized) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Pipeline not initialized.");
                } else if (self.pipeline) |p| {
                    const guardian_ptr: ?*guardian_mod.Guardian = if (self.guardian) |*g| g else null;
                    var engine = autopilot_mod.AutopilotEngine.init(self.allocator, p, guardian_ptr, ".", ".crushcode/autopilot/") catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Failed to initialize autopilot engine.");
                        ctx.redraw = true;
                        return;
                    };
                    defer engine.deinit();
                    const listing = engine.listAgents(self.allocator) catch "(failed to list agents)";
                    defer self.allocator.free(listing);
                    try history_mod.addMessageUnlocked(self, "assistant", listing);
                }
            } else {
                const err_text = try std.fmt.allocPrint(self.allocator, "Unknown autopilot subcommand: {s}\nUse: run, status, schedule, list", .{auto_sub});
                defer self.allocator.free(err_text);
                try history_mod.addMessageUnlocked(self, "assistant", err_text);
            }
        } else if (std.mem.eql(u8, name, "/crush") or std.mem.startsWith(u8, name, "/crush ")) {
            const crush_task = std.mem.trim(u8, name["/crush".len..], " ");
            if (crush_task.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Crush Mode — auto-agentic execution
                    \\
                    \\Usage: /crush <task description>
                    \\
                    \\Examples:
                    \\  /crush fix all auth bugs
                    \\  /crush refactor config module and add tests
                    \\
                    \\The engine will: plan → execute → verify → commit
                );
                return;
            }

            // Get project directory
            const cwd = std.process.getCwdAlloc(self.allocator) catch ".";
            defer self.allocator.free(cwd);

            // Initialize CrushEngine
            var engine = crush_mode_mod.CrushEngine.init(self.allocator, crush_task, cwd);
            engine.auto_approve_read = true;
            engine.auto_approve_write = true; // In TUI, auto-approve by default
            engine.auto_verify = true;
            engine.auto_commit = false; // Don't auto-commit in TUI — user controls git

            self.crush_active = true;
            self.crush_engine = engine;
            self.crush_progress = "Planning...";

            const progress = engine.progressString(self.allocator) catch "Planning...";
            var msg_buf = array_list_compat.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();
            msg_buf.writer().print("🤖 **Crush Mode Activated**\n\n**Task:** {s}\n\n{s}", .{ crush_task, progress }) catch {};
            const msg = try msg_buf.toOwnedSlice();
            try history_mod.addMessageUnlocked(self, "assistant", msg);

            // Note: Full execution requires AI provider loop integration.
            // For now, show the plan state and mark as requiring provider connection.
            self.crush_progress = "Ready — awaiting provider connection for execution";
            try history_mod.addMessageUnlocked(self, "system", "Crush Mode plan generated. Full auto-execution requires streaming AI response — use `/crush <task>` with an active provider.");
            self.crush_active = false;
        } else if (std.mem.startsWith(u8, name, "/team")) {
            // /team subcommands: create, add, run, status, results, cancel
            if (std.mem.startsWith(u8, name, "/team create ")) {
                const team_name = std.mem.trim(u8, name["/team create ".len..], " ");
                if (team_name.len == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Usage: /team create <name>");
                } else {
                    // Clean up existing team if any
                    if (self.live_team != null) {
                        self.live_team.?.deinit();
                        self.live_team = null;
                    }
                    var team = team_coordinator_lib.LiveAgentTeam.init(self.allocator);
                    team.createTeam(team_name, 4, 500000) catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to create team.");
                        ctx.redraw = true;
                        return;
                    };
                    self.live_team = team;
                    const text = try std.fmt.allocPrint(self.allocator, "Team '{s}' created.\nMax parallel: 4 agents\nBudget: 500,000 tokens\nUse /team add <task> to assign tasks.", .{team_name});
                    defer self.allocator.free(text);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                }
            } else if (std.mem.startsWith(u8, name, "/team add ")) {
                const task_prompt = std.mem.trim(u8, name["/team add ".len..], " ");
                if (task_prompt.len == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Usage: /team add <task description>");
                } else if (self.live_team == null) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No team created. Use /team create <name> first.");
                } else {
                    const agent_id = self.live_team.?.assignTask(task_prompt, null, "") catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to assign task.");
                        ctx.redraw = true;
                        return;
                    };
                    const text = try std.fmt.allocPrint(self.allocator, "Task assigned to agent-{d}.\nUse /team run to execute all tasks.", .{agent_id});
                    defer self.allocator.free(text);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                }
            } else if (std.mem.eql(u8, name, "/team run")) {
                if (self.live_team == null) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No team created. Use /team create <name> first.");
                } else {
                    const idle_count = self.live_team.?.countByStatus(.idle);
                    if (idle_count == 0) {
                        try history_mod.addMessageUnlocked(self, "assistant", "No idle tasks to run. Use /team add <task> to assign tasks.");
                    } else {
                        // Resolve base URL from registry or override
                        const base_url: []const u8 = if (self.override_url) |url| url else blk: {
                            const provider = self.registry.getProvider(self.provider_name) orelse break :blk "";
                            break :blk provider.config.base_url;
                        };
                        if (base_url.len == 0) {
                            try history_mod.addMessageUnlocked(self, "assistant", "Error: no provider base URL available. Initialize a provider first.");
                        } else {
                            try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Executing {d} task(s)...", .{idle_count}));
                            self.live_team.?.executeAll(
                                self.provider_name,
                                base_url,
                                self.api_key,
                                self.model_name,
                            ) catch {
                                try history_mod.addMessageUnlocked(self, "assistant", "Error: team execution failed.");
                                ctx.redraw = true;
                                return;
                            };
                            const done = self.live_team.?.countByStatus(.done);
                            const failed = self.live_team.?.countByStatus(.failed);
                            const text = try std.fmt.allocPrint(self.allocator, "Team execution complete.\nCompleted: {d}\nFailed: {d}\nUse /team results to see outputs.", .{ done, failed });
                            defer self.allocator.free(text);
                            try history_mod.addMessageUnlocked(self, "assistant", text);
                        }
                    }
                }
            } else if (std.mem.eql(u8, name, "/team status")) {
                if (self.live_team == null) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No team created. Use /team create <name> first.");
                } else {
                    const status_json = self.live_team.?.getStatus() catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to get team status.");
                        ctx.redraw = true;
                        return;
                    };
                    defer self.allocator.free(status_json);
                    try history_mod.addMessageUnlocked(self, "assistant", status_json);
                }
            } else if (std.mem.eql(u8, name, "/team results")) {
                if (self.live_team == null) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No team created. Use /team create <name> first.");
                } else {
                    const results = self.live_team.?.getResults() catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to get results.");
                        ctx.redraw = true;
                        return;
                    };
                    defer {
                        for (results) |*r| r.deinit(self.allocator);
                        self.allocator.free(results);
                    }
                    if (results.len == 0) {
                        try history_mod.addMessageUnlocked(self, "assistant", "No completed results yet. Use /team run to execute tasks.");
                    } else {
                        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
                        defer buf.deinit();
                        const writer = buf.writer();
                        writer.print("=== Team Results ({d}) ===\n", .{results.len}) catch {};
                        for (results) |r| {
                            const status_icon = switch (r.status) {
                                .done => "✅",
                                .failed => "❌",
                                else => "❓",
                            };
                            writer.print("\n{s} Agent {d} ({s})\n", .{ status_icon, r.agent_id, r.agent_name }) catch {};
                            writer.print("  Task: {s:.80}\n", .{r.task_prompt}) catch {};
                            writer.print("  Output: {s:.200}\n", .{r.output}) catch {};
                            writer.print("  Tokens: {d} | Cost: ${d:.4}\n", .{ r.token_usage, r.cost }) catch {};
                        }
                        try history_mod.addMessageUnlocked(self, "assistant", try buf.toOwnedSlice());
                    }
                }
            } else if (std.mem.eql(u8, name, "/team cancel")) {
                if (self.live_team == null) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No team to cancel.");
                } else {
                    self.live_team.?.cancelAll();
                    try history_mod.addMessageUnlocked(self, "assistant", "All running agents cancelled.");
                }
            } else {
                // Default /team or /team help — show orchestration stats + usage help
                var engine = orchestration_mod.OrchestrationEngine.init(self.allocator) catch {
                    try history_mod.addMessageUnlocked(self, "assistant",
                        \\Team Commands:
                        \\  /team create <name>    — create a new agent team
                        \\  /team add <task>       — add a task to the team
                        \\  /team run              — execute all team tasks in parallel
                        \\  /team status           — show JSON status of all agents
                        \\  /team results          — show results from completed agents
                        \\  /team cancel           — cancel all running agents
                    );
                    ctx.redraw = true;
                    return;
                };
                defer engine.deinit();
                engine.printStats();
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Team orchestration stats printed to log.
                    \\
                    \\Team Commands:
                    \\  /team create <name>    — create a new agent team
                    \\  /team add <task>       — add a task to the team
                    \\  /team run              — execute all team tasks in parallel
                    \\  /team status           — show JSON status of all agents
                    \\  /team results          — show results from completed agents
                    \\  /team cancel           — cancel all running agents
                );
            }
        } else if (std.mem.startsWith(u8, name, "/spawn ")) {
            const spawn_desc = std.mem.trim(u8, name["/spawn ".len..], " ");
            if (spawn_desc.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /spawn <task description>");
            } else {
                var engine = orchestration_mod.OrchestrationEngine.init(self.allocator) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to initialize orchestration engine.");
                    ctx.redraw = true;
                    return;
                };
                defer engine.deinit();
                const result = engine.spawnTeam(spawn_desc, 3) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error: failed to spawn team.");
                    ctx.redraw = true;
                    return;
                };
                defer result.deinit(self.allocator);

                var buf: [4096]u8 = undefined;
                var offset: usize = 0;

                const head = std.fmt.bufPrint(&buf, "=== Team Spawned ===\n  Team:   {s} ({s})\n  Agents: {d}\n  Cost:   ${d:.4}\n\n  Phases ({d}):\n", .{
                    result.team_name,
                    result.team_id,
                    result.agent_count,
                    result.total_estimated_cost,
                    result.plan.total_phases,
                });
                if (head) |written| offset = written.len else |_| {}

                for (result.plan.phases, 0..) |phase, idx| {
                    const line = std.fmt.bufPrint(buf[offset..], "    {d}. {s} — {s} [{s}]\n", .{
                        idx + 1,
                        phase.phase_name,
                        phase.phase_description,
                        phase.recommended_model,
                    });
                    if (line) |written| offset += written.len else |_| {}
                }

                const agents_head = std.fmt.bufPrint(buf[offset..], "\n  Agents:\n", .{});
                if (agents_head) |written| offset += written.len else |_| {}

                for (result.agents, 0..) |agent, idx| {
                    const line = std.fmt.bufPrint(buf[offset..], "    {d}. {s} [{s}] → {s}\n", .{
                        idx + 1,
                        agent.agent_name,
                        @tagName(agent.specialty),
                        agent.model,
                    });
                    if (line) |written| offset += written.len else |_| {}
                }

                const text = try self.allocator.dupe(u8, buf[0..offset]);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/phase-run") or std.mem.startsWith(u8, name, "/phase-run ")) {
            const phase_arg = std.mem.trim(u8, name["/phase-run".len..], " ");
            if (phase_arg.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant",
                    \\Phase Runner:
                    \\  /phase-run <name>  — run a simple 2-phase workflow
                    \\  /phase-run status  — show phase runner info
                );
            } else if (std.mem.eql(u8, phase_arg, "status")) {
                const pipeline_status = if (self.pipeline_initialized) "initialized" else "not initialized";
                const guardian_status = if (self.guardian != null) "active" else "disabled";
                const text = try std.fmt.allocPrint(self.allocator,
                    \\Phase Runner Status:
                    \\  Pipeline: {s}
                    \\  Guardian: {s}
                , .{ pipeline_status, guardian_status });
                defer self.allocator.free(text);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else {
                var runner = phase_runner_mod.PhaseRunner.init(self.allocator, .{
                    .name = phase_arg,
                    .use_adversarial_gates = false,
                    .verbose = false,
                }) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Failed to initialize phase runner.");
                    ctx.redraw = true;
                    return;
                };
                defer runner.deinit();

                const discuss_tasks = [_][]const u8{ "Gather requirements", "Clarify scope" };
                runner.addPhase(1, "discuss", "Gather requirements and clarify scope for the user goal objective", &discuss_tasks) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Failed to add discuss phase.");
                    ctx.redraw = true;
                    return;
                };
                const plan_tasks = [_][]const u8{ "Create implementation plan", "Define tasks and steps to build" };
                runner.addPhase(2, "plan", "Create implementation plan with tasks steps build create write add fix update", &plan_tasks) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Failed to add plan phase.");
                    ctx.redraw = true;
                    return;
                };

                var result = runner.run() catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Phase run failed.");
                    ctx.redraw = true;
                    return;
                };
                defer result.deinit();

                const text = try std.fmt.allocPrint(self.allocator,
                    \\Phase Run Complete:
                    \\  Workflow:  {s}
                    \\  Phases:    {d}/{d} completed
                    \\  Failed:    {d}
                    \\  Progress:  {d:.1}%
                    \\  Duration:  {d}ms
                , .{
                    result.workflow_name,
                    result.completed_phases,
                    result.total_phases,
                    result.failed_phases,
                    result.progress,
                    result.duration_ms,
                });
                defer self.allocator.free(text);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/skills/auto") or std.mem.startsWith(u8, name, "/skills/auto ")) {
            const auto_sub = std.mem.trim(u8, name["/skills/auto".len..], " ");
            if (self.auto_gen) |*ag| {
                if (auto_sub.len == 0) {
                    // Show status
                    const stats = ag.statsSummary() catch "Error getting auto-skill stats";
                    defer self.allocator.free(stats);
                    try history_mod.addMessageUnlocked(self, "assistant", stats);
                } else if (std.mem.eql(u8, auto_sub, "propose")) {
                    const proposable = ag.formatProposableSkills() catch "Error listing proposable skills";
                    defer self.allocator.free(proposable);
                    try history_mod.addMessageUnlocked(self, "assistant", proposable);
                } else if (std.mem.startsWith(u8, auto_sub, "generate ")) {
                    const pattern_name = std.mem.trim(u8, auto_sub["generate ".len..], " ");
                    if (pattern_name.len == 0) {
                        try history_mod.addMessageUnlocked(self, "assistant", "Usage: /skills/auto generate <pattern-name>");
                    } else {
                        // Find the pattern by name
                        var found_pattern: ?*auto_gen_mod.TaskPattern = null;
                        for (ag.patterns.items) |*p| {
                            if (std.mem.eql(u8, p.name, pattern_name)) {
                                found_pattern = p;
                                break;
                            }
                        }
                        if (found_pattern) |p| {
                            const path = ag.generateSkill(p) catch |err| {
                                const err_text = try std.fmt.allocPrint(self.allocator, "Failed to generate skill: {}", .{err});
                                defer self.allocator.free(err_text);
                                try history_mod.addMessageUnlocked(self, "assistant", err_text);
                                ctx.redraw = true;
                                return;
                            };
                            defer self.allocator.free(path);
                            const success_text = try std.fmt.allocPrint(self.allocator, "Skill generated: {s}", .{path});
                            defer self.allocator.free(success_text);
                            try history_mod.addMessageUnlocked(self, "assistant", success_text);
                        } else {
                            const err_text = try std.fmt.allocPrint(self.allocator, "Pattern '{s}' not found. Use /skills/auto propose to list available patterns.", .{pattern_name});
                            defer self.allocator.free(err_text);
                            try history_mod.addMessageUnlocked(self, "assistant", err_text);
                        }
                    }
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant",
                        \\Auto-Skill Generator:
                        \\  /skills/auto              — show status and detected patterns
                        \\  /skills/auto propose      — list proposable skills
                        \\  /skills/auto generate <n> — generate and save a skill
                    );
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Auto-skill generator not initialized.");
            }
        } else if (std.mem.eql(u8, name, "/help")) {
            try history_mod.addMessageUnlocked(self, "assistant", "/clear — Clear conversation history\n/sessions — Browse saved sessions\n/ls — Alias for /sessions\n/resume <id> — Resume a saved session\n/delete <id> — Delete a saved session\n/exit — Exit crushcode\n/model — Show current model\n/thinking — Toggle thinking mode\n/compact — Compact conversation context\n/preview — Toggle file preview pane (Ctrl+\\)\n/theme dark — Switch to dark theme\n/theme light — Switch to light theme\n/theme mono — Switch to monochrome theme\n/workers — List active workers\n/kill <id> — Cancel a worker\n/memory — Show cross-session memory stats\n/plugins — List loaded runtime plugins\n/guardian — Show guardian security stats\n/cognition — Show cognition pipeline stats\n/user — Show user preference profile\n/autopilot [run|status|schedule|list] — Background agent control\n/team — Show orchestration engine stats\n/spawn <desc> — Spawn a multi-agent team\n/phase-run [name|status] — Run phase-based workflow\n/skills/auto [propose|generate] — Auto-skill pattern detection\n/cost [total|today|model|session] — Cost analytics dashboard\n/tree [refresh] — Show session tree hierarchy\n/compress [status|run] — Semantic context compression\n/help — Show available commands");
        } else if (std.mem.eql(u8, name, "/compact")) {
            try self.performCompaction();
        } else if (std.mem.eql(u8, name, "/model")) {
            const text = try std.fmt.allocPrint(self.allocator, "Current model: {s}/{s}", .{ self.provider_name, self.model_name });
            defer self.allocator.free(text);
            try history_mod.addMessageUnlocked(self, "assistant", text);
        } else if (std.mem.startsWith(u8, name, "/model ")) {
            // Parse: "/model provider_name model_name"
            const rest = name["/model ".len..];
            const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
                try history_mod.addMessageUnlocked(self, "error", "Usage: /model <provider> <model>");
                return;
            };
            const provider = rest[0..space_idx];
            const model = rest[space_idx + 1 ..];
            if (provider.len == 0 or model.len == 0) {
                try history_mod.addMessageUnlocked(self, "error", "Usage: /model <provider> <model>");
                return;
            }
            self.allocator.free(self.provider_name);
            self.allocator.free(self.model_name);
            self.provider_name = try self.allocator.dupe(u8, provider);
            self.model_name = try self.allocator.dupe(u8, model);
            self.compactor.max_tokens = context_limits.getContextWindow(provider, model);
            try self.initializeClient();
            const msg = try std.fmt.allocPrint(self.allocator, "Switched to {s}/{s}", .{ provider, model });
            defer self.allocator.free(msg);
            try history_mod.addMessageUnlocked(self, "assistant", msg);
        } else if (std.mem.eql(u8, name, "/preview")) {
            self.right_pane_visible = !self.right_pane_visible;
            if (!self.right_pane_visible) {
                if (self.right_pane_content) |c| {
                    self.allocator.free(c);
                    self.right_pane_content = null;
                }
                if (self.right_pane_title) |t| {
                    self.allocator.free(t);
                    self.right_pane_title = null;
                }
            }
            const state_text = if (self.right_pane_visible) "File preview pane enabled. Use `/preview <filepath>` to show a file." else "File preview pane disabled.";
            try history_mod.addMessageUnlocked(self, "assistant", state_text);
        } else if (std.mem.startsWith(u8, name, "/preview ")) {
            const file_path = std.mem.trim(u8, name["/preview ".len..], &std.ascii.whitespace);
            if (file_path.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /preview <filepath>");
                return;
            }
            const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Failed to read file: {s}", .{@errorName(err)});
                defer self.allocator.free(err_msg);
                try history_mod.addMessageUnlocked(self, "assistant", err_msg);
                return;
            };
            if (self.right_pane_content) |c| self.allocator.free(c);
            if (self.right_pane_title) |t| self.allocator.free(t);
            self.right_pane_content = content;
            self.right_pane_title = try self.allocator.dupe(u8, file_path);
            self.right_pane_visible = true;
            const confirm = try std.fmt.allocPrint(self.allocator, "Previewing: {s} ({d} bytes)", .{ file_path, content.len });
            defer self.allocator.free(confirm);
            try history_mod.addMessageUnlocked(self, "assistant", confirm);
        } else if (std.mem.eql(u8, name, "/refresh")) {
            self.refreshCwdListing();
            const refresh_msg = try std.fmt.allocPrint(self.allocator, "Sidebar refreshed. {d} project files.", .{self.cwd_files.items.len});
            defer self.allocator.free(refresh_msg);
            try history_mod.addMessageUnlocked(self, "assistant", refresh_msg);
        } else if (std.mem.startsWith(u8, name, "/cost")) {
            const sub = std.mem.trim(u8, name[5..], &std.ascii.whitespace);
            const db = session_mod.getSessionDb(self.allocator) catch |err| {
                try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Session DB error: {s}", .{@errorName(err)}));
                return;
            };
            var dashboard = cost_dashboard_mod.CostDashboard.init(self.allocator, db);
            if (sub.len == 0 or std.mem.eql(u8, sub, "total")) {
                const total = dashboard.getTotalCost() catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Error: {s}", .{@errorName(err)}));
                    return;
                };
                const today = dashboard.getTodayCost() catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Error: {s}", .{@errorName(err)}));
                    return;
                };
                const by_provider_raw = dashboard.getCostByProvider() catch &[_]cost_dashboard_mod.ProviderCost{};
                const by_provider: []cost_dashboard_mod.ProviderCost = @constCast(by_provider_raw);
                defer {
                    for (by_provider) |p| self.allocator.free(p.provider);
                    self.allocator.free(by_provider);
                }
                const report = cost_dashboard_mod.formatTotalReport(self.allocator, total, today, by_provider) catch "Error formatting report";
                try history_mod.addMessageUnlocked(self, "assistant", report);
            } else if (std.mem.eql(u8, sub, "model")) {
                const by_model_raw = dashboard.getCostByModel() catch &[_]cost_dashboard_mod.ModelCost{};
                const by_model: []cost_dashboard_mod.ModelCost = @constCast(by_model_raw);
                defer {
                    for (by_model) |m| self.allocator.free(m.model);
                    self.allocator.free(by_model);
                }
                const report = cost_dashboard_mod.formatByModelReport(self.allocator, by_model) catch "Error formatting report";
                try history_mod.addMessageUnlocked(self, "assistant", report);
            } else if (std.mem.eql(u8, sub, "today")) {
                const today = dashboard.getTodayCost() catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Error: {s}", .{@errorName(err)}));
                    return;
                };
                const text = try std.fmt.allocPrint(self.allocator, "Today's Cost\n-------------\nCost: ${d:.4}\nTokens: {d}\nSessions: {d}", .{ today.cost, today.tokens, today.session_count });
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else if (std.mem.eql(u8, sub, "session")) {
                const top_raw = dashboard.getTopSessions() catch &[_]session_db_mod.SessionRow{};
                const top: []session_db_mod.SessionRow = @constCast(top_raw);
                defer {
                    for (top) |s| {
                        self.allocator.free(s.id);
                        self.allocator.free(s.title);
                        self.allocator.free(s.model);
                        self.allocator.free(s.provider);
                    }
                    self.allocator.free(top);
                }
                var buf = array_list_compat.ArrayList(u8).init(self.allocator);
                defer buf.deinit();
                try buf.writer().print("Top Sessions:\n\n", .{});
                for (top) |s| {
                    try buf.writer().print("* {s}\n  ${d:.4} * {d} tokens * {d} turns\n  Model: {s}/{s}\n\n", .{ s.title, s.total_cost, s.total_tokens, s.turn_count, s.provider, s.model });
                }
                try history_mod.addMessageUnlocked(self, "assistant", try buf.toOwnedSlice());
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /cost [total|model|today|session]");
            }
        } else if (std.mem.startsWith(u8, name, "/fork")) {
            const sub = std.mem.trim(u8, name[5..], &std.ascii.whitespace);
            if (sub.len == 0) {
                const fork_point: u32 = @intCast(self.messages.items.len);
                // Build a Session from current state
                var current_session = session_mod.Session{
                    .id = if (self.session_path.len > 0) blk: {
                        const base = std.fs.path.basename(self.session_path);
                        const dot = std.mem.indexOf(u8, base, ".") orelse base.len;
                        break :blk try self.allocator.dupe(u8, base[0..dot]);
                    } else "current",
                    .title = "Current Session",
                    .model = self.model_name,
                    .provider = self.provider_name,
                    .total_tokens = self.total_input_tokens + self.total_output_tokens,
                    .total_cost = 0,
                    .turn_count = self.request_count,
                    .duration_seconds = 0,
                    .created_at = std.time.timestamp(),
                    .updated_at = std.time.timestamp(),
                    .messages = &.{},
                };
                defer self.allocator.free(current_session.id);
                var fm = fork_mod.ForkManager.init(self.allocator, self.session_dir);
                const result = fm.forkSession(&current_session, fork_point) catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Fork error: {s}", .{@errorName(err)}));
                    return;
                };
                defer result.deinit(self.allocator);
                const text = try std.fmt.allocPrint(self.allocator, "Session forked!\nNew session: {s}\nMessages: {d}\nUse /sessions to switch.", .{ result.new_session_id, result.message_count });
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else if (std.mem.eql(u8, sub, "list")) {
                var fm = fork_mod.ForkManager.init(self.allocator, self.session_dir);
                const forks = fm.listAllForks() catch &[_]fork_mod.ForkInfo{};
                defer {
                    for (forks) |f| {
                        self.allocator.free(f.fork_id);
                        self.allocator.free(f.parent_session_id);
                        self.allocator.free(f.title);
                    }
                    self.allocator.free(forks);
                }
                if (forks.len == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No forks found.");
                } else {
                    var buf = array_list_compat.ArrayList(u8).init(self.allocator);
                    defer buf.deinit();
                    try buf.writer().print("Session Forks ({d}):\n\n", .{forks.len});
                    for (forks) |f| {
                        try buf.writer().print("* {s}\n  Parent: {s} (at message {d})\n\n", .{ f.title, f.parent_session_id, f.fork_point });
                    }
                    try history_mod.addMessageUnlocked(self, "assistant", try buf.toOwnedSlice());
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /fork [list]\n  /fork        - Fork current session\n  /fork list   - List all forks");
            }
        } else if (std.mem.startsWith(u8, name, "/tree")) {
            const sub = std.mem.trim(u8, name[5..], &std.ascii.whitespace);
            if (sub.len > 0 and std.mem.eql(u8, sub, "refresh")) {
                // Force reload from database
                const db = session_mod.getSessionDb(self.allocator) catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Session DB error: {s}", .{@errorName(err)}));
                    return;
                };
                self.session_tree.loadFromDb(db) catch |err| {
                    try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Tree load error: {s}", .{@errorName(err)}));
                    return;
                };
                const rendered = self.session_tree.renderToString(self.allocator) catch "Error rendering tree";
                try history_mod.addMessageUnlocked(self, "assistant", rendered);
            } else {
                // Toggle or show tree
                if (self.session_tree.root_nodes.items.len == 0) {
                    // Load for the first time
                    const db = session_mod.getSessionDb(self.allocator) catch |err| {
                        try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Session DB error: {s}", .{@errorName(err)}));
                        return;
                    };
                    self.session_tree.loadFromDb(db) catch |err| {
                        try history_mod.addMessageUnlocked(self, "assistant", try std.fmt.allocPrint(self.allocator, "Tree load error: {s}", .{@errorName(err)}));
                        return;
                    };
                }
                const rendered = self.session_tree.renderToString(self.allocator) catch "Error rendering tree";
                try history_mod.addMessageUnlocked(self, "assistant", rendered);
            }
        } else if (std.mem.eql(u8, name, "/workers")) {
            self.parallel_executor.reapCompleted();
            const parallel_running = self.parallel_executor.runningCount();
            if (self.workers.items.len == 0 and parallel_running == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No active workers.");
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
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/diag")) {
            // Show LSP diagnostics
            const diagnostics = self.lsp_manager.getDiagnostics();
            if (diagnostics.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No LSP diagnostics. Open a file to see diagnostics.");
            } else {
                var buf: [2048]u8 = undefined;
                var offset: usize = 0;
                const head_result = std.fmt.bufPrint(&buf, "LSP Diagnostics:\n", .{});
                if (head_result) |written| {
                    offset = written.len;
                } else |_| {}
                for (diagnostics) |fd| {
                    const line_result = std.fmt.bufPrint(buf[offset..], "\n{s}:\n  {d} errors, {d} warnings\n", .{ fd.file_path, fd.errors, fd.warnings });
                    if (line_result) |written| {
                        offset += written.len;
                    } else |_| {}
                    for (fd.top_messages) |msg| {
                        if (msg) |m| {
                            const sym = switch (m.severity) {
                                .@"error" => "❌",
                                .warning => "⚠",
                                .information => "ℹ",
                                .hint => "○",
                            };
                            const msg_line = std.fmt.bufPrint(buf[offset..], "  {s} {d}: {s}\n", .{ sym, m.line, m.message });
                            if (msg_line) |written| {
                                offset += written.len;
                            } else |_| {}
                        }
                    }
                }
                const text = try self.allocator.dupe(u8, buf[0..offset]);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/refs") or std.mem.startsWith(u8, name, "/refs ")) {
            // LSP find-references
            if (!self.lsp_manager.enabled) {
                try history_mod.addMessageUnlocked(self, "assistant", "LSP is disabled.");
            } else if (self.lsp_manager.file_diagnostics.items.len == 0 and self.recent_files.items.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No files tracked. Open a file first, then use /refs <symbol> or /refs <file>:<line>:<col>.");
            } else {
                const arg = std.mem.trim(u8, name["/refs".len..], " \t\r\n");
                var target_file: ?[]const u8 = null;
                var target_line: u32 = 0;
                var target_char: u32 = 0;

                if (arg.len > 0) {
                    // Parse arg as file:line:col or bare symbol name
                    if (std.mem.indexOfScalar(u8, arg, ':')) |colon1| {
                        target_file = arg[0..colon1];
                        const rest = arg[colon1 + 1 ..];
                        if (std.mem.indexOfScalar(u8, rest, ':')) |colon2| {
                            target_line = std.fmt.parseInt(u32, rest[0..colon2], 10) catch 0;
                            target_char = std.fmt.parseInt(u32, rest[colon2 + 1 ..], 10) catch 0;
                        } else {
                            target_line = std.fmt.parseInt(u32, rest, 10) catch 0;
                        }
                    } else {
                        // Bare symbol — resolve from first tracked file
                        if (self.recent_files.items.len > 0) {
                            target_file = self.recent_files.items[0];
                        } else if (self.lsp_manager.file_diagnostics.items.len > 0) {
                            target_file = self.lsp_manager.file_diagnostics.items[0].file_path;
                        }
                        if (target_file) |fp| {
                            const content = std.fs.cwd().readFileAlloc(self.allocator, fp, 10 * 1024 * 1024) catch "";
                            defer if (content.len > 0) self.allocator.free(content);
                            if (findSymbolPosition(content, arg)) |pos| {
                                target_line = pos.line;
                                target_char = pos.character;
                            }
                        }
                    }
                } else {
                    if (self.recent_files.items.len > 0) {
                        target_file = self.recent_files.items[0];
                    } else if (self.lsp_manager.file_diagnostics.items.len > 0) {
                        target_file = self.lsp_manager.file_diagnostics.items[0].file_path;
                    }
                }

                if (target_file) |fp| {
                    const locations = self.lsp_manager.findReferences(fp, target_line, target_char);
                    if (locations) |locs| {
                        if (locs.len == 0) {
                            try history_mod.addMessageUnlocked(self, "assistant", "No references found.");
                        } else {
                            var buf: [4096]u8 = undefined;
                            var ref_offset: usize = 0;
                            if (std.fmt.bufPrint(&buf, "LSP References ({d}):\n", .{locs.len})) |written| {
                                ref_offset = written.len;
                            } else |_| {}
                            for (locs) |loc| {
                                const display_path = stripFileUriPrefix(loc.uri);
                                const line_result = std.fmt.bufPrint(buf[ref_offset..], "  {s}:{d}:{d}\n", .{ display_path, loc.range.start.line + 1, loc.range.start.character + 1 });
                                if (line_result) |written| {
                                    ref_offset += written.len;
                                } else |_| {}
                            }
                            for (locs) |loc| self.allocator.free(loc.uri);
                            self.allocator.free(locs);
                            const ref_text = try self.allocator.dupe(u8, buf[0..ref_offset]);
                            try history_mod.addMessageUnlocked(self, "assistant", ref_text);
                        }
                    } else {
                        try history_mod.addMessageUnlocked(self, "assistant", "LSP references unavailable — no language server for this file or LSP not started.");
                    }
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No file to search. Usage: /refs [file:line:col] or /refs <symbol>");
                }
            }
        } else if (std.mem.startsWith(u8, name, "/kill ")) {
            const id_str = name[6..];
            const id = std.fmt.parseInt(u32, id_str, 10) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Invalid worker ID. Usage: /kill <id>");
                ctx.redraw = true;
                return;
            };
            var found = false;
            for (self.workers.items) |*w| {
                if (w.id == id) {
                    w.status = .cancelled;
                    const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} cancelled.", .{id});
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                    found = true;
                    break;
                }
            }
            // Also try cancelling from parallel executor
            if (self.parallel_executor.cancel(id_str)) {
                if (!found) {
                    const text = try std.fmt.allocPrint(self.allocator, "Parallel task {s} cancelled.", .{id_str});
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                    found = true;
                }
            }
            if (!found) {
                const text = try std.fmt.allocPrint(self.allocator, "Worker #{d} not found.", .{id});
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/memory")) {
            const count = self.memory.count();
            const tokens = self.memory.estimateTokens();
            const text = try std.fmt.allocPrint(self.allocator, "Memory: {d} messages, ~{d} tokens", .{ count, tokens });
            defer self.allocator.free(text);
            try history_mod.addMessageUnlocked(self, "assistant", text);
        } else if (std.mem.eql(u8, name, "/plugins")) {
            const plugin_names = self.plugin_manager.getAllPlugins();
            if (plugin_names.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No plugins loaded.");
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
                try history_mod.addMessageUnlocked(self, "assistant", text);
            }
        } else if (std.mem.eql(u8, name, "/cost") or std.mem.startsWith(u8, name, "/cost ")) {
            const args = if (std.mem.startsWith(u8, name, "/cost ")) name[6..] else "";
            const sub = std.mem.trim(u8, args, &std.ascii.whitespace);

            const db_ptr = session_mod.getSessionDb(self.allocator) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Failed to open session database.");
                ctx.redraw = true;
                return;
            };
            var dashboard = cost_dashboard_mod.CostDashboard.init(self.allocator, db_ptr);

            if (sub.len == 0 or std.mem.eql(u8, sub, "total")) {
                // Show total + today + by provider
                const total = dashboard.getTotalCost() catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error querying total cost.");
                    ctx.redraw = true;
                    return;
                };
                const today = dashboard.getTodayCost() catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error querying today's cost.");
                    ctx.redraw = true;
                    return;
                };
                const by_provider = dashboard.getCostByProvider() catch
                    @as([]cost_dashboard_mod.ProviderCost, &.{});
                defer cost_dashboard_mod.freeProviderCosts(self.allocator, by_provider);

                const report = cost_dashboard_mod.formatTotalReport(self.allocator, total, today, by_provider) catch "Error formatting report";
                try history_mod.addMessageUnlocked(self, "assistant", report);
            } else if (std.mem.eql(u8, sub, "model") or std.mem.eql(u8, sub, "by-model")) {
                const by_model = dashboard.getCostByModel() catch
                    @as([]cost_dashboard_mod.ModelCost, &.{});
                defer cost_dashboard_mod.freeModelCosts(self.allocator, by_model);

                const report = cost_dashboard_mod.formatByModelReport(self.allocator, by_model) catch "Error formatting report";
                try history_mod.addMessageUnlocked(self, "assistant", report);
            } else if (std.mem.eql(u8, sub, "today")) {
                const today = dashboard.getTodayCost() catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error querying today's cost.");
                    ctx.redraw = true;
                    return;
                };
                const text = try std.fmt.allocPrint(self.allocator, "\xf0\x9f\x92\xb0 Today's Cost\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\nCost: ${d:.4}\nTokens: {d}\nSessions: {d}", .{ today.cost, today.tokens, today.session_count });
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else if (std.mem.eql(u8, sub, "session") or std.mem.eql(u8, sub, "sessions")) {
                const top = dashboard.getTopSessions() catch
                    @as([]session_db_mod.SessionRow, &.{});
                defer session_db_mod.freeSessionRows(self.allocator, top);

                if (top.len == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "No sessions recorded yet.");
                } else {
                    var buf: [4096]u8 = undefined;
                    var poffset: usize = 0;
                    if (std.fmt.bufPrint(&buf, "\xf0\x9f\x93\x8b Top Sessions by Cost\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n", .{})) |written| {
                        poffset = written.len;
                    } else |_| {}
                    for (top, 0..) |s, i| {
                        const preview = if (s.title.len > 30) s.title[0..30] else s.title;
                        if (std.fmt.bufPrint(buf[poffset..], "#{d} ${d:.4} [{s}/{s}] {s}\n", .{ i + 1, s.total_cost, s.provider, s.model, preview })) |written| {
                            poffset += written.len;
                        } else |_| {}
                    }
                    const text = try self.allocator.dupe(u8, buf[0..poffset]);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /cost [total|today|model|session]");
            }
        } else if (std.mem.eql(u8, name, "/undo")) {
            // /undo — restore most recent checkpoint (alias for /rewind last)
            const db_ptr = session_mod.getSessionDb(self.allocator) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Failed to open session database for undo.");
                ctx.redraw = true;
                return;
            };
            const session_id = if (self.current_session) |sess| sess.id else "";
            if (session_id.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No active session to undo.");
            } else {
                var mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
                const restored = mgr.rewindLast(db_ptr, self.allocator, session_id) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error undoing last change.");
                    ctx.redraw = true;
                    return;
                };
                if (restored) |cp| {
                    const text = std.fmt.allocPrint(self.allocator, "Undo: restored {s} (checkpoint #{d}, {s})", .{ cp.file_path, cp.id, cp.operation }) catch "Undo successful.";
                    var cp_mut = cp;
                    cp_mut.deinit(self.allocator);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "Nothing to undo. Use /rewind to see all checkpoints.");
                }
            }
            ctx.redraw = true;
        } else if (std.mem.eql(u8, name, "/rewind") or std.mem.startsWith(u8, name, "/rewind ")) {
            const rewind_sub = std.mem.trim(u8, name["/rewind".len..], " ");
            const db_ptr = session_mod.getSessionDb(self.allocator) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Failed to open session database for rewind.");
                ctx.redraw = true;
                return;
            };
            const session_id = if (self.current_session) |sess| sess.id else "";
            if (session_id.len == 0) {
                try history_mod.addMessageUnlocked(self, "assistant", "No active session to rewind.");
            } else if (rewind_sub.len == 0) {
                // /rewind — list all checkpoints for this session
                var mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
                const checkpoints = mgr.listCheckpoints(db_ptr, self.allocator, session_id) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error listing checkpoints.");
                    ctx.redraw = true;
                    return;
                };
                const text = mgr.formatCheckpointList(self.allocator, checkpoints) catch "Error formatting checkpoints";
                safety_checkpoint_mod.freeCheckpoints(self.allocator, checkpoints);
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else if (std.mem.eql(u8, rewind_sub, "last")) {
                // /rewind last — restore most recent checkpoint
                var mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
                const restored = mgr.rewindLast(db_ptr, self.allocator, session_id) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error rewinding last checkpoint.");
                    ctx.redraw = true;
                    return;
                };
                if (restored) |cp| {
                    const text = std.fmt.allocPrint(self.allocator, "Rewound: restored {s} (checkpoint #{d}, {s})", .{ cp.file_path, cp.id, cp.operation }) catch "Rewound last checkpoint.";
                    var cp_mut = cp;
                    cp_mut.deinit(self.allocator);
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No checkpoints to rewind for this session.");
                }
            } else if (std.mem.eql(u8, rewind_sub, "all")) {
                // /rewind all — restore ALL checkpoints
                var mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
                const count = mgr.rewindAll(db_ptr, self.allocator, session_id) catch {
                    try history_mod.addMessageUnlocked(self, "assistant", "Error rewinding all checkpoints.");
                    ctx.redraw = true;
                    return;
                };
                const text = std.fmt.allocPrint(self.allocator, "Rewound all: restored {d} file(s) to their original state.", .{count}) catch "Rewound all checkpoints.";
                try history_mod.addMessageUnlocked(self, "assistant", text);
            } else {
                // /rewind <N> — restore checkpoint by number (1-indexed)
                const idx = std.fmt.parseInt(usize, rewind_sub, 10) catch {
                    try history_mod.addMessageUnlocked(self, "assistant",
                        \\Rewind Commands:
                        \\  /rewind        — list all checkpoints for this session
                        \\  /rewind last   — restore the most recent checkpoint
                        \\  /rewind all    — restore ALL checkpoints for this session
                        \\  /rewind <N>    — restore checkpoint number N
                    );
                    ctx.redraw = true;
                    return;
                };
                if (idx == 0) {
                    try history_mod.addMessageUnlocked(self, "assistant", "Checkpoint numbers start at 1. Use /rewind to list them.");
                } else {
                    var mgr = safety_checkpoint_mod.CheckpointManager.init(self.allocator, ".crushcode/checkpoints/");
                    const checkpoints = mgr.listCheckpoints(db_ptr, self.allocator, session_id) catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Error listing checkpoints.");
                        ctx.redraw = true;
                        return;
                    };
                    defer safety_checkpoint_mod.freeCheckpoints(self.allocator, checkpoints);
                    if (idx > checkpoints.len) {
                        const err_text = std.fmt.allocPrint(self.allocator, "Checkpoint #{d} not found. Only {d} checkpoint(s) available.", .{ idx, checkpoints.len }) catch "Checkpoint not found.";
                        try history_mod.addMessageUnlocked(self, "assistant", err_text);
                    } else {
                        const cp = checkpoints[idx - 1];
                        // Restore this specific checkpoint
                        if (std.fs.path.dirname(cp.file_path)) |dir_part| {
                            if (dir_part.len > 0) {
                                std.fs.cwd().makePath(dir_part) catch {};
                            }
                        }
                        const file = std.fs.cwd().createFile(cp.file_path, .{ .truncate = true }) catch {
                            try history_mod.addMessageUnlocked(self, "assistant", "Error writing file during rewind.");
                            ctx.redraw = true;
                            return;
                        };
                        defer file.close();
                        file.writeAll(cp.original_content) catch {
                            try history_mod.addMessageUnlocked(self, "assistant", "Error writing file content during rewind.");
                            ctx.redraw = true;
                            return;
                        };
                        // Delete the restored checkpoint
                        db_ptr.deleteCheckpoint(cp.id) catch {};
                        const text = std.fmt.allocPrint(self.allocator, "Rewound: restored {s} (checkpoint #{d}, {s})", .{ cp.file_path, idx, cp.operation }) catch "Rewound checkpoint.";
                        try history_mod.addMessageUnlocked(self, "assistant", text);
                    }
                }
            }
        } else if (std.mem.eql(u8, name, "/compress") or std.mem.startsWith(u8, name, "/compress ")) {
            const sub = std.mem.trim(u8, name["/compress".len..], " ");
            var compressor = semantic_compressor_mod.SemanticCompressor.init(self.allocator);
            defer compressor.deinit();

            if (sub.len == 0 or std.mem.eql(u8, sub, "status")) {
                if (self.codebase_context) |ctx_content| {
                    const total_tokens = compressor.estimateTokens(ctx_content);
                    const file_count = self.context_file_count;
                    const text = try std.fmt.allocPrint(self.allocator,
                        "Context: {d} files, ~{d} tokens uncompressed\n\nCompression levels:\n  Full (>0.8 score): complete source\n  Signatures (0.5-0.8): fn signatures + types + docs\n  Interface (0.2-0.5): struct fields, type aliases only\n  Summary (<0.2): one-line per file\n\nUse /compress run to apply compression and see report.",
                        .{ file_count, total_tokens },
                    );
                    try history_mod.addMessageUnlocked(self, "assistant", text);
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No codebase context loaded. Context is built on startup.");
                }
            } else if (std.mem.eql(u8, sub, "run")) {
                if (self.codebase_context) |ctx_content| {
                    const file_info = semantic_compressor_mod.FileInfo{
                        .path = "context",
                        .content = ctx_content,
                        .estimated_tokens = @intCast(compressor.estimateTokens(ctx_content)),
                    };
                    const scores = [_]f64{0.9, 0.6, 0.3, 0.1};
                    const result = compressor.compressContext(&.{file_info}, &scores) catch {
                        try history_mod.addMessageUnlocked(self, "assistant", "Compression failed.");
                        ctx.redraw = true;
                        return;
                    };
                    const report = compressor.formatCompressionReport(result) catch "Error formatting report";
                    try history_mod.addMessageUnlocked(self, "assistant", report);
                } else {
                    try history_mod.addMessageUnlocked(self, "assistant", "No codebase context to compress.");
                }
            } else {
                try history_mod.addMessageUnlocked(self, "assistant", "Usage: /compress [status|run]");
            }
        } else if (std.mem.eql(u8, name, "/doctor")) {
            const report = doctor_mod.runDoctorChecks(self.allocator) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Doctor checks failed to run.");
                ctx.redraw = true;
                return;
            };
            defer self.allocator.free(report);
            try history_mod.addMessageUnlocked(self, "assistant", report);
        } else if (std.mem.eql(u8, name, "/review") or std.mem.startsWith(u8, name, "/review ")) {
            const review_sub = std.mem.trim(u8, name["/review".len..], " ");
            const scope: review_mod.ReviewScope = blk: {
                if (review_sub.len == 0) break :blk .unstaged;
                if (std.mem.eql(u8, review_sub, "staged")) break :blk .staged;
                if (std.mem.eql(u8, review_sub, "branch")) break :blk .branch;
                if (std.mem.eql(u8, review_sub, "last") or std.mem.eql(u8, review_sub, "last-commit")) break :blk .last_commit;
                break :blk .unstaged;
            };
            const result = review_mod.runReview(self.allocator, scope, null) catch {
                try history_mod.addMessageUnlocked(self, "assistant", "Review failed. Make sure you are in a git repository.");
                ctx.redraw = true;
                return;
            };
            defer self.allocator.free(result);
            try history_mod.addMessageUnlocked(self, "assistant", result);
        } else if (std.mem.eql(u8, name, "/commit") or std.mem.startsWith(u8, name, "/commit ")) {
            const commit_args = std.mem.trim(u8, name["/commit".len..], " ");
             const result = commit_mod.runCommit(self.allocator, commit_args) catch {
                 try history_mod.addMessageUnlocked(self, "assistant", "Commit analysis failed. Make sure you are in a git repository.");
                 ctx.redraw = true;
                 return;
             };
             defer self.allocator.free(result);
             try history_mod.addMessageUnlocked(self, "assistant", result);
        } else if (std.mem.eql(u8, name, "/autocommit")) {
            self.auto_commit_edits = !self.auto_commit_edits;
            const status: []const u8 = if (self.auto_commit_edits) "ON — each edit will be auto-committed to git" else "OFF — edits apply without committing";
            const msg = std.fmt.allocPrint(self.allocator, "Auto-commit: {s}", .{status}) catch "Toggled";
            defer self.allocator.free(msg);
            try history_mod.addMessageUnlocked(self, "system", msg);
        } else if (std.mem.eql(u8, name, "/export") or std.mem.startsWith(u8, name, "/export ")) {
            const export_args = std.mem.trim(u8, name["/export".len..], " ");
            const timestamp = std.time.timestamp();
            const filename = if (export_args.len > 0)
                try self.allocator.dupe(u8, export_args)
            else
                try std.fmt.allocPrint(self.allocator, "session-export-{d}.md", .{timestamp});
            defer if (export_args.len > 0) {} else self.allocator.free(filename);

            const file = std.fs.cwd().createFile(filename, .{ .truncate = true }) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Export failed: {}", .{err});
                try history_mod.addMessageUnlocked(self, "assistant", err_msg);
                ctx.redraw = true;
                return;
            };
            defer file.close();

            var buf = array_list_compat.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            const writer = buf.writer();
            writer.print("# Crushcode Session Export\nGenerated: {d}\nMessages: {d}\n\n---\n\n", .{ timestamp, self.messages.items.len }) catch {};

            for (self.messages.items, 0..) |msg, i| {
                const role_label = if (std.mem.eql(u8, msg.role, "user"))
                    "## You"
                else if (std.mem.eql(u8, msg.role, "assistant"))
                    "## Assistant"
                else if (std.mem.eql(u8, msg.role, "system"))
                    "## System"
                else
                    "## Tool";
                writer.print("{s} (#{d})\n\n{s}\n\n---\n\n", .{ role_label, i + 1, msg.content }) catch {};
            }

            file.writeAll(buf.items) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Export write failed: {}", .{err});
                try history_mod.addMessageUnlocked(self, "assistant", err_msg);
                ctx.redraw = true;
                return;
            };

            const success_msg = try std.fmt.allocPrint(self.allocator, "Session exported to {s} ({d} messages, {d} bytes)", .{ filename, self.messages.items.len, buf.items.len });
            try history_mod.addMessageUnlocked(self, "assistant", success_msg);
        } else if (std.mem.eql(u8, name, "/recipe") or std.mem.startsWith(u8, name, "/recipe ")) {
            const recipe_args = std.mem.trim(u8, name["/recipe".len..], " ");
            if (recipe_args.len == 0 or std.mem.eql(u8, recipe_args, "list")) {
                try history_mod.addMessageUnlocked(self, "system", "📋 Recipe commands: /recipe list | /recipe show <name> | /recipe run <name> [key=val ...]");
            } else if (std.mem.startsWith(u8, recipe_args, "show ")) {
                const recipe_name = recipe_args[5..];
                const msg = try std.fmt.allocPrint(self.allocator, "📋 Showing recipe: {s}", .{recipe_name});
                defer self.allocator.free(msg);
                try history_mod.addMessageUnlocked(self, "system", msg);
            } else if (std.mem.startsWith(u8, recipe_args, "run ")) {
                const rest = recipe_args[4..];
                const msg = try std.fmt.allocPrint(self.allocator, "📋 Running recipe: {s}", .{rest});
                defer self.allocator.free(msg);
                try history_mod.addMessageUnlocked(self, "assistant", msg);
            } else {
                try history_mod.addMessageUnlocked(self, "system", "📋 Usage: /recipe list | /recipe show <name> | /recipe run <name> [key=val ...]");
            }
         }

        ctx.redraw = true;
    }

    fn handleThemeCommandUnlocked(self: *Model, name: []const u8) !bool {
        if (!std.mem.startsWith(u8, name, "/theme")) return false;

        const rest = std.mem.trim(u8, name[6..], " \t\r\n");
        if (rest.len == 0) {
            try history_mod.addMessageUnlocked(self, "system", "Available themes: dark, light, mono");
            return true;
        }

        if (theme_mod.getTheme(rest)) |theme| {
            self.current_theme = theme;
            self.applyThemeStyles();
            const text = try std.fmt.allocPrint(self.allocator, "Theme switched to {s}.", .{theme.name});
            defer self.allocator.free(text);
            try history_mod.addMessageUnlocked(self, "system", text);
            return true;
        }

        const text = try std.fmt.allocPrint(self.allocator, "Unknown theme: {s}", .{rest});
        defer self.allocator.free(text);
        try history_mod.addMessageUnlocked(self, "system", text);
        return true;
    }

    // --- LLM Compaction Support ---
    // Threadlocal refs used by sendToLLMWrapper to access the Model's AIClient
    // without needing a closure (Zig has no closures).
    // Set before calling compactWithLLM, cleared after.
    threadlocal var llm_compact_model_ref: ?*Model = null;

    /// Standalone function matching the sendToLLM signature required by compactWithLLM.
    /// Uses the threadlocal Model ref to access the AIClient and send a summarization prompt.
    fn sendToLLMWrapper(allocator: std.mem.Allocator, prompt: []const u8, model_name: []const u8) anyerror!?[]const u8 {
        _ = model_name; // Use the Model's configured client/model instead

        const model = llm_compact_model_ref orelse {
            std.log.warn("[sendToLLMWrapper] no model ref set, returning null", .{});
            return null;
        };

        var client = model.client orelse {
            std.log.warn("[sendToLLMWrapper] no AIClient available, returning null", .{});
            return null;
        };

        // Send the summarization prompt as a single user message
        const response = client.sendChat(prompt) catch |err| {
            std.log.warn("[sendToLLMWrapper] LLM call failed: {s}, returning null for fallback", .{@errorName(err)});
            return null;
        };

        // Extract text from the first choice
        if (response.choices.len == 0) {
            std.log.warn("[sendToLLMWrapper] empty response choices, returning null", .{});
            return null;
        }

        const content = response.choices[0].message.content orelse {
            std.log.warn("[sendToLLMWrapper] null content in response, returning null", .{});
            return null;
        };

        // Dupe the content (response will be freed by caller)
        return try allocator.dupe(u8, content);
    }

    fn performCompaction(self: *Model) !void {
        if (self.history.items.len <= self.compactor.recent_window) {
            try history_mod.addMessageUnlocked(self, "assistant", "Not enough messages to compact (need more than recent window).");
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

        // Try LLM-based compaction first, fall back to heuristic
        var llm_config = compaction_mod.CompactionConfig{};
        llm_config.llm_compaction_model = self.model_name;

        llm_compact_model_ref = self;
        defer llm_compact_model_ref = null;

        var result = self.compactor.compactWithLLM(compact_messages, llm_config, sendToLLMWrapper) catch |err| blk: {
            std.log.warn("[performCompaction] compactWithLLM failed: {s}, falling back to heuristic", .{@errorName(err)});
            break :blk try self.compactor.compactWithSummary(compact_messages, self.last_compaction_summary);
        };
        defer result.deinit();

        if (result.messages_summarized == 0) {
            try history_mod.addMessageUnlocked(self, "assistant", "No messages were compacted.");
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

        self.context_tokens = token_tracking_mod.estimateContextTokens(self);

        const text = try std.fmt.allocPrint(self.allocator, "Compacted {d} messages. Saved ~{d} tokens. Context: {d}%", .{
            result.messages_summarized,
            result.tokens_saved,
            token_tracking_mod.contextPercent(self),
        });
        try history_mod.addMessageUnlocked(self, "assistant", text);
    }

    pub fn performCompactionAuto(self: *Model) !void {
        if (self.history.items.len <= self.compactor.recent_window) return;

        const ratio = @as(f64, @floatFromInt(self.context_tokens)) /
                      @as(f64, @floatFromInt(self.compactor.max_tokens));

        const compact_messages = try self.allocator.alloc(compaction_mod.CompactMessage, self.history.items.len);
        defer self.allocator.free(compact_messages);
        for (self.history.items, 0..) |msg, i| {
            compact_messages[i] = .{
                .role = msg.role,
                .content = msg.content orelse "",
                .timestamp = null,
            };
        }

        if (ratio >= 0.95) {
            // Full compaction: try LLM-based summarization first, fall back to heuristic
            var llm_config = compaction_mod.CompactionConfig{};
            llm_config.llm_compaction_model = self.model_name;

            llm_compact_model_ref = self;
            defer llm_compact_model_ref = null;

            var result = self.compactor.compactWithLLM(compact_messages, llm_config, sendToLLMWrapper) catch |err| blk: {
                std.log.warn("[performCompactionAuto] compactWithLLM failed: {s}, falling back to heuristic", .{@errorName(err)});
                break :blk try self.compactor.compactWithSummary(compact_messages, self.last_compaction_summary);
            };
            defer result.deinit();

            if (result.messages_summarized == 0) return;

            if (self.last_compaction_summary.len > 0) self.allocator.free(self.last_compaction_summary);
            self.last_compaction_summary = if (result.summary.len > 0) try self.allocator.dupe(u8, result.summary) else "";

            const remove_count = result.messages_summarized;
            for (self.history.items[0..remove_count]) |msg| {
                freeChatMessage(self.allocator, msg);
            }
            const remaining = self.history.items[remove_count..];
            std.mem.copyForwards(core.ChatMessage, self.history.items, remaining);
            self.history.shrinkRetainingCapacity(self.history.items.len - remove_count);
        } else if (ratio >= 0.85) {
            // Light compaction: truncate long messages in-place
            var result = try self.compactor.compactLight(compact_messages);
            defer result.deinit();

            if (result.tokens_saved == 0) return;

            // Update history with truncated content
            for (result.messages, 0..) |comp_msg, i| {
                if (i >= self.history.items.len) break;
                const orig_len: usize = if (self.history.items[i].content) |c| c.len else 0;
                if (comp_msg.content.len < orig_len) {
                    if (self.history.items[i].content) |oc| self.allocator.free(oc);
                    self.history.items[i].content = if (comp_msg.content.len > 0)
                        try self.allocator.dupe(u8, comp_msg.content)
                    else
                        null;
                }
            }
        } else {
            // Micro compaction: prune stale tool outputs only
            var result = try self.compactor.microCompact(compact_messages);
            defer result.deinit();

            if (result.tokens_saved == 0) return;

            // Update stale tool content in history
            for (result.messages, 0..) |comp_msg, i| {
                if (i >= self.history.items.len) break;
                if (!std.mem.eql(u8, self.history.items[i].role, "tool")) continue;
                const orig_len: usize = if (self.history.items[i].content) |c| c.len else 0;
                if (comp_msg.content.len < orig_len) {
                    if (self.history.items[i].content) |oc| self.allocator.free(oc);
                    self.history.items[i].content = if (comp_msg.content.len > 0)
                        try self.allocator.dupe(u8, comp_msg.content)
                    else
                        null;
                }
            }
        }

        self.context_tokens = token_tracking_mod.estimateContextTokens(self);
    }

    /// Scan recent chat messages for file paths and open the first match in
    /// the right-pane preview. Returns true if a file was opened.
    fn previewMostRecentFilePath(self: *Model) bool {
        const items = self.history.items;
        if (items.len == 0) return false;

        // Scan last 20 messages (most recent first)
        const start_idx = if (items.len > 20) items.len - 20 else 0;
        var idx: usize = items.len;
        while (idx > start_idx) {
            idx -= 1;
            const content = items[idx].content orelse continue;
            if (self.extractAndPreviewFilePath(content)) return true;
        }
        return false;
    }

    /// Known source-code extensions used to recognise file paths in text.
    const file_extensions = [_][]const u8{
        ".zig",   ".ts",   ".tsx",  ".js",  ".jsx", ".py",  ".rs",  ".go",
        ".toml",  ".yaml", ".yml",  ".json", ".md",  ".txt", ".sh",  ".bash",
        ".c",     ".h",    ".cpp",  ".hpp", ".java", ".kt",  ".swift",
        ".lua",   ".rb",   ".pl",   ".r",   ".sql",  ".html", ".css",
        ".vue",   ".svelte",
    };

    /// Look for a token that looks like a file path inside `text` and open it
    /// in the preview pane. Returns true on success.
    fn extractAndPreviewFilePath(self: *Model, text: []const u8) bool {
        var iter = std.mem.splitAny(u8, text, " \t\n\r`'\"<>()[]{}:,;");
        while (iter.next()) |token| {
            if (token.len < 5) continue;
            if (std.mem.indexOfScalar(u8, token, '/') == null) continue;

            for (file_extensions) |ext| {
                if (std.mem.endsWith(u8, token, ext)) {
                    const file_path = std.mem.trim(u8, token, "()");
                    if (self.openFilePathPreview(file_path)) return true;
                }
            }
        }
        return false;
    }

    /// Read `file_path` from disk and display it in the right preview pane.
    /// Returns true if the file was successfully opened.
    fn openFilePathPreview(self: *Model, file_path: []const u8) bool {
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return false;
        errdefer self.allocator.free(content);

        // Free previous preview state
        if (self.right_pane_content) |c| self.allocator.free(c);
        if (self.right_pane_title) |t| self.allocator.free(t);

        self.right_pane_content = content;
        self.right_pane_title = self.allocator.dupe(u8, file_path) catch {
            self.allocator.free(content);
            return false;
        };
        self.right_pane_visible = true;

        // Toast notification
        const msg = std.fmt.allocPrint(self.allocator, "Previewing {s}", .{file_path}) catch return true;
        self.toast_stack.push(msg, .info) catch {};

        return true;
    }


};

pub fn onSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model.handleSubmit(value, ctx);
}

fn onPaletteChange(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    try model_palette.setPaletteFilter(model, value);
    ctx.redraw = true;
}

fn onPaletteSubmit(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const ptr = userdata orelse return;
    const model: *Model = @ptrCast(@alignCast(ptr));

    // If user typed text and pressed Enter, check if it matches any item exactly
    if (value.len > 0) {
        var filtered_indices: [widget_palette.max_palette_items]usize = undefined;
        const filtered_count = widget_palette.collectFilteredCommandIndices(model.palette_items, value, filtered_indices[0..]);

        // If there's exactly one match and it's an exact label match, execute it
        if (filtered_count == 1) {
            const item = model.palette_items[filtered_indices[0]];
            if (std.mem.eql(u8, item.label, value) or std.mem.eql(u8, item.action, value)) {
                try model_palette.closePalette(model, ctx);
                try model.executePaletteCommand(item.action, ctx);
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

/// Find the first occurrence of `symbol` in file content as a whole word, returning 0-based line/character.
fn findSymbolPosition(content: []const u8, symbol: []const u8) ?struct { line: u32, character: u32 } {
    if (symbol.len == 0 or content.len == 0) return null;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line += 1;
            col = 0;
            continue;
        }
        if (i + symbol.len <= content.len and std.mem.eql(u8, content[i .. i + symbol.len], symbol)) {
            const before_ok = i == 0 or !std.ascii.isAlphanumeric(content[i - 1]) and content[i - 1] != '_';
            const after_idx = i + symbol.len;
            const after_ok = after_idx >= content.len or !std.ascii.isAlphanumeric(content[after_idx]) and content[after_idx] != '_';
            if (before_ok and after_ok) {
                return .{ .line = line, .character = col };
            }
        }
        col += 1;
    }
    return null;
}

/// Strip "file://" or "file:///" prefix from a URI for display.
fn stripFileUriPrefix(uri: []const u8) []const u8 {
    if (std.mem.startsWith(u8, uri, "file:///")) {
        return uri["file:///".len..];
    }
    if (std.mem.startsWith(u8, uri, "file://")) {
        return uri["file://".len..];
    }
    return uri;
}

// ---------------------------------------------------------------------------
// Input History
// ---------------------------------------------------------------------------

/// Maximum number of input history entries to keep
const max_input_history = 1000;

/// Save a user input to history (deduplicated, most recent first)
fn saveInputHistory(self: *Model, input: []const u8) void {
    if (input.len == 0) return;

    // Don't duplicate if same as last entry
    if (self.input_history.items.len > 0) {
        if (std.mem.eql(u8, self.input_history.items[self.input_history.items.len - 1], input)) {
            return;
        }
    }

    const dupe = self.allocator.dupe(u8, input) catch return;
    self.input_history.append(self.allocator, dupe) catch {
        self.allocator.free(dupe);
        return;
    };

    // Evict oldest entries if over limit
    while (self.input_history.items.len > max_input_history) {
        const old = self.input_history.orderedRemove(0);
        self.allocator.free(old);
    }

    // Reset navigation index
    self.input_history_index = 0;
}

/// Navigate up in input history (older entries)
fn inputHistoryUp(self: *Model) void {
    if (self.input_history.items.len == 0) return;

    // Save current input as draft when first entering history
    if (self.input_history_index == 0) {
        const draft = self.input.buf.dupe() catch return;
        if (self.input_history_draft.len > 0) self.allocator.free(self.input_history_draft);
        self.input_history_draft = draft;
    }

    // Move to older entry (index increases toward end of list)
    if (self.input_history_index < self.input_history.items.len) {
        self.input_history_index += 1;
        const entry = self.input_history.items[self.input_history.items.len - self.input_history_index];
        self.input.buf.clearAndFree();
        self.input.buf.insertSliceAtCursor(entry) catch {};
    }
}

/// Navigate down in input history (newer entries, back to draft)
fn inputHistoryDown(self: *Model) void {
    if (self.input_history_index == 0) return;

    self.input_history_index -= 1;

    if (self.input_history_index == 0) {
        // Restore draft
        self.input.buf.clearAndFree();
        if (self.input_history_draft.len > 0) {
            self.input.buf.insertSliceAtCursor(self.input_history_draft) catch {};
        }
    } else {
        const entry = self.input_history.items[self.input_history.items.len - self.input_history_index];
        self.input.buf.clearAndFree();
        self.input.buf.insertSliceAtCursor(entry) catch {};
    }
}

/// Start reverse-i-search
fn startISearch(self: *Model) void {
    self.isearch_active = true;
    self.isearch_query.clearRetainingCapacity();
    self.isearch_match_index = null;
}

/// Stop reverse-i-search and restore input
fn stopISearch(self: *Model) void {
    self.isearch_active = false;
    self.isearch_query.clearRetainingCapacity();
    self.isearch_match_index = null;
}

/// Update reverse-i-search with a new character or query change
fn updateISearch(self: *Model) void {
    if (!self.isearch_active) return;
    if (self.isearch_query.items.len == 0) {
        self.isearch_match_index = null;
        return;
    }

    const query = self.isearch_query.items;

    // Search from most recent to oldest
    var i: usize = 0;
    while (i < self.input_history.items.len) : (i += 1) {
        const idx = self.input_history.items.len - 1 - i;
        if (std.mem.indexOf(u8, self.input_history.items[idx], query) != null) {
            self.isearch_match_index = idx;
            // Load match into input
            self.input.buf.clearAndFree();
            self.input.buf.insertSliceAtCursor(self.input_history.items[idx]) catch {};
            return;
        }
    }
    self.isearch_match_index = null;
}

/// Find next match in reverse-i-search (Ctrl+S again to cycle)
fn isearchNext(self: *Model) void {
    if (!self.isearch_active or self.input_history.items.len == 0) return;
    const query = self.isearch_query.items;
    if (query.len == 0) return;

    // Start searching from one after current match
    const start: usize = if (self.isearch_match_index) |current|
        if (current > 0) current - 1 else self.input_history.items.len - 1
    else
        self.input_history.items.len - 1;

    var i: usize = start;
    while (true) : (i = if (i > 0) i - 1 else self.input_history.items.len - 1) {
        if (std.mem.indexOf(u8, self.input_history.items[i], query) != null) {
            self.isearch_match_index = i;
            self.input.buf.clearAndFree();
            self.input.buf.insertSliceAtCursor(self.input_history.items[i]) catch {};
            return;
        }
        if (i == start) break; // wrapped around
    }
}

pub fn runWithOptions(allocator: std.mem.Allocator, options: Options) !void {
    var model = try Model.create(allocator, options);
    defer model.destroy();
    try model.run();
}
