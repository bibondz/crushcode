# Roadmap: v0.57+ OS Integration & Agent Power-Ups

**Created:** 2026-04-22
**Branch:** 002-v0.2.2
**Previous Milestone:** v0.52+ (Phases 53-57) — COMPLETE
**Goal:** Real OS notifications, subagent as AI-callable tool, reusable recipe templates

---

## Phase 58: Real OS Notifications

**Goal:** Replace stub showUnixNotification/showWindowsNotification with actual OS-level notifications

**Current state:** `src/plugins/notifier.zig` has full event handling but `showUnixNotification()` and `showWindowsNotification()` just log to console. Need to actually call `notify-send` (Linux), `osascript` (macOS), or Win32 API.

**Files:**
- `src/plugins/notifier.zig` — MODIFIED: implement real `showUnixNotification` with `notify-send`, `osascript` fallback
- `build.zig` — No changes needed (module exists)

---

## Phase 59: Subagent Tool (AI-callable)

**Goal:** Expose the existing `SubAgentDelegator` infrastructure as a builtin tool the AI can call to spawn focused sub-agents

**Current state:** `src/agent/delegate.zig` has `SubAgentDelegator` with depth limiting, tool restrictions, concurrent limits. But it's NOT a tool — the AI can't invoke it.

**Files:**
- `src/tools/subagent.zig` — NEW: Tool wrapper that invokes SubAgentDelegator
- `src/tui/widgets/types.zig` — MODIFIED: Add subagent tool schema
- `src/chat/tool_executors.zig` — MODIFIED: Add subagent executor + binding
- `build.zig` — MODIFIED: subagent_mod registration

---

## Phase 60: Recipes / Prompt Templates

**Goal:** Reusable workflow templates (like Goose recipes) that define multi-step AI workflows with variable substitution

**Files:**
- `src/recipes/recipe.zig` — NEW: Recipe struct, parsing, execution
- `src/recipes/loader.zig` — NEW: Load recipes from .recipe.md files in config dirs
- `src/recipes/runner.zig` — NEW: Execute recipe steps with variable substitution
- `src/core/slash_commands.zig` — MODIFIED: Add /recipe command
- `src/tui/chat_tui_app.zig` — MODIFIED: /recipe command handler
- `build.zig` — MODIFIED: recipe modules registration

---

## Dependencies

All 3 phases are independent — can run in parallel.

---

## Expected Outcome

| Metric | Before | After |
|--------|--------|-------|
| Builtin tools | 29 | 30 |
| Slash commands | 40 | 41 |
| OS notifications | Stub (log only) | Real notify-send/osascript |
| Recipe system | None | Full template system with variable substitution |
