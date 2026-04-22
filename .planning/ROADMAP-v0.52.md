# Roadmap: v0.52+ Competitive Parity & Tooling

**Created:** 2026-04-22
**Branch:** 002-v0.2.2
**Previous Milestone:** v0.47+ (Phases 48-52) — COMPLETE
**Goal:** Close top 10 competitive gaps vs Claude Code, OpenCode, Codex, Goose

---

## Gap Analysis Summary

| Gap | Source | Priority | Phase |
|-----|--------|----------|-------|
| Hook system (pre/post tool, lifecycle) | Claude Code | High | 53 |
| TodoWrite tool | Claude Code | High | 54 |
| apply_patch tool | Claude Code + Codex | High | 54 |
| Question tool | OpenCode | High | 54 |
| /doctor command | Claude Code | Medium | 55 |
| /review command | Claude Code | Medium | 55 |
| /commit command | Claude Code | Medium | 55 |
| Skill loader + dynamic commands | OpenCode + Claude Code | High | 56 |
| Advanced permission modes (auto classifier) | Claude Code | Medium | 57 |

---

## Phase 53: Hook System

**Goal:** Lifecycle hook registry for pre/post tool execution, session start/end, notification

**Files:**
- `src/hooks/registry.zig` — NEW: HookRegistry, HookType enum, HookContext, async execution
- `src/hooks/config.zig` — NEW: Hook config loading from settings, shell command hooks
- `src/chat/tool_executors.zig` — MODIFIED: integrate hooks into adaptToolExecution()
- `src/tui/chat_tui_app.zig` — MODIFIED: session lifecycle hooks (start/end/notification)
- `build.zig` — MODIFIED: hooks_mod registration

**Hook Types:** PreToolUse, PostToolUse, SessionStart, SessionEnd, Notification, PreSessionLoad, PostSessionSave

---

## Phase 54: New Tools (TodoWrite + apply_patch + Question)

**Goal:** 3 new builtin tools (26→29), matching Claude Code + OpenCode capabilities

**Files:**
- `src/tools/todo.zig` — NEW: TodoWrite tool with status tracking (pending/in_progress/completed), priority, persistence
- `src/tools/apply_patch.zig` — NEW: Unified patch format (add/update/delete/move files), context-based hunks
- `src/tools/question.zig` — NEW: Question tool with options, multi-choice, user prompt via TUI
- `src/tui/widgets/types.zig` — MODIFIED: 3 new tool schemas in builtin_tool_schemas
- `src/chat/tool_executors.zig` — MODIFIED: 3 new executors + bindings in builtin_tool_bindings
- `build.zig` — MODIFIED: todo_mod, apply_patch_mod, question_mod registration

---

## Phase 55: Smart Commands (/doctor + /review + /commit)

**Goal:** 3 new slash commands matching Claude Code capabilities

**Files:**
- `src/commands/doctor.zig` — NEW: diagnostic checks (config, env, deps, permissions, updates)
- `src/commands/review.zig` — NEW: AI-powered code review via git diff analysis
- `src/commands/commit.zig` — NEW: AI-generated commits with style matching, safety checks
- `src/core/slash_commands.zig` — MODIFIED: add /doctor, /review, /commit to names
- `src/tui/chat_tui_app.zig` — MODIFIED: command handlers in executePaletteCommand()
- `build.zig` — MODIFIED: doctor_mod, review_mod, commit_mod registration

---

## Phase 56: Skill Loader + Dynamic Commands

**Goal:** Load skills from SKILL.md files, discover dynamic commands from .md files in config dirs

**Files:**
- `src/skills/loader.zig` — MODIFIED: SKILL.md frontmatter parsing, skill discovery from directories
- `src/skills/dynamic_commands.zig` — NEW: discover and load .md command files from config dirs
- `src/core/slash_commands.zig` — MODIFIED: merge dynamic commands into registry
- `src/config/config.zig` — MODIFIED: add skills/commands directory paths
- `build.zig` — MODIFIED: dynamic_commands_mod registration

---

## Phase 57: Advanced Permission Modes

**Goal:** Full 6-mode permission system with auto-classifier and plan mode enforcement

**Files:**
- `src/permission/tool_classifier.zig` — MODIFIED: enhanced risk tiers, auto-approve safe patterns
- `src/permission/auto_classifier.zig` — NEW: transcript-based safety analysis, pattern matching
- `src/permission/evaluate.zig` — MODIFIED: integrate auto-classifier, plan mode strict enforcement
- `src/tui/chat_tui_app.zig` — MODIFIED: mode switching UI, mode display in header
- `build.zig` — MODIFIED: auto_classifier_mod registration

---

## Dependencies

```
Phase 53 (Hooks) ← independent
Phase 54 (Tools) ← independent (can parallel with 53)
Phase 55 (Commands) ← depends on 54 (apply_patch for /commit)
Phase 56 (Skill Loader) ← independent
Phase 57 (Permissions) ← independent
```

**Parallelizable:** 53 + 54 + 56 + 57 can all run in parallel. Phase 55 after 54 completes.

---

## Expected Outcome

| Metric | Before | After |
|--------|--------|-------|
| Builtin tools | 26 | 29 |
| Slash commands | 37 | 40 |
| Hook lifecycle | None | 7 hook types |
| Permission modes | 6 (basic) | 6 (full with auto-classifier) |
| Skill system | Import-only | Full SKILL.md + dynamic commands |
