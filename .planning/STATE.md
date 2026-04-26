# State: Crushcode v1.4.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-26
**Commit:** 555aaa0
**Stats:** ~280 `.zig` files, ~112K lines
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
| Milestone | v1.4.x Compaction Improvements — Phase A+B COMPLETE |
| Phase | Phase 22 (Smart Context + Auto-Compact) — Phase B shipped |
| Commit | 629da2e |
| Last Tag | v1.4.0 |
| Tags | v0.2.1, v0.2.2, v1.0.0, v1.1.0, v1.2.0, v1.3.0, v1.4.0 |

---

## v1.4.0 — Harness Engineering (7 commits, +6192 lines, 44+ tests)

| Feature | Description | Commit |
|---------|-------------|--------|
| P0: Execution Traces | `src/trace/` — Span, Writer, Context (397 lines), hierarchical traces with wall/cpu timing | a1f2c97 |
| P0: Self-Healing Retry | `src/retry/` — Policy, SelfHeal (477 lines), retry with error classification + prompt repair | a1f2c97 |
| P1: Circuit Breaker | `src/agent/circuit_breaker.zig` (148 lines) — closed/open/half_open FSM, configurable thresholds | ab97cd2 |
| P1: Routing Strategies | `src/agent/router.zig` (+211 lines) — FallbackChain, ProviderLatency EMA P50/P95, cost-aware routing | ab97cd2 |
| P1: Guardrail Pipeline | `src/guardrail/` — pipeline, pii_scanner, injection, secrets (1093 lines), priority-sorted scanners | ab97cd2 |
| P2: Observability Metrics | `src/metrics/` — collector, registry (599 lines), counter/gauge/histogram, Prometheus+JSONL export | 8690943 |
| P2: LLM Compaction | `src/agent/compaction.zig` (669→1089 lines) — compactWithLLM, truncateToolOutputs, CompactionConfig | 8690943 |
| P2: Cache-Aware Client | `src/ai/client.zig` (+80 lines) — CacheControl, CacheMarkedMessage, Anthropic cache hints | 8690943 |
| P3: Tool Inspection | `src/tool/inspection.zig` (266 lines) — ToolInspectionPipeline, DangerLevel, pre/post hooks | 0ce2048 |
| P3: Parallel Execution | `src/tool/parallel.zig` (437 lines) — ParallelExecutor, chunked thread-per-task, ordered results | 0ce2048 |
| Wiring | All P1-P3 wired into client.zig, loop.zig, router.zig — guardrails, metrics, circuit breaker feedback | 5b2f2ee, 3375db1 |
| Phase 22: Auto-Compact | Trigger performCompactionAuto() after each AI response when context >70% | 555aaa0 |
| Phase A: Micro-Compact | Prune stale tool outputs older than recent window, 0 quality loss | c274109 |
| Phase A: Multi-Tier Thresholds | micro@<85%, light@85-95%, summary@95%+ graduated compaction | c274109 |
| Phase A: Dynamic Context Limits | context_limits.zig — per-provider/model window sizes (15+ providers, 28 tests) | c274109 |
| Phase A: Agent Framing | 8-section structured prompt for AI-to-AI context recovery | c274109 |
| Phase B: Template Enforcement | enforceSummaryTemplate() validates LLM output has 8 required sections | 629da2e |
| Phase B: Tool Importance Pruning | Protected/normal/aggressive tool categories, prune by importance | 629da2e |
| Phase B: Wire compactWithLLM | sendToLLMWrapper threadlocal pattern, LLM compaction with heuristic fallback | 629da2e |

---

## v1.3.0 — TUI Polish (commits f6c4c4f–b7cbb43)

| Feature | Description | Commit |
|---------|-------------|--------|
| 6 Themes | dark, light, mono + Catppuccin Mocha, Nord, Dracula (truecolor RGB) | f6c4c4f |
| Session Sparkline | ▁▂▃▄▅▆▇█ bar chart of per-turn token usage in sidebar | aca4554 |
| Syntax Preview | File preview with syntax highlighting (keywords, strings, comments, numbers, types) | ed8a108 |
| Dialog Backdrop | Dimmed backdrop behind all overlay dialogs (palette, permission, diff, session, help) | c1f18cc |
| Click-to-Preview | Mouse click in message area scans for file paths, opens in right pane | b7cbb43 |

---

## v1.2.0 — TUI Foundation (commit 032bec3)

| Feature | Description | Status |
|---------|-------------|--------|
| Virtual Scroll | ScrollView builder pattern — only visible messages get widget objects (~80% fewer arena allocations) | ✅ Done |
| Enhanced Status Bar | provider/model prefix + [CRUSH]/[DELEGATE]/[SCROLL] mode tags | ✅ Done |
| Contextual Spinner | "Thinking..."/"Writing..."/"Running {tool}..." phrases on AnimatedSpinner | ✅ Done |
| Tool Markers | 🔧 pending, ✅ success (N lines), ❌ failed in ToolCallWidget | ✅ Done |
| Palette Overhaul | Unified PaletteItem (command/model/file/session), fuzzy match, model switcher, file quick-open | ✅ Done |
| Split Pane | Right pane for file preview, Ctrl+\ toggle, `/preview <file>` | ✅ Done |
| File Tree Sidebar | CWD listing in sidebar "Project" section, Ctrl+R, `/refresh` | ✅ Done |

---

## Key Files

```
src/tui/chat_tui_app.zig      — Main TUI app: Model, draw(), handleEvent(), buildPaletteItems()
src/tui/model/streaming.zig   — Streaming worker, finishRequestSuccess(), auto-compact trigger
src/agent/compaction.zig      — ContextCompactor (1328 lines): microCompact, compactLight, compactWithSummary, compactWithLLM
src/ai/context_limits.zig     — Per-provider/model context window sizes (15+ providers, 28 tests)
src/tui/chat_tui_app.zig      — Main TUI app: Model, draw(), handleEvent(), multi-tier auto-compact
src/tui/model/streaming.zig   — Streaming worker, finishRequestSuccess(), auto-compact trigger
src/tui/model/token_tracking.zig — Cost estimation, model-aware context percent
src/agent/circuit_breaker.zig — CircuitBreaker FSM (closed/open/half_open)
src/agent/router.zig          — ModelRouter with routing strategies, latency tracking
src/ai/client.zig             — AIClient with guardrails, metrics, circuit breaker feedback, cache hints
src/agent/loop.zig            — AgentLoop with tool inspection, metrics, parallel execution
src/metrics/                  — Collector + Registry (counter/gauge/histogram, Prometheus+JSONL)
src/guardrail/                — Pipeline, PII scanner, injection detection, secrets scanner
src/tool/                     — Inspection pipeline, parallel executor
src/trace/                    — Execution traces (Span, Writer, Context)
src/retry/                    — Self-healing retry with error classification
src/graph/graph.zig           — Knowledge graph, relevance scoring, context file selection
src/tui/model/token_tracking.zig — Cost estimation, context percent
```

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
| Circuit Breaker | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Guardrails | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Execution Traces | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Auto-Compact | **multi-tier** ✅ | ✅ single-tier | ❌ | ❌ | ❌ |
| Dynamic Context Limits | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Diff Preview | **apply/reject** ✅ | apply/reject | apply/reject | ❌ | ❌ |

---

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| KnowledgePipeline fix (KP-1) | Medium | Dangling pointer, currently disabled |
| Build.zig cleanup (1115→~700 lines) | Medium | Create `createStdModule()` helper |
| Vault→persistence merge | Medium | Circular dep risk |
| Cache-aware Anthropic HTTP body | Low | CacheControl structs exist, not wired to HTTP body format |
| Guardrail redaction pass | Low | deny works, redact→modified content not fully sent |
| Responsive layout (FlexRow/FlexColumn) | Low | vaxis widgets available but unused |
| Mouse-resizable panes | Low | vaxis SplitView available |
| Input history search | Low | Ctrl+R taken by /refresh |

---

## Next Roadmap Items

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 22 | Smart Context + Auto-Compact | ✅ Phase A+B Done |
| Phase 23 | Myers Diff + Edit Preview | ✅ Already implemented (1898 lines) |
| Phase 24 | System Prompt Engineering + Project Config | **Next** |
| Phase 25 | Batch Operations + Undo/Redo | Not started |

---

## Session Continuity

**Last Updated:** 2026-04-26
**Current Work:** Phase 22 A+B shipped. Phase 23 already implemented. Phase 24 (System Prompt + Project Config) next.
**Next Step:** Phase 24 — AGENTS.md loading, .crushcode/instructions.md, project detection, rich system prompt.
