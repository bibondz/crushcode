# crushcode Roadmap

## v2.0 - Real HTTP Client & Config

### Phase 1: HTTP Client Implementation ✅ DONE
- [x] 1.1 Implement std.http client wrapper for Zig 0.14.0
- [x] 1.2 Add OpenAI API calls (chat/completions)
- [x] 1.3 Add Anthropic API calls
- [x] 1.4 Add provider-specific request builders

### Phase 2: Config System ✅ DONE (Already working)
- [x] 2.1 TOML config parser
- [x] 2.2 API key management
- [x] 2.3 Provider config loading
- [x] 2.4 Environment variable support

### Phase 3: More Providers
- [ ] 3.1 Google Gemini
- [ ] 3.2 Groq
- [ ] 3.3 Other providers

### Phase 4: Plugin/MCP (Optional)
- [ ] 4.1 Complete plugin structure
- [ ] 4.2 Complete MCP discovery

---

## Notes

- Real HTTP client is working!
- Config file: `~/.crushcode/config.toml`
- Format: `provider = "api-key"`