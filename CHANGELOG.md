# Changelog

All notable changes to Crushcode.

## [3.8.0] — 2026-04-29

### Added
- **Unified version system** — single `const version = "3.8.0"` in build.zig, exposed to all modules via `build_options`. `--version` flag, `/version` slash command, and update checker all use the same constant.
- **Notification config** — `notifications_enabled` config field + `CRUSHCODE_NOTIFY` env var for future desktop notification support.

### Changed
- **Release cross-compile** — simplified to `zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall` instead of complex build.zig targets.

## [3.7.0] — 2026-04-29

### Fixed
- Eliminated all `@panic` crash paths — TUI preview null checks (3), permission OOM (1) now use graceful error handling.
- Replaced all `catch unreachable` with proper error propagation — metrics/collector.zig (3), diff/myers.zig (3).
- Replaced all `unreachable` in switch statements with safe defaults — language detection, permission guardian.
- Zero production crash paths remain in the entire codebase.

## [3.6.0] — 2026-04-29

### Added
- **OAuth deduplication** — shared `auth/oauth_helpers.zig` (218L) with PKCE helpers, token parsing, callback server. Both `mcp/oauth.zig` (-26%) and `auth/provider_oauth.zig` (-24%) delegate to it. ~101 lines saved.
- **37 critical-path tests** — `ai/client.zig` (getApiModelName, getChatPath, extractExtendedUsage, buildToolsJson), `ai/registry.zig` (nvidia toString), `agent/loop.zig` (17: AgentMode enum, tool permissions, ModeConfig defaults, LoopConfig, interrupt), `config/config.zig` (9: parseCommaList, getSystemPrompt, mergeOverride).
- **Agent loop decomposition** — extracted `commands/agent_setup.zig` (96L) from handleInteractiveChat god function.

### Cancelled
- Phase 57 (Knowledge Lint Merge) — investigation proved `knowledge/lint.zig` (vault-based) and `core/knowledge_lint.zig` (entry-based) are different linters for different data models. Not duplication.

## [0.2.2] — 2026-04-14

### Added — Architecture & Features (Phase A–D)
- **Architecture reorganization** — shared task primitives, plugin trinity consolidation, CapabilityCatalog, file splits across 6 modules
- **F1: Output Intensity** (`src/core/intensity.zig`) — lite/full/ultra output modes
- **F2: Tiered Context Loading** (`src/core/tiered_loader.zig`) — LoadTier enum with token budgets
- **F5/F6: XML Atomic Plan + Gap Closure** (`src/workflow/phase.zig`) — structured plan format with phase management
- **F8: Revision Loop** (`src/core/revision_loop.zig`) — iterative refinement tracking
- **F10: Adversarial Review** (`src/core/adversarial_review.zig`) — dual-model review framework
- **F11: Session Summarization** (`src/core/session_summarizer.zig`) — session stats on exit
- **F13: Model Hot-Swap** (`src/core/model_hotswap.zig`) — `/model provider/model` with swap history
- **F14: Convergence Detection** (`src/core/convergence.zig`) — plateau detection for agent iterations
- **F15: Custom Commands** (`src/commands/custom_commands.zig`) — markdown-defined slash commands
- **F16: Slash Commands** (`src/core/slash_commands.zig`) — interactive /help, /clear, /exit, /status, /version, /tools, /tokens, /cost
- **F18: Knowledge Lint** (`src/core/knowledge_lint.zig`) — knowledge base consistency checker
- **F19: Source Tracking** (`src/core/source_tracker.zig`) — response provenance metadata
- **F22: Typed Colors** (`src/core/color.zig`) — type-safe ANSI styles replacing raw escape codes

### Changed — Shelfware Integration (Phase E)
- Wired 10 modules into chat.zig runtime: color, slash commands, intensity, model hotswap, session summarizer, tiered loader, convergence, capability catalog, usage budget/report
- Fixed `src/capability/catalog.zig` to use array_list_compat + file_compat
- Fixed `src/usage/report.zig` relative imports → named module imports
- Fixed `src/core/slash_commands.zig` execute() return type handling

### Added — UI/UX (Phase F)
- **Streaming Spinner** (`src/core/spinner.zig`) — shows `⠹ Thinking...` indicator while waiting for AI responses
- **Markdown Renderer** (`src/core/markdown_renderer.zig`) — ANSI-styled headers, bold, italic, code, lists, blockquotes for AI responses
- **Boxed Error Display** (`src/core/error_display.zig`) — Unicode box-drawn error/warning/info messages with color-coded severity
- Wired spinner into interactive AI request flow
- Wired markdown renderer into single-message response output
- Wired error display into 6 error/warning sites across chat.zig

### Added — Config Externalization (Phase G)
- **[model] config section** — `max_tokens` (default 4096) and `temperature` (default 0.7) now configurable via config.toml
- **[[provider_overrides]] config section** — per-provider base_url customization
- Added `max_tokens` and `temperature` fields to AIClient struct, replaced 5 hardcoded 2048/0.7 values
- `buildStreamingBodyFromMessages` now accepts max_tokens/temperature parameters
- Config values wired through both single-message and interactive chat clients

### Changed
- Version bumped to 0.2.2 across install, mcp/client, tui/app

---

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
