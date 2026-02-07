# Crushcode Config System Documentation

## Overview

The config system manages API keys and default settings for all 17 AI providers.

**Version:** v0.1.0  
**Date:** 2026-02-04  
**Status:** ✅ Fully Functional

---

## Configuration File Location

The config file is automatically created at:
- **Linux/macOS:** `~/.crushcode/config.toml`
- **Windows:** `%USERPROFILE%\.crushcode\config.toml`
- **Custom:** Set `CRUSHCODE_CONFIG` environment variable

---

## Configuration File Format (TOML)

```toml
# Crushcode Configuration File

# Default provider and model
default_provider = "openai"
default_model = "gpt-4o"

# API Keys (replace with your actual keys)
[api_keys]
openai = "sk-your-openai-api-key"
anthropic = "sk-ant-your-anthropic-api-key"
gemini = "AIzaSy-your-gemini-api-key"
xai = "xai-your-xai-api-key"
mistral = "your-mistral-api-key"
groq = "gsk_your-groq-api-key"
deepseek = "sk-your-deepseek-api-key"
together = "your-together-api-key"
azure = "your-azure-api-key"
vertexai = "your-vertexai-api-key"
bedrock = "your-bedrock-api-key"
ollama = ""
lm_studio = ""
llama_cpp = ""
openrouter = "sk-or-your-openrouter-api-key"
zai = "your-zai-api-key"
vercel_gateway = "your-vercel-api-key"
```

---

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `CRUSHCODE_CONFIG` | Path to custom config file | `/path/to/custom/config.toml` |
| `HOME` | Home directory (Linux/macOS) | `/home/user` |
| `USERPROFILE` | User profile (Windows) | `C:\Users\Username` |

---

## Usage Examples

### 1. Using Default Provider

```bash
$ crushcode chat "Hello, AI!"
# Uses default_provider and default_model from config
```

### 2. Specifying Provider

```bash
$ crushcode chat --provider anthropic "Hello, Claude!"
# Uses anthropic's API key from config
```

### 3. Specifying Provider and Model

```bash
$ crushcode chat --provider gemini --model gemini-2.0-flash-exp "Hello!"
# Uses gemini's API key and specified model
```

### 4. Custom Config File

```bash
# Set environment variable
export CRUSHCODE_CONFIG=/custom/path/config.toml

# Or on Windows PowerShell
$env:CRUSHCODE_CONFIG = "C:\custom\path\config.toml"

# Run crushcode
crushcode chat "Hello!"
```

---

## API Key Management

### Adding API Keys

1. Open config file: `~/.crushcode/config.toml`
2. Replace placeholder with actual key:
   ```toml
   openai = "sk-proj-abc123xyz789"
   ```
3. Save file

### Removing API Keys

Set to empty string:
```toml
openai = ""
```

### Testing API Key

```bash
$ crushcode chat --provider openai "Test"
# If API key is set, will show "API Key: Set"
# If API key is empty, will show "API Key: Not set"
```

---

## Supported Providers

| Provider | API Key Format |
|----------|---------------|
| OpenAI | `sk-...` |
| Anthropic | `sk-ant-...` |
| Google Gemini | `AIzaSy...` |
| XAI | `xai-...` |
| Mistral | Custom |
| Groq | `gsk_...` |
| DeepSeek | `sk-...` |
| Together AI | Custom |
| Azure OpenAI | Custom |
| Google Vertex AI | Custom |
| AWS Bedrock | Custom |
| Ollama | Empty (local) |
| LM Studio | Empty (local) |
| llama.cpp | Empty (local) |
| OpenRouter | `sk-or-...` |
| Z.ai (Zhipu AI) | Custom |
| Vercel Gateway | Custom |

---

## Config Module API

### Loading Config

```zig
const config = try config_mod.loadOrCreateConfig(allocator);
defer config.deinit();
```

### Getting API Key

```zig
const api_key = config.getApiKey("openai") orelse "";
```

### Getting Default Provider

```zig
const provider = config.default_provider;
const model = config.default_model;
```

---

## Automatic Config Creation

On first run, crushcode automatically creates:
1. Config directory: `~/.crushcode/` (Windows: `%USERPROFILE%\.crushcode\`)
2. Config file: `config.toml` with placeholder keys

---

## Config File Security

**Important:** Config file contains sensitive API keys.

**Recommendations:**
- Set file permissions to `600` (read/write for owner only):
  ```bash
  chmod 600 ~/.crushcode/config.toml
  ```
- Never commit config file to version control
- Use `.gitignore` to exclude config directory:
  ```gitignore
  .crushcode/
  ```

---

## Troubleshooting

### Config File Not Found

If you see "ConfigNotFound" error:
1. Check if config directory exists: `ls ~/.crushcode/`
2. Manually create config file (see format above)
3. Check environment variables: `echo $CRUSHCODE_CONFIG`

### API Key Not Working

If API key is not being used:
1. Verify key is set in config file
2. Check for extra spaces or quotes
3. Ensure provider name matches (e.g., `openai`, not `OpenAI`)

### Parse Errors

If config file has parse errors:
1. Check TOML syntax (no trailing commas)
2. Ensure all keys use `=` (not `:`)
3. Verify sections use `[section_name]` format

---

## Next Steps

With config system complete, the next phase is:
- **HTTP Client Integration** - Make real API calls using stored API keys
- **Interactive Chat Mode** - Continuous conversation with context
- **Streaming Responses** - Real-time AI response streaming

---

## Technical Implementation

### Module Structure

```
src/config/
└── config.zig          # Config parsing and management
```

### Key Functions

- `loadOrCreateConfig()` - Load or create config file
- `getConfigPath()` - Get config file path from env vars
- `createDefaultConfig()` - Create default config with placeholders
- `parseToml()` - Parse TOML config format
- `getApiKey()` - Get API key for specific provider
- `setApiKey()` - Set API key for specific provider

---

## Test Results

| Test | Status |
|------|--------|
| Config file creation | ✅ PASS |
| Config loading | ✅ PASS |
| API key retrieval | ✅ PASS |
| Default provider/model | ✅ PASS |
| Provider override | ✅ PASS |
| Environment variable | ✅ PASS |

---

**Documentation Version:** 1.0  
**Last Updated:** 2026-02-04
