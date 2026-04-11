# Architecture

**Analysis Date:** 2026-04-11

## Pattern Overview

**Overall:** Modular CLI with layered architecture

**Key Characteristics:**
- Command-based CLI dispatch via `handlers.zig`
- Provider-agnostic AI client with registry pattern
- Plugin system with JSON-RPC 2.0 protocol
- MCP (Model Context Protocol) client for external tool integration
- Hybrid bridge unifying built-in plugins and MCP servers

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              crushcode CLI                                   │
│                          (src/main.zig - entry)                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
            ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
            │     CLI      │  │   Config    │  │   Plugin    │
            │   (args.zig) │  │ (config.zig)│  │(interface)  │
            └──────────────┘  └──────────────┘  └──────────────┘
                    │                 │                 │
                    ▼                 │                 │
            ┌──────────────────────────────────────────────┐
            │              Commands (handlers.zig)          │
            │         chat.zig  │  read.zig  │  list       │
            └──────────────────────────────────────────────┘
                    │       │          │
                    ▼       ▼          ▼
            ┌───────────┬───────┬──────────────┐
            │    AI     │ FileOps│  Registry    │
            │ Client    │Reader │ (registry.zig)│
            │(client.zig)│(reader)│             │
            └───────────┴───────┴──────────────┘
                    │
                    ▼
            ┌───────────────────────────────────────────────┐
            │          Hybrid Bridge (hybrid_bridge.zig)     │
            │   ┌─────────────────┬─────────────────────┐   │
            │   │  Plugin Manager │    MCP Client       │   │
            │   │ (plugin_manager)│   (mcp/client.zig)  │   │
            │   └─────────────────┴─────────────────────┘   │
            │   Built-in Plugins:                            │
            │   - PTY (pty.zig)                             │
            │   - Table Formatter (table_formatter.zig)    │
            │   - Notifier (notifier.zig)                   │
            │   - Shell Strategy (shell_strategy.zig)     │
            └───────────────────────────────────────────────┘
```

## Module Dependency Graph

Derived from `build.zig`:

```
main.zig
├── args (cli/args.zig)
├── handlers (commands/handlers.zig)
│   ├── args (cli/args.zig)
│   ├── registry (ai/registry.zig)
│   ├── config (config/config.zig)
│   ├── chat (commands/chat.zig)
│   │   ├── args
│   │   ├── registry
│   │   ├── config
│   │   ├── client (ai/client.zig)
│   │   │   └── registry
│   │   └── provider_config
│   └── read (commands/read.zig)
│       └── fileops (fileops/reader.zig)
├── config (config/config.zig)
├── provider_config
└── plugin (plugin/interface.zig)
    └── protocol (plugin/protocol.zig)

Modules created in build.zig:
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

## Data Flow

### Chat Command Flow

1. **Entry**: `main.zig` receives CLI args
2. **Parse**: `args.zig` parses `--provider`, `--model`, `--interactive`
3. **Config Load**: `config.zig` loads `~/.crushcode/config.toml`
4. **Dispatch**: `handlers.zig.handleChat()` → `chat.zig.handleChat()`
5. **Provider Lookup**: `registry.zig` looks up provider by name
6. **Client Init**: `client.zig.AIClient.init()` creates HTTP client
7. **Request**: `client.zig.sendChat()` sends POST to provider API
8. **Response**: Parse JSON → return `ChatResponse` with choices

### Read Command Flow

1. **Entry**: `main.zig` receives `read` command
2. **Dispatch**: `handlers.zig.handleRead()` → `read.zig.handleRead()`
3. **File Read**: `reader.zig.FileReader.read()` opens file
4. **Output**: `reader.zig.FileContent.print()` prints to stdout

### Plugin Execution Flow

1. **Initialize**: `hybrid_bridge.zig.initializeBuiltIns()`
2. **Register**: `plugin_manager.zig.initializeBuiltIns()` creates 4 built-in plugins
3. **Route**: `hybrid_bridge.zig.routeRequest()` finds appropriate handler
4. **Execute**: Built-in plugin or MCP tool is invoked

## Layers

**CLI Layer:**
- Purpose: Argument parsing and command dispatch
- Location: `src/cli/args.zig`, `src/commands/handlers.zig`
- Contains: `Args` struct, command routing, help/version printing

**Configuration Layer:**
- Purpose: Load and manage user configuration
- Location: `src/config/config.zig`, `src/config/provider_config.zig`
- Contains: `Config` struct, TOML parsing, API key management

**AI Layer:**
- Purpose: Interface with AI providers
- Location: `src/ai/client.zig`, `src/ai/registry.zig`
- Contains: `AIClient`, `ProviderRegistry`, HTTP client, retry logic

**Command Layer:**
- Purpose: Implement user-facing commands
- Location: `src/commands/chat.zig`, `src/commands/read.zig`
- Contains: Chat (interactive + single message), file reading

**Plugin Layer:**
- Purpose: Extensible plugin system
- Location: `src/plugin/interface.zig`, `src/plugin/protocol.zig`
- Contains: `Plugin`, JSON-RPC 2.0 protocol, `PluginManager`

**MCP Layer:**
- Purpose: External tool integration
- Location: `src/mcp/client.zig`, `src/mcp/discovery.zig`
- Contains: `MCPClient`, server discovery, tool execution

**Hybrid Bridge:**
- Purpose: Unify built-in plugins and MCP tools
- Location: `src/hybrid_bridge.zig`
- Contains: `HybridBridge`, tool routing, mappings

## Key Abstractions

**ProviderRegistry** (`src/ai/registry.zig`):
- Purpose: Manage multiple AI provider configurations
- Key types: `ProviderType` enum (22 providers), `Provider`, `ProviderConfig`
- Pattern: Factory method to create providers with default configs

**AIClient** (`src/ai/client.zig`):
- Purpose: Generic HTTP client for any AI provider
- Key types: `ChatRequest`, `ChatResponse`, `ChatMessage`
- Pattern: Builder pattern for options, retry with exponential backoff

**Plugin** (`src/plugin/interface.zig`):
- Purpose: External tool integration interface
- Key types: `Request`, `Response`, `HealthStatus`
- Pattern: Lifecycle (init/deinit), JSON-RPC communication

**HybridBridge** (`src/hybrid_bridge.zig`):
- Purpose: Single entry point for all tools
- Pattern: Route request to either built-in plugin or MCP server

## Entry Points

**main()** (`src/main.zig:45`):
- Triggers: `crushcode [command] [options]`
- Responsibilities: Parse args → load config → dispatch command
- Error handling: Comprehensive early-exit checks with user-friendly messages

**handleChat()** (`src/commands/chat.zig:9`):
- Triggers: `crushcode chat [message] [--provider X] [--model Y] [--interactive]`
- Responsibilities: Initialize provider → create client → send request → print response

**handleRead()** (`src/commands/read.zig:4`):
- Triggers: `crushcode read <file> [file...]`
- Responsibilities: Open files → read content → print formatted output

**handleList()** (`src/commands/handlers.zig:18`):
- Triggers: `crushcode list [--providers] [--models <provider>]`
- Responsibilities: List all providers or models for a provider

## Error Handling

**Strategy:** Early-exit with descriptive error messages

**Patterns:**
- Config errors: `error.HomeNotFound`, `error.InvalidPath`, `error.FileNotFound`
- Auth errors: `error.MissingApiKey`, `error.AuthenticationError`
- Network errors: `error.NetworkError`, `error.ServerError` (with retry)
- Plugin errors: `error.PluginNotFound`, `error.PluginInitializationFailed`

## Cross-Cutting Concerns

**Logging:** `std.log.info/warn/err` - structured logging via Zig's standard library

**Validation:** 
- Provider name validation via `ProviderType` enum
- API key presence check before requests
- File existence checks in `FileReader`

**Authentication:**
- Bearer token in `Authorization` header
- Environment variable fallback for config path
- Provider-specific headers (OpenRouter `HTTP-Referer`, `X-Title`)

---

*Architecture analysis: 2026-04-11*