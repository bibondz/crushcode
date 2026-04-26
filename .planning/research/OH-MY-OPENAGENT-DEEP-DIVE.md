# OhMyOpenAgent Deep Dive Research

**Date**: 2026-04-27
**Source**: `/mnt/d/crushcode-references/oh-my-openagent/`
**Repo**: https://github.com/code-yeongyu/oh-my-openagent
**Commit**: 2892ca4a (branch: dev)
**Scale**: 1766 TypeScript files, 377k LOC, 104 barrel index.ts files

## What Is It

OpenCode **plugin** (npm: `oh-my-opencode`, dual-published as `oh-my-openagent`). NOT a fork — it's a plugin that extends OpenCode with 11 agents, 52 hooks, 26 tools, 3-tier MCP, hashline edit, and Claude Code compatibility.

**Installation**: Add `"oh-my-openagent"` to `opencode.json` plugin array. Done.

## Architecture

### 5-Step Initialization
```
pluginModule.server(input, options)
  1. loadPluginConfig()         — JSONC parse → project/user merge → Zod validate
  2. createManagers()           — TmuxSessionManager, BackgroundManager, SkillMcpManager
  3. createTools()              — SkillContext + AvailableCategories + ToolRegistry (26 tools)
  4. createHooks()              — 3-tier: Core(43) + Continuation(7) + Skill(2) = 52 hooks
  5. createPluginInterface()    — 10 OpenCode hook handlers
```

### 10 OpenCode Hook Handlers
| Handler | Purpose |
|---------|---------|
| `config` | 6-phase: provider → plugin-components → agents → tools → MCPs → commands |
| `tool` | 26 registered tools |
| `chat.message` | First-message variant, session setup, keyword detection |
| `chat.params` | Anthropic effort level, think mode, runtime fallback |
| `chat.headers` | Copilot header injection |
| `event` | Session lifecycle, openclaw dispatch |
| `tool.execute.before` | Pre-tool hooks (file guard, truncator, rules injector) |
| `tool.execute.after` | Post-tool hooks (output truncation, comment checker) |
| `experimental.chat.messages.transform` | Context injection, thinking validation |
| `experimental.session.compacting` | Context + todo preservation |

---

## AST-Grep Source (THE ANSWER)

**ast_grep_search and ast_grep_replace come from OhMyOpenAgent, NOT OpenCode core.**

### Implementation: `src/tools/ast-grep/` (17 files)

**Architecture**: Spawns `sg` CLI binary as subprocess. NOT using `@ast-grep/napi` directly.

**Binary Resolution Chain**:
1. Cached binary (`~/.cache/oh-my-opencode/bin/sg`)
2. `@ast-grep/cli` npm package binary
3. Platform-specific `@ast-grep/cli-{platform}` package
4. Homebrew (`/opt/homebrew/bin/sg`, `/usr/local/bin/sg`)
5. Auto-download from GitHub releases (ast-grep/ast-grep)

**Key Files**:
| File | Lines | Purpose |
|------|-------|---------|
| `tools.ts` | 117 | Tool definitions: ast_grep_search, ast_grep_replace |
| `cli.ts` | 177 | `runSg()` — spawns sg binary with --json=compact, timeout 5min |
| `downloader.ts` | 119 | Auto-download sg binary for current platform |
| `sg-cli-path.ts` | 102 | Binary resolution: cache → npm → platform pkg → homebrew |
| `language-support.ts` | 63 | 25 CLI languages, 5 NAPI languages, extensions map |
| `environment-check.ts` | 89 | Doctor check: is sg binary + @ast-grep/napi available? |
| `types.ts` | 61 | SgResult, CliMatch, SearchMatch, MetaVariable |
| `result-formatter.ts` | — | Format search/replace results |
| `pattern-hints.ts` | — | Helpful hints when pattern returns empty |
| `sg-compact-json-output.ts` | — | Parse --json=compact output |
| `process-output-timeout.ts` | — | Timeout wrapper for spawn |
| `cli-binary-path-resolution.ts` | — | Background init + availability check |

**Tool Schemas**:
- `ast_grep_search`: pattern, lang (25 options), paths?, globs?, context?
- `ast_grep_replace`: pattern, rewrite, lang, paths?, globs?, dryRun? (default: true)

**Smart Behaviors**:
- `--json=compact` + `--update-all` conflict: runs 2 separate passes (collect matches, then write)
- Empty result hints: "Remove trailing colon" for Python, "Include params and body" for JS
- 5-minute timeout with truncation support
- Max 500 matches, max 1MB output

**25 Supported Languages**:
bash, c, cpp, csharp, css, elixir, go, haskell, html, java, javascript, json, kotlin, lua, nix, php, python, ruby, rust, scala, solidity, swift, typescript, tsx, yaml

---

## 26 Tools (Full Catalog)

### Task Management (4)
- `task_create` — subject, description, blockedBy, blocks, metadata, parentID
- `task_list` — list all tasks
- `task_get` — get task by id
- `task_update` — update task fields

### Delegation (1)
- `task` — THE delegation tool. category, prompt, run_in_background, session_id, load_skills

### Agent Invocation (1)
- `call_omo_agent` — direct agent call

### Background Tasks (2)
- `background_output` — collect background task results
- `background_cancel` — cancel running tasks

### LSP Refactoring (6)
- `lsp_goto_definition`, `lsp_find_references`, `lsp_symbols`
- `lsp_diagnostics`, `lsp_prepare_rename`, `lsp_rename`

### Code Search (4)
- `ast_grep_search`, `ast_grep_replace` — AST-aware
- `grep` — ripgrep content search (60s timeout, 10MB limit)
- `glob` — file pattern matching (60s timeout, 100 file limit)

### Session History (4)
- `session_list`, `session_read`, `session_search`, `session_info`

### Skill/Command (2)
- `skill` — load skill by name
- `skill_mcp` — invoke MCP from skill

### System (2)
- `interactive_bash` — tmux command execution
- `look_at` — PDF/image analysis

### Editing (1)
- `hashline_edit` — hash-anchored LINE#ID editing

---

## Hashline Edit (29 files — THE innovation)

**Problem**: Standard edit tools fail because they rely on the model reproducing exact line content. Whitespace, encoding, or concurrent changes → corruption.

**Solution**: Every Read output tagged with `LINE#ID` content hashes:
```
11#VK| function hello() {
22#XJ|   return "world";
33#MB| }
```

**How it works**:
- `computeLineHash(lineNumber, content)` → xxHash32 → 2-char CID from `ZPMQVRWSNKTXJBYH`
- Edit references line by `{lineNumber}#{hash}` — if file changed, hash won't match → rejected
- 3 operations: `replace`, `append`, `prepend`
- Pipeline: normalize → validate → order (bottom-up) → deduplicate → apply → autocorrect → diff

**Pipeline files**:
| Step | File |
|------|------|
| Normalize | `normalize-edits.ts` |
| Validate | `validation.ts` |
| Order | `edit-ordering.ts` (bottom-up to preserve line numbers) |
| Deduplicate | `edit-deduplication.ts` |
| Apply | `edit-operations.ts` → `edit-operation-primitives.ts` |
| Autocorrect | `autocorrect-replacement-lines.ts` (indent restoration) |
| Diff | `hashline-edit-diff.ts` → `diff-utils.ts` |

**Hash computation** (`hash-computation.ts`):
```typescript
function computeLineHash(lineNumber: number, content: string): string {
  const stripped = content.replace(/\r/g, "").trimEnd()
  const seed = /[\p{L}\p{N}]/u.test(stripped) ? 0 : lineNumber
  const hash = Bun.hash.xxHash32(stripped, seed)
  return HASHLINE_DICT[hash % 256]  // 2-char from "ZPMQVRWSNKTXJBYH"
}
```

**Key insight**: If line has no alphanumeric chars (blank/whitespace), uses lineNumber as seed → deterministic for empty lines.

---

## 11 Agents

| Agent | Model | Temp | Mode | Purpose |
|-------|-------|------|------|---------|
| **Sisyphus** | claude-opus-4-7 max | 0.1 | all | Main orchestrator |
| **Hephaestus** | gpt-5.5 medium | 0.1 | all | Autonomous deep worker |
| **Oracle** | gpt-5.5 high | 0.1 | subagent | Read-only consultation |
| **Librarian** | gpt-5.4-mini-fast | 0.1 | subagent | External docs/code search |
| **Explore** | gpt-5.4-mini-fast | 0.1 | subagent | Contextual codebase grep |
| **Multimodal-Looker** | gpt-5.3-codex medium | 0.1 | subagent | PDF/image analysis |
| **Metis** | claude-opus-4-7 max | 0.3 | subagent | Pre-planning consultant |
| **Momus** | gpt-5.5 xhigh | 0.1 | subagent | Plan reviewer |
| **Atlas** | claude-sonnet-4-6 | 0.1 | primary | Todo-list orchestrator |
| **Prometheus** | claude-opus-4-7 max | 0.1 | internal | Strategic planner |
| **Sisyphus-Junior** | claude-sonnet-4-6 | 0.1 | all | Category-spawned executor |

### 8 Delegation Categories
| Category | Model | Domain |
|----------|-------|--------|
| visual-engineering | gemini-3.1-pro high | Frontend, UI/UX |
| ultrabrain | gpt-5.5 xhigh | Hard logic |
| deep | gpt-5.5 medium | Autonomous problem-solving |
| artistry | gemini-3.1-pro high | Creative approaches |
| quick | gpt-5.4-mini | Trivial tasks |
| unspecified-low | claude-sonnet-4-6 | Moderate effort |
| unspecified-high | claude-opus-4-7 max | High effort |
| writing | gemini-3-flash | Documentation |

### Tool Restrictions per Agent
- **Oracle/Librarian/Explore**: No write, edit, task, call_omo_agent
- **Multimodal-Looker**: ALL tools denied except read
- **Atlas**: No task, call_omo_agent
- **Momus**: No write, edit, task

---

## 52 Hooks (Full Catalog)

### Tier 1: Session Hooks (24)
| Hook | Event | Purpose |
|------|-------|---------|
| contextWindowMonitor | session.idle | Track context window usage |
| preemptiveCompaction | session.idle | Trigger compaction before limit |
| sessionRecovery | session.error | Auto-retry on recoverable errors |
| sessionNotification | session.idle | OS notifications on completion |
| thinkMode | chat.params | Dynamic thinking budget |
| anthropicContextWindowLimitRecovery | session.error | Multi-strategy context recovery |
| autoUpdateChecker | session.created | Check npm for plugin updates |
| agentUsageReminder | chat.message | Remind about available agents |
| nonInteractiveEnv | chat.message | Adjust for non-TTY |
| interactiveBashSession | tool.execute | Tmux session for interactive tools |
| ralphLoop | event | Self-referential dev loop |
| editErrorRecovery | tool.execute.after | Retry failed file edits |
| delegateTaskRetry | tool.execute.after | Retry failed task delegations |
| startWork | chat.message | `/start-work` command |
| prometheusMdOnly | tool.execute.before | Enforce .md-only writes for Prometheus |
| sisyphusJuniorNotepad | chat.message | Notepad injection for subagents |
| questionLabelTruncator | tool.execute.before | Truncate long question labels |
| taskResumeInfo | chat.message | Inject task context on resume |
| anthropicEffort | chat.params | Adjust reasoning effort |
| modelFallback | chat.params | Provider-level fallback |
| noSisyphusGpt | chat.message | Block Sisyphus from GPT |
| noHephaestusNonGpt | chat.message | Block Hephaestus from non-GPT |
| runtimeFallback | event | Auto-switch on API errors |
| legacyPluginToast | chat.message | Legacy name migration |

### Tier 2: Tool Guard Hooks (14)
| Hook | Event | Purpose |
|------|-------|---------|
| commentChecker | tool.execute.after | Block AI-generated comment patterns |
| toolOutputTruncator | tool.execute.after | Truncate oversized output |
| directoryAgentsInjector | tool.execute.before | Inject dir AGENTS.md |
| directoryReadmeInjector | tool.execute.before | Inject dir README.md |
| emptyTaskResponseDetector | tool.execute.after | Detect empty task responses |
| rulesInjector | tool.execute.before | Conditional rules from AGENTS.md |
| tasksTodowriteDisabler | tool.execute.before | Disable TodoWrite when task active |
| writeExistingFileGuard | tool.execute.before | Require Read before Write |
| bashFileReadGuard | tool.execute.before | Guard bash file reads |
| readImageResizer | tool.execute.after | Resize large images |
| todoDescriptionOverride | tool.execute.before | Override todo descriptions |
| webfetchRedirectGuard | tool.execute.before | Guard webfetch redirects |
| hashlineReadEnhancer | tool.execute.after | Add LINE#ID hashes to Read output |
| jsonErrorRecovery | tool.execute.after | JSON parse error correction |

### Tier 3: Transform Hooks (5)
| Hook | Event | Purpose |
|------|-------|---------|
| claudeCodeHooks | messages.transform | Claude Code settings.json compat |
| keywordDetector | messages.transform | Detect ultrawork/search/analyze modes |
| contextInjectorMessagesTransform | messages.transform | Inject AGENTS.md/README.md |
| thinkingBlockValidator | messages.transform | Validate thinking blocks |
| toolPairValidator | messages.transform | Validate tool call/result pairs |

### Tier 4: Continuation Hooks (7)
| Hook | Event | Purpose |
|------|-------|---------|
| stopContinuationGuard | chat.message | `/stop-continuation` handler |
| compactionContextInjector | session.compacted | Re-inject context after compaction |
| compactionTodoPreserver | session.compacted | Preserve todos through compaction |
| todoContinuationEnforcer | session.idle | **Boulder**: force continuation on incomplete todos |
| unstableAgentBabysitter | session.idle | Monitor unstable agent behavior |
| backgroundNotificationHook | event | Background task completion |
| atlasHook | event | Master orchestrator for boulder sessions |

### Tier 5: Skill Hooks (2)
| Hook | Event | Purpose |
|------|-------|---------|
| categorySkillReminder | chat.message | Remind about category+skill |
| autoSlashCommand | chat.message | Auto-detect /command in input |

### Most Complex Hooks (LOC)
1. **anthropic-context-window-limit-recovery**: 31 files, ~2232 LOC — Multi-strategy recovery
2. **todo-continuation-enforcer**: 13 files, ~2061 LOC — Boulder mechanism
3. **atlas**: 17 files, ~1976 LOC — Master orchestrator
4. **ralph-loop**: 14 files, ~1687 LOC — Self-referential dev loop
5. **keyword-detector**: ~1665 LOC — Mode detection
6. **rules-injector**: 19 files, ~1604 LOC — Conditional rules

---

## 19 Feature Modules

| Module | Files | Complexity | Purpose |
|--------|-------|------------|---------|
| **background-agent** | 47 | HIGH | Task lifecycle, concurrency (5/model), polling, circuit breaker |
| **opencode-skill-loader** | 33 | HIGH | YAML frontmatter skill loading from 4 scopes |
| **tmux-subagent** | 34 | HIGH | Tmux pane management, grid planning |
| **mcp-oauth** | 18 | HIGH | OAuth 2.0 + PKCE + DCR for MCP servers |
| **skill-mcp-manager** | 18 | HIGH | Tier-3 MCP client lifecycle per session |
| **claude-code-plugin-loader** | 15 | MEDIUM | Plugin discovery from .opencode/plugins/ |
| **builtin-skills** | 17 | LOW | 8 skills: git-master, playwright, frontend-ui-ux, etc. |
| **builtin-commands** | 11 | LOW | Command templates: refactor, init-deep, handoff |
| **claude-tasks** | 7 | MEDIUM | Task schema + file storage + OpenCode todo sync |
| **claude-code-mcp-loader** | 6 | MEDIUM | .mcp.json loading with ${VAR} env expansion |
| **context-injector** | 6 | MEDIUM | AGENTS.md/README.md injection |
| **boulder-state** | 5 | LOW | Persistent state for multi-step operations |
| **run-continuation-state** | 5 | LOW | Persistent state for run command |
| **hook-message-injector** | 5 | MEDIUM | System message injection for hooks |
| **task-toast-manager** | 4 | MEDIUM | Task progress notifications |
| **tool-metadata-store** | 3 | LOW | Tool execution metadata cache |

### Background Agent System (47 files, ~10k LOC)
- States: pending → running → completed/error/cancelled/interrupt
- Concurrency: per-model/provider limits via ConcurrencyManager (FIFO queue)
- Polling: 3s interval, completion via idle events + stability detection (10s unchanged)
- Circuit breaker: automatic failure detection and recovery
- 8 spawner files composing via SpawnerContext interface

### Skill Loader (33 files, ~3.2k LOC)
4-scope skill discovery: project > opencode > user > global
- YAML frontmatter parsing from SKILL.md files
- Skill merger with priority deduplication
- Template resolution with variable substitution
- Provider gating for model-specific skills

### Tmux Subagent (34 files, ~3.6k LOC)
- TmuxSessionManager: pane lifecycle, grid planning
- Spawn action decider + target finder
- Polling manager for session health
- Event handlers for pane creation/destruction

---

## 3-Tier MCP System

| Tier | Source | Mechanism |
|------|--------|-----------|
| 1. Built-in | `src/mcp/` | 3 remote HTTP: websearch (Exa), context7, grep_app |
| 2. Claude Code | `.mcp.json` | ${VAR} env expansion via claude-code-mcp-loader |
| 3. Skill-embedded | SKILL.md YAML | Managed by SkillMcpManager (stdio + HTTP) |

### Built-in MCPs
| Name | URL | Auth |
|------|-----|------|
| websearch | mcp.exa.ai (default) or mcp.tavily.com | EXA_API_KEY (optional) |
| context7 | mcp.context7.com/mcp | CONTEXT7_API_KEY (optional) |
| grep_app | mcp.grep.app | None |

---

## 8 Built-in Skills

| Skill | Size | MCP | Tools |
|-------|------|-----|-------|
| git-master | 1111 LOC | — | Bash |
| playwright | 312 LOC | @playwright/mcp | — |
| agent-browser | (in playwright.ts) | — | Bash(agent-browser:*) |
| playwright-cli | 268 LOC | — | Bash(playwright-cli:*) |
| dev-browser | 221 LOC | — | Bash |
| frontend-ui-ux | 79 LOC | — | — |
| review-work | — | — | — |
| ai-slop-remover | — | — | — |

---

## Conventions

- Runtime: Bun only (1.3.11 in CI)
- TypeScript: strict, ESNext, bundler moduleResolution, bun-types
- Test: Bun test, co-located *.test.ts, given/when/then style
- Factory pattern: createXXX() for all tools, hooks, agents
- File naming: kebab-case
- No path aliases: relative imports only
- JSONC config with Zod v4 validation
- Logger: /tmp/oh-my-opencode.log
- Build: externals include @ast-grep/napi

---

## What Crushcode Can Learn

### Immediately Actionable (Zig-possible)
1. **Hashline Edit** — content hash per line (xxHash32 → 2-char CID). Validates edits before applying. 29-file implementation is reference-quality.
2. **Tool Output Truncation** — limit output by token count, not bytes
3. **Write-Before-Read Guard** — require Read before Write on existing files
4. **Comment Checker** — block AI-generated comment patterns
5. **Edit Error Recovery** — retry failed file edits automatically
6. **Bottom-up Edit Ordering** — sort edits by line number descending to preserve positions
7. **Directory Context Injection** — auto-inject AGENTS.md/README.md from current directory
8. **Preemptive Compaction** — trigger compaction before hitting context limit

### Requires Architecture Work
9. **Background Agent System** — task lifecycle, concurrency per model, circuit breaker
10. **52-hook lifecycle system** — plugin-compatible event system
11. **Category-based delegation** — map task category → optimal model
12. **3-tier MCP** — built-in + .mcp.json + skill-embedded
13. **Skill loader** — YAML frontmatter from SKILL.md, 4-scope discovery
14. **Todo Continuation Enforcer** — "Boulder" mechanism forcing completion

### Blocked by Zig Constraints
15. **AST-grep** — requires spawning `sg` CLI binary (possible but needs binary distribution)
16. **Tmux integration** — requires tmux installed on host
17. **Skill-embedded MCP** — requires MCP client per session
