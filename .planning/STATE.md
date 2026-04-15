# State: Crushcode v0.7.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-15

---

## Project Reference

**Core Value:** Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

**Current Focus:** Phase 21 — MCP → Agent Loop + Tool Unification

---

## v0.6.0 Milestone Complete ✅

All 20 phases across 6 milestones completed. Architecture + UI/UX polish done.

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v0.7.0 — Full AI Agent (Integration + Intelligence) |
| Phase | 21 |
| Plan | Not yet planned |
| Status | Ready for planning |
| Progress | 0% |

---

## Milestone History

| Milestone | Phases | Status |
|-----------|--------|--------|
| v0.3.1 | 1-4 (context, tool loop, permission, fallback) | ✅ Done |
| v0.3.2 | 5-7 (markdown, diff, theme) | ✅ Done |
| v0.4.0 | 8-10 (session, agents, sidebar) | ✅ Done |
| v0.5.0 | 11-15 (LSP, threading, git, oauth, budget) | ✅ Done |
| v0.6.0 | 16-20 (registry, widgets, spinner, gradient, diff) | ✅ Done |
| v0.7.0 | 21-25 (MCP wire, context, diff, prompt, hooks) | 🔄 Current |

---

## v0.7.0 Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 21 | MCP → Agent Loop + Tool Unification | 📋 Planning |
| 22 | Smart Context + Auto-Compact | ⏳ Pending |
| 23 | Myers Diff + Edit Preview | ⏳ Pending |
| 24 | System Prompt Engineering + Project Config | ⏳ Pending |
| 25 | Lifecycle Hooks + Code Quality | ⏳ Pending |

---

## v0.7.0 Architecture Audit

### What's Done (components exist, need wiring)
- MCP Client (633 lines) — NOT wired to TUI agent loop
- Context Compactor (608 lines) — NOT wired, `/compact` returns "not implemented"
- Knowledge Graph (575 lines) — dumps ALL files, no relevance scoring
- Lifecycle Hooks (196 lines) — framework exists, ZERO hooks registered
- Validated Edit (220 lines) — hash-based edits NOT used by TUI edit tool

### What's Missing (need new code)
- Myers diff algorithm (visualizer.zig is naive)
- Edit preview flow (diff display + confirm before apply)
- AGENTS.md / .crushcode/ project config loading
- Relevance-based context selection
- Tool deduplication (250 lines of copy-paste in TUI)

### Key Insight
"All the pieces exist, they just aren't connected."
v0.7.0 is an INTEGRATION milestone — wire existing components together, not build new ones.

---

## Accumulated Context

### Seeds Consumed
- SEED-001: Architecture Improvements → incorporated into Phase 16 + 17

### Research Available
- `.planning/research/UI-UX-ANIMATION-REFERENCE.md` — UI/UX patterns from 6 reference projects

### Decisions
- Integration-first approach (wire before build)
- MCP tools must work transparently alongside builtin tools
- Auto-compact when context >70% — don't wait for manual /compact
- Myers diff for proper hunk generation (not naive line compare)
- AGENTS.md support for project-specific AI instructions
- Honest naming: rename ast_grep → pattern_search (no real AST)

### Blockers
- None — ready for Phase 21 planning

---

## Session Continuity

**Last Updated:** 2026-04-15

Ready for planning: `/gsd-plan-phase 21`
