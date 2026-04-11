# External Integrations

**Analysis Date:** 2026-04-11

## AI Provider Integrations

**Supported Providers:** 22 providers via OpenAI-compatible Chat Completions API

### Cloud API Providers

| Provider | Base URL | Models | Auth |
|----------|---------|-------|------|
| OpenAI | `https://api.openai.com/v1` | gpt-4o, gpt-4-turbo, gpt-4, gpt-3.5-turbo | API key |
| Anthropic | `https://api.anthropic.com/v1` | claude-3.5-sonnet, claude-3-opus, claude-3-sonnet | API key |
| Gemini | `https://generativelanguage.googleapis.com/v1` | gemini-2.0-flash, gemini-1.5-pro, gemini-1.5-flash | API key |
| xAI | `https://api.x.ai/v1` | grok-beta, grok-2-1212 | API key |
| Mistral | `https://api.mistral.ai/v1` | mistral-large, mistral-medium, mistral-small | API key |
| Groq | `https://api.groq.com/openai/v1` | llama-3.3-70b, llama-3.3-8b, mixtral-8x7b | API key |
| DeepSeek | `https://api.deepseek.com/v1` | deepseek-chat, deepseek-coder | API key |
| Together | `https://api.together.xyz/v1` | meta-llama/Meta-Llama-3.1-70B, mistralai/Mixtral-8x7B | API key |
| Azure OpenAI | Custom deployment URL | gpt-4o, gpt-4-turbo, gpt-35-turbo | API key |
| Vertex AI | Custom GCP URL | gemini-2.0-flash, gemini-1.5-pro-001 | GCP auth |
| AWS Bedrock | `https://bedrock-runtime.*.amazonaws.com` | claude-3.5-sonnet, claude-3-5-haiku | AWS credentials |
| Z.ai | `https://open.bigmodel.cn/api/paas/v4` | glm-4-flash, glm-4-plus, glm-4.5-air | API key |
| Vercel Gateway | `https://api.vercel.ai/v1` | Custom provider models | API key |

### Local/Embedded Providers

| Provider | Base URL | Models | Auth |
|----------|---------|-------|------|
| Ollama | `http://localhost:11434/api` | phi3.5, local models | None (local) |
| LM Studio | `http://localhost:1234/v1` | local models | None (local) |
| llama.cpp | `http://localhost:8080/v1` | local models | None (local) |

### Aggregator Providers

**OpenRouter:**
- Base URL: `https://openrouter.ai/api/v1`
- Provides access to 50+ models via single API
- Free tier models available
- App identification headers required:
  - `HTTP-Referer: https://github.com/crushcode/crushcode`
  - `X-Title: Crushcode`

**OpenCode Zen:**
- Base URL: `https://opencode.ai/zen/v1`
- Free models: opencode/minimax-m2.5-free, opencode/big-pickle, opencode/qwen3.6-plus-free
- Paid models: opencode/gpt-5.*, opencode/claude-opus-4-6
- Model discovery via `/zen/v1/models` endpoint with Bearer auth

**OpenCode Go:**
- Base URL: `https://opencode.ai/zen/go/v1`
- Subscription model ($5 first month, $10/month)
- Models: glm-5.1, glm-5, kimi-k2.5, mimo-v2-*, minimax-m2.7

## HTTP Client

**Implementation:** Native Zig `std.http.Client`

**Features:**
- HTTP/1.1 support
- Custom headers
- Request/response streaming
- Dynamic response buffer allocation

**Usage Pattern** (`src/ai/client.zig:211-226`):
```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

const fetch_result = client.fetch(.{
    .method = .POST,
    .location = .{ .uri = uri },
    .payload = json_body,
    .extra_headers = headers_buf.items,
    .response_storage = .{ .dynamic = &response_buf },
});
```

**Retry Logic:**
- Max attempts: 3
- Exponential backoff with jitter
- Retryable errors: timeout, connection_error, rate_limit
- Fail-fast: authentication, invalid_request

## MCP Protocol Support

**Specification:** JSON-RPC 2.0

**Implementation:** `src/mcp/client.zig` (443 lines)

### Transport Types Supported

| Transport | Description | Usage |
|------------|------------|-------|
| stdio | Standard input/output | Local subprocess plugins |
| SSE | Server-Sent Events | HTTP with event streaming |
| HTTP | REST-style | HTTP POST/GET |
| WebSocket | Bidirectional | Real-time communication |

### MCP Server Discovery

**Implementation:** `src/mcp/discovery.zig` (311 lines)

**Default Servers:**
- GitHub MCP: `npm install -g @modelcontextprotocol/github`
- Filesystem MCP: `npm install -g @modelcontextprotocol/filesystem`
- Context7: `npm install -g @modelcontextprotocol/context7`
- Exa Search: `npm install -g @modelcontextprotocol/exa`

**Discovery Paths:**
- `/usr/local/bin`
- `/opt/homebrew/bin`
- `/usr/local/share/mcp-servers`
- `~/.local/share/npx`
- `~/.npm-global/bin`

### MCP Features

- Tool discovery via `tools/list`
- Tool execution via `tools/call`
- JSON-RPC 2.0 request/response
- Error handling with error codes

## Plugin System Architecture

**Implementation:** `src/plugin/interface.zig` (256 lines)

### Plugin Types

| Type | Description | Examples |
|------|------------|----------|
| Built-in | Core features | PTY, Shell, Notifier, TableFormatter |
| External | Custom binaries | Loaded from JSON config |

### Communication Protocol

**Protocol:** JSON-RPC 2.0 (`src/plugin/protocol.zig`)

**Message Types:**
- Request (with id, method, params)
- Response (with id, result or error)
- Notification (no response expected)

**Standard Methods:**
- `plugin.register`
- `plugin.unregister`
- `plugin.execute`
- `plugin.healthCheck`
- `plugin.shutdown`

### Plugin Capabilities

**Defined in:** `src/plugins/registry.zig`

**Built-in Plugins:**
- `pty` - Terminal PTY management
- `shell_strategy` - Shell command execution
- `notifier` - System notifications
- `table_formatter` - Output formatting

### Plugin Manager Features

- Plugin discovery in directory
- JSON config loading
- Process spawn via stdio
- Health check monitoring
- Priority-based execution
- Enable/disable at runtime

## Configuration

**Implementation:** `src/config/config.zig`

**File Format:** TOML

**Config Locations (in priority order):**
1. `$CRUSHCODE_CONFIG` environment variable
2. `~/.crushcode/config.toml` (Linux/macOS)
3. `%USERPROFILE%\.crushcode\config.toml` (Windows)

**Config Schema:**
```toml
default_provider = "openai"
default_model = "gpt-4o"

[api_keys]
openai = "sk-your-key"
anthropic = "sk-ant-your-key"
openrouter = "sk-or-your-key"
opencode_zen = "your-key"
opencode_go = "your-key"
```

## Environment Variables

**Configuration:**
- `CRUSHCODE_CONFIG` - Custom config file path
- `HOME` - Config directory resolution
- `USERPROFILE` - Windows fallback

**Provider-Specific:**
- API keys stored in config file
- Per-provider keys: `openai`, `anthropic`, `gemini`, etc.

## File Operations

**Implementation:** `src/fileops/reader.zig`

**Features:**
- File reading with allocation
- Directory listing
- File existence check
- Content parsing

## CLI Interface

**Implementation:** `src/cli/args.zig`

**Command Syntax:**
```bash
crushcode chat [--provider=NAME] [--model=NAME] [--config=PATH] [--interactive] [message]
crushcode read [--provider=NAME] [--model=NAME] [--config=PATH] [file]
crushcode list [--provider=NAME]
crushcode help
crushcode version
```

---

*Integration audit: 2026-04-11*