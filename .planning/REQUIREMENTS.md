# Requirements: Crushcode

**Defined:** 2026-04-11
**Core Value:** Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

---

## v1 Requirements

These are the foundational requirements needed to have a working AI coding CLI.

### Core AI

- [ ] **AI-01**: User can chat with AI via CLI (streaming responses)
- [ ] **AI-02**: User can switch between AI providers (Ollama, OpenRouter, OpenCode)
- [ ] **AI-03**: Configurable API endpoints and API keys per provider
- [ ] **AI-04**: System prompt support for context setting

### Shell Execution

- [ ] **SH-01**: User can execute shell commands and see output
- [ ] **SH-02**: Command execution returns exit code
- [ ] **SH-03**: Support for interactive commands (PTY)
- [ ] **SH-04**: Command timeout support

### File Operations

- [ ] **FO-01**: User can read files via CLI command
- [ ] **FO-02**: User can write/edit files via AI agent
- [ ] **FO-03**: Support for glob patterns in file selection

### Configuration

- [ ] **CFG-01**: TOML configuration file at ~/.crushcode/config.toml
- [ ] **CFG-02**: Provider configuration (endpoints, models, keys)
- [ ] **CFG-03**: Default provider selection
- [ ] **CFG-04**: Config validation on startup

### CLI Interface

- [ ] **CLI-01**: Command-line argument parsing
- [ ] **CLI-02**: Help text for all commands
- [ ] **CLI-03**: Interactive chat mode (non-streaming)
- [ ] **CLI-04**: Error handling with user-friendly messages

### Build & Distribution

- [ ] **BD-01**: Builds successfully with `zig build`
- [ ] **BD-02**: Produces working executable for current platform
- [ ] **BD-03**: No LSP errors in codebase

---

## v2 Requirements

Deferred for future releases.

### MCP Integration

- **MCP-01**: Full MCP client implementation
- **MCP-02**: MCP server for external tools
- **MCP-03**: MCP discovery of available tools

### Skills System

- **SK-01**: Skill definition system
- **SK-02**: Built-in file operation skills
- **SK-03**: Built-in git skills

### Terminal UI

- **TUI-01**: Rich terminal output (colors, formatting)
- **TUI-02**: Progress indicators/spinners
- **TUI-03**: Interactive selection UI

### Advanced

- **ADV-01**: Job control (background jobs)
- **ADV-02**: Pipe/redirection support
- **ADV-03**: Install script (curl | bash)

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
| AI-01 | Phase 1 | Pending |
| AI-02 | Phase 1 | Pending |
| AI-03 | Phase 1 | Pending |
| AI-04 | Phase 1 | Pending |
| SH-01 | Phase 2 | Pending |
| SH-02 | Phase 2 | Pending |
| SH-03 | Phase 2 | Pending |
| SH-04 | Phase 2 | Pending |
| FO-01 | Phase 1 | Pending |
| FO-02 | Phase 3 | Pending |
| FO-03 | Phase 3 | Pending |
| CFG-01 | Phase 1 | Pending |
| CFG-02 | Phase 1 | Pending |
| CFG-03 | Phase 1 | Pending |
| CFG-04 | Phase 1 | Pending |
| CLI-01 | Phase 1 | Pending |
| CLI-02 | Phase 1 | Pending |
| CLI-03 | Phase 1 | Pending |
| CLI-04 | Phase 1 | Pending |
| BD-01 | Phase 1 | Pending |
| BD-02 | Phase 1 | Pending |
| BD-03 | Phase 1 | Pending |

---

*Requirements defined: 2026-04-11*
*Last updated: 2026-04-11 after domain research*