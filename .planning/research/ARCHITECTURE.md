# Architecture: Zig-based AI CLI

**Project:** Crushcode
**Researched:** 2026-04-11
**Confidence:** MEDIUM

## Executive Summary

The current codebase follows a layered architecture with clear component separation: CLI input → command dispatch → business logic → providers. The structure is sound for a CLI tool but has gaps in session management, streaming, and agent orchestration compared to reference implementations.

## Component Boundaries

| Component | Responsibility | Files | Status |
|-----------|----------------|-------|--------|
| **CLI Input** | Parse argv, validate flags | `cli/args.zig` | ✓ Complete |
| **Commands** | Route to implementations | `commands/handlers.zig`, `chat.zig`, `read.zig` | ✓ Complete |
| **Config** | Load, validate, store user preferences | `config/config.zig`, `provider_config.zig` | ✓ Complete |
| **AI Core** | Provider registry, HTTP client | `ai/client.zig`, `registry.zig` | ✓ Core done |
| **Plugins** | External tool integration | `plugin/`, `plugins/` | ✓ Partial |
| **MCP** | Model Context Protocol client | `mcp/client.zig`, `discovery.zig` | ✓ Partial |
| **Hybrid Bridge** | Plugin + MCP orchestration | `hybrid_bridge.zig` | ⚠️ Stub |
| **Agents** | Agent orchestration | `agents/base.zig` | ⚠️ Stub only |

### Current Data Flow

```
main.zig
  ├── args.zig           → parse CLI args
  ├── config.zig         → load config  
  └── handlers.zig
      ├── chat.zig       → AI chat session
      │   ├── client.zig → HTTP to providers
      │   ├── registry.zig → provider lookup
      │   └── plugin system
      ├── read.zig       → fileops/reader.zig
      └── list.zig       → registry
```

### Module Dependencies (build.zig analysis)

```
main.zig
  ├── args (no deps)
  ├── handlers.zig → args, registry, config, chat, read
  │   ├── chat.zig → args, registry, config, client, provider_config, plugin
  │   ├── read.zig → fileops
  │   └── registry.zig
  ├── config.zig (no deps)
  ├── provider_config.zig (no deps)
  └── plugin.zig
      └── protocol.zig
```

## Architecture Pattern

**Recommended Pattern:** Layered + Pipeline

```
┌─────────────────────────────────────────┐
│         main.zig (entry/dispatch)        │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│     commands/ (handlers, chat, read)     │ ← Thin controller layer
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│    Core Services (ai, config, fileops)   │ ← Business logic
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│   Integration Layer (mcp, plugins)       │ ← External systems
└─────────────────────────────────────────┘
```

## Build Order (Dependency-First)

Based on `build.zig` analysis, modules should be built in this order:

1. **Layer 0** (no dependencies): `cli/args.zig`, `config/`, `plugin/protocol.zig`
2. **Layer 1** (depends on L0): `ai/registry.zig`, `fileops/reader.zig`
3. **Layer 2** (depends on L1): `ai/client.zig`, `plugin/interface.zig`
4. **Layer 3** (depends on L2): `commands/chat.zig`, `commands/read.zig`
5. **Layer 4** (depends on L3): `commands/handlers.zig`
6. **Layer 5** (depends on L4): `main.zig`

## Identified Gaps

| Gap | Severity | Recommendation |
|-----|----------|----------------|
| **No session management** | HIGH | Add `session/` component for chat context, history |
| **No streaming support** | MEDIUM | Add async streaming to `ai/client.zig` |
| **Agent system stub** | MEDIUM | Implement `agents/base.zig` with skill dispatch |
| **HybridBridge not wired** | LOW | Connect `hybrid_bridge.zig` to main flow |
| **MCP discovery unused** | LOW | Wire `mcp/discovery.zig` at startup |

## Reference Architecture Comparison

| Aspect | Current | OpenCode (TS) | Crush (Go) |
|--------|---------|---------------|------------|
| Command routing | Manual dispatch | Skill registry | Interface-based |
| Session/context | None | Skill context | Request scope |
| Plugin system | Protocol interface | MCP-first | gRPC plugins |
| Provider abstraction | Registry | Built-in + MCP | Interface |
| Error handling | Basic | Comprehensive | Structured |

### OpenCode Patterns to Adopt
- **Skill-based dispatch** — Commands as skills with lifecycle
- **MCP-first tools** — MCP as primary tool integration
- **Persistent context** — Session state across commands

### Crush Patterns to Adopt
- **Interface-driven plugins** — Clear plugin boundaries
- **Structured error types** — Domain-specific error enums
- **Component registries** — Centralized capability lookup

## Recommended Phase Structure

### Phase 1: Foundation (current state)
- CLI parsing → command dispatch → config loading
- **Status:** Mostly complete

### Phase 2: Session Layer
- Add `session/` component for chat context
- Implement conversation history management
- Add session persistence (file-based)

### Phase 3: Streaming & Agents
- Add async streaming to AI client
- Implement agent system in `agents/base.zig`
- Wire hybrid_bridge into command flow

### Phase 4: Integration Polish
- Complete MCP discovery
- Plugin lifecycle management
- Error handling layer

## Scalability Considerations

| Scale | Current Approach | Needed Additions |
|-------|-----------------|-------------------|
| 100 users | In-memory state | Session per user |
| 10K users | Sequential HTTP | Connection pooling |
| 1M users | Single instance | Distributed state |

## Sources

- Current codebase analysis (`build.zig` dependency graph)
- Zig stdlib CLI proposal (issue #24601)
- zli framework patterns (xcaeser/zli)
- OpenCode skill architecture (internal reference)
- Crush component patterns (internal reference)