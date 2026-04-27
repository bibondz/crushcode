# State: Crushcode v2.1.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-27
**Stats:** ~280 `.zig` files, ~113K lines
**Remote:** git@github.com:bibondz/crushcode.git
**Branch:** `master`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v2.1.0 — Diff Preview for All Edits |
| Tags | v0.2.1, v0.2.2, v1.0.0–v1.9.0, v2.0.0, v2.1.0 |
| Next | Multi-platform gateway, Windows cross-compile |
| Latest commit | `cf77040` — Diff preview for all edits with streaming-complete indicator |

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
| v1.9.0 | Agent Improvements | Loop detection, desktop notifications, per-mode agent config, MoA wiring |
| v2.0.0 | Daily Driver Readiness | Remote skill discovery, SplitView mouse-drag, OverlayManager, WIN-1 getenv, SQ-1 SQLite tests |
| v2.1.0 | Diff Preview All Edits | Single-hunk diff preview, streaming-complete indicator, apply/reject for every edit |

---

## v2.1.0 Progress — Diff Preview for All Edits

| Item | Status | Notes |
|------|--------|-------|
| Single-hunk diff preview | ✅ Done | `streaming.zig`: `>= 2` → `>= 1` — all edits with hunks get interactive review |
| "Review before applying" label | ✅ Done | `diff_preview.zig`: single-hunk shows "Review before applying" instead of "Hunk 1/1" |
| Streaming-complete indicator | ✅ Done | `diff_preview.zig`: "● Response complete — review changes below" status bar |

---

## Previously Completed

### v2.0.0 — Daily Driver Readiness

| Item | Status | Notes |
|------|--------|-------|
| Remote skill discovery | ✅ Done | `src/skills/remote.zig` — fetch index.json, download skills, cache locally |
| Skill-sync pull CLI | ✅ Done | `crushcode skill-sync pull <url>` + `crushcode skill-sync cached` |
| Config skill_urls | ✅ Done | `skill_urls = url1, url2` in config.toml, parsed as comma list |
| SplitView mouse-drag | ✅ Done | Resizable sidebar + right-pane dividers, drag state in chat_tui_app |
| OverlayManager | ✅ Done | `src/tui/overlay.zig` — unified overlay type system |
| WIN-1 getenv compat | ✅ Done | 15 files migrated to `file_compat.getEnv()` |
| SQ-1 SQLite tests | ✅ Done | `test-sqlite` build step with separate module instance |

### v1.9.0 — Agent Improvements

| Item | Status | Notes |
|------|--------|-------|
| SHA-256 loop detection | ✅ Done | `src/agent/loop_detector.zig` (210L), ring buffer, 8/8 tests passing |
| Desktop notifications | ✅ Done | `src/feedback/notifier.zig`, platform notify-send/osascript |
| Agent mode refinement | ✅ Done | Per-mode config in `src/agent/mode_config.zig` |
| MoA wiring to TUI | ✅ Done | `src/agent/moa.zig` (438L) wired into agent loop |

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
| Remote Skill Hub | **✅** | ❌ | ✅ | ❌ | ❌ |
| Diff Preview (all edits) | **✅** | ✅ | ❌ | ❌ | ❌ |

---

## Remaining Backlog

| Item | Priority | Notes |
|------|----------|-------|
| Multi-platform gateway | Low | Telegram/Discord/Slack |
| Windows cross-compile | Low | 1 remaining error (Zig stdlib open() bug — upstream) |

---

## Session Continuity

**Last Updated:** 2026-04-27
**Status:** v2.1.0 shipped. Diff preview now activates for ALL edits (single + multi hunk), with streaming-complete status indicator.
