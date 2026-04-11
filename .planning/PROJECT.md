# Crushcode

## What This Is

A Zig-based AI coding CLI tool that combines capabilities from OpenCode (AI agent orchestration) and Crush (Shell/CLI in Go). Built in Zig for native performance, zero dependencies, and cross-platform binary output.

## Core Value

Ship a working AI coding assistant in Zig that can execute shell commands, manage files, and interact with AI providers (Ollama, OpenRouter).

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Implement all remaining commands from reference repos
- [ ] Add proper shell execution (PTY, interactive commands)
- [ ] Complete MCP client/server integration
- [ ] Add terminal UI (like Crush's bubble UI)
- [ ] Implement skill system (like OpenCode's skills)
- [ ] Add LSP integration
- [ ] Build install script (like OpenCode's curl | bash)

### Out of Scope

- Desktop GUI app — CLI only for v1
- Web-based UI — terminal-first
- Mobile support

## Context

### Reference Projects Analyzed

**OpenCode** (https://github.com/anomalyco/opencode):
- AI coding agent with TUI
- Skills system with skill definitions
- MCP client/server
- LSP integration
- Install script (curl | bash)
- Multiple AI providers

**Crush** (https://github.com/charmbracelet/crush):
- Shell in Go with bubble UI
- Rich terminal UI components (list, table, spinner)
- Job control, pipes, redirections
- Permission system

### Current Crushcode State

**Existing (from codebase map)**:
- HTTP AI client (Ollama, OpenRouter, OpenCode Zen/Go)
- CLI args parsing
- Config management
- Plugin system (PTYs, shell, notifier, table formatter)
- MCP client and discovery
- File operations module
- Chat command, read command

**Gaps vs References**:
- Skills system (OpenCode has skill definitions)
- Full terminal UI (Crush has rich bubble UI)
- Complete shell execution (need PTY + job control)
- Install script
- LSP integration
- Permission handling

### Current Branch

- Branch: `001-http-client-ai`
- Last work: OpenRouter model support

## Constraints

- **Language**: Zig — must use Zig stdlib only (no external deps)
- **Target**: Cross-platform CLI binary
- **Build**: `zig build` producing `crushcode` executable

## Key Decisions

| Decision | Rationale | Outcome |
|----------|---------|---------|
| Language: Zig | Native performance, zero deps, cross-platform | ✓ Good |
| Build System: Zig build | Standard Zig tooling | — Pending |
| No external deps for AI | Use std.http, std.json | — Pending |

---

*Last updated: 2026-04-11 after cloning reference repos*