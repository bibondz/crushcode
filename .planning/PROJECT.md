# crushcode Project

## Project Overview

**Type:** AI Coding Assistant in Zig  
**Purpose:** Multi-provider AI assistant (17 providers) - CLI tool  
**Version:** v0.1.0 → v2.0目标

**Current Status:** 
- Build: ✅ Working with Zig 0.14.0
- 17 AI Providers: ✅ Registered
- Commands: ✅ chat, read, list, help
- HTTP Client: ⚠️ Stub (simulation only)
- Config: ⚠️ Structure only
- Plugin/MCP: ⚠️ Framework only

## Milestone Goals

### crushcode-v2: Real HTTP Client & Config System

**Objective:** Make crushcode usable with real AI API calls

- [ ] Implement real HTTP Client
- [ ] Config system (API keys storage)
- [ ] Complete Plugin/MCP framework

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Zig 0.14.0 |
| Build | Zig build |
| No deps | Pure Zig |

## Dependencies

- [opencode-ai/opencode](https://github.com/anomalyco/opencode) - Reference
- [charmbracelet/crush](https://github.com/charmbracelet/crush) - Reference

## Success Criteria

1. Can call OpenAI API with real responses
2. Can call Anthropic API with real responses
3. API keys stored securely in config file
4. All 17 providers work

---

## History

### v0.1.0 (initial)
- 17 AI providers registered
- CLI commands: chat, read, list, help
- Build system working
- HTTP client stub only