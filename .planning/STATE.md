# State: Crushcode v0.27.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-19
**Commit:** 6d7ba6d
**Stats:** 195 `.zig` files, ~82K lines

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
| Milestone | v0.27.0 — Memory, Parallel, Skills, Plugins |
| Phase | Complete |
| Status | ✅ Done |
| Code Version | 0.27.0 |

---

## v0.27.0 Plan — Memory, Parallel, Skills Import, Plugin Runtime

| Phase | Description | Status |
|-------|-------------|--------|
| A | Wire memory (agent/memory.zig) into TUI — init, load, persist, /memory command | ✅ Done |
| B | Wire parallel executor (agent/parallel.zig) into TUI — init, /workers, /kill, cleanup | ✅ Done |
| C | Implement real HTTP fetching for skills/import.zig — 4 methods via std.http.Client | ✅ Done |
| D | Wire plugin/runtime.zig into HybridBridge + TUI — 3rd dispatch tier, fix 5 bugs | ✅ Done |
| — | Version bump to 0.27.0 | ✅ Done |

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
| **v0.27.0** | **A–D (memory, parallel, skills HTTP, plugin runtime)** | **✅ Done** |

---

## Architecture Quick Map

```
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update)
src/ai/client.zig — AI HTTP client (19 providers, streaming)
src/agent/ — agent loop, compaction, memory, parallel
src/chat/tool_executors.zig — shared tool implementations
src/mcp/ — MCP client, bridge, discovery
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → runtime plugins)
src/skills/import.zig — skill import via HTTP (clawhub, skills.sh, GitHub, URL)
src/plugin/runtime.zig — external plugin manager (JSON-RPC)
src/diff/ — diff algorithm + visualizer
src/graph/ — knowledge graph
src/capability/ — capability catalog
src/orchestration/ — orchestration layer
src/tools/ — tool definitions
src/plugins/ — plugin implementations
```

---

## Tool Dispatch Chain (HybridBridge)

```
1. Builtin tools (tool_executors.executeBuiltinTool) → 6 tools
2. MCP bridge (mcp_bridge.Bridge.executeTool) → remote MCP servers
3. Runtime plugins (plugin/runtime.ExternalPluginManager) → external plugin processes
```

---

## Session Continuity

**Last Updated:** 2026-04-19
**Current Work:** v0.27.0 complete — all phases committed
**Next Step:** Plan v0.28.0 (user decision needed on scope)
