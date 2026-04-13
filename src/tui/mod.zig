const std = @import("std");
const file_compat = @import("file_compat");

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

// Phase 5 — Animations (typing indicator, streaming, transitions)
pub const CursorState = @import("animate.zig").CursorState;
pub const CursorBlink = @import("animate.zig").CursorBlink;
pub const StreamingText = @import("animate.zig").StreamingText;
pub const FadeTransition = @import("animate.zig").FadeTransition;
pub const Typewriter = @import("animate.zig").Typewriter;
pub const AnimationManager = @import("animate.zig").AnimationManager;

// Phase 6 — High-level application wrapper
pub const TUIApp = @import("app.zig").TUIApp;
pub const runTUI = @import("app.zig").runTUI;
pub const runTUIWithClient = @import("app.zig").runTUIWithClient;
