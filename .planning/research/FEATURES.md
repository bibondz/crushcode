# Feature Landscape: AI Coding CLI

**Domain:** AI-powered command-line coding assistant
**Researched:** 2026-04-11

## Executive Summary

The AI coding CLI space matured rapidly in 2025-2026, with Claude Code setting the benchmark (80%+ SWE-bench), Cursor dominating IDE integration, and tools converging on agentic autonomy. Key differentiators: terminal-native execution, multi-model support, MCP integration, and git-aware workflows. For Crushcode built in Zig, the table stakes are basic AI chat + file + shell execution; differentiators will be performance, zero-dependency deployment, and native terminal integration.

## Table Stakes

Features users expect. Missing = tool not taken seriously as an AI coding CLI.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **AI Chat Interface** | Primary interaction mode - ask questions, get help | Low | Required for any AI CLI |
| **Multi-Provider Support** | Users want model choice, not lock-in | Medium | OpenCode has 75+ providers; Zig stdlib limits this |
| **File Reading** | AI must read codebase context | Low | Basic fileops already implemented |
| **File Writing** | AI must be able to modify code | Low | Table stakes - no excuse not to have |
| **Shell Command Execution** | Run builds, tests, git, etc. | Medium | PTY plugin exists, full job control is gap |
| **Configuration Management** | API keys, preferences, provider selection | Low | Already implemented (TOML) |
| **Context Window** | Must hold code context | Medium | Model-dependent; focus on efficient prompting |
| **Streaming Response** | Real-time AI output feels responsive | Low-Medium | Implemented via std.http |

## Differentiators

Features that set products apart. Not expected by users, but highly valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Autonomous Execution** | AI runs commands, iterates until success | High | Claude Code's signature - hard in Zig |
| **Agent Teams / Subagents** | Multiple AI agents work in parallel | High | Advanced - maybe v2+ |
| **MCP Client** | Extend with model context protocol tools | Medium | Already implemented |
| **Skills System** | Reusable tool definitions (OpenCode pattern) | Medium-High | Could mirror skill to tool mapping |
| **Git Integration** | Atomic commits, diff awareness | Medium | Partially available |
| **Rich Terminal UI** | Bubble-style TUI components (Crush pattern) | Medium | Zig stdlib rendering is possible |
| **Interactive Mode** | Continuous conversation vs single prompts | Low | Already have `-i` flag |
| **Job Control** | Background jobs, fg/bg, pipes | High | Shell-level feature - complex in Zig |
| **Plugins/Extensions** | Shareable tool bundles | Medium | Plugin system already exists |
| **Hooks/Lifecycle** | Run actions on file changes | Medium | Could implement post-action hooks |
| **Large Context (1M)** | Hold entire codebases | High | Depends on model, not tool |
| **Codebase Indexing** | Semantic search across repo | High | RAG pipeline - maybe v2+ |

## Anti-Features

Features to explicitly NOT build.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **IDE Integration** | Out of scope for CLI - desktop app territory | Focus on best CLI experience |
| **Tab Completions** | Cursor owns this; requires editor plugin | Not feasible as standalone CLI |
| **Inline AI Suggestions** | Requires editor binding | Skip entirely |
| **GUI/Windowed UI** | Terminal-first is the constraint | Skip |
| **Web Server** | Not the product - CLI only | Skip |

## Feature Dependencies

```
AI Chat → File Reading → File Writing → Shell Execution
    ↓           ↓            ↓              ↓
 Config     Provider    MCP Client    Job Control
    ↓           ↓            ↓              ↓
Plugins ── Skills System ── Terminal UI
```

## MVP Recommendation

**Prioritize for v1:**

1. **Chat command + file read/write** — Table stakes, already done
2. **Shell execution with PTY** — Working via plugin, need full job control
3. **MCP client** — Already implemented
4. **Config with multi-provider** — 22 providers already supported
5. **Interactive mode** — Already exists

**Defer to v1.1:**
- Skills system (needs skill→tool mapping architecture)
- Rich terminal UI (basic TUI first)
- Full job control (background, fg/bg, pipes)

**Defer to v2:**
- Agent Teams (requires agent orchestration architecture)
- Codebase indexing (RAG pipeline)
- Hooks/lifecycle (post-action system)

## Source Analysis: Crushcode Current Features

| Feature | Status | Source Priority |
|---------|--------|-----------------|
| AI Providers (22) | ✅ Implemented | Table stakes |
| Chat command | ✅ Implemented | Table stakes |
| Read command | ✅ Implemented | Table stakes |
| Config management | ✅ Implemented | Table stakes |
| Plugin system | ⚠️ Partial | Differentiator |
| PTY plugin | ⚠️ Partial | Table stakes |
| MCP client | ⚠️ Partial | Differentiator |
| File operations | ⚠️ Basic | Table stakes |
| Shell strategy | ⚠️ Partial | Table stakes |
| Interactive mode | ❌ Missing | Table stakes |
| Skills system | ❌ Missing | Differentiator |
| Full terminal UI | ❌ Missing | Differentiator |
| Job control | ❌ Missing | Table stakes |
| LSP integration | ❌ Missing | Out of scope |
| Install script | ❌ Missing | Out of scope |

## Market Comparison

| Feature | Claude Code | Cursor | OpenCode | Aider | Crushcode |
|---------|------------|--------|---------|------|-----------|
| CLI-native | ✅ | ❌ | ✅ | ✅ | ✅ |
| IDE-native | ❌ | ✅ | ❌ | ❌ | ❌ |
| AI models | Anthropic | Multiple | 75+ | Multiple | 22 |
| MCP | ✅ | ✅ | ✅ | ❌ | ⚠️ |
| Skills | ❌ | ❌ | ✅ | ❌ | ❌ |
| Git integration | ✅ | ✅ | Partial | ✅ | Partial |
| Plugins | ✅ | ✅ | ✅ | ❌ | ⚠️ |
| TUI | Terminal | GUI | Terminal | Terminal | ⚠️ |
| Free tier | Via API | Limited | Via API | Via API | Via Ollama |
| Language | TypeScript | TypeScript | TypeScript | Python | Zig |

**Key insight:** Claude Code (TypeScript) sets the benchmark at 80%+ SWE-bench. Aiming for similar capability in Zig is the right vision but requires time. Focus on being a different kind of tool: faster, lighter, zero-dependency.

## Sources

- Claude Code vs Cursor comparison (2026): https://claudefa.st/blog/tools/extensions/claude-code-vs-cursor
- AI Coding Tool Comparison 2026: https://www.scotthavird.com/blog/ai-coding-tool-comparison-2026  
- Claude Code Alternatives: https://agents-squads.com/engineering/claude-code-alternatives-2026/
- CLI AI Showdown: https://sanj.dev/post/comparing-ai-cli-coding-assistants/