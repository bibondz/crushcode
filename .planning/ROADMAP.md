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
