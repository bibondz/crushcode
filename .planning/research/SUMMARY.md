# Research Summary: Crushcode AI Coding CLI

**Project:** Crushcode - Zig-based AI Coding CLI
**Researched:** 2026-04-11
**Overall Confidence:** MEDIUM-HIGH

---

## Executive Summary

The AI coding CLI market has matured significantly (2025-2026), with Claude Code establishing the benchmark (80%+ SWE-bench) for autonomous terminal-based coding assistants. The field divides into CLI-native tools (Claude Code, Aider, OpenCode) and IDE-integrated tools (Cursor, Windsurf). Crushcode, built in Zig, occupies a unique position: native performance, zero dependencies, and cross-platform binaries. Current implementation covers table stakes (22 AI providers, chat, read, config), with differentiating features (MCP, skills, rich TUI) as future roadmap items.

**Key Finding:** Users expect AI coding CLIs to deliver autonomous execution, multi-model support, and git-aware workflows. Claude Code wins on reasoning quality; Cursor wins on IDE integration. For Crushcode to compete, lean into performance (Zig's advantage) and avoid feature parity chase with TypeScript-based tools.

---

## Key Findings

### Stack
- **Language:** Zig with stdlib only (no external dependencies)
- **Build:** Zig build system → single cross-platform binary
- **AI Clients:** OpenAI-compatible HTTP via std.http
- **Providers:** 22 supported (Ollama, OpenRouter, OpenAI, Anthropic, etc.)
- **Why Zig:** Zero-cost abstraction, native HTTP/JSON, cross-compile to any platform

### Architecture  
- **Pattern:** Modular command dispatch (handlers → chat/read → ai/client)
- **Plugin System:** JSON-RPC 2.0 for extensions
- **MCP:** Client + server discovery implemented
- **Configuration:** TOML-based, user config at ~/.crushcode/config.toml

### Critical Pitfall
- **Current LSP errors:** 5 distinct compile errors in MCP, Plugin, Config modules — need resolution before build passes
- **Feature gaps:** Interactive mode incomplete, job control missing, skills system not implemented
- **Risk:** Zig's learning curve + limited ecosystem vs TypeScript alternatives

---

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Fix Core Infrastructure
- **Addresses:** LSP errors (MCP client, plugin protocol, config unused)
- **Goal:** Clean build with all modules compiling

### Phase 2: Complete Table Stakes  
- **Addresses:** Interactive mode, shell execution with job control
- **Goal:** AI can read, write, execute shell commands in conversation
- **Avoids:** Feature bloat — focus on working chat loop first

### Phase 3: MCP Integration
- **Addresses:** MCP client completion, server discovery
- **Goal:** Support for 40+ MCP tools (GitHub, Filesystem, Context7, Exa)
- **Avoids:** Reinventing tool ecosystem — MCP is standard

### Phase 4: Differentiators (v1.1)
- **Addresses:** Rich terminal UI, skills system
- **Goal:** TUI with bubble-style components, reusable skill templates
- **Rationale:** Builds on existing plugin architecture

### Phase 5: Advanced (v2)
- **Addresses:** Agent Teams, codebase indexing
- **Goal:** Multiple agents, RAG pipeline for large codebases
- **Rationale:** Requires foundations from phases 1-4

---

## Phase Ordering Rationale

1. **Must fix build first** → Phase 1 fixes compilation errors so development proceeds
2. **Table stakes enable useful work** → Phase 2 completes the feedback loop (chat → read → write → execute → respond)
3. **Standards leverage existing work** → Phase 3 adds MCP without new tool definitions  
4. **Differentiators build on infrastructure** → Phase 4 requires working plugin + MCP systems
5. **Advanced features need architecture** → Phase 5 requires agent orchestration not yet designed

**Research Flags:**
- Phase 1: LSP errors are well-defined, fix is straightforward
- Phase 2: Job control (background, fg/bg, pipes) has Zig implementation complexity
- Phase 3: MCP client mostly complete, needs testing
- Phase 4: Skills system requires design — how to map skills → plugins?
- Phase 5: Agent Teams is aspirational — requires architecture not yet in codebase

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Zig stdlib well-understood, verified in codebase |
| Features | HIGH | Mapped from market analysis + codebase review |
| Architecture | MEDIUM-HIGH | Modular pattern follows well-established Zig patterns |
| Pitfalls | HIGH | LSP errors directly analyzed, fixes verified |
| Roadmap | MEDIUM | Estimated based on feature dependencies |

---

## Gaps to Address

1. **Interactive mode:** Current chat command lacks full interactive session handling
2. **Job control:** Shell execution exists, but background/fg/bg/pipes not implemented  
3. **Skills system:** No skill→tool mapping architecture designed
4. **Rich TUI:** Basic terminal output, no bubble-style components yet
5. **MCP testing:** Client exists, needs integration testing with real MCP servers
6. **Codebase indexing:** Not in scope for v1, requires design for v2

---

## Market Position

| Tool | Strength | Weakness | Crushcode Angle |
|------|----------|----------|----------------|
| Claude Code | 80%+ SWE-bench, reasoning | TypeScript, dependencies | Faster, lighter, single binary |
| Cursor | IDE integration | Not CLI, costs | Terminal-native is design |
| Aider | Git-native | Python | Zig faster, Rust-like |
| OpenCode | 75+ providers | TypeScript | Performance (Zig), cross-compile |
| Gemini CLI | Free tier | Google lock-in | Provider choice (22 now) |

**Positioning:** Crushcode wins on performance and deployment simplicity. Single binary, zero dependencies, cross-platform — not competing on feature count with TypeScript tools.

---

### Additional Reference: Claude Code Source

**Source:** https://github.com/777genius/claude-code-source-code-full (leaked, 2026-03-31) — TypeScript+Bun

| Claude Code Pattern | Crushcode Application |
|-------------------|-------------------|
| Tool registry (~40 tools) | Plugin system ✓ |
| Slash commands (~50) | Subcommands + aliases |
| Zod input validation | Manual/std.json |
| Per-tool permissions | Skip for v1 |
| Service layer | MCP exists → v2 |
| Bundled skills | v2 feature |

**Key implementations to study:** Tool tool definition (`buildTool`), command pattern, service layer organization.

---

## Sources

- Claude Code vs Cursor (2026): https://claudefa.st/blog/tools/extensions/claude-code-vs-cursor
- AI Coding Tool Comparison: https://www.scotthavird.com/blog/ai-coding-tool-comparison-2026
- Claude Code Alternatives: https://agents-squads.com/engineering/claude-code-alternatives-2026/
- CLI AI Showdown: https://sanj.dev/post/comparing-ai-cli-coding-assistants/
- Codebase analysis: .planning/codebase/{STRUCTURE,INTEGRATIONS,STACK}.md

---

*Research complete: 2026-04-11*