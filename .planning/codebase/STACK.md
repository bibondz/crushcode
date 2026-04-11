# Technology Stack

**Analysis Date:** 2026-04-11

## Language

**Primary:**
- Zig (modern systems programming language)
- Language version: Determined by Zig compiler (version 0.13+ recommended based on std library patterns used)

**Why Zig:**
- Native HTTP client support via `std.http`
- Native JSON-RPC 2.0 support via `std.json`
- Native process/child management via `std.process.Child`
- Zero-cost JSON parsing with `std.json.parseFromSlice`
- No external dependencies required

## Build System

**Build Tool:**
- Zig build system (`zig build`)
- Build file: `/mnt/d/crushcode/build.zig` (107 lines)

**Build Configuration:**
```zig
// From build.zig - Module structure
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
```

**Executable Target:**
- Name: `crushcode`
- Target/optimize: Standard Zig options

## Frameworks & Standard Library

**Zig Standard Library Modules Used:**

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

**No External Dependencies:**
- All functionality built with Zig stdlib
- No package manager required
- No external C libraries needed

## Module Structure

**Source Directory Layout:**
```
/mnt/d/crushcode/src/
├── main.zig              # Entry point (126 lines)
├── cli/
│   └── args.zig          # CLI argument parsing (77 lines)
├── ai/
│   ├── client.zig       # AI HTTP client (617 lines)
│   ├── registry.zig      # AI provider registry (382 lines)
│   └── error_handler.zig # Retry/error handling
├── config/
│   ├── config.zig       # Config loading (175 lines)
│   └── provider_config.zig # Extended provider config (187 lines)
├── commands/
│   ├── chat.zig         # Chat command handler
│   ├── read.zig          # Read command handler
│   └── handlers.zig      # Command dispatcher
├── plugin/
│   ├── interface.zig     # Plugin interface (256 lines)
│   └── protocol.zig     # JSON-RPC 2.0 protocol (364 lines)
├── mcp/
│   ├── client.zig       # MCP protocol client (443 lines)
│   └── discovery.zig     # MCP server discovery (311 lines)
├── plugins/
│   ├── registry.zig     # Plugin registry (301 lines)
│   ├── pty.zig          # PTY plugin
│   ├── notifier.zig     # Notification plugin
│   ├── shell_strategy.zig # Shell strategy plugin
│   └── table_formatter.zig # Table formatting plugin
├── fileops/
│   └── reader.zig        # File reading utilities
└── utils/
    └── string.zig        # String utilities
```

**Total Zig Source Files:** 25

## Key Dependencies

**None - Self-Contained:**
- No npm/pip/cargo dependencies
- All HTTP/JSON/network handled by stdlib
- All crypto via `std.crypto` if needed

## Runtime Requirements

**Development:**
- Zig compiler (0.13+)
- Standard C library (libc)
- Terminal for stdio plugins

**Production:**
- Linux/Unix system with Zig runtime
- Or compiled to single binary via Zig
- No interpreter needed

## Platform Support

**Tested/Supported:**
- Linux (primary)
- macOS/Unix-like systems
- Windows (via WSL or cross-compilation)

**Build Targets:**
```bash
zig build                    # Build for host
zig build -Dtarget=x86_64-linux-gnu  # Cross-compile
```

---

*Stack analysis: 2026-04-11*