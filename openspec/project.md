# OpenSpec for Crushcode Project

## Project Overview

**Type:** AI Coding Assistant (Zig-based)
**Purpose:** Multi-provider AI CLI with plugin architecture
**Main Languages:** Zig 0.15.2+, Python for utilities

### Key Components

1. **Crushcode Core** (`src/`)
   - Zig-based AI CLI engine
   - Multi-provider support (17 providers)
   - Plugin architecture for extensibility

2. **Provider System** (`src/providers/`)
   - Unified API for 17 AI providers
   - HTTP client for remote APIs
   - Local provider support (Ollama, LM Studio)

3. **Plugin Architecture** (`src/plugins/`)
   - Dynamic plugin loading
   - Plugin configuration system
   - Extension points system

4. **Configuration System** (`src/config/`)
   - TOML-based configuration
   - Environment variable support
   - CLI argument handling

---

## Essential Commands

### Build and Run

```bash
# Build the project
zig build

# Build and run
zig build run

# Build for release
zig build -Drelease-safe

# Run tests
zig build test

# Install
zig build install

# Run the CLI
./zig-out/bin/crushcode [command]
```

### Available Commands

```bash
# Chat with AI provider
crushcode chat --provider openai --model gpt-4o "Your message"

# List all providers and models
crushcode list

# Configuration management
crushcode config --set provider=openai
crushcode config --get api_key
crushcode config --show

# Plugin management
crushcode plugin list
crushcode plugin install <plugin>
crushcode plugin remove <plugin>

# Help and version
crushcode --help
crushcode --version
```

---

## Project Structure

```
crushcode/
├── src/                        # Zig source code
│   ├── main.zig               # Entry point
│   ├── providers/              # AI provider implementations
│   ├── plugins/               # Plugin system
│   ├── config/               # Configuration management
│   ├── cli/                  # Command interface
│   └── http/                 # HTTP client
├── tests/                     # Test suites
├── examples/                  # Example configurations
├── openspec/                  # OpenSpec documentation
│   ├── AGENTS.md             # AI agent instructions
│   ├── project.md            # This file
│   ├── specs/                # Specifications
│   │   ├── overview/         # Project overview
│   │   ├── core-architecture/ # Zig core engine
│   │   ├── plugin-system/    # Plugin architecture
│   │   ├── providers/        # AI provider configs
│   │   └── performance/      # Performance optimization
│   └── changes/              # Active change proposals
├── build.zig                  # Zig build configuration
├── README.md                  # User documentation
└── tests/                     # Test files
```

---

## Code Patterns and Conventions

### Zig Code

**Style:**
- Use struct-based organization
- Explicit error handling with `try`
- No garbage collection
- Zig 0.15.2+ syntax

**Example:**
```zig
const std = @import("std");

pub const ProviderManager = struct {
    allocator: std.mem.Allocator,
    providers: std.json.ObjectMap,

    pub fn init(allocator: std.mem.Allocator) ProviderManager {
        return ProviderManager{ 
            .allocator = allocator,
            .providers = std.json.ObjectMap.init(allocator)
        };
    }

    pub fn getProvider(self: *ProviderManager, name: []const u8) !?*Provider {
        if (self.providers.get(name)) |provider_value| {
            return @as(*Provider, @ptrCast(provider_value));
        }
        return null;
    }
};
```

---

## Testing Approach

```bash
# Run all tests
zig build test

# Run specific test
zig build test --test-filter [test_name]

# Test in debug mode
zig build test -Ddebug

# Run integration tests
python tests/integration_test.py
```

---

## Important Gotchas

### Provider Configuration
- API keys stored in environment variables or config file
- Each provider has different rate limits
- Local providers require server installation

### Plugin System
- Plugins must implement the Plugin interface
- Plugin configuration in TOML format
- Dynamic loading requires .so/.dll files

---

## Quick Reference

### Provider Support
- **OpenAI**: GPT models (gpt-4o, gpt-4-turbo, gpt-3.5-turbo)
- **Anthropic**: Claude models (claude-3.5-sonnet, claude-3-opus)
- **Google**: Gemini models (gemini-2.0, gemini-1.5)
- **XAI**: Grok models
- **Mistral**: Mistral models
- **Groq**: Fast inference
- **DeepSeek**: DeepSeek models
- **Local**: Ollama, LM Studio, llama.cpp

### Configuration Files
- `~/.config/crushcode/config.toml` - User config
- `.crushcode.toml` - Project config
- Environment variables: `CRUSHCODE_API_KEY`, `CRUSHCODE_PROVIDER`

---

## Emergency Contacts

**If confused:**
1. Read `openspec/project.md` (this file)
2. Check `openspec/AGENTS.md` for AI instructions
3. Review current specs in `openspec/specs/`

**If implementing feature:**
1. Check for existing spec in `openspec/specs/`
2. Create change proposal if needed
3. Update documentation after implementation

---

**Last Updated:** 2026-02-06
**For:** AI Agents
**OpenSpec Version:** 1.1.1
**Crushcode Version:** v0.1.0