# Reference Project Research — Crushcode Improvements

> Synthesized from 18 reference projects across 6 parallel research streams.
> Date: 2026-04-16

## Executive Summary

Research across opencode, crush, claude-code, goose, codex-rust, kimi-cli, deepagents, oh-my-openagent, get-shit-done, cavekit, caveman, cheetahclaws, graphify, multica, turboquant, and ripgrep revealed **75+ unique features/patterns**. Below are the TOP prioritized improvements for crushcode, grouped by category.

---

## Tier 1 — Critical Missing Features (Immediate Impact)

### 1. Shell State Persistence + Background Jobs
**Source**: crush — `internal/shell/shell.go`, `internal/shell/background.go`
- Persistent `cwd` and `env` across commands in a session
- `BackgroundShellManager` — auto-moves long-running commands (>60s) to background
- `job_output` / `job_kill` tools for managing background processes
- Max 50 concurrent jobs, 8hr auto-cleanup
- **Why**: Multi-step coding workflows need stateful shells. Dev servers/watch modes must run non-blocking.

### 2. Command Security: Blocklist + Safe Commands Whitelist
**Source**: crush — `internal/shell/shell.go`, `internal/agent/tools/safe.go`
- Two-tier blocking: `CommandsBlocker` (exact match: curl, sudo, rm) + `ArgumentsBlocker` (subcommand+flag combos)
- Safe read-only commands whitelist (git log, ls, ps, etc.) skip permission prompts
- **Why**: Prevents destructive AI actions while removing friction for safe operations.

### 3. Permission Service with Session-Scoped Grants
**Source**: crush — `internal/permission/permission.go`, claude-code — `docs/subsystems.md`
- Tool-level allowlists in config
- Session-scoped persistent grants (remember approval for same tool+path+action)
- Per-session auto-approve, `--yolo` mode for trusted environments
- Permission modes: default, plan (read-only), auto, bypass
- **Why**: Fine-grained control without re-prompting for repeated safe operations.

### 4. Non-Interactive Mode with Stdin Piping
**Source**: crush — `internal/cmd/run.go`, `internal/cmd/root.go`
- Piped stdin: `curl url | crushcode run "summarize"`
- Output redirection: `crushcode run "generate" > file.md`
- Session continuation: `--session ID`, `--continue`
- Model override: `--model provider/model`
- **Why**: Essential for CLI scripting, CI/CD integration, and Unix composability.

### 5. Tab-Switchable Agent Modes (build/plan)
**Source**: opencode — README
- `build` agent: full-access for development
- `plan` agent: read-only, denies file edits, asks before bash
- `@general` subagent for complex searches
- Switch with Tab key
- **Why**: Lets users safely explore codebases without risk of accidental changes.

---

## Tier 2 — High-Value Features (Next Sprint)

### 6. Hierarchical Config with Priority Chain
**Source**: crush — `internal/config/load.go`
- 4 sources with increasing priority: project `.crush.json`, user `~/.config/`, runtime state
- Env var resolution in config values (`$OPENAI_API_KEY`)
- Shell variable expansion in MCP headers
- Auto-detection of terminal capabilities
- **Why**: Project-specific overrides + user defaults + runtime state.

### 7. Context Window Management + Compaction
**Source**: claude-code — `docs/architecture.md`, open-claude-code — README
- `/compact` command to compress conversation history
- Bounded context window while preserving essential memory
- Auto-summarization of old turns
- **Why**: Keeps long sessions performant; prevents context overflow on large codebases.

### 8. Token Counting + Cost Tracking
**Source**: claude-code — `docs/architecture.md`, crush — session tracking
- Per-turn token usage estimation
- Session cost accumulation
- `/cost` reporting command
- Budget alerts
- **Why**: Users need visibility into spending, especially with paid providers.

### 9. Skill System (SKILL.md Standard)
**Source**: crush — `internal/skills/skills.go`
- Agent Skills open standard (agentskills.io)
- SKILL.md files with YAML frontmatter + markdown body
- Discovery from global/project paths
- Deduplication (user skills override builtins)
- XML prompt injection
- **Why**: Shareable, composable agent capabilities. Compatible with Claude Code's format.

### 10. Custom Commands from Markdown
**Source**: crush — `internal/commands/commands.go`
- Commands loaded from `.crush/commands/` (project) and `~/.config/crush/commands/` (user)
- Named arguments via `$UPPER_CASE` regex extraction
- Namespaced with `user:` and `project:` prefixes
- **Why**: Reusable prompt templates without modifying the tool itself.

### 11. Memory System + CLAUDE.md Compatibility
**Source**: claude-code — `docs/subsystems.md`, best-practice — `CLAUDE.md`
- Hierarchical memory loading (project > user > global)
- Auto memory extraction from conversations
- CLAUDE.md-style governance rules
- **Why**: Persistent context and domain knowledge across sessions.

### 12. Session Management with Hash IDs
**Source**: crush — `internal/session/session.go`
- UUID-backed with XXH3 hash short IDs for user reference
- Session listing, continuation by ID or hash prefix
- "Continue last session" (`--continue`)
- Usage tracking per session (tokens, cost)
- **Why**: Multiple contexts per project; seamless resume.

---

## Tier 3 — Architecture Improvements (Medium-Term)

### 13. Client/Server Architecture
**Source**: opencode — README
- TUI is just one client; server runs the AI logic
- Enables remote driving from mobile/web
- Clean separation of concerns
- **Why**: Future-proofs for multi-client scenarios (IDE plugin, web UI, mobile).

### 14. MCP Server Exposition
**Source**: claude-code — `mcp-server/README.md`
- Expose crushcode's capabilities as MCP server
- Multiple transports: STDIO, HTTP, SSE
- Health checks and tool/resource listing
- **Why**: Other tools can use crushcode as a tool server.

### 15. Centralized Tool Registry with Schemas
**Source**: claude-code — `docs/tools.md`, goose — tool registry
- Per-tool input schema validation
- Permission hooks per tool
- UI rendering hooks
- Dynamic tool loading
- **Why**: Scalable, safe tool ecosystem.

### 16. Git Worktree Isolation
**Source**: claude-code — best-practice, subsystems
- Isolated worktrees per agent/session
- Parallel experiments without cross-talk
- `/diff` and `/commit` workflows
- **Why**: Safe parallel development; clean diff views.

### 17. Output Truncation with Smart Formatting
**Source**: crush — `internal/agent/tools/bash.go`
- Outputs >30K chars truncated by splitting at midpoint
- `... [N lines truncated] ...` notice
- Exit code and interruption status included
- `<cwd>` tags for directory tracking
- **Why**: Prevents token waste from enormous outputs.

### 18. File Tracker for Context Awareness
**Source**: crush — `internal/filetracker/service.go`
- Records every file read per session with timestamps
- Prevents re-reading files the agent already knows
- **Why**: Saves tokens; improves response quality.

### 19. Grep with Ripgrep Fallback + Regex Caching
**Source**: crush — `internal/agent/tools/grep.go`
- Try `rg` first for speed, fallback to stdlib regex
- Thread-safe compiled regex cache
- `.gitignore` + `.crushignore` support
- File type filtering, result truncation
- **Why**: Fast code search is critical for AI coding assistants.

### 20. Log CLI with Tail + Follow
**Source**: crush — `internal/cmd/logs.go`
- `crushcode logs --tail N` and `--follow` flags
- Structured JSON log parsing with colored output
- **Why**: Essential debugging capability.

---

## Tier 4 — Advanced Patterns (Future)

### 21. Knowledge Graph Overlay for Codebases
**Source**: graphify — README
- Graph-based module relationship mapping
- "God nodes" and community detection for architecture understanding
- `GRAPH_REPORT.md` one-page overview
- Graph queries: path, explain, navigate
- **Why**: Structured code understanding beyond grep/search.

### 22. Spec-First Pipeline with Review Gates
**Source**: cavekit — README
- Phase-based workflow: Research → Draft → Architect → Build → Inspect
- Adversarial review gates between phases
- Explicit requirements before implementation
- **Why**: Increases traceability; reduces drift between intent and implementation.

### 23. Hashline (Content-Hash) Edits
**Source**: oh-my-openagent — AGENTS.md
- Surgical edits tagged with content hashes
- Prevents stale edits on changed files
- Verifiable, reproducible modifications
- **Why**: Safety layer for AI-driven code edits.

### 24. Wave-Based Execution with Atomic Commits
**Source**: get-shit-done — ARCHITECTURE.md
- Plans execute in parallel waves
- Each completed task → atomic commit
- Fresh-context per agent (isolated 200K token windows)
- **Why**: Robust traceability; prevents partial-state failures.

### 25. IntentGate Classifier
**Source**: oh-my-openagent — README
- Routes actions by true user intent, not literal command strings
- Reduces misinterpretation and wrong-tooling
- **Why**: Better UX; fewer "the AI did the wrong thing" incidents.

### 26. Nyquist Validation Mapping
**Source**: get-shit-done — USER-GUIDE.md
- Formalized mapping of requirements to automated tests
- Verification BEFORE execution begins
- **Why**: Ensures test coverage aligns with goals from the start.

### 27. LSP + AST-Grep Integration
**Source**: oh-my-openagent — README
- Language Server Protocol for precise code intelligence
- AST-aware search and rewrite patterns
- **Why**: Enables precise refactors, go-to-definition, find-references.

### 28. Sandboxed File System Access
**Source**: codex-rust — `exec-server/src/fs_sandbox.rs`
- Linux/Windows sandboxing with policy transforms
- Per-turn permission approvals
- Sandbox policy composition (normalize/merge/intersect)
- **Why**: Strong isolation for potentially untrusted AI-generated commands.

### 29. Token-Efficient Prompt Modes
**Source**: caveman — README
- Lite/Full/Ultra intensity modes
- Memory/prompt compression
- "Caveman-speak" rewriting for lean prompts
- **Why**: Reduces token usage and cost, especially for long sessions.

### 30. Multi-Provider Agent Daemon
**Source**: multica — README
- Agent lifecycle management across multiple backends
- Runtime discovery of providers
- Daemon mode for persistent agent availability
- **Why**: Running agents across different providers seamlessly.

---

## Tier 5 — UI/UX Design Patterns

### TUI Layout & Interaction

### 31. Modal Overlay Stack with Backdrop Dimming
**Source**: opencode — `packages/opencode/src/cli/cmd/tui/ui/dialog.tsx`
- Stacked dialog system — push/pop modals while preserving context underneath
- Translucent backdrop dims background when dialog is open
- Centered rendering within viewport
- **Why**: Multi-layer confirmation flows (e.g., "discard changes?" → "really?") without losing context.

### 32. Keyboard-Driven Dialog Navigation
**Source**: opencode — `dialog.tsx`, crush — `internal/ui/dialog/quit.go`
- Arrow keys, Tab, Enter, Escape for all dialog navigation
- Two-option button group with visual selection indicator
- ShortHelp/FullHelp exposure showing available keybindings
- **Why**: Terminal users expect keyboard-first interaction; mouse dependency is a UX failure.

### 33. Dynamic Verb-Driven Spinner
**Source**: claude-code — `src/components/Spinner.tsx`, `src/components/design-system/LoadingState.tsx`
- Spinner verb updates in real-time based on task state (thinking, working, searching...)
- Verbs sourced from task state + random verb pools
- Minimum display time (2s) to prevent jank/flashing
- Override colors for theme adaptation
- **Why**: "..." tells users nothing. "Searching codebase..." tells them the app is alive and doing what.

### 34. Hierarchical Multi-Task Spinner Tree
**Source**: claude-code — `Spinner.tsx`
- TeammateSpinnerTree renders concurrent tasks with individual spinners
- Leader vs teammate dynamics — adapts display based on role
- Brief vs full spinner variants for different UI density modes
- **Why**: When multiple agents run in parallel, users need to see what each is doing.

### 35. Progressive Message Rendering
**Source**: goose — `ui/desktop/src/components/ProgressiveMessageList.tsx`, `LoadingGoose.tsx`
- Large chat histories rendered in batches to avoid UI blocking
- Internationalized loading messages with batch counts
- Inline system notifications embedded in the message flow
- State-based loading indicators per chat state (idle, thinking, streaming, error)
- **Why**: Loading 1000 messages at once freezes the terminal. Batching keeps it responsive.

### 36. Tool Header with Status Icons + Inline Parameters
**Source**: kimi-cli — `web/src/components/ai-elements/tool.tsx`
- Backend tool states → visual status icons (loading spinner, ✓ check, ✗ error)
- Primary parameter displayed inline with clickable URL
- Friendly display-name mapping with icons per tool
- Collapsible tool panels for hierarchy
- Truncation logic for long parameter values with expand option
- **Why**: Tool calls should be scannable at a glance — icon + param = instant recognition.

### 37. Accessible Progress Bar
**Source**: kimi-cli — `web/src/components/ui/progress.tsx`
- Radix-based progress bar with accessible structure
- Consistent theming across the app
- **Why**: Standardized progress indication for file operations, downloads, etc.

### 38. Theming via Global Context
**Source**: opencode — `dialog.tsx`, `toast.tsx`; crush — `ui.go`
- Colors, borders, panel backgrounds derived from theme context
- Bold headings and semantic text styling via theme tokens
- Lipgloss-based styling with consistent color tokens (crush)
- **Why**: Light/dark/custom themes without touching every component.

### 39. Global Toast/Notification System with Auto-Dismiss
**Source**: opencode — `packages/opencode/src/cli/cmd/tui/ui/toast.tsx`
- Centralized toast system with duration selector and optional title
- Error states rendered distinctly
- Conditional rendering for transient UI elements
- **Why**: Non-blocking feedback that doesn't interrupt workflow.

### 40. Focus Management + Autofocus in Prompts
**Source**: opencode — `dialog-prompt.tsx`
- Text inputs/areas auto-focus when prompts appear
- Dynamic traits (suspend, status) to reflect busy/editing states
- **Why**: Users shouldn't have to click/tab to start typing in a newly opened input.

### 41. Responsive Terminal Layout with Compact Mode
**Source**: crush — `internal/ui/model/ui.go`
- Header, main, editor, sidebar regions
- Compact mode for smaller terminals
- WindowSizeMsg-based responsive resize
- **Why**: TUI must work on 80-column terminals AND wide screens.

### 42. External Link Component
**Source**: opencode — `link.tsx`
- Clickable text that opens URL in system browser
- **Why**: Reference links in AI responses should be openable without copy-paste.

---

## Recommended Implementation Order

| Phase | Features | Impact |
|-------|----------|--------|
| **v0.8** | Shell state (1), Command security (2), Permission service (3), Non-interactive mode (4) | Core safety + CI/CD |
| **v0.9** | Agent modes (5), Config hierarchy (6), Context compaction (7), Cost tracking (8) | UX + reliability |
| **v0.10** | Skills (9), Custom commands (10), Memory (11), Session management (12) | Extensibility |
| **v0.11** | Client/server (13), MCP server (14), Tool registry (15), Git integration (16) | Architecture |
| **v0.12** | Knowledge graph (21), Hashline edits (23), Wave execution (24), LSP (27) | Advanced |

---

## Source Files Reference

| Project | Key Files |
|---------|-----------|
| opencode | `README.md`, `packages/opencode/AGENTS.md`, `packages/opencode/src/` |
| crush | `internal/shell/shell.go`, `internal/shell/background.go`, `internal/permission/permission.go`, `internal/commands/commands.go`, `internal/skills/skills.go`, `internal/session/session.go`, `internal/config/load.go`, `internal/filetracker/service.go`, `internal/agent/tools/safe.go`, `internal/agent/tools/grep.go`, `internal/cmd/run.go` |
| claude-code | `docs/architecture.md`, `docs/tools.md`, `docs/subsystems.md`, `mcp-server/README.md` |
| claude-code-best-practice | `CLAUDE.md`, `best-practice/claude-settings.md`, `orchestration-workflow/` |
| open-claude-code | `README.md`, `archive/open_claude_code/docs/architecture/overview.md` |
| goose | `AGENTS.md`, `crates/goose/src/agents/subagent_handler.rs`, `crates/goose/src/routes/agent.rs` |
| codex-rust | `README.md`, `codex-rs/exec-server/src/fs_sandbox.rs`, `codex-rs/core/tests/suite/` |
| kimi-cli | `README.md`, `AGENTS.md`, `src/kimi_cli/soul/agent.py`, `src/kimi_cli/soul/kimisoul.py` |
| deepagents | `README.md`, `AGENTS.md`, `src/` structure |
| oh-my-openagent | `README.md`, `AGENTS.md`, `src/tools/`, `src/agents/` |
| get-shit-done | `README.md`, `docs/ARCHITECTURE.md`, `docs/USER-GUIDE.md`, `AGENTS.md` |
| cavekit | `README.md` |
| caveman | `README.md`, `hooks/README.md`, `caveman-compress/README.md` |
| cheetahclaws | `README.md` |
| graphify | `README.md`, `worked/*/README.md` |
| multica | `README.md` |
| turboquant | `README.md` |
| ripgrep | `README.md` |

---

## Tier 6 — Second Brain & Knowledge Intelligence (from 10 new repos)

> Researched 2026-04-17 from: COG-second-brain, Firstbrain, karpathy-second-brain, obsidian-second-brain, obsidian-ai-second-brain, claude-token-efficient, agent-skills-standard, regenrek-agent-skills, DeepTutor, skills-main

### 43. Worker Agent Pattern (File-Based Communication)
**Source**: COG-second-brain — `.claude/agents/worker-*.md`
- 6 specialized worker agents (researcher, data-collector, file-ops, executor, publisher, brief-updater)
- Workers write results to `/tmp/{task-slug}.md`, return only status + path
- Eliminates slow token generation from worker output
- Enables parallel execution — orchestrator spawns 5-7 workers simultaneously
- **Why**: Multi-agent orchestration without token explosion. Workers do heavy lifting, main agent synthesizes.

### 44. Multi-Model Routing
**Source**: COG-second-brain — `CLAUDE.md`
- Smart model assignment: Sonnet for data-heavy tasks, Opus for reasoning/synthesis
- Task-type → model mapping table
- Cost optimization through intelligent routing
- **Why**: Use cheaper/faster models for data collection, premium models only for complex reasoning.

### 45. Progressive Knowledge Enrichment (People CRM Pattern)
**Source**: COG-second-brain — `05-knowledge/people/`
- Tiered enrichment: Stub (1 mention) → Moderate (3+) → Full (8+)
- Citation-based knowledge: every claim includes source + confidence
- Compiled Truth + Timeline pattern: current understanding + append-only history
- **Why**: Progressive codebase understanding — don't over-analyze on first encounter, deepen over time.

### 46. PageRank + Advanced Graph Algorithms
**Source**: Firstbrain — `.agents/skills/graph/graph-engine.cjs`
- PageRank for importance ranking (damping 0.85, 30 iterations)
- Multi-hop connection discovery (2-3 hops with structural similarity)
- Bridge detection for critical connecting nodes
- Jaccard similarity for structural equivalence
- Topic clustering via tag co-occurrence
- **Why**: Native Zig graph algorithms would make crushcode's knowledge graph truly powerful — identify important files, find hidden connections, detect architectural hubs.

### 47. Three-Zone Governance System (AUTO/PROPOSE/NEVER)
**Source**: Firstbrain — `.claude/rules/governance.md`
- AUTO: Safe actions execute immediately (fix links, update memory)
- PROPOSE: User-approval required (new folders, config changes)
- NEVER: Hard boundaries (delete files, merge notes)
- **Why**: Safe autonomous operation — some operations are always safe, some need approval, some are forbidden.

### 48. Layered Memory Architecture (4 Layers)
**Source**: Firstbrain — `.claude/memory/`
- Session memory: current conversation context
- Working memory: project-specific state
- Insights memory: long-term pattern recognition with confidence scoring (0.3-1.0)
- Project memory: per-project context tracking
- Auto-distillation triggers (10+ changes or 3+ related notes)
- **Why**: Different memory lifetimes for different types of knowledge. Session state is ephemeral, insights are permanent.

### 49. Wiki Schema Pattern (Ingest/Query/Lint)
**Source**: karpathy-second-brain — `skills/second-brain*/`
- Immutable raw sources, LLM-maintained wiki
- Three operations: Ingest (process source → wiki pages), Query (search + synthesize), Lint (health-check)
- Structured wiki: sources/, entities/, concepts/, synthesis/, index.md, log.md
- YAML frontmatter with tags, sources, created, updated
- Wikilink-only internal references
- **Why**: Clean knowledge lifecycle. Raw data stays raw, processed knowledge evolves.

### 50. Lint/Health System for Knowledge Quality
**Source**: karpathy-second-brain — `skills/second-brain-lint/SKILL.md`
- Broken wikilink detection
- Orphan page identification
- Contradiction detection between pages
- Stale claim identification
- Missing cross-references
- Index consistency validation
- **Why**: Knowledge bases decay without maintenance. Automated quality checks prevent rot.

### 51. Adversarial Thinking Tools
**Source**: obsidian-second-brain — `README.md`
- `/challenge`: Vault argues against your ideas using your own history
- `/emerge`: Surfaces hidden patterns across time
- `/connect`: Bridges unrelated domains
- `/graduate`: Turns ideas into projects
- Bi-temporal facts: tracks when facts were true AND when learned
- **Why**: Prevents confirmation bias. Makes the coding assistant challenge assumptions.

### 52. Background Agent Pattern (PostCompact Hooks)
**Source**: obsidian-second-brain — `hooks/obsidian-bg-agent.sh`
- Background agent runs after context compaction
- Silently propagates changes to vault
- 4 scheduled agents: morning (daily notes), nightly (consolidation), weekly (review), health (maintenance)
- **Why**: Autonomous maintenance without user intervention. Background agents keep knowledge fresh.

### 53. Context Optimization Rules
**Source**: claude-token-efficient — `CLAUDE.md`
- 63% average token reduction through specific anti-patterns
- Remove sycophantic chatter, redundant explanations, restatements
- Prefer direct answers over verbose prose
- Profile system: coding, agents, analysis, benchmark modes
- Hierarchical composition: Global → Project → Subdirectory rules
- **Why**: Direct token savings on every request. Integrates with existing context budget system.

### 54. Hierarchical Skill Resolution (AGENTS.md → INDEX → SKILL.md)
**Source**: agent-skills-standard — `ARCHITECTURE.md`
- Three-layer lookup: AGENTS.md → _INDEX.md → SKILL.md
- Dual trigger system: File Match (auto, e.g., `*.tsx`) + Keyword Match (explicit)
- 237 skills across 20+ frameworks, each ~500 tokens
- Cross-platform: works with Cursor, Claude, Copilot, Gemini, Windsurf
- **Why**: Scalable skill discovery. Don't load everything — load what's relevant.

### 55. Two-Layer Plugin Model (Tools + Capabilities)
**Source**: DeepTutor — `deeptutor/core/tool_protocol.py`, `capability_protocol.py`
- Level 1 (Tools): Single-function components (rag, web_search, code_execution)
- Level 2 (Capabilities): Multi-step agent pipelines (chat, deep_solve, deep_research)
- UnifiedContext dataclass flows through all operations
- StreamBus for real-time output with stage/content/result/error
- **Why**: Clean separation between atomic tools and complex workflows. Enables composition.

### 56. Multi-Phase Skill Execution Pattern
**Source**: COG-second-brain — `.claude/skills/team-brief/SKILL.md`, obsidian-ai-second-brain — `.github/skills/`
- Phase 1: Setup & Context (sequential, fast)
- Phase 2: Parallel Data Collection (spawn multiple workers)
- Phase 3: Cross-Reference Synthesis (intelligent combination)
- Phase 4: Delivery & Save (present results, persist)
- Scan → Enrich → Create → Report workflow
- **Why**: Predictable execution pattern for complex multi-step operations.

### 57. Skill Synchronization & Distribution
**Source**: regenrek-agent-skills — `sync-skills.sh`
- Git-based rsync synchronization to Claude/Codex skills directories
- Simple file-based skill storage and loading
- Git hooks and file watchers for automatic syncing
- 19 practical workflow-oriented skills
- **Why**: Skills need to be distributed and synced across environments.

---

## v0.14.0 — Recommended Implementation Order

| Phase | Features | Source |
|-------|----------|--------|
| **47** | Graph algorithms (PageRank, clustering, bridge detection, structural similarity) | Firstbrain |
| **48** | Knowledge operations (ingest/query/lint wiki schema) | karpathy-second-brain |
| **49** | Worker agent pattern + multi-model routing | COG-second-brain |
| **50** | Context optimization rules + governance zones | claude-token-efficient + Firstbrain |
| **51** | Hierarchical skill resolution + adversarial tools | agent-skills-standard + obsidian-second-brain |

---

## New Source Files Reference

| Project | Key Files |
|---------|-----------|
| COG-second-brain | `README.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/agents/worker-*.md`, `.claude/skills/team-brief/SKILL.md`, `.claude/skills/auto-research/SKILL.md` |
| Firstbrain | `Cheatsheet.md`, `.agents/skills/graph/graph-engine.cjs`, `.claude/rules/governance.md`, `.claude/memory/insights.md` |
| karpathy-second-brain | `docs/llm-wiki.md`, `skills/second-brain/references/wiki-schema.md`, `skills/second-brain-ingest/SKILL.md`, `skills/second-brain-query/SKILL.md`, `skills/second-brain-lint/SKILL.md` |
| obsidian-second-brain | `README.md`, `hooks/obsidian-bg-agent.sh`, `scripts/bootstrap_vault.py`, `references/claude-md-template.md` |
| obsidian-ai-second-brain | `README.md`, `.github/skills/vault-knowledge-retrieval/SKILL.md`, `.github/skills/vault-note-creation/SKILL.md`, `.github/skills/vault-note-update/SKILL.md` |
| claude-token-efficient | `CLAUDE.md`, `profiles/` |
| agent-skills-standard | `ARCHITECTURE.md`, `skills/typescript/typescript-language/SKILL.md`, `skills/common/common-context-optimization/SKILL.md` |
| regenrek-agent-skills | `skills/security-leak-guardrails/SKILL.md`, `sync-skills.sh` |
| DeepTutor | `SKILL.md`, `deeptutor/core/tool_protocol.py`, `deeptutor/core/capability_protocol.py`, `deeptutor/runtime/orchestrator.py`, `deeptutor/core/context.py` |
| skills-main | `spec/agent-skills-spec.md`, `template/SKILL.md`, `skills/mcp-builder/SKILL.md`, `skills/docx/SKILL.md` |

---

## Tier 7 — Template Marketplace, TUI Capabilities, Agent Infrastructure (final 3 repos)

> Researched 2026-04-17 from: claude-code-templates, libvaxis, OpenHarness

### 58. Component Marketplace with Template System
**Source**: claude-code-templates — `cli-tool/components/`
- 600+ agents, 200+ commands, 55+ MCPs, 60+ settings, 39+ hooks
- YAML frontmatter metadata for all components (name, description, tools, model)
- Progressive disclosure: metadata always loaded, instructions on trigger, references on demand
- Model selection strategy: Opus for planning/architecture, Sonnet for development, Haiku for operations
- CLI installer with interactive browsing, batch installation
- Component reviewer agent for validation (no hardcoded secrets, format compliance)
- **Why**: Pattern for building a composable template/skill marketplace. Progressive disclosure saves tokens.

### 59. Advanced TUI Widget Catalog (libvaxis)
**Source**: libvaxis-0.5.1 — `src/widgets/`
- **CodeView**: Code display with syntax highlighting, line numbers, indentation guides
- **Table**: Complex tables with selection, dynamic column sizing, per-cell styling
- **ScrollView**: Scrollable containers with scrollbars
- **TextInput**: Full Unicode text input with Emacs keybindings
- **TextView**: Rich text display with styling
- **Terminal**: Full virtual terminal emulation widget (PTY integration)
- **Image**: Kitty graphics protocol with scaling, clipping, z-index layering
- **Hyperlinks**: Clickable links in terminal cells
- **Clipboard**: System clipboard integration (OSC 52)
- **Mouse**: Full mouse handling with shapes, 11 buttons, modifiers, drag
- **Double-buffered rendering**: Efficient screen diffing, only updates changed cells
- **GraphemeCache**: Performance-optimized grapheme width caching
- **Why**: Crushcode already uses libvaxis but likely not all features. CodeView, Table, Terminal widgets are untapped potential.

### 60. Agent Harness Pattern (43+ Tools)
**Source**: OpenHarness — `src/openharness/`
- 10 subsystems: Engine, Tools, Skills, Plugins, Permissions, Hooks, Commands, MCP, Memory, Coordinator
- Agent Loop: query → stream → tool-call → loop with retry/backoff
- BaseTool abstract class with self-describing JSON Schema generation
- `is_read_only()` flag on tools for permission decisions
- Hook system: PreToolUse/PostToolUse lifecycle events
- Plugin system compatible with claude-code plugins (.claude-plugin/plugin.json)
- Multi-agent coordination: AgentDefinition with effort levels, memory scopes, permission modes
- TeamRegistry for managing agent teams, background task lifecycle
- SendMessageTool for inter-agent communication
- 54 CLI commands (/help, /commit, /plan, /resume)
- **Why**: Production blueprint for agent infrastructure. Validates crushcode's existing patterns and shows gaps (hooks, plugin compat, multi-agent coordination).

### 61. Permission System with Sensitive Path Protection
**Source**: OpenHarness — `src/openharness/permissions/checker.py`
- Three modes: DEFAULT (ask), AUTO (allow), PLAN (block writes)
- Built-in sensitive path protection (SSH keys, AWS/GCP credentials, .env files)
- Path-based rules with glob patterns
- Command deny patterns (e.g., "rm -rf /")
- Tool-specific allow/deny lists
- PermissionDecision with reason and confirmation requirements
- **Why**: More granular than crushcode's current permission system. Sensitive path protection is a missing safety layer.

---

## Complete Source Files Reference (All 31 Repos)

| # | Project | Key Files |
|---|---------|-----------|
| 1 | opencode | `README.md`, `packages/opencode/AGENTS.md`, `packages/opencode/src/` |
| 2 | crush | `internal/shell/shell.go`, `internal/shell/background.go`, `internal/permission/permission.go`, `internal/commands/commands.go`, `internal/skills/skills.go`, `internal/session/session.go`, `internal/config/load.go`, `internal/filetracker/service.go`, `internal/agent/tools/safe.go`, `internal/agent/tools/grep.go`, `internal/cmd/run.go` |
| 3 | claude-code | `docs/architecture.md`, `docs/tools.md`, `docs/subsystems.md`, `mcp-server/README.md` |
| 4 | claude-code-best-practice | `CLAUDE.md`, `best-practice/claude-settings.md`, `orchestration-workflow/` |
| 5 | open-claude-code | `README.md`, `archive/open_claude_code/docs/architecture/overview.md` |
| 6 | goose | `AGENTS.md`, `crates/goose/src/agents/subagent_handler.rs`, `crates/goose/src/routes/agent.rs` |
| 7 | codex-rust | `README.md`, `codex-rs/exec-server/src/fs_sandbox.rs`, `codex-rs/core/tests/suite/` |
| 8 | kimi-cli | `README.md`, `AGENTS.md`, `src/kimi_cli/soul/agent.py`, `src/kimi_cli/soul/kimisoul.py` |
| 9 | deepagents | `README.md`, `AGENTS.md`, `src/` structure |
| 10 | oh-my-openagent | `README.md`, `AGENTS.md`, `src/tools/`, `src/agents/` |
| 11 | get-shit-done | `README.md`, `docs/ARCHITECTURE.md`, `docs/USER-GUIDE.md`, `AGENTS.md` |
| 12 | cavekit | `README.md` |
| 13 | caveman | `README.md`, `hooks/README.md`, `caveman-compress/README.md` |
| 14 | cheetahclaws | `README.md` |
| 15 | graphify | `README.md`, `worked/*/README.md` |
| 16 | multica | `README.md` |
| 17 | turboquant | `README.md` |
| 18 | ripgrep | `README.md` |
| 19 | COG-second-brain | `README.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/agents/worker-*.md`, `.claude/skills/team-brief/SKILL.md`, `.claude/skills/auto-research/SKILL.md` |
| 20 | Firstbrain | `Cheatsheet.md`, `.agents/skills/graph/graph-engine.cjs`, `.claude/rules/governance.md`, `.claude/memory/insights.md` |
| 21 | karpathy-second-brain | `docs/llm-wiki.md`, `skills/second-brain/references/wiki-schema.md`, `skills/second-brain-ingest/SKILL.md`, `skills/second-brain-query/SKILL.md`, `skills/second-brain-lint/SKILL.md` |
| 22 | obsidian-second-brain | `README.md`, `hooks/obsidian-bg-agent.sh`, `scripts/bootstrap_vault.py`, `references/claude-md-template.md` |
| 23 | obsidian-ai-second-brain | `README.md`, `.github/skills/vault-knowledge-retrieval/SKILL.md`, `.github/skills/vault-note-creation/SKILL.md`, `.github/skills/vault-note-update/SKILL.md` |
| 24 | claude-token-efficient | `CLAUDE.md`, `profiles/` |
| 25 | agent-skills-standard | `ARCHITECTURE.md`, `skills/typescript/typescript-language/SKILL.md`, `skills/common/common-context-optimization/SKILL.md` |
| 26 | regenrek-agent-skills | `skills/security-leak-guardrails/SKILL.md`, `sync-skills.sh` |
| 27 | DeepTutor | `SKILL.md`, `deeptutor/core/tool_protocol.py`, `deeptutor/core/capability_protocol.py`, `deeptutor/runtime/orchestrator.py`, `deeptutor/core/context.py` |
| 28 | skills-main | `spec/agent-skills-spec.md`, `template/SKILL.md`, `skills/mcp-builder/SKILL.md`, `skills/docx/SKILL.md` |
| 29 | claude-code-templates | `cli-tool/components/`, `.claude/agents/`, `.claude/commands/`, `dashboard/` |
| 30 | libvaxis-0.5.1 | `src/Vaxis.zig`, `src/Cell.zig`, `src/Window.zig`, `src/Screen.zig`, `src/widgets/TextInput.zig`, `src/widgets/CodeView.zig`, `src/widgets/Table.zig`, `src/widgets/Terminal.zig`, `src/Image.zig` |
| 31 | OpenHarness | `src/openharness/engine/query_engine.py`, `src/openharness/tools/base.py`, `src/openharness/permissions/checker.py`, `src/openharness/hooks/executor.py`, `src/openharness/coordinator/agent_definitions.py` |
