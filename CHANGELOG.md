# Changelog

All notable changes to Crushcode.

## [0.2.1] — 2026-04-13

### Added
- **`crushcode plugin` command** — `list`, `enable`, `disable`, `status` subcommands for built-in plugin management
- **`src/json/extract.zig`** — zero-copy JSON field extraction (`extractString`, `extractInteger`), used by mcp/client, mcp/discovery, install
- **Plugin system wired** — `src/plugins/` (pty, shell_strategy, table_formatter, notifier, registry) + `src/plugin_manager.zig` fully compiled and integrated into build
- **`out()` stdout helper** — 15 files use the inline helper for consistent stdout output via `file_compat`
- **`err_print()` stderr helper** — `main.zig` uses stderr for error messages

### Fixed
- **PTY plugin** — replaced `@cImport` C interop with `std.posix` (openpty via `/dev/ptmx`, fork, execve, dup2, ioctl, kill)
- **Plugin LSP errors** — fixed `@intCast` result types, for-loop syntax (`0..`), `std.mem.startsWith` type param, `std.mem.sort` API, format specifiers (`{s}`)
- **plugin_manager.zig** — fixed enum tag `.builtin`, removed invalid init `catch`, added `PluginResponse`/`PluginStatus` types, fixed relative imports
- **502 `std.debug.print` calls** — user output → stdout, debug → `std.log`, errors → stderr (was all going to stderr)
- **TokenUsage duplication** — single definition in `streaming/types.zig`, imported by `usage/tracker.zig`
- **RetryConfig cross-reference** — comments linking `ai/error_handler.zig` and `agent/loop.zig` variants

### Changed
- Version bumped to 0.2.1 across install, mcp/client, tui/app

---

## [0.2.0] — 2026-04-12

### Added
- **Shared `src/config/env.zig`** — `getHomeDir`, `getConfigDir`, `getDataDir` (replaced 8 HOME/USERPROFILE duplicates)
- **Shared `src/http/client.zig`** — `httpGet`, `httpPost`, `httpPostForm` (replaced 11 HTTP boilerplate copies)
- **Real LSP client** (756 lines) — JSON-RPC 2.0 transport, Content-Length framing, diagnostics buffering, 5 subcommands (goto, refs, hover, complete, diagnostics)
- **Real OAuth flow** — callback server on random port, code exchange with PKCE, token refresh, `parseTokenResponse` shared helper
- **Real install command** (349 lines) — binary download from GitHub releases, OS/arch auto-detect, version fetch, PATH hints, `--uninstall`
- **Orphaned modules wired** — `diff/visualizer.zig` → handlers, `config/backup.zig` → config, `permission/security.zig` + `prompt.zig` → evaluate
- **`gemma4:31b-cloud`** added to Ollama provider model list
- **Permission evaluator** wired into chat flow
- **Streaming flag** in chat command
- **MCP discovery fixes** — shadow variable, lowerString args, mem.slice, readToEndAlloc args, error union unwrapping

### Removed
- **12 dead files** (2,359 lines) — `agents/base.zig`, `utils/string.zig`, `shell_old.zig`, `hybrid_bridge.zig`, 4 streaming exports, 4 quantization math files
- **`src/openspec/types.zig`** — unused placeholder (user prefers GSD)

---

## [0.1.0] — 2026-04-11

### Initial Release

Built from 27 GSD roadmap phases. 96 source files, ~32K lines of Zig.

#### Commands (17)
| Command | Description |
|---------|-------------|
| `chat` | AI chat (single message + interactive streaming) |
| `read` | Read files with formatting |
| `write` | Write/edit files with glob support |
| `list` | List providers or models |
| `connect` | Interactive provider credential setup |
| `shell` | Execute shell commands with timeout |
| `mcp` | MCP server management (list, tools, execute, connect, discover) |
| `lsp` | LSP operations (goto, refs, hover, complete, diagnostics) |
| `git` | Git shortcuts (status, log, diff, add, commit, push, pull, branch, checkout) |
| `diff` | File diff (inline + unified) |
| `plugin` | Plugin management (list, enable, disable, status) |
| `skill` | List and execute skills |
| `profile` | Profile management (create, switch, delete, set, list, show) |
| `checkpoint` | Session checkpoint save/restore/delete |
| `usage` | Token usage and cost reporting |
| `install` | Self-update from GitHub releases |
| `grep` | AST-aware code pattern search |

#### Module Architecture (20 modules)
| Module | Files | Purpose |
|--------|-------|---------|
| `agent/` | 6 | Agent loop, memory, checkpoint, compaction, parallel execution, worktree |
| `ai/` | 4+ | Multi-provider client, registry (22 providers), error handler, fallback |
| `cli/` | 2 | Argument parsing, intent gate |
| `commands/` | 12 | All CLI command handlers |
| `compat/` | 2 | file_compat, array_list_compat wrappers |
| `config/` | 11 | TOML config, auth, profiles, provider config, env helpers |
| `core/` | 1 | API definitions |
| `diff/` | 1 | Visual diff output |
| `edit/` | 4 | AST-grep, conflict resolution, validated edits |
| `fileops/` | 1 | File reading |
| `graph/` | 3 | Knowledge graph (nodes, edges, communities) |
| `hooks/` | 1 | Lifecycle hooks |
| `http/` | 1 | Shared HTTP client |
| `json/` | 1 | Zero-copy JSON field extraction |
| `mcp/` | 3+ | MCP client, discovery, bridge |
| `permission/` | 4 | Evaluator, security checker, prompt handler, types |
| `plugin/` | 2 | JSON-RPC 2.0 plugin interface |
| `plugins/` | 5 | Built-in plugins (PTY, shell strategy, table formatter, notifier, registry) |
| `skills/` | 2 | Skill loading and import |
| `streaming/` | 5 | Buffer, display, JSON output, session, types |
| `theme/` | 1 | Theme management |
| `tools/` | 1 | Tool registry |
| `tui/` | 8 | Full TUI (animate, app, components, event, input, layout, screen, terminal) |
| `usage/` | 4 | Token tracking, pricing, budget, reporting |
| `workflow/` | 1 | Phase management |

#### AI Providers (22)
openai, anthropic, gemini, xai, mistral, groq, deepseek, together, azure, vertexai, bedrock, ollama, lm-studio, llama-cpp, openrouter, zai, vercel-gateway, opencode-zen, opencode-go, and 3 more.

#### Key Technical Decisions
- **Zero dependencies** — Zig stdlib only (std.http for HTTP, std.json for parsing, std.process for shell)
- **Single binary** — `zig build` produces `crushcode` executable
- **file_compat wrapper** — abstracts stdin/stdout/stderr across Zig API versions
- **TOML config** — `~/.crushcode/config.toml` with profile support
- **JSON-RPC 2.0** — plugin system protocol
- **MCP client** — external tool integration via Model Context Protocol
