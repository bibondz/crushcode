# Crushcode

## What This Is

A Zig-based AI coding CLI/TUI tool that combines AI agent orchestration with a rich terminal interface. Built in Zig for native performance, zero dependencies, and cross-platform binary output. Currently at v0.32.0 with ~250 `.zig` files and ~105K lines.

## Core Value

Ship a self-improving AI coding assistant in Zig that learns from usage, remembers across sessions, and produces production-quality code.

## Current Milestone

**v0.33.0 — Self-Improving Agent** (planned)

Goals:
1. Auto skill generation from repeated usage patterns
2. User model (preferences, communication style, code conventions)
3. Context relevance scoring (stop dumping entire codebase)
4. Plan mode (propose plan → user approves → execute)

## Requirements

### Validated (v0.3.1–v0.32.0)

- [x] AI chat with streaming responses (22 providers)
- [x] TUI with Model/Msg/Update pattern (3924 lines)
- [x] Shell command execution with PTY
- [x] File read/write/edit/glob/grep tools
- [x] MCP client/server integration
- [x] Plugin system with JSON-RPC 2.0
- [x] Skills system with hierarchical resolution
- [x] Multi-agent parallel execution
- [x] Knowledge graph with vault operations
- [x] Auto-context compaction
- [x] 4-layer memory architecture
- [x] 21 TUI slash commands
- [x] Git worktree support

### Active (v0.33.0)

- [ ] **SELF-01**: Auto-detect repeated task patterns and generate SKILL.md files
- [ ] **SELF-02**: Persistent user model (USER.md) learning preferences across sessions
- [ ] **SELF-03**: Context relevance scoring — rank files by query similarity, not dump all
- [ ] **SELF-04**: Plan mode — generate structured plan before code changes, user approves
- [ ] **SELF-05**: Feedback loop — rate task outcomes, improve future suggestions

### Backlog

- [ ] Sub-agent delegation (isolated child agents)
- [ ] Graduated permission system (risk-based auto/manual approval)
- [ ] Mixture-of-Agents reasoning (multiple models collaborate)
- [ ] Skill hub (share/install skills from community)
- [ ] Expand builtin tools (web_fetch, code_search, git_ops)
- [ ] Streaming diff preview with accept/reject
- [ ] Sandboxed execution for untrusted shell commands

### Out of Scope

- Desktop GUI app — CLI/TUI only
- Web-based UI — terminal-first
- Mobile support
- Model weight training/fine-tuning

## Context

### Reference Projects Analyzed

| Project | Key Takeaway |
|---------|-------------|
| **Hermes Agent** (NousResearch) | Self-improving loop, auto skill gen, MoA reasoning, multi-platform gateway |
| **Claude Code** (Anthropic) | Plan mode, micro-compaction, 29 tools, progressive disclosure |
| **Codex** (OpenAI) | Structured plan items, sandbox execution, error code system |
| **OpenCode** (anomalyco) | TUI architecture, session context breakdown, skill system |
| **Goose** (block) | Permission inspector chain, retry manager, session extension |
| **Awesome Design MD** (VoltAgent) | DESIGN.md format for UI consistency |

### Architecture

```
src/main.zig → cli/args.zig → commands/handlers.zig
src/tui/chat_tui_app.zig — main TUI app (Model/Msg/Update)
src/ai/client.zig — AI HTTP client (22 providers, streaming)
src/agent/ — agent loop, compaction, memory, parallel, orchestrator
src/hybrid_bridge.zig — unified tool dispatch (builtin → MCP → plugins)
src/skills/ — loader, resolver, pipeline, import, agents_parser
src/knowledge/ — schema, vault, persistence, ops, lint
src/plugin/ — mod.zig barrel (types, registry, manager, runtime, protocol)
src/permission/ — evaluate, audit, governance, guardian, lists
src/mcp/ — client, bridge, discovery, server, transport
```

## Constraints

- **Language**: Zig — must use Zig stdlib only (no external deps)
- **Target**: Cross-platform CLI binary
- **Build**: `zig build` producing `crushcode` executable
- **Build cache**: `--cache-dir /tmp/zig-build-cache`
- **Platform**: Linux primary, WSL secondary

## Key Decisions

| Decision | Rationale | Outcome |
|----------|---------|---------|
| Language: Zig | Native performance, zero deps, cross-platform | ✓ Good |
| No external deps | std.http, std.json, std.process | ✓ Working |
| Hybrid bridge for tools | Builtin → MCP → Plugin dispatch | ✓ Extensible |
| 4-layer memory | Session → Working → Insights → Project | ✓ Sophisticated |
| JSON-RPC 2.0 plugins | Industry standard, simple protocol | ✓ Interoperable |

---

*Last updated: 2026-04-19 for v0.33.0 milestone planning*
