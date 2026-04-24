<!-- GSD:project-start source:PROJECT.md -->
## Project

**Crushcode**

A Zig-based AI coding CLI tool that combines capabilities from OpenCode (AI agent orchestration) and Crush (Shell/CLI in Go). Built in Zig for native performance, zero dependencies, and cross-platform binary output.

**Core Value:** Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

### Constraints

- **Language**: Zig — must use Zig stdlib only (no external deps)
- **Target**: Cross-platform CLI binary
- **Build**: `zig build` producing `crushcode` executable
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Language
- Zig (modern systems programming language)
- Language version: Determined by Zig compiler (version 0.13+ recommended based on std library patterns used)
- Native HTTP client support via `std.http`
- Native JSON-RPC 2.0 support via `std.json`
- Native process/child management via `std.process.Child`
- Zero-cost JSON parsing with `std.json.parseFromSlice`
- No external dependencies required
## Build System
- Zig build system (`zig build`)
- Build file: `/mnt/d/crushcode/build.zig` (107 lines)
- cli_mod: src/cli/args.zig
- registry_mod: src/ai/registry.zig
- client_mod: src/ai/client.zig
- config_mod: src/config/config.zig
- provider_config_mod: src/config/provider_config.zig
- fileops_mod: src/fileops/reader.zig
- plugin_mod: src/plugin/interface.zig (imports protocol.zig)
- read_mod: src/commands/read.zig
- chat_mod: src/commands/chat.zig
- handlers_mod: src/commands/handlers.zig
- main_mod: src/main.zig
- Name: `crushcode`
- Target/optimize: Standard Zig options
## Frameworks & Standard Library
| Module | Purpose |
|--------|---------|
| `std` | Core standard library |
| `std.http` | HTTP client (fetch, request, response) |
| `std.json` | JSON parsing and serialization |
| `std.process` | Process/child spawning |
| `std.fs` | File system operations |
| `std.net` | Network streams |
| `std.time` | Timestamp generation |
| `std.thread` | Sleep/delay |
| `std.hash` | Hash functions |
| `std.sort` | Sorting utilities |
| `std.heap` | Heap allocation |
| `std.fmt` | String formatting |
| `std.mem` | Memory operations |
- All functionality built with Zig stdlib
- No package manager required
- No external C libraries needed
## Module Structure
## Key Dependencies
- No npm/pip/cargo dependencies
- All HTTP/JSON/network handled by stdlib
- All crypto via `std.crypto` if needed
## Runtime Requirements
- Zig compiler (0.13+)
- Standard C library (libc)
- Terminal for stdio plugins
- Linux/Unix system with Zig runtime
- Or compiled to single binary via Zig
- No interpreter needed
## Platform Support
- Linux (primary)
- macOS/Unix-like systems
- Windows (via WSL or cross-compilation)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- Pattern: `kebab-case.zig` (lowercase with hyphens)
- Example: `client.zig`, `error_handler.zig`, `string.zig`
- Pattern: `PascalCase`
- Example: `AIClient`, `ChatResponse`, `ProviderRegistry`, `PluginManager`
- Pattern: `camelCase`
- Example: `init()`, `deinit()`, `sendChat()`, `loadOrCreateConfig()`
- Pattern: `camelCase` with `snake_case` for some internal fields
- Example: `allocator`, `api_key`, `provider_name`, `request_times`
- Pattern: `PascalCase`
- Example: `AIClientError`, `ProviderType`, `RetryConfig`
## Error Handling
- Functions return error unions: `pub fn sendChat(...) !ChatResponse`
- Pattern: `try` for propagating, `catch` for handling
- Null checks with `if (value) |v| { ... }` pattern
- Uses `orelse` for default values: `args.provider orelse config.default_provider`
## Memory Management
- Uses `std.heap.page_allocator` in most CLI entry points
- Passes allocator as first parameter to functions
- `defer` statements for guaranteed cleanup:
- `errdefer` for error rollback:
## File Organization
- Each `.zig` file defines one primary public type
- Files group related functionality by domain
## Import Patterns
## Struct Patterns
## Documentation Style
- Uses `///` for public function documentation
- Describes purpose, parameters, and behavior
- Example from `src/main.zig`:
- Used for validation and explanations
- Pattern: `// Early exit for empty command string (safety check)`
## Code Style
- 4 spaces, no tabs
- Prefers `const` over `var`
- Only uses `var` for mutable state (rare)
- Early exit pattern: `if (condition) return;`
- Uses `switch` for error handling
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Command-based CLI dispatch via `handlers.zig`
- Provider-agnostic AI client with registry pattern
- Plugin system with JSON-RPC 2.0 protocol
- MCP (Model Context Protocol) client for external tool integration
- Hybrid bridge unifying built-in plugins and MCP servers
## Component Diagram
```
```
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
## Data Flow
### Chat Command Flow
### Read Command Flow
### Plugin Execution Flow
## Layers
- Purpose: Argument parsing and command dispatch
- Location: `src/cli/args.zig`, `src/commands/handlers.zig`
- Contains: `Args` struct, command routing, help/version printing
- Purpose: Load and manage user configuration
- Location: `src/config/config.zig`, `src/config/provider_config.zig`
- Contains: `Config` struct, TOML parsing, API key management
- Purpose: Interface with AI providers
- Location: `src/ai/client.zig`, `src/ai/registry.zig`
- Contains: `AIClient`, `ProviderRegistry`, HTTP client, retry logic
- Purpose: Implement user-facing commands
- Location: `src/commands/chat.zig`, `src/commands/read.zig`
- Contains: Chat (interactive + single message), file reading
- Purpose: Extensible plugin system
- Location: `src/plugin/interface.zig`, `src/plugin/protocol.zig`
- Contains: `Plugin`, JSON-RPC 2.0 protocol, `PluginManager`
- Purpose: External tool integration
- Location: `src/mcp/client.zig`, `src/mcp/discovery.zig`
- Contains: `MCPClient`, server discovery, tool execution
- Purpose: Unify built-in plugins and MCP tools
- Location: `src/hybrid_bridge.zig`
- Contains: `HybridBridge`, tool routing, mappings
## Key Abstractions
- Purpose: Manage multiple AI provider configurations
- Key types: `ProviderType` enum (22 providers), `Provider`, `ProviderConfig`
- Pattern: Factory method to create providers with default configs
- Purpose: Generic HTTP client for any AI provider
- Key types: `ChatRequest`, `ChatResponse`, `ChatMessage`
- Pattern: Builder pattern for options, retry with exponential backoff
- Purpose: External tool integration interface
- Key types: `Request`, `Response`, `HealthStatus`
- Pattern: Lifecycle (init/deinit), JSON-RPC communication
- Purpose: Single entry point for all tools
- Pattern: Route request to either built-in plugin or MCP server
## Entry Points
- Triggers: `crushcode [command] [options]`
- Responsibilities: Parse args → load config → dispatch command
- Error handling: Comprehensive early-exit checks with user-friendly messages
- Triggers: `crushcode chat [message] [--provider X] [--model Y] [--interactive]`
- Responsibilities: Initialize provider → create client → send request → print response
- Triggers: `crushcode read <file> [file...]`
- Responsibilities: Open files → read content → print formatted output
- Triggers: `crushcode list [--providers] [--models <provider>]`
- Responsibilities: List all providers or models for a provider
## Error Handling
- Config errors: `error.HomeNotFound`, `error.InvalidPath`, `error.FileNotFound`
- Auth errors: `error.MissingApiKey`, `error.AuthenticationError`
- Network errors: `error.NetworkError`, `error.ServerError` (with retry)
- Plugin errors: `error.PluginNotFound`, `error.PluginInitializationFailed`
## Cross-Cutting Concerns
- Provider name validation via `ProviderType` enum
- API key presence check before requests
- File existence checks in `FileReader`
- Bearer token in `Authorization` header
- Environment variable fallback for config path
- Provider-specific headers (OpenRouter `HTTP-Referer`, `X-Title`)
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
