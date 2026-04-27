# State: Crushcode v1.8.0+

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-27
**Stats:** ~280 `.zig` files, ~112K lines
**Remote:** git@github.com:bibondz/crushcode.git
**Branch:** `master`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | Post-v1.8.0 — Agent Improvements |
| Tags | v0.2.1, v0.2.2, v1.0.0, v1.1.0, v1.2.0, v1.3.0, v1.4.0, v1.5.0, v1.6.0, v1.7.0, v1.8.0 |
| Next | Agent gaps: desktop notifications, agent mode refinement |
| Latest commit | `ccdb5a9` — feat(tui): input history search + responsive layout |

---

## Version History

| Version | Description | Key Features |
|---------|-------------|--------------|
| v1.0.0 | Core Completion | File context, tool loop, permissions, provider fallback |
| v1.1.0 | Readability | Markdown rendering, diff view, theme system |
| v1.2.0 | TUI Foundation | Virtual scroll, palette, split pane, file tree sidebar |
| v1.3.0 | TUI Polish | 6 themes, sparkline, syntax preview, click-to-preview, dialogs |
| v1.4.0 | Full AI Agent | Auto-compact, Myers diff, system prompt, relevance scoring, user model, auto-skill, plan mode, feedback loop, 30 tools, graduated permissions, sub-agent delegation |
| v1.5.0 | Stability + Polish | Build.zig refactor (-86L), /export CLI+TUI, KP-1 verified stale, slash commands verified |
| v1.6.0 | Security + Cost | Guardrail redaction, cache-aware Anthropic, post-inspection masking, context compaction |
| v1.7.0 | AST-Aware Search | sg binary spawn, 3-tier grep cascade (sg→rg→grep), language auto-detect |
| v1.8.0 | TUI UX | Input history (Up/Down + Ctrl+R reverse-i-search), responsive sidebar layout |

---

## Post-v1.8.0 Progress — Agent Improvements

| Item | Status | Notes |
|------|--------|-------|
| SHA-256 loop detection | ✅ Done | `src/agent/loop_detector.zig` (210L), ring buffer, 8/8 tests passing |
| Desktop notifications | ⬜ Not started | Platform-specific (OS notify), lower priority |
| Agent mode refinement | ⬜ Not started | OpenCode subagent/primary/all pattern |

### SHA-256 Loop Detection — Details
- **File:** `src/agent/loop_detector.zig` (~210 lines)
- **Pattern:** Ring buffer of SHA-256 signatures (stack-allocated, no allocator)
- **Config:** window=10, maxRepeats=5, max window=32
- **Integration:** Wired into both sequential + parallel tool execution paths in `loop.zig`
- **Build:** `simpleMod` in build.zig (zero deps — pure `std`)
- **Old detection preserved:** `self_heal.detectRepetition` still catches failing-tool patterns separately
- **Reference:** Crush `loop_detection.go` (92L)

---

## Previously Completed

### v1.8.0 — TUI UX
| Item | Status | Notes |
|------|--------|-------|
| Input history (Up/Down) | ✅ Done | inputHistoryUp/Down, saves draft, 1000 entry cap |
| Ctrl+R reverse-i-search | ✅ Done | Incremental search, cycle matches, (no match) display |
| Responsive sidebar | ✅ Done | min(30, max(20, width/4)), auto-hide <80 chars |

### v1.7.0 — AST-Aware Search
| Item | Status | Notes |
|------|--------|-------|
| sg binary spawn | ✅ Done | tryExecuteSg() spawns `sg run -p <pattern> --json` via std.process.Child |
| 3-tier grep cascade | ✅ Done | sg (AST) → rg (regex) → grep (POSIX) fallback chain |
| Language auto-detect | ✅ Done | Maps include patterns (*.ts, *.py, *.rs etc.) to ast-grep language names |

### v1.5.0 — Stability + Polish
| Item | Status | Notes |
|------|--------|-------|
| KP-1 KnowledgePipeline | ✅ Verified stale | Dangling pointer was vxfw.App, already fixed |
| Build.zig cleanup | ✅ Done (cd81742) | 1123→1037 lines, consolidated imports |
| /export CLI + TUI | ✅ Done | Real markdown export, custom path support |
| /doctor, /review, /commit | ✅ Verified real | 512L, 168L, 411L — fully implemented |

### v1.6.0 — Security + Cost Optimization
| Item | Status | Notes |
|------|--------|-------|
| Guardrail redaction | ✅ Done | PII redaction wired into sendChatStreaming |
| Cache-aware Anthropic | ✅ Done | buildCacheAwareStreamingBody for Anthropic/Bedrock/VertexAI |
| Post-inspection masking | ✅ Done | Secrets in tool output masked instead of blocked |
| Context compaction w/ LLM | ✅ Done | compactLight wired into AgentLoop |

---

## Competitive Position

| Feature Area | Crushcode | Claude Code | OpenCode | Codex | Goose |
|---|---|---|---|---|---|
| Builtin tools | **30** | 40+ | 20+ | 15 | 12 |
| Providers | **23** | 1 | 20+ | 1 | 10 |
| Session backend | **SQLite** ✅ | JSONL | SQLite | File | File |
| Syntax highlight | **20 langs** ✅ | ⚠️ | ⚠️ | ❌ | ❌ |
| TUI Themes | **6 (RGB)** ✅ | ❌ | ❌ | ❌ | ❌ |
| Knowledge Graph | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| 4-layer Memory | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Circuit Breaker | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Guardrails | **✅ unique** | ❌ | ❌ | ❌ | ❌ |
| Auto-Compact | **multi-tier** ✅ | ✅ single-tier | ❌ | ❌ | ❌ |
| AST Search | **sg binary** ✅ | ❌ | ❌ | ❌ | ❌ |
| Loop Detection | **SHA-256** ✅ | ❌ | ❌ | ❌ | ✅ (Go) |

---

## Remaining Backlog

| Item | Priority | Notes |
|------|----------|-------|
| Desktop notifications | Medium | Platform-specific OS notify |
| Agent mode refinement | Low | OpenCode subagent/primary/all pattern |
| MoA wiring to TUI | Low | moa.zig (438L) exists, unwired |
| Streaming diff preview | Low | diffpane/tuicr integration |
| Skill hub integration | Low | External skill marketplace |
| Multi-platform gateway | Low | Telegram/Discord/Slack |

---

## Session Continuity

**Last Updated:** 2026-04-27
**Status:** v1.8.0 shipped. Post-v1.8.0 agent improvements in progress. SHA-256 loop detection complete.
