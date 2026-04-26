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
| Next | v1.5.0 — Stability + Polish (in progress) |
| Latest commit | `cd81742` — refactor build.zig, fix /export stub |

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

## v1.6.0 Progress — Security + Cost Optimization

| Item | Status | Notes |
|------|--------|-------|
| Guardrail redaction | ✅ Done | PII redaction wired into sendChatStreaming |
| Cache-aware Anthropic | ✅ Done | buildCacheAwareStreamingBody for Anthropic/Bedrock/VertexAI |
| Post-inspection masking | ✅ Done | Secrets in tool output masked instead of blocked |
| Context compaction w/ LLM | ✅ Done | compactLight wired into AgentLoop |

| Item | Status | Notes |
|------|--------|-------|
| KP-1 KnowledgePipeline | ✅ Verified stale | Dangling pointer was vxfw.App, already fixed |
| Build.zig cleanup | ✅ Done (cd81742) | 1123→1037 lines, consolidated imports |
| /export CLI | ✅ Done (cd81742) | Real markdown export, custom path support |
| /doctor, /review, /commit | ✅ Verified real | 512L, 168L, 411L — fully implemented |
| TUI /export handler | ✅ Done | Wire into chat_tui_app.zig, full message history |

---

## v1.6.0 Progress — Security + Cost Optimization

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
**Status:** v1.5.0 in progress. All known issues resolved. Backlog items remain (low priority).
