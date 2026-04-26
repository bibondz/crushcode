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

## ไม่ทำ (defer indefinitely)
- Voice input
- Vim mode
- Package managers (deb/rpm/brew) — install command พอ
- IDE bridge (VS Code / JetBrains)
- Real AST parsing (tree-sitter) — REPLACED: 3-tier (Regex + LSP + sg binary)

---

## v1.5.0 — Stability + Polish (IN PROGRESS)

**วัตถุประสงค์**: Fix known bugs, clean up codebase, polish remaining edges

### Progress

| Item | Status | Description |
|------|--------|-------------|
| KP-1 KnowledgePipeline | ✅ VERIFIED STALE | Dangling pointer was vxfw.App (already fixed). Pipeline works correctly. |
| Build.zig cleanup | ✅ DONE | 1123→1037 lines (-86). Consolidated compat loop, test array, addImports. |
| /export stub | ✅ DONE (CLI) | Real implementation: creates timestamped markdown file. TUI handler pending. |
| /doctor, /review, /commit | ✅ VERIFIED REAL | 512L, 168L, 411L — all fully implemented, not stubs. |
| TUI /export handler | ✅ DONE | Full message history export to markdown file in TUI mode. |

### Backlog (researched but deferred)
- Streaming diff preview (diffpane, tuicr)
- Mixture-of-Agents reasoning (Hermes MoA)
- Skill hub integration
- Sandboxed execution (gVisor/LXC)
- Multi-platform gateway (Telegram/Discord/Slack)
- sg binary spawn for AST-aware search
- Vault→persistence merge (circular dep risk)
