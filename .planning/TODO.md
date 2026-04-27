# Crushcode — TODO & Known Issues

**Updated:** 2026-04-27
**Version:** v2.1.0

---

## HIGH Priority

_No HIGH priority items currently._

---

## MEDIUM Priority

### [WIN-1] Windows Cross-Compile

**Status:** Partial (commit `506acd3`)
**Files:** `src/main.zig` (sigaction guard), build.zig

**Remaining:**
- Full `zig build -Dtarget=x86_64-windows-gnu` test
- Verify TUI rendering on Windows Terminal
- Test PTY alternative (conpty) for shell command execution

---

### Future TUI Improvements

| Item | Effort | Status | Notes |
|------|--------|--------|-------|
| ~~Responsive layout~~ | ~~Medium~~ | ✅ v1.8.0 | min(30, max(20, w/4)), auto-hide <80 |
| ~~Input history search~~ | ~~Low~~ | ✅ v1.8.0 | Ctrl+R reverse-i-search, Up/Down history |
| ~~Mouse-resizable panes (SplitView)~~ | ~~Medium~~ | ✅ v2.0.0 | Drag resize on sidebar + right-pane |
| ~~Proper dialog overlay abstraction~~ | ~~Medium~~ | ✅ v2.0.0 | OverlayManager in src/tui/overlay.zig |
| ~~Diff preview for all edits~~ | ~~Low~~ | ✅ v2.1.0 | Single + multi hunk apply/reject review |

---

## LOW Priority

### [VP-1] Vault→Persistence Merge

**Status:** Not started
**Risk:** Circular dependency — vault.zig imports knowledge_persistence.

---

### [SQ-1] SQLite Test Runner

**Status:** ✅ Done (v2.0.0)
**File:** `test-sqlite` build step with separate module instance

---

## Done (v2.1.0 — 2026-04-27)

- [x] Single-hunk diff preview activation (`streaming.zig`: >= 2 → >= 1)
- [x] "Review before applying" label for single-hunk edits
- [x] Streaming-complete status indicator in diff preview widget

## Done (v2.0.0 — 2026-04-27)

- [x] Remote skill discovery (`src/skills/remote.zig`, 540L)
- [x] Skill-sync pull/cached CLI commands
- [x] Config skill_urls comma-separated parsing
- [x] SplitView mouse-drag resize
- [x] OverlayManager unified overlay system
- [x] WIN-1 getenv compat (15 files)
- [x] SQ-1 SQLite test runner

## Done (v1.9.0 — 2026-04-27)

- [x] SHA-256 loop detection (ring buffer, 8/8 tests)
- [x] Desktop notifications (notify-send/osascript)
- [x] Agent mode refinement (per-mode config)
- [x] MoA wiring to TUI (438L module)

## Done (v1.8.0 — 2026-04-27)

- [x] Input history (Up/Down) — 1000 entry cap, saves draft
- [x] Ctrl+R reverse-i-search — incremental search, cycle matches
- [x] Responsive sidebar — min(30, max(20, width/4)), auto-hide <80

---

## Done (v1.4.x Phase A — 2026-04-26)

- [x] Micro-compact: prune stale tool outputs older than recent window (compaction.zig +239 lines)
- [x] Multi-tier auto-compact: micro@<85%, light@85-95%, summary@95%+
- [x] Dynamic context limits per provider/model (context_limits.zig, 28 tests)
- [x] Agent-to-agent framing in summarization prompt (8-section structured)
- [x] Model switch updates compactor.max_tokens dynamically

## Done (v1.4.x Phase B — 2026-04-26)

- [x] Template-enforced structured summarization (enforceSummaryTemplate, 8 required sections)
- [x] Tool importance-based pruning (protected/normal/aggressive categories)
- [x] Wire compactWithLLM via sendToLLMWrapper threadlocal pattern
- [x] 14 new inline tests

## Done (v1.4.x Phase 24 — 2026-04-26)

- [x] Multi-format context file loading (12+ formats: AGENTS/CLAUDE/GEMINI/.cursorrules/.cursor/rules/.github/copilot)
- [x] Structured XML injection (<memory><file path="...">pattern)
- [x] Enhanced base prompt (17 guidelines across Core/Editing/Communication/Safety)
- [x] Dynamic tool tips per project language (Zig/Rust/Go/JS/Python/C++)
- [x] 3 new inline tests

## Done (v1.4.0 session — 2026-04-26)

- [x] P0: Execution traces (src/trace/ — Span, Writer, Context, 397 lines)
- [x] P0: Self-healing retry (src/retry/ — Policy, SelfHeal, 477 lines)
- [x] P0: Wire traces + retry into client.zig and agent loop
- [x] P1: Circuit breaker (closed/open/half_open FSM, 148 lines)
- [x] P1: Routing strategies (FallbackChain, ProviderLatency EMA, 211 lines)
- [x] P1: Guardrail pipeline (PII, injection, secrets — 1093 lines)
- [x] P2: Observability metrics (collector + registry — 599 lines)
- [x] P2: LLM compaction (compactWithLLM, truncateToolOutputs — 1089 lines)
- [x] P2: Cache-aware client (CacheControl, CacheMarkedMessage)
- [x] P3: Tool inspection pipeline (DangerLevel, pre/post hooks — 266 lines)
- [x] P3: Parallel tool execution (chunked thread-per-task — 437 lines)
- [x] Wire P1-P3 into client.zig, loop.zig, router.zig
- [x] Circuit breaker feedback loop in client.zig
- [x] Phase 22: Auto-compact trigger in finishRequestSuccess()
- [x] Tagged v1.4.0, pushed to origin/master

## Done (v1.3.0 session — 2026-04-26)

- [x] Catppuccin Mocha, Nord, Dracula themes (75 RGB color slots each)
- [x] Multi-line input verified (Shift+Enter, Ctrl+X Ctrl+E — pre-existing)
- [x] Session cost sparkline (▁▂▃▄▅▆▇█) in sidebar
- [x] Syntax highlighting in right pane file preview
- [x] Dimmed backdrop behind all overlay dialogs
- [x] Click-to-preview file paths from chat messages
- [x] Agent metadata in CompactResult for checkpoint restore
- [x] Theme sidebar hints for new themes
- [x] Tagged v1.3.0, pushed to origin/master

## Done (v1.2.0 session — 2026-04-26)

- [x] Virtual scroll (ScrollView builder pattern)
- [x] Enhanced status bar (provider/model + mode tags)
- [x] Contextual spinner ("Thinking..."/"Writing..."/"Running tool...")
- [x] Tool markers (🔧 pending, ✅ success, ❌ failed)
- [x] Palette overhaul (PaletteItem, fuzzy match, model switcher, file quick-open)
- [x] Test harness (26 tests)
- [x] Typewriter animation re-enabled

## Done (v1.1.0 session — 2026-04-26)

- [x] Streaming render dead — tick timer fix
- [x] KnowledgePipeline crash — disabled pending fix
- [x] Permission toJson use-after-free — errdefer fix
- [x] Guardian dangling pointer — owned copy fix
- [x] default_tools.json parse error — removed dup brackets
- [x] Agent-loop segfault — dupe config strings
- [x] Model display double prefix — strip provider prefix
- [x] HTTP retry blindness — parseHttpStatus classification
- [x] NVIDIA NIM provider added (23rd)
- [x] Accidentally committed files removed (1018 files)
- [x] .gitignore cleanup
