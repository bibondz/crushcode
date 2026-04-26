# Crushcode — TODO & Known Issues

**Updated:** 2026-04-26
**Version:** v1.4.0 (Harness Engineering complete, Phase 22 auto-compact shipped)

---

## HIGH Priority

### [KP-1] KnowledgePipeline Dangling Pointer

**Status:** Disabled (commit `bfdcb01`), pending fix
**File:** `src/agent/context_builder.zig:175-197`
**Plan:** `.planning/phases/kp-fix-PLAN.md`

**Problem:** `KnowledgePipeline.init()` returns the struct by value. Internal `KnowledgeIngester` and `KnowledgeQuerier` store `*KnowledgeVault` pointers to the `vault` field of the returned struct. When the struct is moved (returned by value), these pointers dangle. The HashMap iterator assertion fires during `query()` on the corrupt pointer.

**Impact:** TUI has no auto-indexing, no knowledge graph context in AI prompts.

**Fix:** Heap-allocate `KnowledgePipeline` via `allocator.create()`. Return `*KnowledgePipeline` instead of `KnowledgePipeline`. Update all call sites.

---

### [KP-2] Permission toJson Use-After-Free Pattern

**Status:** Fixed in commit `1ed5908` (4 methods)
**File:** `src/permission/types.zig`

**Problem Pattern:** Methods using `defer` for arena cleanup but returning json objects allocated on that arena. Fixed to `errdefer`. **Watch for this pattern** in other modules.

---

## MEDIUM Priority

### [HARNESS-1] Cache-Aware Anthropic HTTP Body

**Status:** Partial
**Files:** `src/ai/client.zig` — CacheControl + CacheMarkedMessage structs exist

**Gap:** CacheControl structs are defined but not wired into the actual HTTP body format for Anthropic API requests. Need to add `cache_control` field to message objects in the JSON body.

---

### [HARNESS-2] Guardrail Redaction Pass

**Status:** Partial
**Files:** `src/guardrail/pipeline.zig`

**Gap:** Deny mode works. Redact mode needs to actually modify the content (replace PII/secrets with `[REDACTED]`) before sending to provider.

---

### [HARNESS-3] LLM Compaction Full Wiring

**Status:** Partial
**Files:** `src/agent/compaction.zig` — compactWithLLM() exists

**Gap:** compactWithLLM() needs a `sendToLLM` function pointer plumbed through the agent loop to actually call the AI for summarization.

---

### [TW-1] Typewriter Animation Thread Safety

**Status:** Fixed (commit `83d11cb`)
**File:** `src/tui/widgets/typewriter.zig`

**Current State:** Re-enabled with thread-safe lock ordering. Worker thread sets text, main thread animates via tick timer.

---

### [WIN-1] Windows Cross-Compile

**Status:** Partial (commit `506acd3`)
**Files:** `src/main.zig` (sigaction guard), build.zig

**Remaining:**
- Full `zig build -Dtarget=x86_64-windows-gnu` test
- Verify TUI rendering on Windows Terminal
- Test PTY alternative (conpty) for shell command execution

---

### [BZ-1] Build.zig Cleanup

**Status:** Not started
**File:** `build.zig` (~1115 lines)

**Goal:** Reduce to ~700 lines by creating `createStdModule()` helper.

---

## LOW Priority

### [VP-1] Vault→Persistence Merge

**Status:** Not started
**Risk:** Circular dependency — vault.zig imports knowledge_persistence.

---

### [SQ-1] SQLite Test Runner

**Status:** Known issue
**Problem:** `zig build test` fails on sqlite module because `@cImport` needs libc. Individual module tests pass.

---

### Future TUI Improvements

| Item | Effort | Notes |
|------|--------|-------|
| Responsive layout (FlexRow/FlexColumn) | Medium | vaxis widgets available |
| Mouse-resizable panes (SplitView) | Medium | vaxis SplitView available |
| Input history search (Ctrl+R conflict) | Low | Need new binding |
| Proper dialog overlay abstraction | Medium | Currently 6 ad-hoc overlays |

---

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
