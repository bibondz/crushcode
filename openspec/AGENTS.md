# AI Agent Instructions for Crushcode Project

## Project Type

This is a **Zig-based AI CLI application** with plugin architecture, supporting 17 AI providers.

## Purpose

- Multi-provider AI coding assistant written in Zig 0.15.2
- Plugin system for extensibility
- Configuration management for AI providers
- Command-line interface with subcommands

## Essential Commands

### Build Commands
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
```

### CLI Commands
```bash
# Chat with AI provider
crushcode chat --provider <provider> --model <model> <message>

# List providers and models
crushcode list

# Configuration
crushcode config --set <key>=<value>
crushcode config --get <key>
crushcode config --show

# Plugin management
crushcode plugin list
crushcode plugin install <plugin>
crushcode plugin remove <plugin>
```

## Code Organization

### Core Modules
```
src/
├── main.zig              # Entry point
├── providers/            # AI provider implementations
│   ├── provider.zig      # Provider interface
│   ├── openai.zig        # OpenAI implementation
│   ├── anthropic.zig     # Anthropic implementation
│   └── ...
├── plugins/              # Plugin system
│   ├── plugin.zig        # Plugin interface
│   ├── loader.zig        # Dynamic plugin loading
│   └── registry.zig      # Plugin registry
├── config/               # Configuration management
│   ├── config.zig        # Configuration struct
│   └── parser.zig        # TOML/YAML parsing
├── cli/                  # Command interface
│   ├── commands.zig      # Command implementations
│   └── args.zig          # Argument parsing
└── http/                 # HTTP client
    └── client.zig        # HTTP client implementation
```

### Supported Providers
- OpenAI (GPT models)
- Anthropic (Claude models)
- Google Gemini
- XAI (Grok)
- Mistral
- Groq
- DeepSeek
- Together AI
- Azure OpenAI
- Google Vertex AI
- AWS Bedrock
- Ollama (Local)
- LM Studio (Local)
- llama.cpp (Local)
- OpenRouter
- Z.ai (Zhipu AI)
- Vercel Gateway

## Code Patterns

### Error Handling
Always use explicit error handling with `try` and `catch`:

```zig
const result = some_operation() catch |err| {
    std.log.err("Operation failed: {}", .{err});
    return err;
};
```

### Memory Management
- Use allocators explicitly
- Clean up resources with `defer`
- Follow RAII pattern when possible

### Provider Interface
All providers must implement the Provider interface:

```zig
pub const Provider = struct {
    name: []const u8,
    models: []const []const u8,
    
    chat: *const fn(self: *Provider, message: []const u8) ![]const u8,
    list_models: *const fn(self: *Provider) ![]const []const u8,
};
```

## Testing Approach

### Unit Tests
Each module should have corresponding tests:

```zig
test "provider initialization" {
    const provider = try OpenAIProvider.init(testing.allocator);
    defer provider.deinit();
    
    try testing.expectEqualStrings("openai", provider.name);
}
```

### Integration Tests
Test provider integration with mock APIs.

## Documentation Requirements

### Code Comments
- Public functions must have documentation comments
- Complex algorithms need inline comments
- Example usage for public APIs

### OpenSpec Compliance
All specifications must follow OpenSpec format:
- Folder-based structure: `openspec/specs/[capability]/spec.md`
- YAML front matter with metadata
- Gherkin format for requirements

## Configuration

### Environment Variables
- `CRUSHCODE_API_KEY` - API key for default provider
- `CRUSHCODE_PROVIDER` - Default provider
- `CRUSHCODE_MODEL` - Default model

### Config Files
- `~/.config/crushcode/config.toml` - User configuration
- `.crushcode.toml` - Project configuration

## Anti-Hallucination Rules

### Do NOT:
- Create providers without proper API documentation
- Assume API formats without checking provider docs
- Hardcode API keys or credentials
- Change the Provider interface without updating all implementations

### Do:
- Always validate API responses against expected schemas
- Use proper error handling for network failures
- Follow provider rate limits
- Keep provider configuration consistent

## Regression Prevention

Before making changes:
1. Check if the feature was implemented before
2. Verify no existing functionality will break
3. Run full test suite
4. Test with multiple providers if relevant

## Common Tasks

### Adding New Provider
1. Create provider file in `src/providers/`
2. Implement Provider interface
3. Add to provider registry
4. Add tests
5. Update documentation

### Adding Plugin Support
1. Define plugin interface in `src/plugins/plugin.zig`
2. Implement dynamic loading
3. Add plugin configuration schema
4. Test plugin loading/unloading

---

**Last Updated:** 2026-02-06
**For:** AI Agents implementing Crushcode
**OpenSpec Version:** 1.1.1