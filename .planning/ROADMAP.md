# Roadmap: Crushcode v1

**Created:** 2026-04-11
**Granularity:** Coarse
**Parallelization:** true

---

## Phases

- [x] **Phase 1: Core Infrastructure** - Config, AI chat, CLI, build system
- [x] **Phase 2: Shell Execution** - Command execution with PTYand timeouts
- [x] **Phase 3: AI File Operations** - AI-driven file write/edit with glob patterns
- [x] **Phase 4: Skills System** - Built-in commands and extensibility
- [x] **Phase 5: Terminal UI** - Rich interactive interface
- [x] **Phase 6: MCP Integration** - Model Context Protocol support

---

## Phase Details

### Phase 1: Core Infrastructure

**Goal:** Users can configure providers, chat with AI, read files, and build the project

**Depends on:** Nothing (first phase)

**Requirements:** AI-01, AI-02, AI-03, AI-04, FO-01, CFG-01, CFG-02, CFG-03, CFG-04, CLI-01, CLI-02, CLI-03, CLI-04, BD-01, BD-02, BD-03

**Success Criteria** (what must be TRUE):
  1. User can configure Ollama/OpenRouter/OpenCode providers in ~/.crushcode/config.toml
  2. User can start chat session and receive streaming AI responses
  3. User can switch between configured providers during chat
  4. User can read any file using the read command
  5. `zig build` produces working crushcode executable with no LSP errors
  6. Help text displays for all commands with user-friendly error messages

**Plans:** 1 plan

- [ ] 01-01-PLAN.md — System prompt + streaming support

**UI hint:** yes

---

### Phase 2: Shell Execution

**Goal:** Users can execute shell commands from within the AI chat context

**Depends on:** Phase 1

**Requirements:** SH-01, SH-02, SH-03, SH-04

**Success Criteria** (what must be TRUE):
  1. User can type shell commands and see command output in chat
  2. Exit codes from commands are returned and visible
  3. Interactive commands (like htop, vim) work via PTY
  4. Commands can be terminated after a configurable timeout

**Plans:** 3 plans

- [ ] 02-01-PLAN.md — Shell command with output + exit codes
- [ ] 02-02-PLAN.md — PTY integration for interactive commands
- [ ] 02-03-PLAN.md — Timeout support

---

### Phase 3: AI File Operations

**Goal:** AI agent can write and edit files based on user requests

**Depends on:** Phase 1 (AI), Phase 2 (Shell for save operations)

**Requirements:** FO-02, FO-03

**Success Criteria** (what must be TRUE):
  1. User can ask AI to "write this file" and AI creates/modifies the file
  2. User can specify file targets using glob patterns (e.g., "edit all *.test.ts files")
  3. File operations succeed or return clear error messages

**Plans:** 1 plan

- [x] 03-01-PLAN.md — AI-driven file operations with glob

---

### Phase 4: Skills System

**Goal:** Built-in commands and extensibility

**Depends on:** Phase 1

**Requirements:** SK-01, SK-02, SK-03

**Success Criteria** (what must be TRUE):
  1. Users can run built-in skills (echo, date, whoami, etc.)
  2. Skills system is extensible for future commands
  3. Skills are documented in help text

**Plans:** 1 plan

- [ ] 04-01-PLAN.md — Skills system implementation

---

### Phase 5: Terminal UI

**Goal:** Rich interactive interface with colors and formatting

**Depends on:** Phase 1

**Requirements:** TUI-01, TUI-02, TUI-03

**Success Criteria** (what must be TRUE):
  1. ANSI colors work in terminal
  2. Interactive TUI mode launches with `crushcode tui`
  3. Progress indicators and formatted output work

**Plans:** 1 plan

- [ ] 05-01-PLAN.md — TUI utilities and interactive mode

---

### Phase 6: MCP Integration

**Goal:** Model Context Protocol support for external tools

**Depends on:** Phase 1, Phase 4

**Requirements:** MCP-01, MCP-02, MCP-03

**Success Criteria** (what must be TRUE):
  1. HTTP transport for MCP connections works
  2. MCP server discovery functional
  3. Tool execution via MCP available

**Plans:** 1 plan

- [ ] 06-01-PLAN.md — MCP client implementation

---

## Progress

| Phase | Plans Complete | Status | Completed |
|------|----------------|--------|-----------|
| 1. Core Infrastructure | 1/1 | Complete | ✅ |
| 2. Shell Execution | 3/3 | Complete | ✅ |
| 3. AI File Operations | 1/1 | Complete | ✅ |
| 4. Skills System | 1/1 | Complete | ✅ |
| 5. Terminal UI | 1/1 | Complete | ✅ |
| 6. MCP Integration | 1/1 | Complete | ✅ |

---

## v2 Improvements (New Phases)

### Phase 7: MCP Authentication ✅

**Goal:** OAuth 2.0 support for MCP servers with dynamic client registration

**Depends on:** Phase 6

**Requirements:** 
- OAuth callback server implementation
- Token storage and refresh
- Dynamic client registration
- CSRF state validation

**Success Criteria:**
1. OAuth flow completes for MCP servers requiring auth ✅
2. Tokens are stored and automatically refreshed ✅
3. CSRF protection prevents attacks ✅

**Plans:** 1 plan
- [x] 07-01-PLAN.md — OAuth authentication for MCP ✅

---

### Phase 8: Permission System ✅

**Goal:** Pattern-based permission allow/deny/ask rules for tool safety

**Depends on:** Phase 1

**Requirements:**
- Allowlist with pattern matching
- "tool:action" format support
- Wildcard patterns (* and **)
- User prompt for "ask" actions

**Success Criteria:**
1. Tools can be allowed/denied by pattern ✅
2. User is prompted for confirmation when needed ✅
3. Auto-approval works for trusted operations ✅

**Plans:** 1 plan
- [x] 08-01-PLAN.md — Permission evaluation system ✅

---

### Phase 9: Skill System

**Goal:** SKILL.md parsing and runtime skill loading

**Depends on:** Phase 1

**Requirements:**
- YAML frontmatter parsing
- Directory-based skill discovery
- Skill XML generation for prompts
- User skill override support

**Success Criteria:**
1. Skills are loaded from SKILL.md files
2. Skills appear in AI prompts
3. User skills override builtins

**Plans:** 1 plan
- [x] 09-01-PLAN.md — Skill loading system ✅

---

### Phase 10: Tool Registry ✅

**Goal:** Dynamic tool loading with feature flags and aliases

**Depends on:** Phase 6

**Requirements:**
- Tool registry with HashMap storage
- Feature-flag controlled loading
- Tool aliases for compatibility
- Concurrency safety flags

**Success Criteria:**
1. Tools load dynamically at runtime ✅
2. Feature flags enable/disable tools ✅
3. Aliases provide backward compatibility ✅

**Plans:** 1 plan
- [x] 10-01-PLAN.md — Dynamic tool registry ✅

---

### Phase 11: Agent Framework ✅

**Goal:** Enhanced agent with streaming, checkpoint, and memory

**Depends on:** Phase 1

**Requirements:**
- Streaming response handling
- File-based checkpoint system
- Conversation memory management
- Multi-agent coordination (future)

**Success Criteria:**
1. Streaming responses display in real-time ✅
2. Checkpoints save/restore agent state ✅
3. Memory persists across sessions ✅

**Plans:** 1 plan
- [x] 11-01-PLAN.md — Agent streaming and state ✅

---

### Phase 12: Config Enhancement ✅

**Goal:** Advanced config with file watching, backups, migrations

**Depends on:** Phase 1

**Requirements:**
- File watching for config changes
- Backup creation before changes
- Config migration system
- Environment variable integration

**Success Criteria:**
1. Config changes are watched and reloaded ✅
2. Backups exist before dangerous changes ✅
3. Migrations handle version upgrades ✅

**Plans:** 1 plan
- [x] 12-01-PLAN.md — Advanced configuration ✅

---

### Phase 13: TurboQuant Integration ✅

**Goal:** KV cache compression for memory-efficient AI inference with 3.8-6.4x compression ratios

**Depends on:** Phase 1 (Core Infrastructure), Phase 11 (Agent Framework)

**Requirements:**
- Quantization types and utilities
- Bit-packing and compression algorithms  
- KV cache manager with compression support
- AI client integration for compression options

**Success Criteria:**
1. Compression achieves 3.8x-6.4x ratios matching TurboQuant ✅
2. Quality preserved (cos_sim > 0.94 for turbo4, > 0.997 for quality mode) ✅
3. Inner product bias < 0.1% (unbiased estimation) ✅
4. Memory savings enable 2x larger context windows ✅
5. Integration works with existing providers ✅

**Plans:** 1 plan
- [x] 13-01-PLAN.md — KV cache compression with TurboQuant ✅

---

*Last updated: 2026-04-11 (All phases complete!)*

---

## v3 Improvements (Phase 14-16)

Sources: multica (Go managed agents platform), oh-my-openagent (TypeScript multi-agent plugin)

### Phase 14: Streaming Session Abstraction ✅

**Goal:** Unified streaming session interface across all AI providers with real-time token display

**Depends on:** Phase 1 (Core Infrastructure), Phase 11 (Agent Framework)

**Requirements:** STREAM-01, STREAM-02, STREAM-03, STREAM-04, STREAM-05

**Success Criteria:**
1. Users see real-time token-by-token output during AI responses ✅
2. All providers (OpenAI, Anthropic, Ollama, etc.) stream through a unified interface ✅
3. Provider-specific parsers handle NDJSON, SSE, and JSON-RPC formats ✅
4. Sessions can be paused, resumed, and cancelled mid-stream ✅
5. Tool calls stream with visible intermediate results ✅
6. Existing `sendChat` / `sendChatWithHistory` APIs continue to work (backward compatible) ✅

**Plans:** 1 plan
- [x] 14-01-PLAN.md — Streaming session abstraction ✅

---

### Phase 15: Token Usage Tracking ✅

**Goal:** Comprehensive token and cost tracking for AI interactions with budget alerts

**Depends on:** Phase 14 (Streaming — usage data comes from streaming responses)

**Requirements:** TOKEN-01, TOKEN-02, TOKEN-03, TOKEN-04, TOKEN-05

**Success Criteria:**
1. Every AI request records input/output/cache tokens ✅
2. Sessions accumulate total token usage across requests ✅
3. Cost estimation available per provider based on pricing tables ✅
4. `crushcode usage` command shows session-level and cumulative reports ✅
5. Budget alerts fire when approaching configurable limits ✅
6. Token data persists in session checkpoints ✅

**Plans:** 1 plan
- [x] 15-01-PLAN.md — Token usage tracking and cost estimation ✅

---

### Phase 16: Hashline Edit Validation ✅

**Goal:** Content-hash-based file edit validation preventing stale-line errors

**Depends on:** Phase 3 (AI File Operations)

**Requirements:** HASH-01, HASH-02, HASH-03, HASH-04, HASH-05

**Success Criteria:**
1. File lines can be annotated with content hashes (hashline format) ✅
2. Edit operations validate hashes before applying changes ✅
3. Conflicts detected when file was modified externally (hash mismatch) ✅
4. Existing edit/write commands gain hash validation without API change ✅
5. Hash index cached for large files to avoid rehashing ✅
6. Graceful fallback to line-number-based editing when hashes unavailable ✅

**Plans:** 1 plan
- [x] 16-01-PLAN.md — Hashline edit validation system ✅

---

### Phase 17: Model Fallback Chains ✅

**Goal:** Auto-retry with alternative models when primary provider fails

**Depends on:** Phase 1 (Core Infrastructure)

**Requirements:** FALLBACK-01, FALLBACK-02, FALLBACK-03

**Success Criteria:**
1. Configurable fallback chain of provider+model pairs ✅
2. Automatic retry with next model on failure ✅
3. Delay between retries with configurable timeout ✅

**Plans:** Implemented directly in `src/ai/fallback.zig`

---

### Phase 18: Background Parallel Agents ✅

**Goal:** Concurrent task execution with up to 5 parallel agents per provider

**Depends on:** Phase 1 (Core Infrastructure)

**Requirements:** PARALLEL-01, PARALLEL-02, PARALLEL-03

**Success Criteria:**
1. Submit multiple tasks to parallel executor ✅
2. Track task status (pending/running/completed/failed/cancelled) ✅
3. Cancel individual tasks ✅

**Plans:** Implemented directly in `src/agent/parallel.zig`

---

### Phase 19: Skill Import from Registries ✅

**Goal:** Fetch skills from remote registries (clawhub.ai, skills.sh, GitHub)

**Depends on:** Phase 9 (Skill System)

**Requirements:** IMPORT-01, IMPORT-02, IMPORT-03

**Success Criteria:**
1. Import skills from clawhub.ai, skills.sh, GitHub URLs ✅
2. Skills installed to local skills directory ✅
3. Import result feedback with success/failure status ✅

**Plans:** Implemented directly in `src/skills/import.zig`

---

### Phase 20: Git Worktree Isolation ✅

**Goal:** Per-task git worktree isolation for safe parallel execution

**Depends on:** Phase 1 (Core Infrastructure)

**Requirements:** WORKTREE-01, WORKTREE-02, WORKTREE-03

**Success Criteria:**
1. Create isolated worktree per task ✅
2. Automatic cleanup after task completion ✅
3. List and manage active worktrees ✅

**Plans:** Implemented directly in `src/agent/worktree.zig`

---

### Phase 21: Lifecycle Hooks System ✅

**Goal:** Three-tier hook system (Core/Continuation/Skill) with priority execution

**Depends on:** Phase 1 (Core Infrastructure)

**Requirements:** HOOKS-01, HOOKS-02, HOOKS-03

**Success Criteria:**
1. Register hooks at three tiers (core, continuation, skill) ✅
2. Execute hooks by phase and priority ✅
3. Enable/disable individual hooks ✅

**Plans:** Implemented directly in `src/hooks/lifecycle.zig`

---

### Phase 22: IntentGate Classifier ✅

**Goal:** Smart command routing by intent classification (research/implementation/fix/etc.)

**Depends on:** Phase 1 (Core Infrastructure)

**Requirements:** INTENT-01, INTENT-02, INTENT-03

**Success Criteria:**
1. Classify user messages into 7 intent types ✅
2. Keyword-based scoring with confidence levels ✅
3. Suggested actions per intent type ✅

**Plans:** Implemented directly in `src/cli/intent_gate.zig`

---

*Last updated: 2026-04-11 — Phase 14-22 complete (all 22 phases done!)*

---

## v5 Improvements (Phase 23-27)

Sources: OpenHarness (Python agent harness), Graphify (Python knowledge graphs), Get-Shit-Done (TypeScript phase workflow)

### Phase 23: Codebase Knowledge Graph

**Goal:** AST-based code analysis with graph building for codebase understanding (71.5x token compression)

**Depends on:** Phase 1 (Core Infrastructure)

**Reference:** Graphify — tree-sitter AST extraction, NetworkX graph building, Leiden clustering

**Requirements:**
- AST-based source file parsing (Zig, TypeScript, Python, Go support)
- Graph data structure with nodes (functions, types, imports) and edges (calls, imports, inherits)
- Confidence tags: EXTRACTED / INFERRED / AMBIGUOUS
- Community detection for architecture analysis
- Token compression via graph representation

**Success Criteria:**
1. Source files parsed into AST nodes with symbol extraction
2. Call/import/inheritance relationships captured as graph edges
3. Community clustering groups related modules
4. Graph representation provides significant token compression vs raw source

**Plans:** Implemented directly in `src/graph/`

---

### Phase 24: Agent Loop Engine

**Goal:** Streaming tool-call cycle with automatic retry, parallel execution, and exponential backoff

**Depends on:** Phase 14 (Streaming), Phase 18 (Parallel Agents)

**Reference:** OpenHarness — agent loop in query_engine.py, swarm in swarm/registry.py

**Requirements:**
- Tool call cycle: user message → AI response → tool execution → AI continues
- Streaming tool results with visible intermediate output
- Exponential backoff retry on failures
- Multi-agent swarm with team spawning
- Personal agent gateway (ohmo) for chat platform integration

**Success Criteria:**
1. AI can call tools and receive results in a continuous loop
2. Tool execution streams intermediate results
3. Failed tool calls retry with exponential backoff
4. Multiple agents can collaborate on complex tasks

**Plans:** Implemented directly in `src/agent/loop.zig`

---

### Phase 25: Phase Workflow System

**Goal:** GSD-inspired discuss→plan→execute→verify→ship development workflow

**Depends on:** Phase 1 (Core Infrastructure), Phase 24 (Agent Loop)

**Reference:** Get-Shit-Done — phase-runner.ts, plan-parser.ts, XML atomic plans, wave execution

**Requirements:**
- Phase lifecycle: discuss → plan → execute → verify → ship
- XML-based atomic plans with verification criteria
- Wave execution (parallel independent, sequential dependent)
- Fresh context windows per plan to prevent context rot
- Progress tracking and reporting

**Success Criteria:**
1. Users can create and execute phased development plans
2. Plans have verification criteria checked automatically
3. Waves execute parallel tasks concurrently
4. Progress persists across sessions

**Plans:** Implemented directly in `src/workflow/`

---

### Phase 26: Auto-Context Compaction

**Goal:** Automatic context compression for long sessions to prevent token overflow

**Depends on:** Phase 11 (Agent Memory), Phase 15 (Token Tracking)

**Reference:** OpenHarness — auto-compaction in context management

**Requirements:**
- Detect when context approaches token limit
- Summarize older conversation turns
- Preserve recent context at full fidelity
- Configurable compaction thresholds
- Compact on-the-fly without user intervention

**Success Criteria:**
1. Long sessions automatically compact when approaching limits
2. Recent messages preserved at full fidelity
3. Older messages summarized without losing key decisions
4. Compaction is transparent to the user

**Plans:** Implemented directly in `src/agent/compaction.zig`

---

### Phase 27: Project Scaffolding

**Goal:** Generate project structure from requirements through automated roadmapping

**Depends on:** Phase 25 (Phase Workflow)

**Reference:** Get-Shit-Done — project scaffolding from requirements→roadmap, RESEARCH.md, PROJECT.md

**Requirements:**
- Generate PROJECT.md from user description
- Create RESEARCH.md with technology analysis
- Build phased ROADMAP.md from requirements
- REQUIREMENTS.md generation with acceptance criteria
- Directory structure scaffolding

**Success Criteria:**
1. User provides project description → full scaffolding generated
2. ROADMAP has phases with dependencies and verification criteria
3. REQUIREMENTS have acceptance criteria and priority levels
4. Directory structure matches conventions

**Plans:** Implemented directly in `src/scaffold/`

---

*Last updated: 2026-04-11 — Phase 23-27 planned, ready for implementation*