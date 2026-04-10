# Requirements - crushcode-v2

## HTTP Client Implementation

### R1: HTTP Request System
- Must use Zig's built-in `std.http` client
- Support POST requests with JSON body
- Read and parse JSON responses
- Handle request/response headers

### R2: Provider API Compatibility
- OpenAI-compatible API format (most similar)
- Anthropic API format
- Provider-specific endpoint building

### R3: Error Handling
- Network errors with retry logic
- Rate limit handling
- Authentication errors
- Parse error responses

## Config System

### R4: Config File
- TOML format
- Provider configs with API keys
- Model selections per provider
- Default provider setting

### R5: Provider Override
- Config file → environment variables → CLI flags
- Priority: CLI > ENV > Config file

## Success Criteria

- [x] `crushcode chat --provider ollama --model phi3.5 "hello"` returns real response ✅
- [ ] `crushcode chat --provider openai --model gpt-4o "hello"` returns real response (needs API key)
- [ ] `crushcode chat --provider anthropic --model claude-3.5-sonnet "hello"` returns real response (needs API key)
- [ ] API keys loaded from config file
- [ ] All 17 providers return real responses

---

## Out of Scope (v2.0)

- Streaming responses (now working! ✅)
- Plugin/MCP completion (defer to v2.1)
- Local models (already supported via Ollama)