# State: Crushcode v1.7.0

**Project:** Crushcode - Zig-based AI Coding CLI
**Updated:** 2026-04-27
**Stats:** ~280 `.zig` files, ~112K lines
**Remote:** git@github.com:bibondz/crushcode.git
**Branch:** `master`

---

## Current Position

| Field | Value |
|-------|-------|
| Milestone | v1.7.0 — AST-Aware Search COMPLETE |
| Tags | v0.2.1, v0.2.2, v1.0.0, v1.1.0, v1.2.0, v1.3.0, v1.4.0, v1.5.0, v1.6.0, v1.7.0 |
| Next | Backlog items or v1.8.0 |
| Latest commit | `920060f` — feat(search): add ast-grep (sg) binary spawn as tier-1 search |

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

---

## v1.7.0 Progress — AST-Aware Search

| Item | Status | Notes |
|------|--------|-------|
| sg binary spawn | ✅ Done | tryExecuteSg() spawns `sg run -p <pattern> --json` via std.process.Child |
| 3-tier grep cascade | ✅ Done | sg (AST) → rg (regex) → grep (POSIX) fallback chain |
| Language auto-detect | ✅ Done | Maps include patterns (*.ts, *.py, *.rs etc.) to ast-grep language names |
| Build verify | ✅ Done | Clean build, exit 0 |
| Tag + push | ✅ Done | v1.7.0 tagged and pushed to origin |

---

## Previously Completed

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

---

## Remaining Backlog

| Item | Priority | Notes |
|------|----------|-------|
| Streaming diff preview | Low | diffpane/tuicr integration |
| Mixture-of-Agents | Low | Hermes MoA reasoning |
| Skill hub integration | Low | External skill marketplace |
| Sandboxed execution | Low | gVisor/LXC |
| Multi-platform gateway | Low | Telegram/Discord/Slack |
| Vault→persistence merge | Low | Circular dep risk |

---

## Session Continuity

**Last Updated:** 2026-04-27
**Status:** v1.7.0 shipped. All milestones through v1.7.0 complete. Backlog items remain.
