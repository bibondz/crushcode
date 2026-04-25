# Crushcode

A Zig-based AI coding CLI tool that combines AI agent orchestration with shell/CLI capabilities. Built in Zig for native performance, zero dependencies, and cross-platform binary output.

[![Zig Version](https://img.shields.io/badge/Zig-0.13+-red.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Build Status](https://img.shields.io/badge/build-passing-green.svg)](https://github.com/yourusername/crushcode)

## Overview

Crushcode is a powerful AI coding assistant that integrates multiple AI providers, a plugin system, MCP (Model Context Protocol) client, LSP support, and a full TUI interface. It enables AI agents to execute shell commands, manage files, and interact with external tools. Written entirely in Zig using only the standard library, it compiles to a single, fast binary with no external dependencies.

## Features

- **22 AI Providers**: OpenAI, Anthropic, Gemini, XAI, Mistral, Groq, DeepSeek, Together, Azure, VertexAI, Bedrock, Ollama, LM Studio, llama.cpp, OpenRouter, Zai, Vercel Gateway, OpenCode Zen, OpenCode Go, and more
- **17 CLI Commands**: chat, read, write, list, connect, shell, mcp, lsp, git, diff, plugin, skill, profile, checkpoint, usage, install, grep, and more
- **MCP Client**: Full Model Context Protocol support for external tool integration
- **LSP Client**: Language Server Protocol client (goto, refs, hover, complete, diagnostics)
- **Plugin System**: JSON-RPC 2.0 based plugin architecture with built-in plugins
- **TUI Interface**: Full terminal UI with markdown rendering, diff preview, and interactive sessions
- **Streaming Support**: Real-time streaming responses with typewriter effect
- **Tool Execution**: Built-in tools for web fetch, search, edit, LSP operations, and more
- **Permission System**: Fine-grained permission evaluation with safety checks
- **Usage Tracking**: Token usage and cost reporting with budget limits
- **Knowledge Graph**: Codebase indexing with graph-based navigation
- **Agent System**: Autonomous agents with memory, checkpoints, and parallel execution
- **Session Management**: Session save/restore, fork, and history
- **Profile Support**: Named profiles for different provider configurations
- **Configuration**: TOML-based configuration with provider overrides

## Quick Start

### Prerequisites

- Zig 0.13 or later
- Linux, macOS, or Unix-like system (Windows via WSL or cross-compilation)

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/crushcode.git
cd crushcode

# Build debug binary
zig build

# Build optimized release binary (3.5MB)
zig build -Doptimize=ReleaseSmall

# WSL users: use cache-dir to avoid filesystem issues
zig build --cache-dir /tmp/zigcache

# The binary will be at zig-out/bin/crushcode
```

### Installation

**macOS / Linux (one-liner):**
```bash
curl -fsSL https://github.com/bibondz/crushcode/raw/main/install.sh | sh
```

**Windows (PowerShell):**
```powershell
irm https://github.com/bibondz/crushcode/raw/main/install.ps1 | iex
```

**Build from source:**
```bash
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/crushcode ~/.local/bin/   # or /usr/local/bin/
```

## Usage

### Chat with AI

```bash
# Single message
crushcode chat "Explain this code" --provider openai --model gpt-4

# Interactive mode
crushcode chat --interactive

# With streaming
crushcode chat "Help me refactor this" --stream

# With TUI
crushcode tui
```

### File Operations

```bash
# Read files with formatting
crushcode read src/main.zig src/config.zig

# Write files with glob support
crushcode write "Replace TODO comments" src/**/*.zig

# Diff files
crushcode diff file1.zig file2.zig
```

### MCP (Model Context Protocol)

```bash
# List available MCP servers
crushcode mcp list

# Connect to an MCP server
crushcode mcp connect <server-name>

# Execute MCP tool
crushcode mcp execute <tool-name> --args '{"key": "value"}'

# Discover MCP servers
crushcode mcp discover
```

### LSP Operations

```bash
# Go to definition
crushcode lsp goto src/main.zig:42:10

# Find references
crushcode lsp refs src/main.zig:42:10

# Hover information
crushcode lsp hover src/main.zig:42:10

# Code completion
crushcode lsp complete src/main.zig:42:10

# Diagnostics
crushcode lsp diagnostics src/main.zig
```

### Git Integration

```bash
# Git status
crushcode git status

# Git log
crushcode git log --oneline -10

# Git diff
crushcode git diff HEAD

# Git commit
crushcode git add . && crushcode git commit -m "Add new feature"
```

### Plugin Management

```bash
# List plugins
crushcode plugin list

# Enable plugin
crushcode plugin enable <plugin-name>

# Disable plugin
crushcode plugin disable <plugin-name>

# Plugin status
crushcode plugin status
```

### Other Commands

```bash
# List providers
crushcode list --providers

# List models for a provider
crushcode list --models openai

# Connect provider credentials
crushcode connect openai

# Execute shell command with timeout
crushcode shell --timeout 30 "cargo build"

# List and execute skills
crushcode skill list
crushcode skill execute <skill-name>

# Profile management
crushcode profile create my-profile
crushcode profile switch my-profile

# Session checkpoint
crushcode checkpoint save my-session
crushcode checkpoint restore my-session

# Usage report
crushcode usage report

# AST-aware grep
crushcode grep "async function" src/**/*.ts
```

## Configuration

Crushcode uses a TOML configuration file at `~/.crushcode/config.toml`.

### Example Configuration

```toml
[default]
provider = "openai"
model = "gpt-4"

[model]
max_tokens = 4096
temperature = 0.7

[openai]
api_key = "sk-..."
base_url = "https://api.openai.com/v1"

[anthropic]
api_key = "sk-ant-..."

[[provider_overrides]]
provider = "ollama"
base_url = "http://localhost:11434/v1"

[profiles.work]
provider = "anthropic"
model = "claude-3-opus-20240229"

[profiles.local]
provider = "ollama"
model = "llama2:70b"
```

### Provider Setup

Use the interactive connect command to set up provider credentials:

```bash
crushcode connect openai
# Follow the prompts to enter your API key
```

Or manually edit the config file to add API keys and customize settings.

## Architecture

Crushcode is organized into 20+ modules with clear separation of concerns:

- **`src/cli/`** - Argument parsing and command routing
- **`src/commands/`** - User-facing command implementations
- **`src/ai/`** - AI provider communication (client, registry, error handling)
- **`src/agent/`** - Autonomous agent system (loop, memory, checkpoint, parallel execution)
- **`src/config/`** - Configuration management (TOML parsing, profiles, auth)
- **`src/mcp/`** - Model Context Protocol client and discovery
- **`src/lsp/`** - Language Server Protocol client
- **`src/plugin/`** - Plugin system with JSON-RPC 2.0 protocol
- **`src/tui/`** - Full terminal UI implementation
- **`src/streaming/`** - Streaming response handling
- **`src/usage/`** - Token usage and cost tracking
- **`src/permission/`** - Permission system and security checks
- **`src/knowledge/`** - Knowledge graph and codebase indexing

See [STRUCTURE.md](STRUCTURE.md) for detailed architecture documentation.

## AI Providers

Crushcode supports 22 AI providers out of the box:

1. OpenAI
2. Anthropic
3. Gemini
4. XAI
5. Mistral
6. Groq
7. DeepSeek
8. Together
9. Azure
10. VertexAI
11. Bedrock
12. Ollama
13. LM Studio
14. llama.cpp
15. OpenRouter
16. Zai
17. Vercel Gateway
18. OpenCode Zen
19. OpenCode Go
20. And 3 more

Each provider is configured in `~/.crushcode/config.toml` with its own API key and optional base URL override.

## Building

### Debug Build

```bash
zig build
```

### Release Builds

```bash
# Small optimized binary (recommended)
zig build -Doptimize=ReleaseSmall

# Fast optimized binary
zig build -Doptimize=ReleaseFast

# Fully optimized binary with diagnostics
zig build -Doptimize=ReleaseSafe
```

### Cross-Compilation

```bash
# Target Windows x86_64
zig build -Dtarget=x86_64-windows-gnu

# Target macOS aarch64 (Apple Silicon)
zig build -Dtarget=aarch64-macos

# Target Linux x86_64
zig build -Dtarget=x86_64-linux
```

### WSL Note

If building on WSL, use the cache-dir flag to avoid filesystem performance issues:

```bash
zig build --cache-dir /tmp/zigcache
```

### Binary Size

The ReleaseSmall build produces a ~3.5MB static binary with no external dependencies.

## Contributing

Contributions are welcome! Please follow these guidelines:

1. **Code Style**: Follow the conventions outlined in [CONVENTIONS.md](CONVENTIONS.md)
   - Use `kebab-case.zig` for filenames
   - Use `PascalCase` for types
   - Use `camelCase` for functions
   - 4 spaces, no tabs
   - Prefer `const` over `var`

2. **Architecture**: Consult [STRUCTURE.md](STRUCTURE.md) before adding features
   - Check dependency rules (no circular imports)
   - Use shared utilities instead of duplicating code
   - Place new code in appropriate directories

3. **Testing**: Build and test before submitting
   - Run `zig build` to verify compilation
   - Test your changes across different providers
   - Check for memory leaks with valgrind if applicable

4. **Documentation**: Update relevant docs
   - Add comments to public functions using `///`
   - Update CHANGELOG.md for user-facing changes
   - Update STRUCTURE.md for architectural changes

5. **Pull Requests**: Provide clear descriptions
   - Explain the change and why it's needed
   - Reference related issues
   - Include usage examples if adding a command

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

Crushcode combines concepts from OpenCode (AI agent orchestration) and Crush (Shell/CLI in Go), reimplemented in Zig for performance and portability.

Built with:
- Zig standard library only (no external dependencies)
- Vaxis for TUI rendering
- SQLite for session storage

---

**Version**: 1.0.0 | **Size**: 96 source files, ~32K lines of Zig | **Dependencies**: None
