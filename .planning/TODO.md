# Crushcode — TODO & Known Issues

**Updated:** 2026-04-26
**Version:** v1.3.0 (TUI polish batch complete)

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
**File:** `build.zig` (~900 lines)

**Goal:** Reduce to ~500 lines by creating `createStdModule()` helper.

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

### [TAG-1] v1.3.0 Release Tag

**Status:** Ready to tag
**Blockers:** None — all TUI features shipped, build clean, tests pass

**Version bump files (5):**
1. `src/tui/widgets/types.zig` — `app_version`
2. `src/commands/update.zig` — `current_version`
3. `src/commands/install.zig` — `version`
4. `src/mcp/client.zig` — client_info version
5. `src/mcp/server.zig` — server_info version + test assertion

---

### Future TUI Improvements

| Item | Effort | Notes |
|------|--------|-------|
| Responsive layout (FlexRow/FlexColumn) | Medium | vaxis widgets available |
| Mouse-resizable panes (SplitView) | Medium | vaxis SplitView available |
| Input history search (Ctrl+R conflict) | Low | Need new binding |
| Proper dialog overlay abstraction | Medium | Currently 6 ad-hoc overlays |
| Syntax code preview (CodeView) | Low | No vaxis CodeView widget yet |

---

## Done (v1.3.0 session — 2026-04-26)

- [x] Catppuccin Mocha, Nord, Dracula themes (75 RGB color slots each)
- [x] Multi-line input verified (Shift+Enter, Ctrl+X Ctrl+E — pre-existing)
- [x] Session cost sparkline (▁▂▃▄▅▆▇█) in sidebar
- [x] Syntax highlighting in right pane file preview
- [x] Dimmed backdrop behind all overlay dialogs
- [x] Click-to-preview file paths from chat messages
- [x] Agent metadata in CompactResult for checkpoint restore
- [x] Theme sidebar hints for new themes

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
