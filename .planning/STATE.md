# State: Crushcode v0.40.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-21
**Commit:** b5b9fcf
**Stats:** ~268 `.zig` files, ~117K lines
**Remote:** git@github.com:bibondz/crushcode.git

---

## Project Reference

**Core Value:** Ship a self-improving AI coding assistant in Zig that learns from usage, remembers across sessions, and produces production-quality code.

**Build:** `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zigcache`
**Test:** `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zigcache`
**Branch:** `002-v0.2.2`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v0.47+ Agent Unification & Safety Net — COMPLETE |
| Phase | All 5 phases (48–52) complete |
| Status | ✅ Milestone finished — 26 builtin tools, 5 new infra features |
| Code Version | 0.47.0 |
| Binary Size | 125MB (includes SQLite amalgamation) |

---

## v0.37+ — Competitive Dominance Roadmap

Roadmap: `.planning/ROADMAP-v0.37.md`

| Phase | Description | Status | Commit |
|-------|-------------|--------|--------|
| Phase 38 | Streaming Diff Preview — per-hunk apply/reject with syntax highlighting | ✅ Done | c596292 |
| Phase 39 | Crush Mode — auto-agentic task→plan→exec→verify→commit | ✅ Done | c596292 |
| Phase 40 | SQLite Session Backend — replace JSON, enable analytics + crash recovery | ✅ Done | c6ccc08 |
| Phase 41 | Web Tools — web_search + web_fetch tools for AI (19 builtin tools total) | ✅ Done | dc7461b |
| Phase 42 | Image in Terminal — Kitty/Sixel protocol + image_display tool (20 builtin tools) | ✅ Done | 133ba1c |
| Phase 43 | Smart Context — query intent extraction, relevance scoring, auto-pruning | ✅ Done | 6ae6d3c |
| Phase 44 | LSP as Tools — 6 LSP tools (definition, references, diagnostics, hover, symbols, rename) | ✅ Done | 6ae6d3c |
| Phase 45 | Multi-File Edit — atomic batch edits with transaction rollback | ✅ Done | 6ae6d3c |
| Phase 46 | Cost Analytics — /cost dashboard with per-session/day/provider/model breakdown | ✅ Done | 14abafc |
| Phase 47 | Session Forking — /fork command to branch conversations | ✅ Done | 14abafc |
| Phase 48 | Live Agent Teams — wire orchestrator to real AI execution, /team command | ✅ Done | fb00497 |
| Phase 49 | Session Tree Navigator — visual TUI session hierarchy, /tree command | ✅ Done | fb00497 |
| Phase 50 | Checkpoints & Rewind — auto-snapshot before AI edits, /rewind command | ✅ Done | fb00497 |
| Phase 51 | Side Chains — /btw context switching, compact summary injection | ✅ Done | b5b9fcf |
| Phase 52 | Semantic Context Compression — AST-aware 4-level compression, /compress command | ✅ Done | b5b9fcf |

### Phase 38: Streaming Diff Preview (c596292)

**Files:**
- `src/tui/widgets/diff_preview.zig` — NEW, 274 lines: Interactive diff preview widget
- `src/tui/chat_tui_app.zig` — Modified: diff preview state, key handling, overlay rendering
- `src/tui/syntax/` — NEW: syntax highlighting (highlighter, themes, tree_sitter, vaxis_renderer)
- `build.zig` — Added `diff` + `myers` imports

**Features:** When AI calls edit/write_file with 2+ diff hunks, interactive overlay shows each hunk with [y/n/a/q/j/k] controls. Only applied hunks modify the file.

### Phase 39: Crush Mode (c596292)

**Files:**
- `src/execution/crush_mode.zig` — NEW, 550 lines: CrushEngine with plan generation, step parsing, auto-approve, build verification, auto-commit
- `src/commands/handlers/agent_loop_handler.zig` — Added `handleCrush()` with --auto-approve/--no-commit/--no-verify/--dry-run
- `src/commands/handlers/experimental.zig` — Re-export handleCrush
- `src/commands/handlers.zig` — Re-export + help text
- `src/cli/registry.zig` — Registered `crush` command
- `src/tui/chat_tui_app.zig` — `/crush` slash command + crush engine fields + deinit

**Features:** `crushcode crush "fix auth bugs"` → auto plan → execute → verify → commit. TUI counterpart via `/crush`.

### Phase 40: SQLite Session Backend (c6ccc08)

**Files:**
- `vendor/sqlite3/sqlite3.c` + `sqlite3.h` — Vendored SQLite 3.47.0 amalgamation (~8.8MB)
- `src/db/sqlite.zig` — NEW, 226 lines: Thin Zig wrapper over C API (Db, Stmt, bind/step/column)
- `src/db/session_db.zig` — NEW, 567 lines: Session/message CRUD with WAL mode, indexes, upsert
- `src/db/migration.zig` — NEW, 157 lines: JSON→SQLite one-time migration with marker file
- `src/session.zig` — Modified: SQLite-first backend with JSON fallback, same public API
- `build.zig` — C interop via addCSourceFile + linkLibC
- `src/main.zig` — Fixed pre-existing sigemptyset() API mismatch

**Architecture:** SQLite-first with JSON fallback. Zero caller changes — same `saveSession`, `loadSession`, `listSessions` signatures. WAL mode for crash safety. Auto-migrates existing JSON sessions on first run. Marker file prevents re-import.

**First C interop in crushcode** — `@cImport` + `linkLibC()` pattern established for future use.

### Phase 41: Web Search + Fetch Tools (dc7461b)

**Files:**
- `src/tools/web_fetch.zig` — NEW, 217 lines: URL content fetcher using `std.http.Client.fetch()` with HTML→text stripping
- `src/tools/web_search.zig` — NEW, 198 lines: DuckDuckGo HTML search (no API key), result parsing
- `src/chat/tool_executors.zig` — Modified: `web_fetch` + `web_search` executors, bindings, dispatch
- `src/tui/widgets/types.zig` — Modified: Tool schemas for AI discovery
- `build.zig` — Module registration

**Features:** AI can now search the web (`web_search {"query": "..."}`) and fetch URL content (`web_fetch {"url": "..."}`). Uses DDG HTML search — zero API keys required. HTML→text conversion with entity decoding, script/style tag stripping, whitespace normalization.

---

### Phase 42: Image in Terminal (uncommitted)

**Files:**
- `src/tools/image_display.zig` — NEW, 289 lines: Image metadata tool (magic byte detection, PNG/JPEG dimension parsing, format validation)
- `src/tui/image.zig` — NEW, 459 lines: GraphicsProtocol enum, detectProtocol(), SixelEncoder, formatPlaceholder(), formatImageForChat()
- `src/tui/widgets/types.zig` — Modified: image_display schema (20th builtin tool)
- `src/chat/tool_executors.zig` — Modified: imageDisplayExecutor + binding + dispatch
- `build.zig` — Modified: image_display_mod + image_mod registration

**Architecture:** Kitty protocol handled by vaxis built-in (`vaxis.Vaxis.loadImage`, `caps.kitty_graphics`). Sixel fallback via custom encoder with palette quantization. Terminal detection via `TERM_PROGRAM`/`TERM` env vars. Text placeholder for unsupported terminals.

**Tests:** 7/7 pass (detectProtocol, SixelEncoder empty/small, formatPlaceholder, formatImageForChat kitty/none, formatFileSize)

---

## Competitive Position (Updated — v0.47+ Complete)

| Feature Area | Crushcode | Claude Code | OpenCode | Codex | Goose |
|---|---|---|---|---|---|
| Builtin tools | **26** | 40+ | 20+ | 15 | 12 |
| Providers | **22** | 1 | 20+ | 1 | 10 |
| Session backend | **SQLite** ✅ | JSONL | SQLite | File | File |
| Syntax highlight | **20 langs** ✅ | ⚠️ | ⚠️ | ❌ | ❌ |
| Knowledge Graph | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| 4-layer Memory | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| MoA Synthesis | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Autopilot | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Crush Mode | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Diff Preview | **apply/reject** ✅ | apply/reject | apply/reject | ❌ | ❌ |
| Web Search | **✅** | ✅ | ❌ | ❌ | ❌ |
| Web Fetch | **✅** | ✅ | ❌ | ❌ | ❌ |
| Image in Terminal | **Kitty + Sixel** ✅ | ❌ | ❌ | ❌ | ❌ |
| Smart Context | **Intent-based scoring** ✅ | ❌ | ❌ | ❌ | ❌ |
| LSP as Tools | **6 tools** ✅ | ✅ | ❌ | ❌ | ❌ |
| Multi-File Edit | **Atomic batch** ✅ | ❌ | ❌ | ❌ | ❌ |
| Cost Analytics | **/cost dashboard** ✅ | ❌ | ❌ | ❌ | ❌ |
| Session Forking | **/fork command** ✅ | ❌ | ❌ | ❌ | ❌ |
| Agent Teams | **/team parallel** ✅ | ✅ | ✅ | ❌ | ❌ |
| Session Tree | **visual hierarchy** ✅ | ✅ | ✅ | ❌ | ❌ |
| Checkpoints & Rewind | **/rewind auto-snapshot** ✅ | ✅ | ❌ | ❌ | ❌ |
| Side Chains | **/btw context switch** ✅ | ✅ | ❌ | ❌ | ❌ |
| Semantic Compression | **4-level AST-aware** ✅ | ❌ | ❌ | ❌ | ❌ |

---

## v0.33.0 — Self-Improving Agent

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 26 | Context Relevance Scoring — `scoreRelevanceAdvanced()` with PageRank, file-type bias, community bonus; pipeline integration in TUI; header shows "ctx: 8/14 files (scored)" | ✅ Done |
| Phase 27 | User Model — `src/agent/user_model.zig` with USER.md persistence, preference tracking (coding style, tools, language), `/user` command | ✅ Done |
| Phase 28 | Auto Skill Generation — `src/skills/auto_gen.zig` with pattern detection, sliding window analysis, injection scan, `/skills/auto` command | ✅ Done |
| Phase 29 | Plan Mode — `src/commands/handlers/plan_handler.zig` with risk assessment, propose-before-execute, `/plan on/off/approve/cancel` | ✅ Done |
| Phase 30 | Feedback Loop — `src/agent/feedback.zig` with JSON persistence, outcome tracking, quality scores, `/feedback stats/recent/rate` | ✅ Done |

### New Files Added
- `src/agent/user_model.zig` (440 lines)
- `src/skills/auto_gen.zig` (717 lines)
- `src/commands/handlers/plan_handler.zig` (606 lines)
- `src/agent/feedback.zig` (737 lines)

### Modified Files
- `src/graph/graph.zig` — Enhanced scoring with PageRank cache, file-type weighting, community bonus
- `src/tui/chat_tui_app.zig` — Pipeline context, user model, auto-gen, plan mode, feedback wiring
- `src/tui/widgets/header.zig` — Scored context display
- `build.zig` — 4 new modules registered
- `src/core/slash_commands.zig` — 4 new commands: /user, /skills/auto, /plan, /feedback
- `src/tui/widgets/setup.zig` — Slash command prefix matching

---

## v0.32.0 Plan — Runtime Bug Fixes

| Fix | Description | Status |
|-----|-------------|--------|
| memory.zig | Replace naive `{s}` JSON serialization with `std.json.Stringify.valueAlloc` — fixes data corruption on messages containing quotes, backslashes, newlines | ✅ Done |
| parallel.zig — thread safety | Thread-local `ArenaAllocator` per worker — eliminates shared allocator state across threads | ✅ Done |
| parallel.zig — use-after-free | Dupe response content onto executor's allocator before arena cleanup | ✅ Done |
| parallel.zig — empty base_url | New `base_url` field on `ParallelTask`, passed through `submit()` from provider registry | ✅ Done |
| runtime.zig — double-kill | `getPlugin()` returns `?*RuntimePlugin` (pointer) instead of value copy — prevents double-kill on process deinit | ✅ Done |
| runtime.zig — exec validation | Validate executable exists before spawning plugin process | ✅ Done |
| hybrid_bridge.zig | Remove `mut_plugin` copy shim since `getPlugin` now returns pointer | ✅ Done |
| ai.zig | Update `submit()` callers to pass `base_url` from provider registry | ✅ Done |
| — | Version bump to 0.32.0 | ✅ Done |

### New Tests Added
- `Memory - save and load with special characters` — round-trip with `\"hello\\nworld\"`
- `Memory - save and load with JSON in content` — round-trip with embedded JSON object

---

## Milestone History

| Milestone | Phases | Status |
|-----------|--------|--------|
| v0.3.1 | 1-4 (context, tool loop, permission, fallback) | ✅ Done |
| v0.3.2 | 5-7 (markdown, diff, theme) | ✅ Done |
| v0.4.0 | 8-10 (session, agents, sidebar) | ✅ Done |
| v0.5.0 | 11-15 (LSP, threading, git, oauth, budget) | ✅ Done |
| v0.6.0 | 16-20 (registry, widgets, spinner, gradient, diff) | ✅ Done |
| v0.7.0 | 21-25 (MCP wire, context, diff, prompt, hooks) | ✅ Done |
| v0.8.0 | 26-29 (shell state, security, permissions, non-interactive) | ✅ Done |
| v0.9.0 | 30-34 (TUI fix, hierarchical config, file tracker, ripgrep, log CLI) | ✅ Done |
| v0.10.0 | 35-37 (output truncation, tool validation, git worktree CLI) | ✅ Done |
| v0.11.0 | 38-40 (agent modes, wave execution, spec-first pipeline) | ✅ Done |
| v0.12.0 | 41-43 (auto-compaction, CLAUDE.md memory, token/cost tracking) | ✅ Done |
| v0.13.0 | 44-46 (session CLI, MCP server core, MCP transport + CLI) | ✅ Done |
| v0.14.0 | 47-51 (graph algorithms, knowledge ops, workers, governance, TUI) | ✅ Done |
| v0.15.0 | 52-54 (worker execution, knowledge persistence, skill resolution) | ✅ Done |
| v0.16.0 | 55-57 (multi-agent coordination, hook executor, background agents) | ✅ Done |
| v0.17.0 | 58-60 (adversarial thinking, layered memory, skill pipeline) | ✅ Done |
| v0.18.0 | 61-63 (code preview, template marketplace, skill sync) | ✅ Done |
| v0.19.0 | 64 (content-based file detection) | ✅ Done |
| v0.20.0–v0.25.0 | Feature expansion (see git log) | ✅ Done |
| v0.26.0 | A–D (agent loop, hybrid bridge, e2e test, version bump) | ✅ Done |
| v0.27.0 | A–D (memory, parallel, skills HTTP, plugin runtime) | ✅ Done |
| v0.28.0 | A–F (backlog commit: ~90 files, agent/knowledge/command/skill/permission/TUI) | ✅ Done |
| v0.29.0 | B–C (slash commands wired into TUI, MCP tool execution fixed) | ✅ Done |
| v0.30.0 | D: unified slash commands + git remote + master push | ✅ Done |
| v0.31.0 | E–G: split handlers, relocate modules, consolidate lists | ✅ Done |
| **v0.32.0** | **Runtime bug fixes: memory JSON, parallel thread safety, plugin pointer** | **✅ Done** |
| **v0.33.0** | **Self-improving agent: relevance scoring, user model, auto skills, plan mode, feedback** | **✅ Done** |
| **v0.37.0** | **Phase 38: Streaming Diff Preview** | **✅ Done** |
| **v0.38.0** | **Phase 39: Crush Mode (auto-agentic)** | **✅ Done** |
| **v0.39.0** | **Phase 40: SQLite Session Backend** | **✅ Done** |
| **v0.40.0** | **Phase 41: Web Search + Fetch Tools** | **✅ Done** |
| **v0.41.0** | **Phase 42: Image in Terminal (Kitty/Sixel)** | **✅ Done** |
| **v0.42.0** | **Phases 43-47: Smart Context, LSP Tools, Multi-File Edit, Cost Analytics, Session Forking** | **✅ Done** |
| **v0.47.0** | **Phases 48-52: Agent Teams, Session Tree, Checkpoints, Side Chains, Semantic Compression** | **✅ Done** |

---

## Architecture Quick Map

```
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update)
src/ai/client.zig — AI HTTP client (22 providers, streaming)
src/agent/ — agent loop, compaction, memory, parallel, orchestrator, context_builder
src/commands/handlers/ — ai.zig, system.zig, tools.zig, experimental.zig (shim → 5 domain handlers)
src/chat/tool_executors.zig — 19 builtin tool implementations
src/db/ — SQLite wrapper, session CRUD, JSON migration
src/tools/ — web_fetch, web_search
src/mcp/ — MCP client, bridge, discovery, server
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → runtime plugins)
src/execution/ — autopilot, phase_runner, crush_mode
src/skills/import.zig — skill import via HTTP (clawhub, skills.sh, GitHub, URL)
src/plugin/runtime.zig — external plugin manager (JSON-RPC)
src/permission/ — evaluate, audit, governance, guardian, lists, security
src/knowledge/ — schema, vault, persistence, ops, lint
src/diff/ — Myers diff with hunks, DiffHunk/DiffLine/DiffResult
src/tui/syntax/ — syntax highlighting (20 languages)
src/tui/widgets/ — diff_preview, header, input, sidebar, palette, etc.
vendor/sqlite3/ — SQLite 3.47.0 amalgamation (vendored C)
```

---

## Tool Dispatch Chain (HybridBridge)

```
1. Builtin tools (tool_executors.executeBuiltinTool) → 20 tools
   - File ops: read_file, write_file, create_file, edit, move_file, copy_file, delete_file, file_info
   - Search: grep, glob, search_files
   - Shell: shell
   - Directory: list_directory
   - Git: git_status, git_diff, git_log
   - Web: web_fetch, web_search
   - Image: image_display
2. MCP bridge (mcp_bridge.Bridge.executeTool) → remote MCP servers
3. Runtime plugins (plugin/runtime.ExternalPluginManager) → external plugin processes
```

---

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| Build.zig cleanup (900→~500 lines) | Medium | Create `createStdModule()` helper to eliminate compat injection loop |
| Vault→persistence merge | Medium | Circular dep risk — vault.zig imports knowledge_persistence |
| SQLite test runner | Low | `zig build test` fails on sqlite module (@cImport needs libc); individual module tests pass |

---

## Session Continuity

**Last Updated:** 2026-04-22
**Current Work:** v0.47+ Agent Unification & Safety Net milestone COMPLETE. All 5 phases (48–52) shipped.
**Next Step:** Define next milestone or push to remote
