# Crushcode — Session Handoff

**Updated:** 2026-04-19
**Status:** v0.32.0 complete ✅

---

## What Is This Project

Zig-based AI coding CLI/TUI. Single binary, zero deps. ~250 `.zig` files, ~105K lines.
Build: `cd /mnt/d/crushcode && zig build --cache-dir /tmp/zig-build-cache`
Test: `cd /mnt/d/crushcode && zig build test --cache-dir /tmp/zig-build-cache`
Branch: `002-v0.2.2` | Last commit: `8faf8b2` | Build: ✅ clean | Tests: ✅ pass
Remote: `git@github.com:bibondz/crushcode.git` (SSH, ed25519 key)

## Constraints

- CLI IS the TUI — no separate mode
- `export CI=true GIT_TERMINAL_PROMPT=0 GIT_EDITOR=: GIT_PAGER=cat` always
- Thai+English mixed — respond understandably
- "passing compiler ≠ program works" — test runtime too
- Read files thoroughly before editing (`ลองอ่านไฟล์ project ให้รอบคอบก่อนแก้ไขครับ`)
- Keep STATE.md updated (`ทำไมไม่ค่อยจด state เลยครับ`)
- Don't just delete — think about merging/improving (`อย่าคิดแต่ว่าจะลบอย่างเดียวครับ`)

## Zig API Notes

- `std.json.Stringify.valueAlloc(allocator, value, options)` for JSON serialization
- `std.json.parseFromSlice` / `parseFromSliceLeaky` for deserialization
- `array_list_compat.ArrayList(T)` not `std.ArrayList(T)` — project convention
- `file_compat.wrap()` for file handles
- `std.heap.ArenaAllocator` for thread-local allocations (page_allocator is thread-safe but ArenaAllocator is NOT)
- `std.http.Client` — create fresh per-thread, don't share across threads

## Version Bump Pattern (5 files + 1 test)

1. `src/tui/widgets/types.zig` — `app_version`
2. `src/commands/update.zig` — `current_version`
3. `src/commands/install.zig` — `version`
4. `src/mcp/client.zig` — client_info version
5. `src/mcp/server.zig` — server_info version + test assertion

## Recent Work (v0.31.0–v0.32.0)

### v0.31.0 — Codebase Reorganization
- Split `experimental_handlers.zig` (3208 lines) → 5 domain files + 35-line re-export shim
- Relocated: orchestration→agent, cognition→agent, guardian→permission
- Consolidated: permission lists→lists.zig, knowledge ops→ops.zig
- Build.zig: 5 new handler modules, consolidated module declarations

### v0.32.0 — Runtime Bug Fixes
- **memory.zig**: Replaced naive `{s}` JSON formatting with `std.json.Stringify.valueAlloc` — was breaking on messages with quotes/backslashes/newlines
- **parallel.zig**: Thread-local `ArenaAllocator` per worker, dupe response content before arena cleanup, `base_url` field on `ParallelTask`
- **runtime.zig**: `getPlugin()` returns pointer (not value copy) — prevents double-kill on process deinit
- **runtime.zig**: Validate executable exists before spawning plugin process
- **hybrid_bridge.zig**: Removed `mut_plugin` copy shim
- **ai.zig**: Updated `submit()` callers for new `base_url` parameter

## Architecture Quick Map

```
build.zig (~863 lines) — module imports + build config
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update, ~3924 lines)
src/ai/client.zig — AI HTTP client (22 providers, streaming)
src/ai/registry.zig — provider registry
src/agent/ — agent loop, compaction, memory, parallel, orchestrator, context_builder, checkpoint
src/commands/handlers/ — ai.zig, system.zig, tools.zig, experimental.zig (shim → 5 domain handlers)
src/chat/tool_executors.zig — shared tool implementations (6 builtin tools)
src/mcp/ — client, bridge, discovery, server, transport, oauth
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → runtime plugins)
src/skills/import.zig — skill import via HTTP (clawhub, skills.sh, GitHub, URL)
src/plugin/ — mod.zig barrel (types, registry, manager, runtime, protocol)
src/permission/ — evaluate, audit, governance, guardian, lists
src/knowledge/ — schema, vault, persistence, ops, lint
src/graph/ — types, parser, algorithms, graph
src/tui/widgets/ — types, helpers, messages, header, input, sidebar, palette, permission, setup, spinner, gradient, toast, typewriter, code_view, data_table, scroll_panel
```

## Tool Dispatch Chain (HybridBridge)

```
1. Builtin tools (tool_executors.executeBuiltinTool) → 6 tools: read_file, shell, write_file, glob, grep, edit
2. MCP bridge (mcp_bridge.Bridge.executeTool) → remote MCP servers
3. Runtime plugins (plugin/runtime.ExternalPluginManager) → external plugin processes via JSON-RPC
```

## TUI Slash Commands (21)

```
/clear /sessions /ls /exit /model /thinking /compact
/theme /workers /kill /memory /plugins
/guardian /cognition /autopilot /team /spawn /phase-run /help
```

## Git Operations

```bash
# Always prefix with env vars
export CI=true DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never HOMEBREW_NO_AUTO_UPDATE=1 GIT_EDITOR=: EDITOR=: VISUAL='' GIT_SEQUENCE_EDITOR=: GIT_MERGE_AUTOEDIT=no GIT_PAGER=cat PAGER=cat npm_config_yes=true PIP_NO_INPUT=1 YARN_ENABLE_IMMUTABLE_INSTALLS=false

# Push requires SSH agent
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519

# Fast-forward master
git checkout master && git merge --ff-only 002-v0.2.2 && git push origin master && git checkout 002-v0.2.2
```

## Known Remaining Items

| Item | Priority | Notes |
|------|----------|-------|
| Build.zig cleanup (863→~500 lines) | Medium | Create `createStdModule()` helper to eliminate compat injection loop |
| Vault→persistence merge | Medium | Circular dep risk — vault.zig imports knowledge_persistence |
| Fresh roadmap for daily driver | Low | All roadmap v0.3.1–v0.7.0 done. Need new goals. |

## How To Continue

1. Read `.planning/STATE.md` for current position
2. Check git log for recent changes
3. Pick from known remaining items above, or plan new features
4. Build-test after every change, commit with descriptive messages
