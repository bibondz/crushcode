const std = @import("std");
const file_compat = @import("file_compat");

// Import the AI client type
const AIClient = @import("core_api").AIClient;

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
    client: ?*AIClient, // AI client for chat

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
        };
    }

    pub fn deinit(self: *TUIApp) void {
        self.input_reader.deinit();
        self.input_box.deinit();
        self.scrollback.deinit();
        self.screen.deinit();
        self.terminal.deinit();
    }

    pub fn addLine(self: *TUIApp, text: []const u8) !void {
        try self.scrollback.pushLine(text, .default, .default, .{});
    }

    pub fn addUserLine(self: *TUIApp, text: []const u8) !void {
        // User input in default (simpler than trying to use NamedColor)
        try self.scrollback.pushLine(text, .default, .default, .{ .bold = true });
    }

    pub fn addAssistantLine(self: *TUIApp, text: []const u8) !void {
        // Assistant response in default (simpler)
        try self.scrollback.pushLine(text, .default, .default, .{});
    }

    pub fn addErrorLine(self: *TUIApp, text: []const u8) !void {
        // Error in default (simpler)
        try self.scrollback.pushLine(text, .default, .default, .{});
    }

    /// Clear all scrollback content
    pub fn clearScrollback(self: *TUIApp) void {
        while (self.scrollback.lines.pop()) |line| {
            // Line is *const Line, need to make mutable copy for deinit
            var mutable_line = line;
            mutable_line.deinit(self.allocator);
        }
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

    /// Process a single key event, returns true if app should continue
    pub fn handleKey(self: *TUIApp, event: Event) !bool {
        switch (event) {
            .key_press => |kp| {
                const key = kp.key;
                const mods = kp.mods;

                // Handle Ctrl+C / Ctrl+D to exit
                if (mods.ctrl and key == .character) {
                    if (kp.mods.ctrl and key == .character) {
                        // Ctrl+C
                        return false;
                    }
                }

                switch (key) {
                    .character => |ch| {
                        if (mods.ctrl) {
                            // Ctrl+key shortcuts
                            if (ch == 'c' or ch == 'C') {
                                return false; // Exit on Ctrl+C
                            }
                            if (ch == 'd' or ch == 'D') {
                                return false; // Exit on Ctrl+D
                            }
                            if (ch == 'l' or ch == 'L') {
                                // Clear screen
                                self.clearScrollback();
                                return true;
                            }
                        } else {
                            // Regular character input - insert byte
                            var byte: [1]u8 = undefined;
                            byte[0] = @truncate(ch);
                            self.input_box.insert(&byte) catch {};
                        }
                    },
                    .enter => {
                        // Get input and process it
                        const input = self.input_box.getText();
                        if (input.len > 0) {
                            try self.addUserLine(input);
                            try self.processInput(input);
                            self.input_box.clear();
                        }
                    },
                    .escape => {
                        // Check for Escape key (or Alt+key)
                        return false;
                    },
                    .backspace => {
                        self.input_box.backspace();
                    },
                    .tab => {
                        // Maybe autocomplete in the future
                    },
                    .up => {
                        // History navigation (future)
                    },
                    .down => {
                        // History navigation (future)
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
                    else => {
                        // Ignore other keys for now
                    },
                }
            },
            .resize => |rs| {
                // Resize screen (ignore errors)
                self.screen.resize(rs.width, rs.height) catch {};
            },
            else => {},
        }
        return true;
    }

    /// Process user input - commands or chat messages
    fn processInput(self: *TUIApp, input: []const u8) !void {
        // Check for commands
        if (input.len > 0 and input[0] == '/') {
            try self.handleCommand(input);
        } else {
            // Send to AI if client is available
            try self.addUserLine(input);

            if (self.client) |client| {
                // Add user message immediately
                try self.addUserLine(input);

                // Send to AI and get response (blocking call)
                const response = client.sendChat(input) catch |err| {
                    try self.addErrorLine("AI Error: ");
                    try self.addErrorLine(@errorName(err));
                    return;
                };

                // Display AI response - get content from first choice
                const ai_content = if (response.choices.len > 0)
                    response.choices[0].message.content orelse "(empty content)"
                else
                    "(empty response)";

                try self.addAssistantLine(ai_content);
            } else {
                try self.addAssistantLine("(No AI client - run with 'crushcode tui' to connect to AI)");
            }
        }
    }

    /// Handle slash commands
    fn handleCommand(self: *TUIApp, cmd: []const u8) !void {
        const trimmed = std.mem.trim(u8, cmd, " \t");
        if (std.mem.eql(u8, trimmed, "/help") or std.mem.eql(u8, trimmed, "/h")) {
            try self.addAssistantLine("Commands:");
            try self.addAssistantLine("  /help   - Show this help");
            try self.addAssistantLine("  /clear  - Clear screen");
            try self.addAssistantLine("  /exit   - Exit TUI");
            try self.addAssistantLine("  /version - Show version");
        } else if (std.mem.eql(u8, trimmed, "/clear") or std.mem.eql(u8, trimmed, "/c")) {
            self.clearScrollback();
        } else if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q")) {
            try self.addAssistantLine("Goodbye!");
        } else if (std.mem.eql(u8, trimmed, "/version") or std.mem.eql(u8, trimmed, "/v")) {
            try self.addAssistantLine("Crushcode TUI v0.1.0");
            try self.addAssistantLine("Zig-based AI coding assistant");
        } else {
            try self.addErrorLine("Unknown command");
            try self.addAssistantLine("Type /help for available commands");
        }
    }
};

/// Run interactive TUI with event loop (legacy, no AI client)
pub fn runTUI(allocator: std.mem.Allocator, prompt_fn: anytype) !void {
    _ = prompt_fn; // TODO: integrate AI chat

    var app = try TUIApp.init(allocator, null);
    defer app.deinit();

    // Welcome message
    try app.addLine("═══════════════════════════════════════════════════");
    try app.addLine("              Crushcode TUI v0.1.0");
    try app.addLine("═══════════════════════════════════════════════════");
    try app.addLine("");
    try app.addLine("Type your message and press Enter to chat.");
    try app.addLine("Type /help for commands, /exit to quit.");
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
    try out.print("\nThanks for using Crushcode TUI!\n", .{});
}

/// Run interactive TUI with AI client for real chat
pub fn runTUIWithClient(allocator: std.mem.Allocator, client: *AIClient) !void {
    var app = try TUIApp.init(allocator, client);
    defer app.deinit();

    // Welcome message with AI info
    try app.addLine("═══════════════════════════════════════════════════");
    try app.addLine("              Crushcode TUI v0.1.0");
    try app.addLine("═══════════════════════════════════════════════════");
    try app.addLine("");
    try app.addLine("AI Chat Mode - Connected to your configured provider");
    try app.addLine("Type your message and press Enter to chat.");
    try app.addLine("Type /help for commands, /exit to quit.");
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
    try out.print("\nThanks for using Crushcode TUI!\n", .{});
}
