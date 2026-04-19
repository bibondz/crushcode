# State: Crushcode v0.32.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-19
**Commit:** b4dfe10
**Stats:** ~250 `.zig` files, ~105K lines
**Remote:** git@github.com:bibondz/crushcode.git

---

## Project Reference

**Core Value:** Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

**Build:** `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zig-build-cache`
**Test:** `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zig-build-cache`
**Branch:** `002-v0.2.2`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v0.32.0 — Runtime Bug Fixes |
| Phase | Complete |
| Status | ✅ Done |
| Code Version | 0.32.0 |

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

---

## Architecture Quick Map

```
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update)
src/ai/client.zig — AI HTTP client (19 providers, streaming)
src/agent/ — agent loop, compaction, memory, parallel, orchestrator, context_builder
src/commands/handlers/ — ai.zig, system.zig, tools.zig, experimental.zig (shim → 5 domain handlers)
src/chat/tool_executors.zig — shared tool implementations
src/mcp/ — MCP client, bridge, discovery, server
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → runtime plugins)
src/skills/import.zig — skill import via HTTP (clawhub, skills.sh, GitHub, URL)
src/plugin/runtime.zig — external plugin manager (JSON-RPC)
src/permission/ — evaluate, audit, governance, guardian, lists, security
src/knowledge/ — schema, vault, persistence, ops, lint
src/tools/ — tool definitions
```

---

## Tool Dispatch Chain (HybridBridge)

```
1. Builtin tools (tool_executors.executeBuiltinTool) → 6 tools
2. MCP bridge (mcp_bridge.Bridge.executeTool) → remote MCP servers
3. Runtime plugins (plugin/runtime.ExternalPluginManager) → external plugin processes
```

---

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| Build.zig cleanup (863→~500 lines) | Medium | Create `createStdModule()` helper to eliminate compat injection loop |
| Vault→persistence merge | Medium | Circular dep risk — vault.zig imports knowledge_persistence |
| Fresh roadmap for daily driver | Low | All roadmap v0.3.1–v0.7.0 done. Need new goals. |

---

## Session Continuity

**Last Updated:** 2026-04-19
**Current Work:** v0.32.0 complete — runtime bugs fixed in memory, parallel, plugin modules
**Next Step:** Build.zig cleanup, or fresh roadmap for daily driver goals
