# Crushcode — Session Handoff

**Updated:** 2026-04-26
**Status:** v1.4.0 Harness Engineering COMPLETE ✅ + Phase 22 Auto-Compact ✅
**Branch:** `master` | **Last commit:** `555aaa0` | **Build:** ✅ clean | **Tests:** ✅ pass

---

## What Is This Project

Zig-based AI coding CLI/TUI. Single binary, zero deps. ~280 `.zig` files, ~112K lines.
Build: `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zigcache`
Test: `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zigcache`
Remote: `git@github.com:bibondz/crushcode.git` (SSH, ed25519 key)

## Constraints

- CLI IS the TUI — no separate mode
- `export CI=true GIT_TERMINAL_PROMPT=0 GIT_EDITOR=: GIT_PAGER=cat` always
- Thai+English mixed — respond understandably
- "passing compiler ≠ program works" — test runtime too
- Read files thoroughly before editing
- Keep STATE.md updated
- Don't just delete — think about merging/improving
- **MAX 2 CONCURRENT BACKGROUND TASKS**
- Build: `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zigcache`
- Drop aarch64-linux, keep aarch64-macos
- Don't compress GSD planning docs

## Zig API Notes

- `std.json.Stringify.valueAlloc(allocator, value, options)` for JSON serialization
- `std.json.parseFromSlice` / `parseFromSliceLeaky` for deserialization
- `array_list_compat.ArrayList(T)` not `std.ArrayList(T)` — project convention
- `array_list_compat.ArrayList.deinit()` takes no allocator param (stores internally)
- `file_compat.wrap()` for file handles
- `std.heap.ArenaAllocator` for thread-local allocations (page_allocator is thread-safe but ArenaAllocator is NOT)
- `std.http.Client` — create fresh per-thread, don't share across threads

## Version Bump Pattern (5 files + 1 test)

1. `src/tui/widgets/types.zig` — `app_version`
2. `src/commands/update.zig` — `current_version`
3. `src/commands/install.zig` — `version`
4. `src/mcp/client.zig` — client_info version
5. `src/mcp/server.zig` — server_info version + test assertion

## Recent Work (v1.2.0–v1.4.0)

### v1.4.0 — Harness Engineering (7 commits, +6192 lines)

- **P0: Execution Traces** — src/trace/ (Span, Writer, Context, hierarchical timing)
- **P0: Self-Healing Retry** — src/retry/ (error classification + prompt repair)
- **P1: Circuit Breaker** — closed/open/half_open FSM, configurable thresholds
- **P1: Routing Strategies** — FallbackChain, ProviderLatency EMA P50/P95, cost-aware routing
- **P1: Guardrail Pipeline** — PII scanner, injection detection, secrets scanner (1093 lines)
- **P2: Observability Metrics** — counter/gauge/histogram, Prometheus + JSONL export
- **P2: LLM Compaction** — compactWithLLM, truncateToolOutputs, CompactionConfig
- **P2: Cache-Aware Client** — CacheControl, CacheMarkedMessage for Anthropic cache hints
- **P3: Tool Inspection** — ToolInspectionPipeline, DangerLevel (safe/moderate/dangerous)
- **P3: Parallel Execution** — chunked thread-per-task, ordered results
- **Wiring** — All P1-P3 wired into client.zig, loop.zig, router.zig with circuit breaker feedback
- **Phase 22: Auto-Compact** — Trigger performCompactionAuto() after each AI response when context >70%

### v1.3.0 — TUI Polish (5 commits)

- **6 Themes**: Catppuccin Mocha, Nord, Dracula added (truecolor RGB, 75 slots each)
- **Session Sparkline**: ▁▂▃▄▅▆▇█ per-turn token usage chart in sidebar
- **Syntax Preview**: File preview pane with language-aware highlighting (20 langs)
- **Dialog Backdrop**: Dimmed backdrop behind all 6 overlay types
- **Click-to-Preview**: Mouse click scans messages for file paths, opens in preview

### v1.2.0 — TUI Foundation (1 large commit)

- **Virtual Scroll**: ScrollView builder — only visible widgets created (~80% fewer allocations)
- **Status Bar**: provider/model prefix + [CRUSH]/[DELEGATE]/[SCROLL] mode tags
- **Contextual Spinner**: "Thinking..."/"Writing..."/"Running {tool}..."
- **Tool Markers**: 🔧 pending, ✅ success (N lines), ❌ failed
- **Palette Overhaul**: PaletteItem categories (⚡/🤖/📄/💾), fuzzy search, model switcher, 120-char popup
- **Split Pane**: Right pane with Ctrl+\ toggle
- **File Tree Sidebar**: CWD listing, Ctrl+R refresh

## Architecture Quick Map

```
build.zig (~1115 lines) — module imports + build config (all harness modules registered)
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model, draw(), handleEvent())
src/tui/model/streaming.zig — streaming worker, finishRequestSuccess(), auto-compact trigger
src/tui/theme.zig — 6 themes × 75 color slots
src/tui/markdown.zig — syntax highlighting (20 langs), public tokenizer
src/tui/widgets/ — palette, sidebar, messages, spinner, input, multiline_input, diff_preview, etc.
src/tui/model/ — streaming, token_tracking, palette, session_mgmt, history, helpers
src/ai/client.zig — AI HTTP client (23 providers, streaming, guardrails, metrics, circuit breaker)
src/ai/registry.zig — provider registry
src/agent/loop.zig — agent loop (tool inspection, metrics, parallel execution)
src/agent/compaction.zig — ContextCompactor (compactWithLLM, compactLight, compactWithSummary)
src/agent/circuit_breaker.zig — closed/open/half_open FSM
src/agent/router.zig — routing strategies, latency tracking
src/commands/handlers/ — ai.zig, system.zig, tools.zig, experimental.zig (shim → 5 domain handlers)
src/chat/tool_executors.zig — shared tool implementations (30 builtin tools)
src/metrics/ — collector, registry (counter/gauge/histogram, Prometheus+JSONL)
src/guardrail/ — pipeline, pii_scanner, injection, secrets
src/tool/ — inspection, parallel execution
src/trace/ — execution traces (Span, Writer, Context)
src/retry/ — self-healing retry with error classification
src/mcp/ — client, bridge, discovery, server, transport, oauth
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → runtime plugins)
src/db/ — SQLite wrapper, session CRUD, JSON migration
```

## TUI Key Bindings

```
Ctrl+P      Command palette (search commands, switch models, open files)
Ctrl+B      Toggle sidebar
Ctrl+\      Toggle right pane (file preview)
Ctrl+R      Refresh sidebar project files
Ctrl+H / ?  Help overlay
Ctrl+X,E    Open external editor ($EDITOR)
Shift+Enter New line in input
Enter       Send message
j/k         Scroll messages (in scroll mode)
g/G         Scroll top/bottom
```

## TUI Overlay System (6 types)

All overlays get dimmed backdrop (header_bg + dim=true):
1. Palette (`show_palette`)
2. Permission dialog (`pending_permission`)
3. Diff preview (`diff_preview_active`)
4. Session list (`show_session_list`)
5. Resume prompt (`resume_prompt_session`)
6. Help (`show_help`)

## Mouse Support

- Left click in message area → scans last 20 messages for file paths → opens in preview
- Wheel scroll handled by vaxis ScrollView (wheel_scroll=3)
- Mouse shape changes not yet implemented

## Git Operations

```bash
# Always prefix with env vars
export CI=true DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never HOMEBREW_NO_AUTO_UPDATE=1 GIT_EDITOR=: EDITOR=: VISUAL='' GIT_SEQUENCE_EDITOR=: GIT_MERGE_AUTOEDIT=no GIT_PAGER=cat PAGER=cat npm_config_yes=true PIP_NO_INPUT=1 YARN_ENABLE_IMMUTABLE_INSTALLS=false

# Push requires SSH agent
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
```

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| KnowledgePipeline fix (KP-1) | Medium | Dangling pointer, currently disabled |
| Build.zig cleanup (1115→~700 lines) | Medium | Create `createStdModule()` helper |
| Vault→persistence merge | Medium | Circular dep risk |
| Cache-aware Anthropic HTTP body | Low | CacheControl structs exist, not wired to HTTP body |
| Guardrail redaction pass | Low | deny works, redact→modified content not fully sent |
| LLM compaction full wiring | Low | Needs sendToLLM function pointer |
| Responsive layout | Low | FlexRow/FlexColumn available |
| Resizable panes | Low | SplitView available |
| Input history search | Low | Need new binding (Ctrl+R taken) |

## Next Roadmap Items

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 22 | Smart Context + Auto-Compact | ✅ Mostly done |
| Phase 23 | Myers Diff + Edit Preview | Not started |
| Phase 24 | System Prompt Engineering + Project Config | Not started |
| Phase 25 | Batch Operations + Undo/Redo | Not started |

## How To Continue

1. Read `.planning/STATE.md` for current position
2. Check git log for recent changes
3. Pick from known remaining items above, or plan new features
4. Build-test after every change, commit with descriptive messages
5. Max 2 concurrent background tasks
