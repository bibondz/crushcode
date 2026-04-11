# Requirements: Crushcode

**Defined:** 2026-04-11
**Core Value:** Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

---

## v1 Requirements

These are the foundational requirements needed to have a working AI coding CLI.

### Core AI

- [x] **AI-01**: User can chat with AI via CLI (streaming responses)
- [x] **AI-02**: User can switch between AI providers (Ollama, OpenRouter, OpenCode)
- [x] **AI-03**: Configurable API endpoints and API keys per provider
- [x] **AI-04**: System prompt support for context setting

### Shell Execution

- [x] **SH-01**: User can execute shell commands and see output
- [x] **SH-02**: Command execution returns exit code
- [x] **SH-03**: Support for interactive commands (PTY)
- [x] **SH-04**: Command timeout support

### File Operations

- [x] **FO-01**: User can read files via CLI command
- [x] **FO-02**: User can write/edit files via AI agent
- [x] **FO-03**: Support for glob patterns in file selection

### Configuration

- [x] **CFG-01**: TOML configuration file at ~/.crushcode/config.toml
- [x] **CFG-02**: Provider configuration (endpoints, models, keys)
- [x] **CFG-03**: Default provider selection
- [x] **CFG-04**: Config validation on startup

### CLI Interface

- [x] **CLI-01**: Command-line argument parsing
- [x] **CLI-02**: Help text for all commands
- [x] **CLI-03**: Interactive chat mode (non-streaming)
- [x] **CLI-04**: Error handling with user-friendly messages

### Build & Distribution

- [x] **BD-01**: Builds successfully with `zig build`
- [x] **BD-02**: Produces working executable for current platform
- [x] **BD-03**: No LSP errors in codebase

---

## v2 Requirements

Extensions for future releases.

### Skills System

- [x] **SK-01**: Skill definition system
- [x] **SK-02**: Built-in file operation skills
- [x] **SK-03**: Built-in git skills

### Terminal UI

- [x] **TUI-01**: Rich terminal output (colors, formatting)
- [x] **TUI-02**: Progress indicators/spinners
- [x] **TUI-03**: Interactive selection UI

### MCP Integration

- [x] **MCP-01**: Full MCP client implementation (HTTP transport)
- [x] **MCP-02**: MCP server for external tools
- [x] **MCP-03**: MCP discovery of available tools

### Advanced

- [x] **ADV-01**: Job control (background jobs) - framework ready
- [x] **ADV-02**: Pipe/redirection support
- [x] **ADV-03**: Install script

---

## v2 Requirements (New)

### MCP Authentication

- [ ] **MCP-AUTH-01**: OAuth callback server implementation
- [ ] **MCP-AUTH-02**: Token storage and refresh mechanism
- [ ] **MCP-AUTH-03**: Dynamic client registration
- [ ] **MCP-AUTH-04**: CSRF state validation

### Permission System

- [ ] **PERM-01**: Pattern-based allow/deny/ask rules
- [ ] **PERM-02**: Wildcard pattern matching (* and **)
- [ ] **PERM-03**: User prompt for "ask" actions
- [ ] **PERM-04**: Session auto-approval

### Skill System

- [ ] **SKILL-01**: SKILL.md YAML frontmatter parsing
- [ ] **SKILL-02**: Directory-based skill discovery
- [ ] **SKILL-03**: XML generation for AI prompts
- [ ] **SKILL-04**: User skill override support

### Tool Registry

- [ ] **TOOL-REG-01**: Dynamic tool loading at runtime
- [ ] **TOOL-REG-02**: Feature-flag controlled loading
- [ ] **TOOL-REG-03**: Tool aliases for compatibility
- [ ] **TOOL-REG-04**: Concurrency safety flags

### Agent Framework

- [ ] **AGENT-01**: Streaming response handling
- [ ] **AGENT-02**: File-based checkpoint system
- [ ] **AGENT-03**: Conversation memory management
- [ ] **AGENT-04**: Multi-agent coordination

### Config Enhancement

- [ ] **CFG-05**: File watching for config changes
- [ ] **CFG-06**: Backup creation before changes
- [ ] **CFG-07**: Config migration system
- [ ] **CFG-08**: Environment variable integration

---

## Out of Scope

| Feature | Reason |
|---------|--------|
| Desktop GUI | CLI-only for v1 |
| Web-based UI | Terminal-first approach |
| Mobile support | Not applicable |
| IDE integration (VSCode plugin) | Future consideration |

---

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| AI-01 | Phase 1 | ✅ Complete |
| AI-02 | Phase 1 | ✅ Complete |
| AI-03 | Phase 1 | ✅ Complete |
| AI-04 | Phase 1 | ✅ Complete |
| SH-01 | Phase 2 | ✅ Complete |
| SH-02 | Phase 2 | ✅ Complete |
| SH-03 | Phase 2 | ✅ Complete |
| SH-04 | Phase 2 | ✅ Complete |
| FO-01 | Phase 1 | ✅ Complete |
| FO-02 | Phase 3 | ✅ Complete |
| FO-03 | Phase 3 | ✅ Complete |
| CFG-01 | Phase 1 | ✅ Complete |
| CFG-02 | Phase 1 | ✅ Complete |
| CFG-03 | Phase 1 | ✅ Complete |
| CFG-04 | Phase 1 | ✅ Complete |
| CLI-01 | Phase 1 | ✅ Complete |
| CLI-02 | Phase 1 | ✅ Complete |
| CLI-03 | Phase 1 | ✅ Complete |
| CLI-04 | Phase 1 | ✅ Complete |
| BD-01 | Phase 1 | ✅ Complete |
| BD-02 | Phase 1 | ✅ Complete |
| BD-03 | Phase 1 | ✅ Complete |
| SK-01 | Phase 4 | ✅ Complete |
| SK-02 | Phase 4 | ✅ Complete |
| SK-03 | Phase 4 | ✅ Complete |
| TUI-01 | Phase 5 | ✅ Complete |
| TUI-02 | Phase 5 | ✅ Complete |
| TUI-03 | Phase 5 | ✅ Complete |
| MCP-01 | Phase 6 | ✅ Complete |
| MCP-02 | Phase 6 | ✅ Complete |
| MCP-03 | Phase 6 | ✅ Complete |
| ADV-01 | Advanced | ✅ Complete |
| ADV-02 | Advanced | ✅ Complete |
| ADV-03 | Advanced | ✅ Complete |

**Total:** 32/32 requirements complete ✅

---

*Requirements defined: 2026-04-11*
*Last updated: 2026-04-11 after v1 completion*