/// Syntax highlighting module for crushcode TUI
/// Provides tree-sitter-based syntax highlighting with vaxis integration
pub const highlighter = @import("highlighter.zig");
pub const tree_sitter = @import("tree_sitter.zig");
pub const themes = @import("themes.zig");
pub const vaxis_renderer = @import("vaxis_renderer.zig");

// Re-export main types for convenience
pub const SyntaxHighlighter = highlighter.SyntaxHighlighter;
pub const HighlightedCode = highlighter.HighlightedCode;
pub const Theme = themes.Theme;
pub const VaxisRenderer = vaxis_renderer.VaxisRenderer;
