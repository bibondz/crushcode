# Crushcode - AI Coding Assistant

## Overview

Crushcode is an AI coding assistant written in Zig 0.15.2, designed to work with multiple AI providers.

**Current Version:** v0.1.0

## Features

### Multi-Provider Support
17 AI providers supported:
- OpenAI (GPT models: gpt-4o, gpt-4-turbo, gpt-4, gpt-3.5-turbo)
- Anthropic (Claude models: claude-3.5-sonnet-20241022, claude-3-opus-20240229)
- Google Gemini (Gemini models: gemini-2.0-flash-exp, gemini-1.5-pro, gemini-1.5-flash)
- XAI (Grok models: grok-beta, grok-2-1212)
- Mistral (Mistral models: mistral-large-latest, mistral-medium-latest, mistral-small-latest)
- Groq (Fast inference: llama-3.3-70b-versatile, llama-3.3.8b-instant)
- DeepSeek (DeepSeek models: deepseek-chat, deepseek-coder)
- Together AI (Llama models)
- Azure OpenAI (GPT models on Azure)
- Google Vertex AI (Gemini models on Google Cloud)
- AWS Bedrock (Anthropic, Llama models)
- Ollama (Local LLM: llama3.3, llama3.2, codellama, mistral)
- LM Studio (Local models)
- llama.cpp (Local server)
- OpenRouter (Multi-provider: OpenAI, Anthropic, Google Gemini, etc.)
- Z.ai (Zhipu AI: glm-4-flash, glm-4-plus, glm-4.5-air)
- Vercel Gateway (Vercel AI Gateway)

## Commands

### Chat
Interactive chat with AI support.
- Provider selection via `--provider` flag
- Model selection via `--model` flag
- Mock responses for testing (until API keys added)

```bash
# Start chat with OpenAI
crushcode chat --provider openai --model gpt-4o "Hello, can you help me?"

# Chat with Claude
crushcode chat --provider anthropic --model claude-3.5-sonnet "Help me write some Zig code"

# Chat with Ollama (local)
crushcode chat --provider ollama --model llama3.3 "Generate a function in Zig"

# List all providers
crushcode list

# List models for a provider
crushcode list openai

# List all models
crushcode list --models openai
```

### Read
Read file contents with display of size and content.

```bash
# Read single file
crushcode read src/main.zig

# Read multiple files
crushcode read src/main.zig src/commands/chat.zig

# Read with help
crushcode read --help
```

### List
List all available AI providers.

```bash
# Show all providers
crushcode list

# Show models for a provider
crushcode list openai

# Show all models
crushcode list --models openai
```

### Help
Show usage information and examples.

### Version
Display version information.

---

## Project Structure

```
crushcode/
├── src/
│   ├── main.zig                 # Entry point
│   ├── cli/
│   │   └── args.zig            # Flag parsing
│   ├── commands/
│   │   ├── handlers.zig        # Command handlers
│   │   ├── chat.zig          # Chat command
│   │   └── read.zig          # Read command
│   ├── ai/
│   │   ├── registry.zig        # Provider registry (17 providers)
│   │   ├── client.zig          # AI client (HTTP client, ready for API integration)
│   │   └── types.zig         # AI types (ChatRequest, ChatResponse, etc.)
│   ├── fileops/
│   │   └── reader.zig       # File reading
│   └── core/              # Core functionality (if any)
└── build.zig                # Build configuration
```

---

## Module System

**Zig 0.15.2 Writergate API Pattern:**

The build system uses Zig 0.15.2's new module and writer interface system. Key changes:

1. **Module Creation:**
   ```zig
   const cli_mod = b.createModule(.{
       .root_source_file = b.path("src/cli/args.zig"),
       .target = target,
       .optimize = optimize,
   });
   ```

2. **Writer Interface:**
   ```zig
   var writer = std.fs.File.stdout().writer(&buffer);
   const writer_ptr = &writer.interface;
   ```

3. **HTTP Client:**
   ```zig
   const response_writer = &response_buffer.writer;
   ```

---

## HTTP Client Pattern (For Future Implementation)

When implementing real AI chat, use this pattern:

```zig
// Create response buffer
var response_buffer = std.Io.Writer.Allocating.init(allocator);
defer response_buffer.deinit();
const response_writer = *std.Io.Writer = &response_buffer.writer;

// Send HTTP POST
const response = try client.fetch(.{
    .method = .POST,
    .location = .{ .uri = uri },
    .response_writer = response_writer,
    .headers = headers.items,
});
```

---

## Configuration (Future)

When API keys are added, configuration will be loaded from:
- `~/.crushcode/config.toml` - User config file
- Environment variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.)
- Command-line arguments (`crushcode chat --api-key sk-xxx`)

---

## Building

```bash
# Build project
cd crushcode
zig build

# Run
zig-out/bin/crushcode help
zig-out/bin/crushcode version
zig-out/bin/crushcode list
zig-out/bin/crushcode read src/main.zig
zig-out/bin/cushcode chat --provider openai --model gpt-4o "message"
```

---

## Notes

- **Mock Chat Mode:** Currently displays mock responses
- **No API Keys:** All providers initialized with empty API keys
- **HTTP Client Stub:** Exists in `src/ai/client.zig` ready for integration
- **Memory Safety:** Proper allocator usage with defer patterns
- **Build System:** Clean module system with no circular dependencies

---

## Troubleshooting

### Build Errors?

If build fails, try:
```bash
zig build 2>&1 | head -50
```

### LSP Errors?

LSP errors about unused constants can be fixed by:
- Removing unused module imports
- Using proper module naming convention

### Missing Module?

If seeing "no module named" error, the module may need to be:
- Created in `src/ai/` directory
- Imported in build.zig with `.addImport()`
- Referenced in command file with `@import()`

---

## Next Steps

### Option A: Document & Polish
1. ✅ **Write README.md** (done)
2. Document usage examples (done)
3. Add more command examples to help text

### Option B: HTTP Client (Complex)
1. Research Zig 0.15.2 HTTP documentation thoroughly
2. Implement real `client.fetch()` with actual API calls
3. Add API key management (config file + env vars)
4. Implement JSON request/response parsing properly
5. Add streaming response support

### Option C: Config System
1. Create config file parser (`~/.crushcode/config.toml`)
2. Add API key storage (encrypted)
3. Add command-line config override
4. Add provider/model default values

### Option D: Enhanced Features
1. Multi-file chat (`crushcode chat @file1 @file2 @file3`)
2. Interactive chat mode (continuous conversation)
3. Code generation from OpenSpec specs
4. Streaming responses
5. Conversation history management

---

## Technical Achievements

✅ **Provider Registry** - 17 providers with model lists
✅ **Flag Parsing** - `--provider`, `--model`, `--config`
✅ **Read Command** - Single/multiple file reading
✅ **Chat Command** - Mock implementation with flags
✅ **Module System** - Clean build system
✅ **Memory Management** - Proper allocator/deallocator patterns

---

## Summary

**Status:** ✅ Build successful, all commands working
**Working:** 6/6 commands (help, version, list, read, chat)
**Ready:** HTTP client stub exists for future API integration
**Time:** ~2 hours development session

**Next:** Choose path forward:
- Document & Polish (simple, recommended)
- HTTP Client integration (complex)
- Config system (medium)
- Enhanced features (long term)
