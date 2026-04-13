const std = @import("std");
const file_compat = @import("file_compat");
const array_list_compat = @import("array_list_compat");

// Import AI types
const core_api = @import("core_api");
const AIClient = core_api.AIClient;
const ChatMessage = core_api.ChatMessage;
const markdown_mod = @import("markdown_renderer");

// Re-export all TUI types for convenient access
pub const Terminal = @import("terminal.zig").Terminal;
pub const Event = @import("event.zig").Event;
pub const Key = @import("event.zig").Key;
pub const Modifiers = @import("event.zig").Modifiers;
pub const Parser = @import("parser.zig").Parser;
pub const InputReader = @import("input.zig").InputReader;

// Phase 2 — Double-buffered screen with diff-based rendering
pub const NamedColor = @import("screen.zig").NamedColor;
pub const Color = @import("screen.zig").Color;
pub const Style = @import("screen.zig").Style;
pub const Cell = @import("screen.zig").Cell;
pub const Screen = @import("screen.zig").Screen;

// Phase 3 — Layout engine (flexbox-style)
pub const Rect = @import("layout.zig").Rect;
pub const Padding = @import("layout.zig").Padding;
pub const FlexDirection = @import("layout.zig").FlexDirection;
pub const SizeHint = @import("layout.zig").SizeHint;
pub const LayoutNode = @import("layout.zig").LayoutNode;
pub const LayoutEngine = @import("layout.zig").LayoutEngine;

// Phase 4 — UI Components
pub const Rune = @import("components.zig").Rune;
pub const Line = @import("components.zig").Line;
pub const Scrollback = @import("components.zig").Scrollback;
pub const InputBox = @import("components.zig").InputBox;
pub const Spinner = @import("components.zig").Spinner;
pub const ProgressBar = @import("components.zig").ProgressBar;
pub const renderMarkdown = @import("components.zig").renderMarkdown;

// Phase 5 — Animations
pub const CursorState = @import("animate.zig").CursorState;
pub const CursorBlink = @import("animate.zig").CursorBlink;
pub const StreamingText = @import("animate.zig").StreamingText;
pub const FadeTransition = @import("animate.zig").FadeTransition;
pub const Typewriter = @import("animate.zig").Typewriter;
pub const AnimationManager = @import("animate.zig").AnimationManager;

const MAX_HISTORY = 1000;

// ============================================================================
// TUIApp — High-level wrapper combining all TUI components
// ============================================================================

pub const TUIApp = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    screen: Screen,
    scrollback: Scrollback,
    input_box: InputBox,
    input_reader: InputReader,
    client: ?*AIClient,

    // Conversation history for multi-turn chat
    messages: array_list_compat.ArrayList(ChatMessage),

    // Command history for Up/Down navigation
    input_history: array_list_compat.ArrayList([]const u8),
    history_index: usize,
    saved_input: []const u8,

    // Token tracking
    total_input_tokens: u64,
    total_output_tokens: u64,
    request_count: u32,

    // Provider info for display
    provider_name: []const u8,
    model_name: []const u8,

    // Exit flag
    should_exit: bool,

    pub fn init(allocator: std.mem.Allocator, client: ?*AIClient) !TUIApp {
        const terminal = try Terminal.init(allocator);
        const size = terminal.getSize();
        const screen = try Screen.init(allocator, size.width, size.height);
        const scrollback = try Scrollback.init(allocator, 200, 1000);
        const input_box = InputBox.init(allocator);
        const input_reader = InputReader.init(allocator, terminal.tty_in);

        return .{
            .allocator = allocator,
            .terminal = terminal,
            .screen = screen,
            .scrollback = scrollback,
            .input_box = input_box,
            .input_reader = input_reader,
            .client = client,
            .messages = array_list_compat.ArrayList(ChatMessage).init(allocator),
            .input_history = array_list_compat.ArrayList([]const u8).init(allocator),
            .history_index = 0,
            .saved_input = "",
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .request_count = 0,
            .provider_name = "unknown",
            .model_name = "unknown",
            .should_exit = false,
        };
    }

    pub fn deinit(self: *TUIApp) void {
        // Free conversation messages
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.name);
                    self.allocator.free(tc.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.messages.deinit();

        // Free input history
        for (self.input_history.items) |entry| {
            self.allocator.free(entry);
        }
        self.input_history.deinit();

        self.input_reader.deinit();
        self.input_box.deinit();
        self.scrollback.deinit();
        self.screen.deinit();
        self.terminal.deinit();
    }

    pub fn setProviderInfo(self: *TUIApp, provider: []const u8, model: []const u8) void {
        self.provider_name = provider;
        self.model_name = model;
    }

    pub fn addLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .default, .default, .{});
    }

    pub fn addUserLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .default, .default, .{ .bold = true });
    }

    pub fn addAssistantLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .default, .default, .{});
    }

    pub fn addErrorLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .{ .named = .red }, .default, .{ .bold = true });
    }

    pub fn addDimmedLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .default, .default, .{ .dim = true });
    }

    /// Clear all scrollback content
    pub fn clearScrollback(self: *TUIApp) void {
        while (self.scrollback.lines.pop()) |line| {
            var mutable_line = line;
            mutable_line.deinit(self.allocator);
        }
    }

    /// Clear conversation history (messages + token counters)
    pub fn clearHistory(self: *TUIApp) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.name);
                    self.allocator.free(tc.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.messages.clearRetainingCapacity();
        self.total_input_tokens = 0;
        self.total_output_tokens = 0;
        self.request_count = 0;
    }

    pub fn render(self: *TUIApp) !void {
        self.screen.clear();
        const h = self.screen.height;
        if (h > 0) {
            const rect = Rect{ .x = 0, .y = 0, .w = self.screen.width, .h = h };
            self.scrollback.render(&self.screen, rect);

            // Render input area at bottom
            const input_rect = Rect{ .x = 0, .y = h - 1, .w = self.screen.width, .h = 1 };
            self.input_box.render(&self.screen, input_rect);
        }

        try self.screen.render(self.terminal.writer());
        self.terminal.flush();
    }

    // ========================================================================
    // Keyboard handling
    // ========================================================================

    /// Process a single key event, returns true if app should continue
    pub fn handleKey(self: *TUIApp, event: Event) !bool {
        if (self.should_exit) return false;

        switch (event) {
            .key_press => |kp| {
                const key = kp.key;
                const mods = kp.mods;

                switch (key) {
                    .character => |ch| {
                        if (mods.ctrl) {
                            return self.handleCtrlKey(ch);
                        } else if (mods.alt) {
                            // Alt+key shortcuts (future: word navigation)
                        } else {
                            // Regular character input
                            var byte: [1]u8 = undefined;
                            byte[0] = @intCast(ch);
                            self.input_box.insert(&byte) catch {};
                        }
                    },
                    .enter => {
                        try self.handleSubmit();
                    },
                    .escape => {
                        return false; // Exit on Esc
                    },
                    .backspace => {
                        self.input_box.backspace();
                    },
                    .tab => {
                        // Future: autocomplete
                    },
                    .up => {
                        self.historyPrev();
                    },
                    .down => {
                        self.historyNext();
                    },
                    .left => {
                        self.input_box.moveLeft();
                    },
                    .right => {
                        self.input_box.moveRight();
                    },
                    .home => {
                        self.input_box.moveHome();
                    },
                    .end => {
                        self.input_box.moveEnd();
                    },
                    .delete => {
                        self.input_box.delete();
                    },
                    .page_up => {
                        self.scrollback.scrollUp(10);
                    },
                    .page_down => {
                        self.scrollback.scrollDown(10);
                    },
                    else => {
                        // Ignore F-keys etc.
                    },
                }
            },
            .resize => |rs| {
                self.screen.resize(rs.width, rs.height) catch {};
            },
            else => {},
        }
        return true;
    }

    /// Handle Ctrl+key shortcuts
    fn handleCtrlKey(self: *TUIApp, ch: u21) bool {
        const byte = @as(u8, @intCast(ch));
        switch (byte) {
            'c', 'C' => return false, // Exit
            'd', 'D' => return false, // Exit
            'l', 'L' => {
                // Clear screen
                self.clearScrollback();
                return true;
            },
            'g', 'G' => {
                // Show help
                self.showHelp();
                return true;
            },
            'k', 'K' => {
                // Kill to end of line
                self.killToEnd();
                return true;
            },
            'u', 'U' => {
                // Kill to start of line
                self.killToStart();
                return true;
            },
            'a', 'A' => {
                // Move to beginning of line (readline)
                self.input_box.moveHome();
                return true;
            },
            'e', 'E' => {
                // Move to end of line (readline)
                self.input_box.moveEnd();
                return true;
            },
            'n', 'N' => {
                // New session — clear history
                self.clearScrollback();
                self.clearHistory();
                self.addDimmedLine("--- New Session ---") catch {};
                return true;
            },
            else => return true,
        }
    }

    /// Kill text from cursor to end of line
    fn killToEnd(self: *TUIApp) void {
        const cursor = self.input_box.cursor;
        const len = self.input_box.text.items.len;
        if (cursor < len) {
            // Remove characters from cursor to end
            var i: usize = len;
            while (i > cursor) : (i -= 1) {
                _ = self.input_box.text.orderedRemove(cursor);
            }
        }
    }

    /// Kill text from start of line to cursor
    fn killToStart(self: *TUIApp) void {
        var i: usize = self.input_box.cursor;
        while (i > 0) : (i -= 1) {
            _ = self.input_box.text.orderedRemove(0);
        }
        self.input_box.cursor = 0;
    }

    /// Navigate to previous history entry
    fn historyPrev(self: *TUIApp) void {
        if (self.input_history.items.len == 0) return;

        // Save current input if at the bottom
        if (self.history_index == self.input_history.items.len) {
            self.saved_input = self.allocator.dupe(u8, self.input_box.getText()) catch "";
        }

        if (self.history_index > 0) {
            self.history_index -= 1;
            const entry = self.input_history.items[self.history_index];
            self.input_box.clear();
            self.input_box.insert(entry) catch {};
        }
    }

    /// Navigate to next history entry
    fn historyNext(self: *TUIApp) void {
        if (self.input_history.items.len == 0) return;

        if (self.history_index < self.input_history.items.len - 1) {
            self.history_index += 1;
            const entry = self.input_history.items[self.history_index];
            self.input_box.clear();
            self.input_box.insert(entry) catch {};
        } else if (self.history_index == self.input_history.items.len - 1) {
            self.history_index = self.input_history.items.len;
            self.input_box.clear();
            if (self.saved_input.len > 0) {
                self.input_box.insert(self.saved_input) catch {};
                self.allocator.free(self.saved_input);
                self.saved_input = "";
            }
        }
    }

    /// Submit current input
    fn handleSubmit(self: *TUIApp) !void {
        const input = self.input_box.getText();
        if (input.len == 0) return;

        // Add to command history
        const input_copy = self.allocator.dupe(u8, input) catch return;
        self.input_history.append(input_copy) catch {};
        self.history_index = self.input_history.items.len;

        // Free saved input if any
        if (self.saved_input.len > 0) {
            self.allocator.free(self.saved_input);
            self.saved_input = "";
        }

        // Display user input
        try self.addUserLine(input);
        self.input_box.clear();

        // Check for slash commands
        if (input[0] == '/') {
            try self.handleCommand(input);
        } else {
            try self.sendToAI(input);
        }
    }

    /// Send message to AI with conversation history
    fn sendToAI(self: *TUIApp, user_message: []const u8) !void {
        const client = self.client orelse {
            try self.addErrorLine("No AI client connected");
            return;
        };

        // Append user message to history
        const user_role = try self.allocator.dupe(u8, "user");
        const user_content = try self.allocator.dupe(u8, user_message);
        try self.messages.append(.{
            .role = user_role,
            .content = user_content,
            .tool_call_id = null,
            .tool_calls = null,
        });

        // Show thinking indicator
        try self.addDimmedLine("Thinking...");

        // Render to show "Thinking..." before blocking call
        try self.render();

        // Send with history
        const response = client.sendChatWithHistory(self.messages.items) catch |err| {
            // Remove "Thinking..." line
            _ = self.scrollback.popLastLine();
            try self.addErrorLine(@errorName(err));
            return;
        };

        // Remove "Thinking..." line
        _ = self.scrollback.popLastLine();

        if (response.choices.len == 0) {
            try self.addErrorLine("Empty response from AI");
            return;
        }

        const choice = response.choices[0];
        const content = choice.message.content orelse "";

        // Append assistant message to history
        const assistant_role = try self.allocator.dupe(u8, "assistant");
        const assistant_content = try self.allocator.dupe(u8, content);
        try self.messages.append(.{
            .role = assistant_role,
            .content = assistant_content,
            .tool_call_id = null,
            .tool_calls = null,
        });

        // Display response with markdown rendering
        if (content.len > 0) {
            // Use markdown renderer for each line
            var pos: usize = 0;
            while (pos < content.len) {
                const eol = if (std.mem.indexOfScalar(u8, content[pos..], '\n')) |i| pos + i else content.len;
                const line_slice = content[pos..eol];
                // Use pushLine directly for raw content (markdown formatting via ANSI)
                try self.scrollback.pushLine(line_slice, .default, .default, .{});
                pos = eol + 1;
            }
        }

        // Show token usage
        if (response.usage) |usage| {
            self.total_input_tokens += usage.prompt_tokens;
            self.total_output_tokens += usage.completion_tokens;
            self.request_count += 1;
            const usage_text = try std.fmt.allocPrint(self.allocator, "({d} in / {d} out | total: {d})", .{
                usage.prompt_tokens,
                usage.completion_tokens,
                self.total_input_tokens + self.total_output_tokens,
            });
            defer self.allocator.free(usage_text);
            try self.addDimmedLine(usage_text);
        }
    }

    /// Handle slash commands
    fn handleCommand(self: *TUIApp, cmd: []const u8) !void {
        const trimmed = std.mem.trim(u8, cmd, " \t");
        if (std.mem.eql(u8, trimmed, "/help") or std.mem.eql(u8, trimmed, "/h")) {
            self.showHelp();
        } else if (std.mem.eql(u8, trimmed, "/clear") or std.mem.eql(u8, trimmed, "/c")) {
            self.clearScrollback();
        } else if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q")) {
            self.should_exit = true;
        } else if (std.mem.eql(u8, trimmed, "/version") or std.mem.eql(u8, trimmed, "/v")) {
            try self.addAssistantLine("Crushcode v0.2.2");
        } else if (std.mem.eql(u8, trimmed, "/usage") or std.mem.eql(u8, trimmed, "/cost")) {
            const text = try std.fmt.allocPrint(self.allocator, "Requests: {d} | Tokens: {d} in / {d} out", .{
                self.request_count,
                self.total_input_tokens,
                self.total_output_tokens,
            });
            defer self.allocator.free(text);
            try self.addAssistantLine(text);
        } else if (std.mem.eql(u8, trimmed, "/status") or std.mem.eql(u8, trimmed, "/s")) {
            const text = try std.fmt.allocPrint(self.allocator, "Provider: {s} | Model: {s} | Messages: {d} | Turns: {d}", .{
                self.provider_name,
                self.model_name,
                self.messages.items.len,
                self.request_count,
            });
            defer self.allocator.free(text);
            try self.addAssistantLine(text);
        } else if (std.mem.eql(u8, trimmed, "/tokens") or std.mem.eql(u8, trimmed, "/t")) {
            const text = try std.fmt.allocPrint(self.allocator, "Input: {d} | Output: {d} | Total: {d}", .{
                self.total_input_tokens,
                self.total_output_tokens,
                self.total_input_tokens + self.total_output_tokens,
            });
            defer self.allocator.free(text);
            try self.addAssistantLine(text);
        } else {
            try self.addErrorLine("Unknown command. Type /help for available commands.");
        }
    }

    /// Show help with keyboard shortcuts
    fn showHelp(self: *TUIApp) void {
        self.addAssistantLine("Commands:") catch {};
        self.addAssistantLine("  /help (/h)    Show this help") catch {};
        self.addAssistantLine("  /clear (/c)   Clear screen") catch {};
        self.addAssistantLine("  /status (/s)  Show session status") catch {};
        self.addAssistantLine("  /usage        Show token usage") catch {};
        self.addAssistantLine("  /tokens (/t)  Show token counts") catch {};
        self.addAssistantLine("  /version (/v) Show version") catch {};
        self.addAssistantLine("  /exit (/q)    Exit") catch {};
        self.addAssistantLine("") catch {};
        self.addAssistantLine("Keyboard Shortcuts:") catch {};
        self.addAssistantLine("  Ctrl+C / Ctrl+D / Esc  Exit") catch {};
        self.addAssistantLine("  Ctrl+L    Clear screen") catch {};
        self.addAssistantLine("  Ctrl+N    New session") catch {};
        self.addAssistantLine("  Ctrl+K    Kill to end of line") catch {};
        self.addAssistantLine("  Ctrl+U    Kill to start of line") catch {};
        self.addAssistantLine("  Ctrl+A    Move to start") catch {};
        self.addAssistantLine("  Ctrl+E    Move to end") catch {};
        self.addAssistantLine("  Up/Down   Command history") catch {};
        self.addAssistantLine("  PgUp/Dn   Scroll messages") catch {};
    }
};

/// Run interactive TUI with AI client for real chat
pub fn runTUIWithClient(allocator: std.mem.Allocator, client: *AIClient) !void {
    var app = try TUIApp.init(allocator, client);
    defer app.deinit();

    // Set provider/model info from client
    app.provider_name = client.provider.name;
    app.model_name = client.model;

    // Welcome banner
    try app.addLine("╔══════════════════════════════════════════════════╗");
    try app.addLine("║            Crushcode v0.2.2                     ║");
    try app.addLine("║       Zig-based AI Coding Assistant              ║");
    try app.addLine("╚══════════════════════════════════════════════════╝");
    try app.addLine("");

    const info = try std.fmt.allocPrint(allocator, "Provider: {s} | Model: {s}", .{ app.provider_name, app.model_name });
    defer allocator.free(info);
    try app.addLine(info);
    try app.addLine("Ctrl+G for help | Ctrl+L clear | Up/Down history | Esc exit");
    try app.addLine("");

    try app.render();

    // Main event loop
    var running = true;
    while (running) {
        if (app.input_reader.readEvent()) |event| {
            running = try app.handleKey(event);
            try app.render();
        }
    }

    // Exit message (rendered after terminal restore)
    const out = file_compat.File.stdout().writer();
    try out.print("\n", .{});

    // Print session summary after terminal restored
    if (app.request_count > 0) {
        try out.print("Session: {d} requests | {d} tokens in / {d} out\n", .{
            app.request_count,
            app.total_input_tokens,
            app.total_output_tokens,
        });
    }
}

/// Run interactive TUI with event loop using a prompt function for AI responses
pub fn runTUI(allocator: std.mem.Allocator, prompt_fn: anytype) !void {
    var app = try TUIApp.init(allocator, null);
    defer app.deinit();

    try app.addLine("╔══════════════════════════════════════════════════╗");
    try app.addLine("║            Crushcode v0.2.2                     ║");
    try app.addLine("╚══════════════════════════════════════════════════╝");
    try app.addLine("");
    try app.addLine("No AI client. Run 'crushcode chat' for AI mode.");
    try app.addLine("Type /help for commands, Esc to exit.");
    try app.addLine("");

    try app.render();

    var running = true;
    while (running) {
        if (app.input_reader.readEvent()) |event| {
            switch (event) {
                .key_press => |kp| {
                    switch (kp.key) {
                        .enter => {
                            const input = app.input_box.getText();
                            if (input.len > 0) {
                                try app.addUserLine(input);

                                if (input[0] == '/') {
                                    try app.handleCommand(input);
                                } else {
                                    const response = prompt_fn(input) catch |err| {
                                        try app.addErrorLine(@errorName(err));
                                        app.input_box.clear();
                                        try app.render();
                                        continue;
                                    };
                                    try app.addAssistantLine(response);
                                }
                                app.input_box.clear();
                            }
                        },
                        else => {
                            running = try app.handleKey(event);
                        },
                    }
                },
                else => {
                    running = try app.handleKey(event);
                },
            }
            try app.render();
        }
    }

    const out = file_compat.File.stdout().writer();
    try out.print("\n", .{});
}
