# Crushcode Comprehensive Reference Research

**Date**: 2026-04-27
**Scope**: ALL 41 reference repos at `/mnt/d/crushcode-references/`
**Method**: 5 parallel explore agents + direct file reads
**Purpose**: Find EVERY useful pattern for Crushcode (Zig, zero deps)

---

## 1. AST-Grep: Source Identified

**Answer**: `ast_grep_search` and `ast_grep_replace` come from **OhMyOpenAgent** plugin, NOT OpenCode core.

- **OpenCode core**: Zero ast-grep code. Only references ast-grep CDN once for tree-sitter-nix WASM.
- **OhMyOpenAgent**: Full `src/tools/ast-grep/` module (17 files). Spawns `sg` CLI binary. Auto-downloads.
- **Implementation**: CLI subprocess (`sg run -p PATTERN --lang LANG --json=compact`), NOT NAPI bindings.
- **25 languages**: bash, c, cpp, csharp, css, elixir, go, haskell, html, java, javascript, json, kotlin, lua, nix, php, python, ruby, rust, scala, solidity, swift, typescript, tsx, yaml.
- **Smart**: Empty result hints, 5-min timeout, 500 match cap, 2-pass for `--update-all` + `--json=compact`.
- **For Zig**: Could spawn `sg` binary same way — but requires binary distribution or user install.

---

## 2. Reference Repo Inventory (41 repos)

| Category | Repos |
|----------|-------|
| **AI Agent Platforms** | opencode, oh-my-openagent, goose-latest, goose-1.30.0, codex-rust-v0.121.0, codex, kimi-cli-1.35.0, open-claude-code, claude-code, hermes-agent, deepagents-0.5.3 |
| **Planning/Workflow** | get-shit-done (GSD), OpenHarness |
| **CLI/TUI** | crush (BubbleTea/Go), libvaxis-latest, libvaxis-0.5.1 (Zig TUI), caveman, cavekit |
| **Skills/Templates** | claude-code-templates, claude-code-templates-latest, claude-code-best-practice, claude-token-efficient, agent-skills-standard, skills-main, regenrek-agent-skills |
| **Checkpoint/Safety** | cheetahclaws |
| **Search** | ripgrep |
| **File Detection** | magika |
| **Graph/Viz** | graphify |
| **Second Brain** | karpathy-second-brain, COG-second-brain, obsidian-ai-second-brain, obsidian-second-brain, Firstbrain, DeepTutor |
| **Other** | future-agi, turboquant, multica, libvaxis |

---

## 3. Agent Orchestration Patterns

### Comparison Across 7 Repos

| Pattern | oh-my-openagent (TS) | goose (Rust) | codex-rust (Rust) | deepagents (Py) | hermes (Py) | open-claude-code (TS) |
|---------|---------------------|-------------|------------------|----------------|------------|---------------------|
| **Definition** | Factory functions `createXXXAgent(model) → AgentConfig` | Agent trait (2.5k LOC) with tool execution loop | `AgentControl` service with thread resolution | LangChain middleware `create_deep_agent()` | AIAgent class (~12k LOC) | SDK-based Claude client |
| **Spawning** | `buildAgent()` composes factory + categories + skills | `Container::create()` with tool schemas | `resolve_agent_target()` maps to ThreadId | `SubAgent` middleware with isolated graph | Direct instantiation | Direct instantiation |
| **Background** | BackgroundManager, 5/model concurrency | Scheduler trait with worker pools | Async with service pool | LangChain async middleware | CLI batch, async | Generator-based |
| **Tool Restrictions** | `denied_tools` array per agent | Tool schema filtering | Permission-based | Subagent tool override | Toolset-based | Permission modes |
| **Categories** | 8 categories mapping to models | Extension-based | Thread categories | Description matching | Toolset categories | Implicit tool selection |
| **Session** | UUID + profile isolation | Session + thread management | ThreadId + conversation tracking | LangGraph checkpoint | SQLite + FTS5 | Session-based |
| **Error Recovery** | Per-agent fallback chains + circuit breaker | RetryManager + exponential backoff | Service fallback | Middleware failover | `classify_api_error()` | Provider-level retry |

### Key Files by Repo
- **oh-my-openagent**: `src/agents/types.ts` (200 LOC), `src/agents/builtin-agents.ts` (182 LOC), `src/agents/sisyphus.ts` (559 LOC)
- **goose**: `crates/goose/src/agents/agent.rs` (2,502 LOC), `crates/goose/src/agents/tool_confirmation_router.rs`
- **codex-rust**: `codex-rs/core/src/agent/control.rs` (1,213 LOC), `codex-rs/core/src/agent/agent_resolver.rs` (36 LOC)
- **deepagents**: `libs/deepagents/middleware/subagents.py` (602 LOC)
- **hermes**: `run_agent.py` (~12k LOC)

### Most Relevant for Crushcode (Zig)
1. **codex-rust patterns** — Service-based, thread resolution, similar to Zig's architecture
2. **oh-my-openagent factory pattern** — Clean, composable, category-based model routing
3. **goose retry manager** — Comprehensive exponential backoff with success checks

---

## 4. Edit Tools & Safety Patterns

### Comparison Across 6 Repos

| Pattern | oh-my-openagent | codex-rust | goose | cheetahclaws | crush | open-claude-code |
|---------|----------------|------------|-------|-------------|-------|-----------------|
| **Edit Type** | Hash-based (LINE#ID) | Patch-based (unified diff) | String find/replace | Checkpoint + backup | String + permission | String replacement |
| **Validation** | Hash mismatch → reject | Sequence seeking | Context matching | File state tracking | Permission system | Read-first |
| **Undo** | None (prevention) | Ghost commits | None | Version restore | History integration | Session undo |
| **Error Recovery** | Hook-based reminders | Git rollback | Helpful error messages | Auto-rollback | Permission recovery | Error messages |
| **Batch** | replace/append/prepend | Multi-hunk patches | Sequential | Atomic batch | MultiEdit tool | MultiEdit |
| **Safety Level** | ★★★★★ Maximum | ★★★★ High | ★★★ Medium | ★★★★★ Maximum | ★★★★ Industrial | ★★ Medium |
| **Zig Suitability** | ★★★★★ Best | ★★ Needs git | ★★★★ Good | ★★★ Heavy | ★★★ Needs perm | ★★★★★ Best |

### Hashline Edit (oh-my-openagent) — THE Innovation
- `computeLineHash(lineNum, content)` → xxHash32 → 2-char from `ZPMQVRWSNKTXJBYH`
- Every Read output: `42#VK| function hello() {`
- Edit references `{lineNum}#{hash}` — file changed = hash mismatch = rejected
- 3 ops: replace, append, prepend
- Pipeline: normalize → validate → order (bottom-up) → deduplicate → apply → autocorrect → diff
- **29 files**, full implementation reference
- **Zig: trivial to implement** — xxHash32 in stdlib, simple CID mapping

### Codex-Rust Patch System
- `*** Begin Patch` format with hunks (AddFile, DeleteFile, UpdateFile)
- Sophisticated sequence seeking for fuzzy content matching
- Ghost commits for undo (git stash snapshots)
- **342 LOC** for apply-patch, **187 LOC** for undo
- **Zig: patch parsing is feasible**, but git dependency is a blocker

### Cheetahclaws Checkpoint System
- Auto-backup before every file modification
- Complete file history with versioning
- Point-in-time restoration
- **Python, 422 LOC** — could be adapted to Zig

### Crush Permission System
- Before/after string replacement with explicit permission requests
- File modification time tracking (`modTime.After(lastRead)`)
- MultiEdit for complex operations
- **577 LOC** total (edit.go + multiedit.go + lsp/edit.go)

### Recommendations for Crushcode
1. **Primary**: Hash-based validation (oh-my-openagent) — zero deps, maximum safety
2. **Secondary**: File mod-time tracking (crush) — simple additional check
3. **Error UX**: Helpful contextual messages (goose) — shows similar content on mismatch
4. **Backup**: Lightweight checkpoint before destructive ops (cheetahclaws pattern)

---

## 5. TUI & Terminal Patterns

### Comparison Across 5 Repos

| Pattern | opencode (TS/React) | crush (Go/BubbleTea) | codex-rust (Rust/Ratatui) | libvaxis (Zig!) |
|---------|--------------------|--------------------|--------------------------|----------------|
| **Framework** | React-based TUI | BubbleTea (Elm arch) | Ratatui | Native Zig |
| **Event Loop** | crossterm broadcast | Tea.Program messages | crossterm async | `vaxis.Loop(Event)` |
| **Widgets** | React components | BubbleTea Model | Ratatui primitives | vxfw Flutter-like |
| **Rendering** | Virtual DOM + morphdom | Lipgloss escape seqs | Double-buffered 60fps | Double-buffered diff |
| **Markdown** | `marked` + streaming | Custom | pulldown-cmark + syntect | Needs integration |
| **Syntax HL** | highlight.js | Custom | syntect (250 langs) | Needs integration |
| **Streaming** | markdown-stream.ts | Custom | MarkdownStreamCollector | Event-driven redraw |
| **Input** | React forms | BubbleTea keys | Custom text widget | TextField widget |
| **Resize** | CSS media queries | Lipgloss responsive | Ratatui constraints | Constraint-based layout |

### libvaxis — The Zig TUI Library (RECOMMENDED)
- **Zero external deps** — pure Zig, no terminfo
- **Two-tier API**: Low-level (Window/Cell) + High-level (vxfw framework)
- **Built-in widgets**: Text, Button, TextField, ListView, ScrollView, Border, FlexColumn, FlexRow, SplitContainer
- **Modern features**: RGB colors, kitty keyboard protocol, mouse, images
- **Performance**: Thread-safe, double-buffered, differential updates
- **Layout**: Flutter-inspired constraint-based system
- **Files**: `src/Vaxis.zig`, `src/vxfw/vxfw.zig`, `src/vxfw/Text.zig`

### Codex-Rust Syntax Highlighting
- `syntect` with `two_face` grammar/theme bundles
- ~250 languages, 32+ themes
- Performance guards: 512KB / 10K line limits
- ANSI color palette support
- **For Zig**: Regex-based highlighting (Crushcode already has 20 langs) is sufficient for now

---

## 6. MCP, Skills, Config, Hooks, Commands, Permissions

### MCP Implementation

| Repo | Transports | Tool Discovery | Lifecycle |
|------|-----------|----------------|-----------|
| **opencode** | stdio, HTTP, SSE, WebSocket | Runtime registration | Status tracking (connected/disabled/failed/needs_auth) |
| **oh-my-openagent** | 3-tier: built-in HTTP + .mcp.json + skill-embedded | Per-session client isolation | OAuth 2.0 + PKCE + DCR |
| **crush** | stdio, HTTP, SSE | Config-based (.crush.json) | Simple lifecycle |
| **cheetahclaws** | stdio, HTTP | Dynamic registration | Python-based lifecycle |
| **claude-code** | stdio, HTTP, SSE | Transport-agnostic factory | 8 tools, 3 prompts |

### Skill Loading (Universal: Router → Index → Target)

**SKILL.md Format** (standard across ALL repos):
```yaml
---
name: skill-name
description: When to use this skill
triggers: ['*.ts', 'keyword']
allowedTools: ['Bash', 'Read', 'Edit']
---

# Skill instructions
```

**Discovery Methods**:
1. **File pattern matching** — crush, skills-main
2. **Keyword matching** — agent-skills-standard, regenrek-agent-skills
3. **Auto-discovery** — claude-code, opencode
4. **4-scope priority** — oh-my-openagent (project > opencode > user > global)

### Configuration System

| Repo | Format | Merge Strategy | Validation |
|------|--------|---------------|------------|
| **oh-my-openagent** | JSONC | User → Project → Defaults (deep merge) | Zod v4 (32 schema files) |
| **opencode** | Multiple formats | Managed → CLI → Local → Project → Global → Defaults | Type checking |
| **crush** | JSON (.crush.json) | .crush.json → crush.json → ~/.config/crush/crush.json | Go structs |
| **claude-code** | JSON settings | Hierarchical with environment overrides | Schema |

### Hook/Lifecycle System

**27 Standard Hook Events** (from claude-code-best-practice):

| Priority | Events | Zig Implementation |
|----------|--------|--------------------|
| **P1** | PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest | Function pointer callbacks |
| **P2** | SessionStart, SessionEnd, Setup | Simple lifecycle hooks |
| **P3** | ConfigChange, CwdChanged, FileChanged | File watchers |

**OhMyOpenAgent's 52 Hooks** — most complex implementation:
- 5 tiers: Session(24) → Tool-Guard(14) → Transform(5) → Continuation(7) → Skill(2)
- Complex orchestrators: atlas (1976 LOC), todo-continuation-enforcer (2061 LOC), ralph-loop (1687 LOC)

### Command System

**Universal `/command` pattern** with YAML frontmatter:
```yaml
---
name: command-name
description: When to use
argumentHint: "[issue-number]"
---

# Command implementation as prompt template
```

**Discovery**: Auto from `.claude/commands/`, `.opencode/commands/`, `.crushcode/commands/`

### Permission System

**5 Permission Modes** (from claude-code):
1. `default` — Always ask
2. `auto` — Classifier decides
3. `plan` — Read-only
4. `acceptEdits` — Auto-approve file edits
5. `bypassPermissions` — Never ask

**Pattern Matching Engine**:
```
Bash(git *)     → Allow git commands
Edit(*.ts)      → Allow TS file edits
mcp__.*         → Allow MCP tools
Read(/home/*)   → Allow home dir reads
```

### Plugin System

**3 Plugin Models**:
1. **Marketplace** — skills-main (git repo based)
2. **Distribution** — agent-skills-standard (CLI tool, rsync)
3. **Interface** — oh-my-openagent (abstract interfaces, runtime injection)

---

## 7. AI Provider & Streaming Patterns

### Provider Abstraction

| Repo | Pattern | Key Feature |
|------|---------|-------------|
| **opencode** | Config-first with validation | 75+ providers, regex validation, env var API keys |
| **oh-my-openagent** | Availability mapping | Per-provider availability checks, OpenAI-only mode |
| **goose** | ACP protocol abstraction | Session-based, tool permission routing |
| **crush** | Embedded config + lazy loading | `go:embed` provider data, sync.OnceValue |

### Streaming (SSE)

**open-claude-code** has the most complete SSE implementation:
- Full event support: `message_start`, `content_block_*`, `message_delta`, `message_stop`
- Buffer handling for incomplete chunks
- Tool input streaming via `input_json_delta`
- Thinking block support via `thinking_delta`

**For Zig**: Parse SSE with simple line-by-line state machine — no external deps needed.

### Token Counting

**goose** has the most sophisticated implementation:
- Tiktoken-rs for o200k_base tokenizer
- LRU cache (10,000 entries) with DashMap
- Tool token overhead calculation (function init: 7 tokens, property init: 3 tokens)
- **For Zig**: Simple chars/4 estimation is fine for now, add caching later.

### Context Management

**kimi-cli** checkpoint system:
- JSONL-based context persistence
- Checkpoint creation and reversion
- File rotation for history
- Token count integration

**For Zig**: Already have compaction system (`src/agent/compaction.zig`, 1328 lines).

### Model Fallback

**oh-my-openagent** — most configurable:
- Per-agent fallback chains: `k2p5 → kimi-k2.5 → gpt-5.5 → glm-5`
- Two systems: proactive `model-fallback` (chat.params) + reactive `runtime-fallback` (session.error)
- 4-step model resolution: override → category-default → provider-fallback → system-default

### Retry with Backoff

**goose** — most comprehensive:
- `RetryManager` with attempt tracking
- Configurable retry limits and timeouts
- Success check execution before retry
- Env var configuration: `GOOSE_RECIPE_RETRY_TIMEOUT_SECONDS`
- On-failure command execution

---

## 8. Additional Gems From Less-Explored Repos

### GSD (get-shit-done) — THE Planning Layer
- **40+ slash commands** for project lifecycle
- Wave-based parallel execution (independent plans run simultaneously)
- Atomic git commits per task
- XML prompt formatting optimized for Claude
- Fresh context per plan (200k tokens per executor)
- **Crushcode already uses GSD** in `.planning/` directory

### Caveman — Token Efficiency
- Ultra-compressed communication mode (~75% token reduction)
- 4 intensity levels: lite, full, ultra, wenyan
- Auto-detection of when to compress vs expand
- **Relevant**: Crushcode could implement similar modes

### claude-token-efficient — Token Optimization
- Profiles for different compression levels
- Benchmark results for token savings
- Rules for efficient prompting

### Magika — AI File Type Detection
- Rust/Python/JS implementations
- AI-powered file type identification
- **For Zig**: Could port the Rust implementation or use simpler extension-based detection

### OpenHarness — Agent Dashboard
- Frontend dashboard for agent monitoring
- Python-based agent framework
- Autopilot dashboard for visualization

### ripgrep — Search Engine Reference
- Rust-based regex search engine
- Glob-based file filtering
- **For Zig**: Already have `src/tools/grep.zig` but ripgrep's ignore-file parsing is reference-quality

---

## 9. Actionable Priority Matrix for Crushcode

### Tier 1: Immediate (Zero deps, high impact)

| Feature | Source | Effort | Impact |
|---------|--------|--------|--------|
| **Hashline Edit** | oh-my-openagent | Medium | ★★★★★ — Solves "harness problem" |
| **Write-Before-Read Guard** | crush | Low | ★★★★ — Prevents blind overwrites |
| **Tool Output Truncation** | oh-my-openagent | Low | ★★★★ — Prevents context bloat |
| **Bottom-up Edit Ordering** | oh-my-openagent | Low | ★★★★ — Prevents line drift |
| **Comment Checker** | oh-my-openagent | Low | ★★★ — Blocks AI slop |
| **Preemptive Compaction** | oh-my-openagent | Medium | ★★★★★ — Context management |
| **File Mod-Time Tracking** | crush | Low | ★★★★ — Stale file detection |
| **Token Estimation Cache** | goose | Low | ★★★ — Performance |

### Tier 2: Architecture (Requires design)

| Feature | Source | Effort | Impact |
|---------|--------|--------|--------|
| **Background Agent System** | oh-my-openagent | High | ★★★★★ — Parallel execution |
| **Category-based Delegation** | oh-my-openagent | Medium | ★★★★ — Task → optimal model |
| **Hook Lifecycle System** | oh-my-openagent | High | ★★★★ — Extensible platform |
| **3-tier MCP** | oh-my-openagent | High | ★★★★★ — Tool ecosystem |
| **Skill Loader** | crush/agent-skills-standard | Medium | ★★★★ — SKILL.md parsing |
| **Slash Command System** | GSD/crush | Medium | ★★★★ — User interface |
| **Permission System** | crush/claude-code | Medium | ★★★★ — Safety |
| **Model Fallback** | oh-my-openagent | Medium | ★★★★ — Reliability |
| **SSE Streaming Parser** | open-claude-code | Medium | ★★★★★ — Core functionality |

### Tier 3: Future (Blocked or complex)

| Feature | Source | Blocker |
|---------|--------|---------|
| **AST-grep** | oh-my-openagent | Requires sg binary distribution |
| **libvaxis TUI** | libvaxis-latest | Integration effort, API maturity |
| **Real tree-sitter** | goose | Zero-dep constraint (C library) |
| **Plugin System** | oh-my-openagent | Needs architecture first |
| **Context Window Monitor** | oh-my-openagent | Needs hook system first |
| **Tmux Integration** | oh-my-openagent | Requires tmux installed |
| **OAuth for MCP** | oh-my-openagent | Complex protocol |

---

## 10. Key Reference Files Index

### Agent Orchestration
- `oh-my-openagent/src/agents/types.ts` — AgentFactory, AgentMode
- `oh-my-openagent/src/agents/builtin-agents.ts` — 11 agents registry
- `goose-latest/crates/goose/src/agents/agent.rs` — 2,502 LOC Rust agent
- `codex-rust/codex-rs/core/src/agent/control.rs` — 1,213 LOC service

### Edit Tools
- `oh-my-openagent/src/tools/hashline-edit/` — 29 files, hash-based editing
- `codex-rust/codex-rs/apply-patch/src/lib.rs` — 342 LOC patch system
- `codex-rust/codex-rs/core/src/tasks/undo.rs` — 187 LOC ghost commits
- `crush/internal/agent/tools/edit.go` — 234 LOC string replacement
- `crush/internal/agent/tools/multiedit.go` — 187 LOC batch edits

### TUI
- `libvaxis-latest/src/Vaxis.zig` — Core Zig TUI
- `libvaxis-latest/src/vxfw/vxfw.zig` — Flutter-like widget framework
- `codex-rust/codex-rs/tui/src/tui.rs` — Ratatui TUI
- `codex-rust/codex-rs/tui/src/markdown_render.rs` — Terminal markdown
- `codex-rust/codex-rs/tui/src/render/highlight.rs` — Syntax highlighting

### MCP/Skills/Config
- `oh-my-openagent/src/mcp/` — 3-tier MCP system
- `oh-my-openagent/src/features/opencode-skill-loader/` — 33 files skill loading
- `oh-my-openagent/src/config/schema/` — 32 files JSONC validation
- `crush/internal/skills/skills.go` — SKILL.md parsing
- `claude-code-best-practice/.claude/hooks/` — 27 hooks with config

### Streaming/Provider
- `open-claude-code/v2/src/core/streaming.mjs` — Complete SSE implementation
- `goose-latest/crates/goose/src/agents/retry.rs` — Retry with backoff
- `goose-latest/crates/goose/src/token_counter.rs` — Token caching
- `kimi-cli-1.35.0/src/kimi_cli/soul/context.py` — Context management

### Planning
- `get-shit-done/` — 40+ slash commands, wave execution, XML prompts
- `get-shit-done/agents/` — 20+ specialized planning agents
