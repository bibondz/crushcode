<!-- GSD:project-start source:PROJECT.md -->
## Project

**Crushcode** — Zig-based AI coding CLI. Combines OpenCode (agent orchestration) + Crush (Shell/CLI in Go). Native perf, zero deps, cross-platform binary.

**Core Value:** Ship working AI coding assistant in Zig. Execute shell commands, manage files, interact with AI providers (Ollama, OpenRouter).

### Constraints

- **Language**: Zig stdlib only (no external deps)
- **Target**: Cross-platform CLI binary
- **Build**: `zig build` → `crushcode` executable
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Language
- Zig (0.13+), `std.http`, `std.json`, `std.process.Child`, `std.json.parseFromSlice`
- Zero external deps

## Build System
- `zig build` — Build file: `/mnt/d/crushcode/build.zig` (107 lines)
- Modules: cli_mod(`src/cli/args.zig`), registry_mod(`src/ai/registry.zig`), client_mod(`src/ai/client.zig`), config_mod(`src/config/config.zig`), provider_config_mod(`src/config/provider_config.zig`), fileops_mod(`src/fileops/reader.zig`), plugin_mod(`src/plugin/interface.zig`), read_mod(`src/commands/read.zig`), chat_mod(`src/commands/chat.zig`), handlers_mod(`src/commands/handlers.zig`), main_mod(`src/main.zig`)
- Name: `crushcode`

## Frameworks & Standard Library
| Module | Purpose |
|--------|---------|
| `std` | Core |
| `std.http` | HTTP client |
| `std.json` | JSON parse/serialize |
| `std.process` | Process spawn |
| `std.fs` | File ops |
| `std.net` | Network |
| `std.time` | Timestamps |
| `std.thread` | Sleep/delay |
| `std.hash` | Hash |
| `std.sort` | Sort |
| `std.heap` | Heap alloc |
| `std.fmt` | Format |
| `std.mem` | Memory |

No package manager. No external C libs.

## Platform Support
- Linux (primary), macOS, Windows (WSL/cross-compile)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming
- Files: `kebab-case.zig` (`client.zig`, `error_handler.zig`)
- Types: `PascalCase` (`AIClient`, `ChatResponse`, `ProviderRegistry`)
- Functions: `camelCase` (`init()`, `deinit()`, `sendChat()`)
- Fields: `camelCase` + `snake_case` internal (`allocator`, `api_key`)
- Errors: `PascalCase` (`AIClientError`, `ProviderType`, `RetryConfig`)

## Error Handling
- Error unions: `pub fn sendChat(...) !ChatResponse`
- `try` propagate, `catch` handle
- Null: `if (value) |v| { ... }`
- Default: `orelse` — `args.provider orelse config.default_provider`

## Memory
- `std.heap.page_allocator` at entry points
- Allocator as first param
- `defer` for cleanup, `errdefer` for rollback

## File Organization
- One primary type per `.zig` file, grouped by domain

## Docs
- `///` for public functions (purpose, params, behavior)
- Inline comments: `// Early exit for empty command string (safety check)`

## Style
- 4 spaces, no tabs. `const` > `var`. Early exit: `if (cond) return;`. `switch` for errors.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Patterns
- CLI dispatch via `handlers.zig`
- Provider-agnostic AI client + registry
- Plugin system (JSON-RPC 2.0)
- MCP client for external tools
- Hybrid bridge (built-in plugins + MCP)

## Module Dependency Graph
```
- cli_mod → src/cli/args.zig
- registry_mod → src/ai/registry.zig
- client_mod → src/ai/client.zig (imports: registry)
- config_mod → src/config/config.zig
- provider_config_mod → src/config/provider_config.zig
- fileops_mod → src/fileops/reader.zig
- plugin_mod → src/plugin/interface.zig (imports: protocol)
- read_mod → src/commands/read.zig (imports: fileops)
- chat_mod → src/commands/chat.zig (imports: args, registry, config, client, provider_config, plugin)
- handlers_mod → src/commands/handlers.zig (imports: args, registry, config, chat, read)
- main_mod → src/main.zig (imports: args, handlers, config, provider_config, plugin)
```

## Layers
- **CLI**: `src/cli/args.zig`, `src/commands/handlers.zig` — Args struct, routing, help/version
- **Config**: `src/config/config.zig`, `src/config/provider_config.zig` — Config struct, TOML, API keys
- **AI**: `src/ai/client.zig`, `src/ai/registry.zig` — AIClient, ProviderRegistry, HTTP, retry
- **Commands**: `src/commands/chat.zig`, `src/commands/read.zig` — Chat (interactive + single), file read
- **Plugin**: `src/plugin/interface.zig`, `src/plugin/protocol.zig` — Plugin, JSON-RPC 2.0, PluginManager
- **MCP**: `src/mcp/client.zig`, `src/mcp/discovery.zig` — MCPClient, discovery, tool exec
- **Bridge**: `src/hybrid_bridge.zig` — HybridBridge, tool routing

## Key Abstractions
- `ProviderType` enum (22 providers), `Provider`, `ProviderConfig` — factory method
- `ChatRequest`, `ChatResponse`, `ChatMessage` — builder pattern, retry w/ backoff
- `Request`, `Response`, `HealthStatus` — lifecycle (init/deinit), JSON-RPC
- `HybridBridge` — route to built-in plugin or MCP server

## Entry Points
- `crushcode [command] [options]` — parse args → load config → dispatch
- `crushcode chat [msg] [--provider X] [--model Y] [--interactive]` — init provider → client → request → response
- `crushcode read <file> [file...]` — open → read → format → print
- `crushcode list [--providers] [--models <provider>]` — list providers/models

## Error Types
- Config: `error.HomeNotFound`, `error.InvalidPath`, `error.FileNotFound`
- Auth: `error.MissingApiKey`, `error.AuthenticationError`
- Network: `error.NetworkError`, `error.ServerError` (retry)
- Plugin: `error.PluginNotFound`, `error.PluginInitializationFailed`

## Cross-Cutting
- Provider validation via `ProviderType` enum
- API key check before requests
- Bearer token in `Authorization` header
- Env var fallback for config path
- Provider-specific headers (OpenRouter `HTTP-Referer`, `X-Title`)
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Start work via GSD command to keep planning artifacts in sync:
- `/gsd:quick` — small fixes, docs, ad-hoc
- `/gsd:debug` — investigation, bug fix
- `/gsd:execute-phase` — planned phase work

No direct repo edits outside GSD workflow unless user explicitly bypasses.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Not configured. Run `/gsd:profile-user` to generate.
> Managed by `generate-claude-profile` — do not edit manually.
<!-- GSD:profile-end -->
