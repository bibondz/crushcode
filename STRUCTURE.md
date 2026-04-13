# Crushcode Codebase Structure

Living reference. Consult before adding features to know where things go.

---

## Directory Map

```
src/
├── main.zig                 Entry point. Parse args → load config → dispatch to handlers.
│
├── cli/                     Argument parsing and routing
│   ├── args.zig             Args struct, --flags, command enum
│   └── intent_gate.zig      Classify user intent (question vs command vs conversation)
│
├── commands/                User-facing command implementations
│   ├── handlers.zig         Central dispatch: routes command → handler function
│   ├── chat.zig             `crushcode chat` — single message, interactive, streaming
│   ├── connect.zig          `crushcode connect` — interactive credential setup
│   ├── git.zig              `crushcode git` — git shortcuts
│   ├── install.zig          `crushcode install` — self-update from GitHub releases
│   ├── jobs.zig             `crushcode jobs` — background job management
│   ├── plugin_command.zig   `crushcode plugin-command` — JSON-RPC plugin execution
│   ├── read.zig             `crushcode read` — file reading with formatting
│   ├── shell.zig            `crushcode shell` — shell command execution
│   ├── skills.zig           `crushcode skill` — list and execute skills
│   ├── tui.zig              `crushcode tui` — ANSI TUI for chat
│   └── write.zig            `crushcode write` — file writing with glob support
│
├── ai/                      AI provider communication
│   ├── client.zig           AIClient — HTTP requests, streaming, tool calling (1408 lines ⚠️)
│   ├── registry.zig         ProviderRegistry — 22 providers, model lists
│   ├── error_handler.zig    Retry logic, error formatting
│   └── fallback.zig         Model fallback chain
│
├── agent/                   Autonomous agent system
│   ├── loop.zig             AgentLoop — multi-turn tool-call cycle
│   ├── memory.zig           Conversation history management
│   ├── checkpoint.zig       Session save/restore
│   ├── compaction.zig       Context window compaction (summarize old messages)
│   ├── parallel.zig         Parallel agent executor
│   └── worktree.zig         Git worktree isolation for agents
│
├── config/                  Configuration management
│   ├── config.zig           Config struct — load/save ~/.crushcode/config.toml
│   ├── toml.zig             TOML parser
│   ├── provider_config.zig  Per-provider configuration (base_url, headers, models)
│   ├── profile.zig          Named profiles — create, switch, delete
│   ├── auth.zig             API key and OAuth token storage
│   ├── backup.zig           Config file backup and migration
│   ├── env.zig              Shared env helpers: getHomeDir, getConfigDir, getDataDir
│   ├── tool_loader.zig      Load tool definitions from JSON config
│   ├── quantization_config.zig  Quantization settings (placeholder for future)
│   ├── default_commands.zig Generated command list
│   └── default_commands.json    Command definitions
│
├── compat/                  Zig API compatibility wrappers
│   ├── file.zig             File wrapper — stdin/stdout/stderr with .writer()/.print()
│   └── array_list.zig       ArrayList helpers — toOwnedSlice, etc.
│
├── core/                    Shared API types
│   └── api.zig              Public type definitions used across modules
│
├── diff/                    Diff visualization
│   └── visualizer.zig       Inline and unified diff output
│
├── edit/                    Code editing tools
│   ├── ast_grep.zig         AST-aware code pattern search and replace
│   ├── validated_edit.zig   Safe edit with hash verification
│   ├── hashline.zig         Hash-based line identification
│   ├── hash_index.zig       Hash index for fast lookup
│   └── conflict.zig         Merge conflict detection and resolution
│
├── fileops/                 File operations
│   └── reader.zig           FileReader — read and format file contents
│
├── graph/                   Knowledge graph (codebase indexing)
│   ├── graph.zig            Graph — nodes, edges, communities, compression
│   ├── parser.zig           Source code parser for graph construction
│   └── types.zig            Graph type definitions
│
├── hooks/                   Lifecycle hooks
│   └── lifecycle.zig        Hook registry — pre/post execution callbacks
│
├── http/                    Shared HTTP client
│   └── client.zig           httpGet, httpPost, httpPostForm — wrapper over std.http
│
├── json/                    JSON utilities
│   └── extract.zig          Zero-copy extractString/extractInteger from raw JSON
│
├── lsp/                     Language Server Protocol client
│   └── client.zig           JSON-RPC 2.0 LSP client (goto, refs, hover, complete, diagnostics)
│
├── mcp/                     Model Context Protocol
│   ├── client.zig           MCPClient — server connections, tool discovery, execution (1764 lines ⚠️)
│   ├── discovery.zig        MCP server search (npm registry, config file)
│   └── bridge.zig           MCP → AI chat integration bridge
│
├── permission/              Permission system
│   ├── evaluate.zig         Evaluator — check tool permissions against policy
│   ├── security.zig         Security checker — dangerous commands, sensitive paths
│   ├── prompt.zig           Interactive permission prompt with timeout
│   └── types.zig            PermissionRequest, PermissionResponse, Policy types
│
├── plugin/                  Plugin system (JSON-RPC 2.0)
│   ├── interface.zig        Plugin struct, PluginManager, lifecycle
│   └── protocol.zig         JSON-RPC 2.0 Request/Response/Notification types
│
├── plugins/                 Built-in plugins (imported by plugin_manager.zig)
│   ├── pty.zig              PTY session management (Unix openpty)
│   ├── shell_strategy.zig   Command validation, ban interactive tools
│   ├── table_formatter.zig  Markdown table parser and formatter
│   ├── notifier.zig         Cross-platform notification system
│   └── registry.zig         Plugin lifecycle management, enable/disable
│
├── plugin_manager.zig       Orchestrates all built-in plugins
│
├── protocol/                Shared protocol types
│   ├── ai_types.zig         ChatMessage, ChatRequest, ChatResponse, ToolCall
│   └── tool_types.zig       Tool type definitions
│
├── scaffold/                Project scaffolding
│   └── project.zig          Generate PROJECT.md, REQUIREMENTS.md, ROADMAP.md
│
├── skills/                  Skill system
│   ├── types.zig            Skill struct, SkillLoader — parse SKILL.md files
│   └── import.zig           Import skills from external registries
│
├── streaming/               Streaming response handling
│   ├── types.zig            TokenUsage, StreamEvent, StreamChunk
│   ├── buffer.zig           Streaming buffer — accumulate chunks
│   ├── display.zig          Stream output display
│   ├── session.zig          StreamSession — manage streaming state
│   ├── json_output.zig      JSON Lines output format
│   └── parsers/
│       ├── ndjson.zig       Newline-delimited JSON parser
│       └── sse.zig          Server-Sent Events parser
│
├── theme/                   Color/theme system
│   └── mod.zig              Theme definitions, color palette
│
├── tools/                   Tool registry
│   └── registry.zig         ToolRegistry — register, enable/disable, categorize tools
│
├── tui/                     Full terminal UI (screen buffer based)
│   ├── mod.zig              TUI module re-exports
│   ├── app.zig              Application state and command handling
│   ├── components.zig       UI components — buttons, lists, text areas (1037 lines ⚠️)
│   ├── screen.zig           Screen buffer — render, scroll, regions
│   ├── layout.zig           Layout engine — vertical, horizontal, flex
│   ├── animate.zig          Animation system — spinner, progress
│   ├── parser.zig           Input parser — key sequences, mouse
│   ├── event.zig            Event types — key, mouse, resize
│   ├── input.zig            Input handling
│   └── terminal.zig         Terminal setup — raw mode, size detection
│
├── usage/                   Token usage and cost tracking
│   ├── tracker.zig          TokenUsage tracking per session
│   ├── pricing.zig          Per-model pricing table
│   ├── budget.zig           Budget limits (daily/monthly)
│   └── report.zig           Usage report formatting
│
└── workflow/                Workflow phase management
    └── phase.zig            Phase struct, dependency resolution, verification
```

---

## Dependency Rules

### Who imports whom (allowed →)

```
main.zig          → handlers, config, args, plugin
handlers.zig      → all commands/*, all top-level modules
commands/*        → ai/, config/, plugin/, compat/, streaming/, tools/
ai/               → config/, compat/, http/, protocol/
agent/            → ai/, config/, compat/
mcp/              → ai/, config/, compat/, http/, json/
plugin/           → compat/ only
plugins/          → compat/ only (via plugin_manager)
permission/       → compat/ only
config/           → compat/, env/, http/
tui/              → compat/ only (self-contained rendering)
streaming/        → compat/ only
```

### Forbidden patterns

- **commands/ importing commands/** — Route through handlers instead. (Exception: skills.zig, git.zig, jobs.zig currently import shell.zig — tech debt)
- **Circular imports** — A → B → A is banned. Currently clean.
- **plugin/ importing plugins/** — plugin_manager.zig mediates
- **tui/ importing ai/ or config/** — TUI is self-contained

---

## Adding New Features — Placement Guide

### "I want to add a new command"

1. Create `src/commands/<name>.zig`
2. Add `pub fn handle<Name>(allocator, args) void` 
3. Add command to enum in `src/cli/args.zig`
4. Add dispatch case in `src/commands/handlers.zig`
5. Register module in `build.zig`: `createModule` + `addImport` on handlers_mod + add to compat loop
6. Use `out()` helper (from file_compat) for output, NOT `std.debug.print`

### "I want to add a new AI provider"

1. Add entry to `ProviderType` enum in `src/ai/registry.zig`
2. Add default config in `getProviderDefaults()` in same file
3. Add models list in `getProviderModels()` 
4. Provider auto-works — `ai/client.zig` is provider-agnostic

### "I want to add a new built-in plugin"

1. Create `src/plugins/<name>.zig` — implement init/deinit/handleRequest
2. Add plugin field to `PluginManager` struct in `src/plugin_manager.zig`
3. Add init/register in `initializeBuiltIns()`
4. Add dispatch case in `handleRequest()`
5. Add import at bottom of plugin_manager.zig

### "I want to add a new shared utility"

1. Create in appropriate directory (see map above)
2. If cross-cutting (like env.zig, http/client.zig): create own dir
3. Register as module in `build.zig`
4. Add `addImport` on consuming modules
5. Add to compat imports loop for array_list_compat + file_compat

### "I want to add a new TUI component"

1. Add to `src/tui/components.zig` (or split if large enough)
2. Import via relative `@import` from tui/mod.zig
3. TUI is self-contained — don't import from ai/ or config/

---

## Shared Infrastructure (use, don't duplicate)

| Utility | Location | Purpose |
|---------|----------|---------|
| `file_compat.File` | `src/compat/file.zig` | stdin/stdout/stderr wrapper — `.writer()`, `.print()` |
| `array_list_compat` | `src/compat/array_list.zig` | ArrayList helpers |
| `env.getHomeDir()` | `src/config/env.zig` | HOME/USERPROFILE fallback |
| `env.getConfigDir()` | `src/config/env.zig` | ~/.crushcode path |
| `httpGet/httpPost` | `src/http/client.zig` | Shared HTTP client |
| `json_extract.extractString` | `src/json/extract.zig` | Zero-copy JSON field extraction |
| `TokenUsage` | `src/streaming/types.zig` | Canonical token usage struct |
| `out()` helper | Per-file (15 files) | `file_compat.File.stdout().writer().print(fmt, args) catch {}` |
| `stdout_print()` | handlers.zig | Same as out(), different name (avoids shadow) |

---

## File Size Watch List

Files approaching or exceeding maintainability limits. Split before growing further.

| File | Lines | Status |
|------|-------|--------|
| mcp/client.zig | 1764 | ⛔ Split: protocol.zig + transport.zig + client.zig |
| handlers.zig | 1621 | ⛔ Split: move implementations to respective command files |
| chat.zig | 1478 | ⚠️ Split: interactive mode → separate file |
| ai/client.zig | 1408 | ⚠️ Split: streaming → separate file |
| tui/components.zig | 1037 | ⚠️ Consider splitting by component type |
| tui/screen.zig | 766 | OK for now |
| graph/parser.zig | 773 | OK for now |
| mcp/discovery.zig | 542 | OK for now |
| scaffold/project.zig | 573 | OK for now |
| workflow/phase.zig | 674 | OK for now |

---

## Build System Convention

Every new module follows this pattern in `build.zig`:

```zig
const my_mod = b.createModule(.{
    .root_source_file = b.path("src/my/module.zig"),
    .target = target,
    .optimize = optimize,
});
// Add imports it needs:
my_mod.addImport("file_compat", compat_file_mod);
// Add it as import on consumers:
handlers_mod.addImport("my_module", my_mod);
```

All modules are added to the compat imports loop at bottom of build.zig (auto-gets array_list_compat + file_compat).
