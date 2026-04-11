# Codebase Structure

**Analysis Date:** 2026-04-11

## Directory Layout

```
crushcode/
├── build.zig                 # Build configuration (module definitions)
├── src/
│   ├── main.zig              # CLI entry point
│   ├── cli/
│   │   └── args.zig         # CLI argument parsing
│   ├── ai/
│   │   ├── client.zig       # AI HTTP client
│   │   ├── registry.zig     # Provider registry (22 providers)
│   │   └── error_handler.zig # Retry logic and error handling
│   ├── commands/
│   │   ├── handlers.zig     # Command dispatcher
│   │   ├── chat.zig         # Chat command (interactive + single)
│   │   └── read.zig         # Read file command
│   ├── config/
│   │   ├── config.zig       # Config loading (TOML)
│   │   └── provider_config.zig # Extended provider config
│   ├── plugin/
│   │   ├── interface.zig     # Plugin interface
│   │   └── protocol.zig     # JSON-RPC 2.0 protocol
│   ├── mcp/
│   │   ├── client.zig       # MCP client (JSON-RPC 2.0)
│   │   └── discovery.zig    # MCP server discovery
│   ├── plugins/
│   │   ├── pty.zig          # PTY terminal plugin
│   │   ├── table_formatter.zig # Markdown table formatter
│   │   ├── notifier.zig     # Desktop notifications
│   │   ├── shell_strategy.zig # Shell command strategy
│   │   └── registry.zig     # Plugin registry
│   ├── fileops/
│   │   └── reader.zig       # File reading
│   ├── plugin_manager.zig    # Plugin lifecycle management
│   └── hybrid_bridge.zig     # Unified tool routing
├── .crushcode/
│   └── config.toml          # Default config (created on first run)
└── README.md
```

## Directory Purposes

**`src/`:**
- Purpose: All application source code
- Contains: Zig source files, organized by concern

**`src/cli/`:**
- Purpose: Command-line interface
- Contains: `args.zig` - argument parsing
- Key files: `args.zig` - `Args` struct with `parse()` method

**`src/ai/`:**
- Purpose: AI provider integration
- Contains: HTTP client, provider registry, error handling
- Key files: `client.zig` - generic AI HTTP client; `registry.zig` - 22 providers

**`src/commands/`:**
- Purpose: CLI command implementations
- Contains: `handlers.zig` - dispatcher; `chat.zig` - chat logic; `read.zig` - file reading
- Key files: `handlers.zig` - routes to command-specific handlers

**`src/config/`:**
- Purpose: Configuration management
- Contains: `config.zig` - TOML config loading; `provider_config.zig` - extended config
- Key files: `config.zig` - loads `~/.crushcode/config.toml`

**`src/plugin/`:**
- Purpose: Plugin system interface and protocol
- Contains: `interface.zig` - Plugin struct; `protocol.zig` - JSON-RPC 2.0
- Key files: `interface.zig` - Plugin, PluginManager; `protocol.zig` - Request, Response

**`src/mcp/`:**
- Purpose: Model Context Protocol client
- Contains: `client.zig` - MCP client; `discovery.zig` - server discovery
- Key files: `client.zig` - MCPConnection, MCPTool; `discovery.zig` - MCPDiscovery

**`src/plugins/`:**
- Purpose: Built-in plugin implementations
- Contains: 4 built-in plugins (PTY, TableFormatter, Notifier, ShellStrategy)
- Key files: `pty.zig`, `table_formatter.zig`, `notifier.zig`, `shell_strategy.zig`

**`src/fileops/`:**
- Purpose: File system operations
- Contains: `reader.zig` - file reading
- Key files: `reader.zig` - FileReader, FileContent

## Key File Locations

**Entry Points:**
- `src/main.zig:45` - `pub fn main()` - CLI entry point
- `src/commands/handlers.zig:10` - `handleChat()` - chat command
- `src/commands/handlers.zig:14` - `handleRead()` - read command
- `src/commands/handlers.zig:18` - `handleList()` - list command

**Configuration:**
- `src/config/config.zig:100` - `getConfigPath()` - config file location
- `src/config/config.zig:159` - `loadOrCreateConfig()` - load or create config
- `src/config/provider_config.zig:87` - `ExtendedConfig.init()` - extended config

**AI Client:**
- `src/ai/client.zig:54` - `AIClient.init()` - create client
- `src/ai/client.zig:81` - `sendChat()` - send chat request
- `src/ai/registry.zig:265` - `ProviderRegistry` - manage providers

**Plugin System:**
- `src/plugin/interface.zig:6` - `Plugin` struct definition
- `src/plugin/interface.zig:152` - `PluginManager` struct
- `src/plugin/protocol.zig:136` - `ProtocolHandler` - JSON-RPC parsing

**MCP:**
- `src/mcp/client.zig:7` - `MCPClient` struct
- `src/mcp/client.zig:29` - `connectToServer()` - connect to MCP server
- `src/mcp/discovery.zig:6` - `MCPDiscovery` struct

**Hybrid Bridge:**
- `src/hybrid_bridge.zig:6` - `HybridBridge` struct
- `src/hybrid_bridge.zig:26` - `initializeBuiltIns()` - init plugins
- `src/hybrid_bridge.zig:86` - `routeRequest()` - route to handler

## Naming Conventions

**Files:**
- `snake_case.zig` - all Zig source files use snake_case
- `module_name.zig` - each file is a module (e.g., `client.zig`, `registry.zig`)

**Structs/Types:**
- PascalCase: `AIClient`, `ProviderRegistry`, `PluginManager`, `MCPClient`
- Type suffixes: `Config`, `Request`, `Response`, `Handler`

**Functions:**
- snake_case: `handleChat`, `sendChat`, `loadOrCreateConfig`, `initializeBuiltIns`
- Verb-noun pattern: `handleX`, `sendX`, `loadX`, `getX`, `setX`

**Variables/Fields:**
- snake_case: `default_provider`, `api_key`, `provider_name`
- Prefix: `is_` for booleans: `is_local`, `has_key`

**Modules/Packages:**
- Directories: `commands/`, `config/`, `ai/`, `plugin/`, `mcp/`, `fileops/`, `plugins/`
- Module imports: `@import("client")`, `@import("registry")`

## Where to Add New Code

**New Command:**
- Implementation: `src/commands/<command_name>.zig`
- Registration: Add to `src/commands/handlers.zig`
- Dispatch: Add case in `src/main.zig:109-125`

**New AI Provider:**
- Implementation: Add to `src/ai/registry.zig`
- Add to `ProviderType` enum (line 3-22)
- Add config in `getConfigForProvider()` (line 85-262)

**New Built-in Plugin:**
- Implementation: `src/plugins/<plugin_name>.zig`
- Registration: Add to `src/plugin_manager.zig:45-130`
- Add to `PluginManager` struct (line 11-14)

**New MCP Server:**
- Implementation: Via `src/mcp/client.zig`
- Discovery: Add to `src/mcp/discovery.zig:addDefaultServers()`

**New File Operation:**
- Implementation: `src/fileops/<operation>.zig`
- Export via `src/fileops/reader.zig` pattern

## Module Boundaries

**CLI → Commands:** `handlers.zig` is the thin glue layer; commands implement logic

**Commands → AI:** Commands use `registry.zig` to find provider, then `client.zig` for HTTP

**Config → Commands:** Config is passed to commands; commands call `config.getApiKey()`

**Plugin Interface → Plugins:** `interface.zig` defines Plugin struct; implementations in `plugins/`

**MCP → Hybrid Bridge:** `hybrid_bridge.zig` is the facade; routes to either plugin or MCP

**No circular dependencies:** build.zig shows clean import graph from main → handlers → chat/read → ai/config

## Special Directories

**`.crushcode/`:**
- Purpose: User configuration storage
- Contains: `config.toml`
- Generated: Yes (on first run via `createDefaultConfig()`)
- Committed: No (in `.gitignore`)

**`src/plugins/`:**
- Purpose: Built-in plugin implementations
- Contains: 4 plugins (PTY, TableFormatter, Notifier, ShellStrategy)
- Generated: No
- Committed: Yes

---

*Structure analysis: 2026-04-11*