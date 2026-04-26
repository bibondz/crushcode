# State: Crushcode v1.4.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-27
**Stats:** ~280 `.zig` files, ~112K lines
**Remote:** git@github.com:bibondz/crushcode.git
**Branch:** `master`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v1.4.0 — ALL 33 phases COMPLETE |
| Tags | v0.2.1, v0.2.2, v1.0.0, v1.1.0, v1.2.0, v1.3.0, v1.4.0 |
| Next | v1.5.0 — Stability + Polish |

---

## Version History

| Version | Description | Key Features |
|---------|-------------|--------------|
| v1.0.0 | Core Completion | File context, tool loop, permissions, provider fallback |
| v1.1.0 | Readability | Markdown rendering, diff view, theme system |
| v1.2.0 | TUI Foundation | Virtual scroll, palette, split pane, file tree sidebar |
| v1.3.0 | TUI Polish | 6 themes, sparkline, syntax preview, click-to-preview, dialogs |
| v1.4.0 | Full AI Agent | Auto-compact, Myers diff, system prompt, relevance scoring, user model, auto-skill, plan mode, feedback loop, 30 tools, graduated permissions, sub-agent delegation |

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

---

## Known Remaining Items (v1.5.0)

| Item | Priority | Notes |
|------|----------|-------|
| KnowledgePipeline fix (KP-1) | High | Dangling pointer, currently disabled |
| Build.zig cleanup | Medium | 1115→~700 lines, createStdModule() helper |
| Slash command stubs | Medium | /export, /review, /doctor, /commit |
| Cache-aware Anthropic body | Low | CacheControl structs exist, not wired |
| Guardrail redaction | Low | deny works, redact not fully wired |
| Responsive layout | Low | FlexRow/FlexColumn unused |
| Input history search | Low | Ctrl+R taken by /refresh |

---

## Session Continuity

**Last Updated:** 2026-04-27
**Status:** All ROADMAP phases (1-33) complete. v1.5.0 planning next.
