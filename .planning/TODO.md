# Crushcode — TODO & Known Issues

**Updated:** 2026-04-26
**Version:** v1.1.0 (8 post-release bugfixes applied)

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

**Problem Pattern:** Methods using `defer` for arena cleanup but returning json objects allocated on that arena. Fixed to `errdefer`. **Watch for this pattern** in other modules — any function that creates an ArenaAllocator, allocates a result on it, then returns the result. The `defer arena.deinit()` kills the returned data.

---

## MEDIUM Priority

### [TW-1] Typewriter Animation Thread Safety

**Status:** Workaround in place (commit `19cc7d4`)
**File:** `src/tui/widgets/typewriter.zig`

**Current State:** `updateText()` sets `revealed = total_codepoints` immediately, bypassing animation. The actual typewriter animation (per-character reveal with randomized delay) is disabled because it was being called from the worker thread, which is unsafe for TUI state.

**Fix:** Implement proper per-char timer on main thread:
- Worker thread sends chars to a thread-safe queue
- Main thread's tick handler (now 33ms) pops from queue and reveals one char per tick
- Keeps the typewriter effect without thread safety issues

---

### [WIN-1] Windows Cross-Compile

**Status:** Partial (commit `506acd3`)
**Files:** `src/main.zig` (sigaction guard), build.zig

**Current State:** `sigaction` call guarded behind `@hasDecl(os.system, "sigaction")`. Windows paths fixed (LOCALAPPDATA). PowerShell installer added.

**Remaining:**
- Full `zig build -Dtarget=x86_64-windows-gnu` test
- Verify TUI rendering on Windows Terminal
- Test PTY alternative (conpty) for shell command execution
- Verify MCP server discovery paths

---

### [BZ-1] Build.zig Cleanup

**Status:** Not started
**File:** `build.zig` (~900 lines)

**Goal:** Reduce to ~500 lines by creating `createStdModule()` helper to eliminate the compat injection loop. Currently each module registration follows the same pattern with slight variations.

---

## LOW Priority

### [VP-1] Vault→Persistence Merge

**Status:** Not started
**Files:** `src/knowledge/vault.zig`, `src/knowledge/knowledge_persistence.zig`

**Risk:** Circular dependency — vault.zig imports knowledge_persistence. Need to extract shared types to break the cycle.

---

### [SQ-1] SQLite Test Runner

**Status:** Known issue
**File:** `build.zig`

**Problem:** `zig build test` fails on sqlite module because `@cImport` needs libc. Individual module tests pass. Workaround: test individual modules.

---

### [TAG-1] v1.2.0 Release Tag

**Status:** Ready after KnowledgePipeline fix
**Blockers:** KP-1 (KnowledgePipeline fix) — or accept disabled state and document it

**Version bump files (5):**
1. `src/tui/widgets/types.zig` — `app_version`
2. `src/commands/update.zig` — `current_version`
3. `src/commands/install.zig` — `version`
4. `src/mcp/client.zig` — client_info version
5. `src/mcp/server.zig` — server_info version + test assertion

---

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
