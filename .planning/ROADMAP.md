# Crushcode Roadmap

Created: 2026-04-14 · Updated: 2026-04-27

## หลักการ
ทำให้ crushcode ใช้เป็น daily driver ได้จริง — ทดแทน opencode ได้

## Ref Sources (ทั้งหมดที่ใช้)
- `/mnt/d/crushcode-references/opencode/` — TypeScript/Node.js (OpenTUI + SolidJS)
- `/mnt/d/crushcode-references/crush/` — Go (Bubble Tea + Lipgloss)
- `/mnt/d/crushcode-references/open-claude-code/` — Node.js
- `/mnt/d/crushcode-references/claude-code/` — TypeScript (React + Ink)
- `/mnt/d/crushcode-references/cheetahclaws/` — Python

---

## v1.0.0 — Core Completion ✅ DONE

### Phase 1: File Context → AI ✅
### Phase 2: Multi-turn Tool Loop ✅
### Phase 3: Permission TUI Dialog ✅
### Phase 4: Provider Fallback ✅

---

## v1.1.0 — Readability Polish ✅ DONE

### Phase 5: Full Markdown Rendering ✅
### Phase 6: Diff View ✅
### Phase 7: Theme System ✅

---

## v1.2.0 — TUI Foundation ✅ DONE

### Phase 8: Session Persistence + Resume ✅
### Phase 9: Multi-Agent in TUI ✅
### Phase 10: Sidebar ✅

---

## v1.3.0 — TUI Polish + Advanced Features ✅ DONE

### Phase 11: LSP Deep Integration ✅
### Phase 12: Multi-Agent Threading ✅
### Phase 13: Git Advanced ✅
### Phase 14: OAuth Provider Flow ✅
### Phase 15: Token Budget Completion ✅
### Phase 16: Command Registry ✅
### Phase 17: TUI Widget Extraction ✅
### Phase 18: Animated Spinner + Stalled Detection ✅
### Phase 19: Gradient Text + Toast Notifications ✅
### Phase 20: Diff Word Highlighting + Typewriter Streaming ✅
### Phase 21: MCP → Agent Loop + Tool Unification ✅

---

## v1.4.0 — Full AI Agent (Harness + Intelligence) ✅ DONE

### Phase 22: Smart Context + Auto-Compact ✅ DONE
- Auto-compact when context >70%
- Multi-tier thresholds: micro@<85%, light@85-95%, summary@95%+
- Dynamic context limits per provider/model (15+ providers, 28 tests)
- Relevance-based file selection, token-aware system prompt

### Phase 23: Myers Diff + Edit Preview ✅ DONE
- Myers diff algorithm (596 lines)
- Edit preview with apply/reject flow
- Hash-validated edits, proper +/- coloring

### Phase 24: System Prompt Engineering + Project Config ✅ DONE
- 12+ context file formats (AGENTS.md, CLAUDE.md, .cursorrules, etc.)
- Structured XML injection
- 17 guidelines across Core/Editing/Communication/Safety
- Dynamic tool tips per language (Zig/Rust/Go/JS/Python/C++)

### Phase 25: Lifecycle Hooks + Code Quality ✅ DONE
- Lifecycle hooks fully wired (7 call sites, 3 core hooks)
- tree_sitter.zig stub removed (438 lines deleted)
- AST replaced by 3-tier (Regex + LSP + sg binary)

### Research Sprint (2026-04-27) ✅ DONE
- 41 reference repos analyzed
- CheckpointManager wired to delete_file + move_file
- /undo command in TUI
- Write-before-read guard
- Token estimation LRU cache (xxHash64)
- HTTP connection reuse (threadlocal)
- Hashline Edit (LINE#ID, ~530 lines)

### Phase 26: Context Relevance Scoring ✅ DONE
- PageRank + keyword matching + file type weighting + recency bias + community bonus
- Smart context builder via buildSmartContext()
- Header: `ctx:{d}% | {d}/{d} scored`

### Phase 27: User Model (USER.md) ✅ DONE
- Persistent preferences to ~/.crushcode/USER.md (440 lines)
- Confidence scoring, observation engine, 7 tests
- Loaded on startup, injected into system prompt, /user command

### Phase 28: Auto Skill Generation ✅ DONE
- Pattern detection across sessions (717 lines)
- AutoSkillGenerator with TaskPattern, confidence scoring

### Phase 29: Plan Mode ✅ DONE
- Structured plan format (575 lines)
- Plan steps with files affected + risk level

### Phase 30: Feedback Loop ✅ DONE
- Task outcome tracking with quality rating (737 lines)
- /feedback slash command, injected into system prompt

### Phase 31: Expand Builtin Tools to 15+ ✅ DONE
- list_directory, create_file, move_file, copy_file, undo_edit, git_status, git_diff, git_log, search_files
- 30 builtin tools total

### Phase 32: Graduated Permission System ✅ DONE
- Tool categorization (read/write/destructive)
- Auto-classification with tiers, session memory
- 11 permission module files

### Phase 33: Sub-Agent Delegation ✅ DONE
- Sub-agent spawning with scoped context (605 lines)
- Parent collects and synthesizes results

---

## v2.2.0 — Context Intelligence ✅ DONE

**วัตถุประสงค์**: Give AI project structure awareness, add auto-commit workflow, test integration

| Item | Status | Description |
|------|--------|-------------|
| Repo map | ✅ DONE | `src/context/repo_map.zig` — directory tree summary injected into system prompt |
| Auto-commit toggle | ✅ DONE | `/autocommit` slash command — git add + commit after each diff preview |
| Test runner tool | ✅ DONE | `run_tests(filter?)` — AI can run project tests and get results |
| Windows cross-compile | ✅ DONE | 8 POSIX API calls gated, clean x86_64-windows-gnu build |

---

## v2.1.0 — Diff Preview for All Edits ✅ DONE

**วัตถุประสงค์**: Every file edit gets interactive diff preview before applying

| Item | Status | Description |
|------|--------|-------------|
| Single-hunk diff preview | ✅ DONE | All edits with hunks activate interactive review |
| Streaming-complete indicator | ✅ DONE | "● Response complete" status in diff widget |

---

## ไม่ทำ (defer indefinitely)
- Voice input
- Vim mode
- Package managers (deb/rpm/brew) — install command พอ
- IDE bridge (VS Code / JetBrains)
- Real AST parsing (tree-sitter) — REPLACED: 3-tier (Regex + LSP + sg binary)

---

## v1.5.0 — Stability + Polish ✅ DONE

**วัตถุประสงค์**: Fix known bugs, clean up codebase, polish remaining edges

### Progress

| Item | Status | Description |
|------|--------|-------------|
| KP-1 KnowledgePipeline | ✅ VERIFIED STALE | Dangling pointer was vxfw.App (already fixed). Pipeline works correctly. |
| Build.zig cleanup | ✅ DONE | 1123→1037 lines (-86). Consolidated compat loop, test array, addImports. |
| /export stub | ✅ DONE | Real implementation: creates timestamped markdown file. CLI + TUI. |
| /doctor, /review, /commit | ✅ VERIFIED REAL | 512L, 168L, 411L — all fully implemented, not stubs. |
| TUI /export handler | ✅ DONE | Full message history export to markdown file in TUI mode. |

---

## v1.6.0 — Security + Cost Optimization ✅ DONE

**วัตถุประสงค์**: Wire existing 80%+ done infrastructure, close security gaps, reduce API costs

| Item | Status | Description |
|------|--------|-------------|
| Guardrail redaction | ✅ DONE | Wire redacted_content into AI request flow (PII masking) |
| Cache-aware Anthropic | ✅ DONE | Wire buildCacheAwareStreamingBody for Anthropic/Bedrock/VertexAI |
| Post-inspection masking | ✅ DONE | Mask tool output containing secrets instead of blocking |
| Context compaction w/ LLM | ✅ DONE | ContextCompactor wired into AgentLoop, compactLight on token threshold |

---

## v1.7.0 — AST-Aware Search ✅ DONE

**วัตถุประสงค์**: Add ast-grep (sg) binary spawn for structural code search

| Item | Status | Description |
|------|--------|-------------|
| sg binary spawn | ✅ DONE | tryExecuteSg() spawns `sg run -p <pattern> --json`, parses JSON matches |
| 3-tier grep cascade | ✅ DONE | sg (AST) → rg (regex) → grep (POSIX) fallback chain |
| Language auto-detect | ✅ DONE | Maps include patterns to ast-grep language names for `-l` flag |

### Backlog (remaining)
- Mixture-of-Agents reasoning (Hermes MoA)
- Sandboxed execution (gVisor/LXC)
- Vault→persistence merge (circular dep risk)

---

## v1.8.0 — TUI UX ✅ DONE

**วัตถุประสงค์**: Input history search + responsive layout

| Item | Status | Description |
|------|--------|-------------|
| Input history (Up/Down) | ✅ DONE | inputHistoryUp/Down, saves draft, 1000 entry cap |
| Ctrl+R reverse-i-search | ✅ DONE | Incremental search through history, cycle matches, (no match) display |
| Responsive sidebar | ✅ DONE | min(30, max(20, width/4)), auto-hide at <80 chars |

---

## v2.1.0 — Diff Preview for All Edits ✅ DONE

**วัตถุประสงค์**: Every file edit (single or multi hunk) shows interactive diff preview before applying

| Item | Status | Description |
|------|--------|-------------|
| Single-hunk diff preview | ✅ DONE | `streaming.zig`: `>= 2` → `>= 1` — all edits with hunks activate interactive review |
| "Review before applying" label | ✅ DONE | Single-hunk shows descriptive label instead of "Hunk 1/1" |
| Streaming-complete indicator | ✅ DONE | "● Response complete — review changes below" status in diff widget |

---

## v2.0.0 — Daily Driver Readiness ✅ DONE

**วัตถุประสงค์**: Remote skill discovery + TUI polish + cross-platform compat

| Item | Status | Description |
|------|--------|-------------|
| Remote skill discovery | ✅ DONE | `src/skills/remote.zig` — fetch index.json, download skills, cache locally |
| Skill-sync CLI | ✅ DONE | `crushcode skill-sync pull <url>` + `crushcode skill-sync cached` |
| Config skill_urls | ✅ DONE | Comma-separated list in config.toml |
| SplitView mouse-drag | ✅ DONE | Resizable sidebar + right-pane dividers |
| OverlayManager | ✅ DONE | Unified overlay type system |
| WIN-1 getenv compat | ✅ DONE | 15 files migrated to file_compat.getEnv() |
| SQ-1 SQLite tests | ✅ DONE | Separate test-sqlite build step |

---

## Post-v1.8.0 — Agent Improvements ✅ DONE

**วัตถุประสงค์**: Close gaps vs reference repos (Crush, OpenCode) in agent infrastructure

| Item | Status | Description |
|------|--------|-------------|
| SHA-256 loop detection | ✅ DONE | Ring buffer, SHA-256 sigs, window=10, maxRepeats=5, 8/8 tests |
| Desktop notifications | ✅ DONE | OS notify when agent finishes/needs permission |
| Agent mode refinement | ✅ DONE | OpenCode subagent/primary/all pattern |
| MoA wiring to TUI | ✅ DONE | moa.zig (438L) wired into agent loop |

---

## v2.3.0 — Tool Expansion ✅ DONE

**วัตถุประสงค์**: PR creation, multimodal input, semantic search, configurable keybindings

| Item | Status | Description |
|------|--------|-------------|
| PR creation tool | ✅ DONE | `create_pr` — gh pr create wrapper with title/body/base/draft |
| Configurable keybindings | ✅ DONE | `src/config/keymap.zig` — TOML keymap at ~/.crushcode/keymap.toml |
| Multimodal input | ✅ DONE | `src/tools/image_analyzer.zig` — base64 encodes PNG/JPEG/GIF/WebP/BMP |
| Semantic search | ✅ DONE | `src/search/semantic.zig` (381L) — embedding API + cosine similarity |

---

## v2.4.0 — Context Awareness ✅ DONE

**วัตถุประสงค์**: File watcher, streaming tool display, batch embeddings

| Item | Status | Description |
|------|--------|-------------|
| Context file watcher | ✅ DONE | `src/config/file_watcher.zig` — polls CLAUDE.md/AGENTS.md mtime, auto-rebuilds |
| Streaming tool display | ✅ DONE | `⏳ tool_name...` indicator before execution, cleared on completion |
| Embedding batch API | ✅ DONE | `embedBatch()` in semantic.zig — array of texts, parseBatchEmbeddings() |

---

## v3.0.0 — Forge Identity + Shell Safety ✅ DONE

**วัตถุประสงค์**: Unique brand identity (Forge naming) + critical shell safety features + reference repo gap closure

Based on gap analysis of 17 CLI core references + 36 orchestra references.

### Phase 39: Forge Naming System ✅ (3222bc5)
### Phase 40: Shell Safety ✅ (09f33b0)
### Phase 41: Context Management ✅ (d00f3dc)
### Phase 42: Alloy (Skill) System ✅ (60d2d84)

---

## v3.1.0 — Trace & Observability ✅ DONE

**วัตถุประสงค์**: Make every agent run inspectable, debuggable, and comparable. Build on existing trace/ modules (span.zig, writer.zig, context.zig) to add HTML trace reports, run comparison, failure diagnosis, and a `crushcode trace` CLI command.

Based on CheetahClaws Layer 5 (Observability, Trace, and Replay) roadmap analysis.

### Phase 43: Trace HTML Export + Run Comparison ✅ (d93c03a)

**Plans:** 4 plans in 3 waves — ALL COMPLETE

Plans:
- [x] 43-01-PLAN.md — Trace reader: JSONL parser, trace enumeration, span filtering, failure classification
- [x] 43-02-PLAN.md — Export format generators: self-contained HTML, JSON, Markdown
- [x] 43-03-PLAN.md — Run comparison engine: metric deltas, verdicts, tool usage diff
- [x] 43-04-PLAN.md — CLI wiring: `crushcode trace` command, registry, build.zig

**Delivered:** reader.zig (724L), html_report.zig (264L), json_export.zig (80L), markdown_export.zig (93L), comparison.zig (647L), trace_cmd.zig (327L) + `lens` Forge alias

---

## v3.2.0 — Agent Core Live ✅ DONE

**วัตถุประสงค์**: Make crushcode a REAL coding agent — AI uses tools in a multi-turn loop during interactive chat.

**Critical discovery**: After deep investigation, the entire agent core was already built:
- `AgentLoop` (1,187L) — full tool-call cycle with retry, compaction, loop detection, modes
- `chat_bridge.zig` (198L) — AISendFn adapter bridging AIClient ↔ AgentLoop
- `tool_executors.zig` (2,760L) — 34 built-in tool executors with 3-tier permission
- `session.zig` — SQLite session persistence with restore
- `chat.zig` line 2108 — already calls `agent_loop.run(chat_bridge.sendInteractiveLoopMessages, user_message)`
- 24+ slash commands (/mode, /model, /compact, /cost, /memory, etc.)

**The only gap found**: Edit diff preview — `previewEditDiff()` existed but wasn't wired into `executeEditTool`.

### Phase 44: Agent Loop Audit + Diff Preview ✅ (a6f9c99)

**Delivered:**
- Diff preview wired into `edit` tool — shows Myers unified diff before applying changes
- Diff preview wired into `write_file` tool — shows diff for existing file overwrites

**Bug fixes during testing (bcceedb):**
- `appendEscapedJsonString` didn't escape control characters (0x00-0x1F) — streaming was BROKEN for all providers
- Added error response body logging in `sendChatStreaming` for debugging

**Test results (end-to-end):**
- ✅ Single-shot chat: works (non-streaming + streaming)
- ✅ Streaming: fixed — was broken due to unescaped control chars
- ✅ List providers/models: works (23 providers, model listing)
- ⚠️ Tool calls in single-shot mode: model returns tool calls but they're shown as raw text, not executed
- ✅ Interactive agent loop: uses AgentLoop.run() with full tool execution

---

## v3.3.0 — Agent UX Hardening ✅ DONE

**วัตถุประสงค์**: Fix real gaps found during end-to-end testing. Make the agent loop production-ready.

**Based on actual testing, not assumptions.**

### Phase 45: Single-Shot Tool Execution ✅ (d5ddb51)

**Gap**: `crushcode chat "read src/main.zig"` — model returns tool_calls but shown as raw text.
**Fix**: Detect tool_calls in single-shot response → execute via AgentLoop → send results back → return final answer.

### Phase 46: Streaming Error Recovery ✅ (e37f3b3)

**Gap**: Streaming failures show raw error names and stack traces.
**Fix**: Boxed, human-readable error messages mapped from error types. No stack traces on user-facing errors.

### Phase 47: Provider Streaming Fallback ✅ (e37f3b3)

**Gap**: No fallback when streaming fails with transient errors.
**Fix**: Auto-retry with non-streaming on ServerError/NetworkError/TimeoutError. Yellow warning during fallback.

---

## v3.4.0 — Agent Safety Rails 🔥 CURRENT

**วัตถุประสงค์**: Wire existing safety infrastructure into the agent loop. Infrastructure exists (BudgetManager, ContextCompactor, tool_timeout_ms) but none of it is connected. This is integration work.

**Based on code audit of loop.zig (1187L), budget.zig (213L), tracker.zig, main.zig SIGINT handler.**

### Phase 48: Tool Timeout Enforcement

**Gap**: `tool_timeout_ms` exists in LoopConfig (default 30000ms) but `executeTool()` never checks it. Tools can run forever.
**Fix**: Add elapsed time check in executeTool retry loop. Return error if tool exceeds timeout.

### Phase 49: Graceful Agent Abort (Ctrl+C)

**Gap**: SIGINT handler in main.zig calls `exit(130)` — no cleanup. AgentLoop has `running` flag but no `abort()` method, and SIGINT doesn't set it.
**Fix**: Add `abort()` method. Wire SIGINT to set `running=false` via atomic flag. Agent loop checks flag each iteration and exits cleanly.

### Phase 50: Budget Integration

**Gap**: BudgetManager exists (213L) with `checkBeforeRequest()`, `recordCost()`, `isOverBudget()` — none called from AgentLoop. No cost tracking per agent session.
**Fix**: Check budget before each iteration. Record cost after each AI response. Show warning at 80%. Hard stop at 100%.

### Phase 51: Context Compaction Default

**Gap**: ContextCompactor exists but must be explicitly enabled via `enableCompaction()`. Not called by default. Agent can exceed context window.
**Fix**: Auto-enable compactor in AgentLoop.init() with sensible defaults. Trigger compaction at 70% context usage.

---

## v3.5.0 — Daily Driver Polish 🔥 CURRENT

**วัตถุประสงค์**: Close the last quality-of-life gaps between crushcode and a production daily-driver AI coding CLI. The codebase is mature (103K lines, 39 TODOs, 22 providers, 34 tools, 46 slash commands). Remaining work is polish, not architecture.

**Based on**: Full codebase audit of TUI (5312L), interactive mode (2600L), agent loop (1200L), CLI commands, config, and reference repo gap analysis.

### Phase 52: Budget Wiring — Chat.zig → AgentLoop

**Gap**: BudgetManager field added to AgentLoop in Phase 50, but chat.zig never sets it. The /cost budget command parses the amount but doesn't actually create or wire a BudgetManager. Interactive sessions have no spending guard.
**Fix**: In handleInteractiveChat, create BudgetManager from config (or /cost budget amount), assign to agent_loop.budget_manager before each agent run. Wire config.toml budget fields.

### Phase 53: Streaming Tool Progress — Interactive Mode

**Gap**: In interactive mode, when the agent executes tools, there's no real-time progress. User sees nothing until the entire tool call + AI follow-up completes. Single-shot mode shows "⏳ tool_name..." but interactive doesn't.
**Fix**: Add streaming tool progress to the interactive agent loop path — show "⏳ tool_name..." indicator during tool execution, cleared when complete. Match the single-shot UX.

### Phase 54: /model Switch — Live Provider+Model Swap

**Gap**: /model shows current model but doesn't support switching mid-session. Users must exit and restart to change provider/model. Reference CLIs (OpenCode, Claude Code) all support mid-session switching.
**Fix**: /model <provider>/<model> switches the AI client's provider and model without restarting the session. Re-initialize AIClient with new provider/model, keep message history.

### Phase 55: Prompt Pipeline — Context Files Auto-Load

**Gap**: System prompt injection works for single-shot mode (CLAUDE.md, AGENTS.md loaded), but interactive mode doesn't reload when context files change during a session. If a user edits CLAUDE.md mid-session, the old prompt stays.
**Fix**: Check context file mtimes before each AI request (file_watcher.zig already exists). If changed, rebuild system prompt. Show "↻ Context updated" notification.

---

## Ref Sources (reorganized 2026-04-28)

### CLI Core (`/mnt/d/crushcode-cli-reference/`) — 17 repos
- opencode, crush, open-claude-code, claude-code, cheetahclaws, codex, codex-rust, goose-latest, hermes-agent, oh-my-openagent, kimi-cli, deepagents, get-shit-done, ripgrep, libvaxis-latest, libvaxis-0.5.1, claude-token-efficient

### Orchestra/Enhancement (`/mnt/d/crush-code-orchestra-work-ref/`) — 36 repos
- OpenHands, Open-Claude-Cowork, kuse_cowork, openwork, eigent, goose, AionUi, multica, thClaws, BMAD-METHOD, design.md, superpowers, COG-second-brain, Firstbrain, obsidian-second-brain, karpathy-second-brain, agent-skills-standard, skills-main, caveman, cavekit, claude-code-templates, claude-code-best-practice, awesome-design-md, future-agi, magika, graphify, OpenHarness, and more
