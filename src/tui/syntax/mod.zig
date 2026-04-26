/// Syntax highlighting module for crushcode TUI
/// NOTE: This entire directory is NOT compiled (not in build.zig).
/// Production highlighting uses src/tui/markdown.zig (regex-based, 20 languages).
/// This directory is preserved for future libvaxis integration.
/// tree_sitter.zig removed 2026-04-27 — AST replaced by 3-tier (Regex + LSP + sg binary).
pub const highlighter = @import("highlighter.zig");
pub const themes = @import("themes.zig");
pub const vaxis_renderer = @import("vaxis_renderer.zig");

// Re-export main types for convenience
pub const Theme = themes.Theme;
pub const VaxisRenderer = vaxis_renderer.VaxisRenderer;
