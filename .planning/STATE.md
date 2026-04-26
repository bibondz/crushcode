# State: Crushcode v1.3.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-26
**Commit:** b7cbb43
**Stats:** ~265 `.zig` files, ~105K lines
**Remote:** git@github.com:bibondz/crushcode.git
**Branch:** `master`

---

## Project Reference

**Core Value:** Ship a self-improving AI coding assistant in Zig that learns from usage, remembers across sessions, and produces production-quality code.

**Build:** `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zigcache`
**Test:** `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zigcache`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v1.3.0 TUI Overhaul — COMPLETE |
| Phase | All TUI backlog items shipped |
| Status | ✅ Clean build, all tests pass |
| Code Version | 1.3.0 (uncommitted version bump) |
| Last Tag | v1.2.0 |

---

## v1.2.0 — TUI Foundation (commit 032bec3)

| Feature | Description | Status |
|---------|-------------|--------|
| Virtual Scroll | ScrollView builder pattern — only visible messages get widget objects (~80% fewer arena allocations) | ✅ Done |
| Enhanced Status Bar | provider/model prefix + [CRUSH]/[DELEGATE]/[SCROLL] mode tags | ✅ Done |
| Contextual Spinner | "Thinking..."/"Writing..."/"Running {tool}..." phrases on AnimatedSpinner | ✅ Done |
| Tool Markers | 🔧 pending, ✅ success (N lines), ❌ failed in ToolCallWidget | ✅ Done |
| Palette Overhaul | Unified PaletteItem (command/model/file/session), fuzzy match highlighting, model switcher, file quick-open, 120-char wide popup | ✅ Done |
| Test Harness | 26 inline tests for TUI widgets | ✅ Done |
| Typewriter Fix | Re-enable animation with thread-safe lock ordering | ✅ Done |
| Split Pane | Right pane for file preview, Ctrl+\ toggle, `/preview <file>` | ✅ Done |
| File Tree Sidebar | CWD listing in sidebar "Project" section, Ctrl+R, `/refresh` | ✅ Done |
| Fuzzy Palette | Fuzzy scoring, sorted results, Tab completion | ✅ Done |

---

## v1.3.0 — TUI Polish (commits f6c4c4f–b7cbb43)

| Feature | Description | Commit |
|---------|-------------|--------|
| 6 Themes | dark, light, mono + Catppuccin Mocha, Nord, Dracula (truecolor RGB) | f6c4c4f |
| Session Sparkline | ▁▂▃▄▅▆▇█ bar chart of per-turn token usage in sidebar | aca4554 |
| Syntax Preview | File preview with syntax highlighting (keywords, strings, comments, numbers, types) | ed8a108 |
| Dialog Backdrop | Dimmed backdrop behind all overlay dialogs (palette, permission, diff, session, help) | c1f18cc |
| Click-to-Preview | Mouse click in message area scans for file paths, opens in right pane | b7cbb43 |
| Multi-line Input | Shift+Enter newlines, Ctrl+X Ctrl+E external editor (pre-existing) | — |
| Theme sidebar hints | /theme catppuccin, /theme nord, /theme dracula in sidebar | aca4554 |

---

## Key Files (TUI Layer)

```
src/tui/chat_tui_app.zig      — 4634 lines: Model, draw(), handleEvent(), buildPaletteItems()
src/tui/theme.zig              — 6 themes × 75 color slots (dark/light/mono/catppuccin/nord/dracula)
src/tui/widgets/palette.zig    — PaletteItem with categories, fuzzy search, match highlighting
src/tui/widgets/sidebar.zig    — Files, Project, Session, Sparkline, Workers, Diagnostics, MCP, Theme
src/tui/widgets/messages.zig   — ToolCallWidget with 🔧/✅/❌ markers
src/tui/widgets/spinner.zig    — context_phrase for contextual spinner text
src/tui/widgets/input.zig      — MultiLineInputWidget wrapping MultiLineInputState
src/tui/widgets/multiline_input.zig — Gap buffer, Shift+Enter, Ctrl+X Ctrl+E, suggestion autocomplete
src/tui/widgets/diff_preview.zig — Per-hunk apply/reject overlay
src/tui/model/streaming.zig    — Spinner context_phrase based on streaming state
src/tui/model/palette.zig      — Palette state management
src/tui/model/token_tracking.zig — Cost estimation, context percent
src/tui/markdown.zig           — Syntax highlighting (20 langs), public CodeLanguage/parseCodeLanguage/appendHighlightedCodeLine
```

---

## v0.37+ — Competitive Dominance Roadmap (Complete)

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 38–60 | See previous STATE.md history | ✅ All Done |
| Edit Safety | mtime check, auto LSP diagnostics | ✅ Done |
| Stable Polish | 4 shared modules, generic dispatch, 41 tests, CI | ✅ Done |
| v1.2.0 TUI | Virtual scroll, status bar, spinner, tool markers, palette | ✅ Done |
| v1.3.0 TUI | 6 themes, sparkline, syntax preview, backdrop, click-preview | ✅ Done |

---

## Competitive Position

| Feature Area | Crushcode | Claude Code | OpenCode | Codex | Goose |
|---|---|---|---|---|---|
| Builtin tools | **30** | 40+ | 20+ | 15 | 12 |
| Providers | **23** | 1 | 20+ | 1 | 10 |
| Session backend | **SQLite** ✅ | JSONL | SQLite | File | File |
| Syntax highlight | **20 langs** ✅ | ⚠️ | ⚠️ | ❌ | ❌ |
| TUI Themes | **6 (RGB)** ✅ | ❌ | ❌ | ❌ | ❌ |
| Virtual Scroll | **✅** | ✅ | ✅ | ❌ | ❌ |
| Token Sparkline | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Click-to-Preview | **✅** | ✅ | ❌ | ❌ | ❌ |
| Knowledge Graph | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| 4-layer Memory | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| MoA Synthesis | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Autopilot | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Crush Mode | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Diff Preview | **apply/reject** ✅ | apply/reject | apply/reject | ❌ | ❌ |

---

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| Build.zig cleanup (900→~500 lines) | Medium | Create `createStdModule()` helper |
| Vault→persistence merge | Medium | Circular dep risk |
| SQLite test runner | Low | @cImport needs libc; individual module tests pass |
| v1.3.0 version bump (5 files) | Low | Version bump files listed in HANDOFF.md |
| Responsive layout (FlexRow/FlexColumn) | Low | vaxis widgets available but unused |
| Mouse-resizable panes | Low | vaxis SplitView available |
| KnowledgePipeline fix (KP-1) | Medium | Dangling pointer, currently disabled |
| Input history search | Low | Ctrl+R taken by /refresh |

---

## Session Continuity

**Last Updated:** 2026-04-26
**Current Work:** v1.3.0 TUI Polish COMPLETE. All 6 backlog items shipped. Clean build, tests pass.
**Next Step:** Tag v1.3.0, or plan next batch (responsive layout, resizable panes, more testing).
