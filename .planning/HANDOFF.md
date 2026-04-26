# Crushcode — Session Handoff

**Updated:** 2026-04-26
**Status:** v1.3.0 TUI Polish COMPLETE ✅
**Branch:** `master` | **Last commit:** `b7cbb43` | **Build:** ✅ clean | **Tests:** ✅ pass

---

## What Is This Project

Zig-based AI coding CLI/TUI. Single binary, zero deps. ~265 `.zig` files, ~105K lines.
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

## Recent Work (v1.2.0–v1.3.0 — TUI Overhaul)

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
build.zig (~900 lines) — module imports + build config
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model, draw(), handleEvent(), ~4634 lines)
src/tui/theme.zig — 6 themes × 75 color slots
src/tui/markdown.zig — syntax highlighting (20 langs), public tokenizer
src/tui/widgets/ — palette, sidebar, messages, spinner, input, multiline_input, diff_preview, etc.
src/tui/model/ — streaming, token_tracking, palette, session_mgmt, history, helpers
src/ai/client.zig — AI HTTP client (23 providers, streaming)
src/ai/registry.zig — provider registry
src/agent/ — agent loop, compaction, memory, parallel, orchestrator, context_builder, checkpoint
src/commands/handlers/ — ai.zig, system.zig, tools.zig, experimental.zig (shim → 5 domain handlers)
src/chat/tool_executors.zig — shared tool implementations (30 builtin tools)
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
| Build.zig cleanup (900→~500 lines) | Medium | Create `createStdModule()` helper |
| Vault→persistence merge | Medium | Circular dep risk |
| v1.3.0 version bump + tag | Low | 5 files to update |
| Responsive layout | Low | FlexRow/FlexColumn available |
| Resizable panes | Low | SplitView available |
| Input history search | Low | Need new binding (Ctrl+R taken) |

## How To Continue

1. Read `.planning/STATE.md` for current position
2. Check git log for recent changes
3. Pick from known remaining items above, or plan new features
4. Build-test after every change, commit with descriptive messages
5. Max 2 concurrent background tasks
