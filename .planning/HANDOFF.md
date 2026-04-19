# Crushcode — Session Handoff

**Updated:** 2026-04-15
**Status:** Phase 22 done ✅, Phase 23 next

---

## What Is This Project

Zig-based AI coding CLI/TUI. Single binary, zero deps. ~144 `.zig` files, ~47K lines.
Build: `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zig-build-cache`
Test: `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zig-build-cache`
Branch: `002-v0.2.2` | Last commit: `c3d8088` | Build: ✅ clean | Tests: ✅ pass

## Zig 0.15.2 API Notes (MUST follow)

- `ArrayList.append(allocator, item)` — allocator is first arg
- `ArrayList.toOwnedSlice(allocator)` — same
- `ArrayList(u8).empty` not `.init()`
- `splitScalar()` returns iterator directly (no `.iterator()`)
- `std.log.info` disabled by `log_level = .warn` — use `file_compat.File.stdout().writer()` for output

## Constraints

- CLI IS the TUI — no separate mode
- `export CI=true GIT_TERMINAL_PROMPT=0 GIT_EDITOR=: GIT_PAGER=cat` always
- Thai+English mixed — respond understandably
- "passing compiler ≠ program works" — test runtime too
- Visual beauty required, but animations must be compact

## v0.7.0 Progress (Integration Milestone)

| Phase | Description | Status |
|-------|-------------|--------|
| 21 | MCP → Agent Loop + Tool Unification | ✅ Done (c3d8088) |
| **22** | **Smart Context + Auto-Compact** | **✅ Done** |
| **23** | **Myers Diff + Edit Preview** | **📋 NEXT** |
| 24 | System Prompt Engineering + Project Config | ⏳ |
| 25 | Lifecycle Hooks + Code Quality | ⏳ |

## What Phase 21 Accomplished

- MCPBridge wired into TUI Model (non-fatal init)
- Tool routing: builtin first → MCP fallback
- MCP tools dynamically injected into system prompt
- 180 lines of duplicate inline tools replaced with shared `tool_executors.zig`
- Sidebar shows MCP server status (●/○) + tool count
- Fixed bridge.zig: argument parsing (was discarding JSON) + error set mismatch

## Phase 22: What To Do (from ROADMAP.md)

**Goal:** Relevance-scored context + auto-compact when context fills

1. Wire `src/agent/compaction.zig` ContextCompactor into TUI streaming loop
2. Auto-compact trigger when >70% context used
3. Implement `/compact` slash command using existing `compact()` method
4. Relevance-based context selection in `src/graph/graph.zig` — score files by query similarity, not dump all
5. Token-aware system prompt — truncate context to fit model limits
6. Show context usage in header: `ctx: 45% | 14 files`

**Key files:**
- `src/agent/compaction.zig` (608 lines) — ContextCompactor, full logic, not wired
- `src/graph/graph.zig` (575 lines) — dumps ALL files, needs relevance scoring
- `src/tui/chat_tui_app.zig` — wire compaction here, add auto-compact trigger
- Plan files needed: `22-01-PLAN.md`, `22-02-PLAN.md`

## Known Bugs (fix opportunistically)

- `src/ai/client.zig:416` — naive JSON escaping in `performHttpRequest`, will break on special chars
- `src/skills/import.zig` — all 4 import methods are stubs
- `src/agent/memory.zig` (230 lines) — not wired into chat
- `src/plugin/runtime.zig` (245 lines) — not connected to agent loop
- `src/agent/parallel.zig` (517 lines) — not integrated

## Architecture Quick Map

```
build.zig — module imports + build config
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update pattern)
src/ai/client.zig — AI HTTP client (19 providers, streaming)
src/ai/registry.zig — provider registry
src/agent/compaction.zig — context compaction (NOT WIRED)
src/agent/memory.zig — memory persistence (NOT WIRED)
src/graph/graph.zig — knowledge graph (WIRED but dumb: dumps all)
src/mcp/bridge.zig — MCP tool bridge ✅
src/mcp/client.zig — MCP client ✅
src/chat/tool_executors.zig — shared tool implementations ✅
src/tui/widgets/sidebar.zig — sidebar with MCP status ✅
src/config/ — config loading, provider config
src/diff/visualizer.zig — diff display (naive, Phase 23 target)
```

## How To Continue

1. Read ROADMAP.md lines 299-315 for Phase 22 details
2. Read compaction.zig and graph.zig to understand existing code
3. Plan with `/gsd-plan-phase 22` or inline
4. Execute, build-test, commit
