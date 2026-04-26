# Crushcode Roadmap — v0.3.x → v0.4.0

Created: 2026-04-14

## หลักการ
ทำให้ crushcode ใช้เป็น daily driver ได้จริง — ทดแทน opencode ได้

## Ref Sources (ทั้งหมดที่ใช้)
- `/mnt/d/crushcode-references/opencode/` — TypeScript/Node.js (OpenTUI + SolidJS)
- `/mnt/d/crushcode-references/crush/` — Go (Bubble Tea + Lipgloss)
- `/mnt/d/crushcode-references/open-claude-code/` — Node.js
- `/mnt/d/crushcode-references/claude-code/` — TypeScript (React + Ink)
- `/mnt/d/crushcode-references/cheetahclaws/` — Python

---

## v0.3.1 — Core Completion (ใช้งานได้จริง)

### Phase 1: File Context → AI
**ปัญหา**: TUI ส่งแค่ conversation history ให้ AI ไม่ส่ง codebase context
**ทำ**: 
- ย้าย knowledge graph context builder จาก chat.zig เข้า TUI
- ส่ง source files เป็น system prompt เหมือนที่ chat.zig ทำ (lines 588-650)
- Auto-detect project structure (src/ files, build.zig)
- แสดงใน header: `ctx: 14 files indexed`
- ไฟล์: แก้ chat_tui_app.zig — เพิ่ม context builder ตอน init

### Phase 2: Multi-turn Tool Loop
**ปัญหา**: AI ตอบแค่ทีเดียว ไม่วน tool call loop
**ทำ**:
- หลัง AI ตอบ: check ว่ามี tool_calls ไหม
- ถ้ามี: execute tools → ส่งผลกลับเป็น tool result message → เรียก AI อีกที
- วนจนกว่า AI จะตอบโดยไม่เรียก tool (หรือครบ max iterations = 10)
- แสดง tool execution progress ใน TUI
- ไฟล์: แก้ chat_tui_app.zig streaming worker — เพิ่ม tool loop

### Phase 3: Permission TUI Dialog
**ปัญหา**: AI เรียก shell command โดยไม่ถาม user
**ทำ**:
- ก่อน execute tool: popup dialog "Allow Bash: rm -rf / ? [y/n/a(lways)]"
- 3 modes: default (ask), auto (allow all), plan (ask only destructive)
- แสดง tool name + arguments ใน dialog
- จำคำตอบตาม session
- ไฟล์: แก้ chat_tui_app.zig — เพิ่ม PermissionDialog widget

### Phase 4: Provider Fallback
**ปัญหา**: provider ล่ม = จบ ไม่ลองตัวอื่น
**ทำ**:
- ต่อจาก fallback.zig ที่มีอยู่แล้ว
- ถ้า primary provider ล้มเหลว: ลองตัวถัดไปที่มี API key
- แสดงใน status bar: `⚠ openrouter timeout → trying groq`
- Auto-retry ด้วย backoff

---

## v0.3.2 — Readability Polish

### Phase 5: Full Markdown Rendering
**ปัญหา**: Markdown parser ยัง basic — ไม่รองรับ table, blockquote, nested list
**ทำ**:
- Tables: `| col1 | col2 |` → aligned columns with box-drawing chars
- Blockquotes: `> text` → dimmed prefix
- Nested lists: indentation
- Horizontal rules: `---` → full-width line
- Links: `[text](url)` → underlined text
- Task lists: `- [x] done` / `- [ ] todo` → checkbox icons ☑ ☐

### Phase 6: Diff View
**ปัญหา**: ไม่มี diff display เลย
**ทำ**:
- Unified diff: `-` red lines, `+` green lines, context dimmed
- แสดงเมื่อ AI เรียก edit/write_file tool
- Line numbers ด้านซ้าย
- Truncate ถ้า diff ยาวเกิน 30 lines + "show more"
- ไฟล์: สร้าง `src/tui/diff.zig` — diff parser + renderer

### Phase 7: Theme System
**ปัญหา**: มี theme เดียว
**ทำ**:
- Theme struct: user_fg, assistant_fg, error_fg, header_bg, code_bg, border, dimmed
- 3 built-in themes: default (dark), light, monochrome
- `/theme` command in palette — switch live
- Save preference to config.toml
- ไฟล์: สร้าง `src/tui/theme.zig`

---

## v0.4.0 — Advanced Features

### Phase 8: Session Persistence + Resume
**ทำ**:
- Auto-save conversation to `~/.crushcode/sessions/`
- `/resume` command — list sessions, pick one to continue
- Session file: JSON with messages + metadata (tokens, duration, model)
- Crash recovery: detect interrupted session, offer resume

### Phase 9: Multi-Agent in TUI
**ทำ**:
- Spawn sub-agents in background threads
- Show agent status in TUI: `● Agent 1: analyzing src/ai/... ✓`
- Results merge back into main conversation
- `/agents` palette command — spawn with category

### Phase 10: Sidebar (stretch)
**ทำ**:
- Toggle sidebar with Ctrl+B
- Show: recent files, LSP diagnostics (if available), session info
- Minimal — just file list + error count
- ไม่จำเป็นสำหรับ v0.4.0 ถ้าเวลาไม่พอ

---

## ลำดับการทำ
```
v0.3.1 Phase 1 → Phase 2 → Phase 3 → Phase 4
         (context)  (tool loop)  (permission)  (fallback)

v0.3.2 Phase 5 → Phase 6 → Phase 7
         (markdown)  (diff)  (theme)

v0.4.0 Phase 8 → Phase 9 → Phase 10
         (session)  (agents)  (sidebar)
```

---

## v0.5.0 — Full Parity

### Phase 11: LSP Deep Integration
**Goal:** LSP diagnostics integrated into TUI sidebar with auto-detection
**ปัญหา**: LSP client มีแต่ CLI ไม่ได้เชื่อม TUI
**ทำ**:
- Initialize LSP client ใน chat_tui_app.zig เมื่อเปิดไฟล์
- openDocument() เมื่อ edit
- Poll getDiagnostics() → แสดงใน sidebar (error count + file list)
- Real-time diagnostics update
- Auto-detect LSP server จาก file extension (zls, rust-analyzer, gopls, etc.)
- ไฟล์: แก้ chat_tui_app.zig + SidebarWidget — เพิ่ม LSP diagnostics section

**Plans:** 1 plan
Plans:
- [ ] 11-01-PLAN.md — LSPManager module + TUI sidebar diagnostics integration

### Phase 12: Multi-Agent Threading
**Goal:** Replace polling/sleep-based ParallelExecutor with real std.Thread.spawn() worker threads for concurrent multi-agent execution
**Plans:** 1 plan
Plans:
- [ ] 12-01-PLAN.md — Threading infrastructure (CompletionQueue, workerThreadMain, ParallelExecutor rewrite, TUI lifecycle integration)

### Phase 13: Git Advanced
**ปัญหา**: git commands ยัง basic (status, diff, add, commit, push, pull, branch, log)
**ทำ**:
- git blame — แสดง per-line author
- git stash — stash/pop/list
- git rebase — interactive rebase support
- git merge — merge branches
- git bisect — binary search for bugs
- git remote — add/remove/list remotes
- git log -S — search commit history
- ไฟล์: แก้ src/commands/git.zig — เพิ่ม commands

### Phase 14: OAuth Provider Flow
**Goal:** Generalize OAuth from MCP to AI providers, enabling browser-based login with automatic token refresh
**Plans:** 1 plan
Plans:
- [ ] 14-01-PLAN.md — ProviderOAuth module + auth CLI command (login/status/logout)

### Phase 15: Token Budget Completion
**ปัญหา**: Budget tracking มีแต่ยังไม่มี time-based reset + TUI display
**ทำ**:
- Daily/monthly reset logic (timestamp-based)
- Budget display ใน TUI status bar
- /budget command — show current usage vs limits
- Alert when approaching limit
- ไฟล์: แก้ src/usage/budget.zig + chat_tui_app.zig

---

## ลำดับการทำ
```
v0.3.1 Phase 1 → Phase 2 → Phase 3 → Phase 4       ✅ DONE
         (context)  (tool loop)  (permission)  (fallback)

v0.3.2 Phase 5 → Phase 6 → Phase 7                  ✅ DONE
         (markdown)  (diff)  (theme)

v0.4.0 Phase 8 → Phase 9 → Phase 10                 ✅ DONE
         (session)  (agents)  (sidebar)

v0.5.0 Phase 11 → Phase 12 → Phase 13 → Phase 14 → Phase 15   ✅ DONE
         (LSP)     (agents)   (git)     (oauth)    (budget)
```

---

## v0.6.0 — Architecture + UI/UX Polish

Architecture first (foundation), then UI/UX polish on top.

### Phase 16: Command Registry
**Goal:** Replace 30+ branch if-else dispatch with O(1) command lookup
**ปัญหา**: main.zig มี 30+ `else if` branches สำหรับ route commands — เพิ่ม command ใหม่ต้องแก้ 4 ไฟล์
**ทำ**:
- สร้าง `src/cli/registry.zig` — CommandRegistry with comptime hash map
- Command module pattern: export `.name`, `.handler`, `.description`
- main.zig dispatch becomes 5 lines instead of 80
- handlers.zig becomes thin re-export layer
- ไฟล์: new `src/cli/registry.zig`, rewrite `src/main.zig` dispatch, slim `src/commands/handlers.zig`

**Plans:** 1 plan
Plans:
- [ ] 16-01-PLAN.md — Create comptime command registry + wire dispatch into main.zig

### Phase 17: TUI Widget Extraction
**Goal:** Break chat_tui_app.zig (4279 lines) into modular widget files
**ปัญหา**: chat_tui_app.zig ยากต่อการ navigate, test, และ reuse widgets
**ทำ**:
- Extract HeaderWidget → `src/tui/widgets/header.zig`
- Extract SidebarWidget → `src/tui/widgets/sidebar.zig`
- Extract InputWidget → `src/tui/widgets/input.zig`
- Extract MessageWidget → `src/tui/widgets/messages.zig`
- Extract PermissionDialogWidget → `src/tui/widgets/permission.zig`
- Extract CommandPaletteWidget → `src/tui/widgets/palette.zig`
- chat_tui_app.zig becomes assembly file (~500 lines)
- ไฟล์: new `src/tui/widgets/*.zig`, slim `src/tui/chat_tui_app.zig`

**Plans:** 3 plans
Plans:
- [ ] 17-01-PLAN.md — Shared types + helpers + message/tool call display widgets
- [ ] 17-02-PLAN.md — Chrome widgets (header, sidebar with SidebarContext, input)
- [ ] 17-03-PLAN.md — Overlay widgets (palette, permission, setup) + final integration

### Phase 18: Animated Spinner + Stalled Detection
**Goal:** Frame-based spinner with gradient colors and stalled-stream detection
**ปัญหา**: AI thinking/loading ไม่มี visual feedback ที่ดี
**ทำ**:
- สร้าง `src/tui/widgets/spinner.zig` — AnimatedSpinner with frame cycling
- Gradient color cycling (braille frames: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
- Stalled detection: turns red when no token received for 5+ seconds
- Token counter + elapsed time display
- Birth offset for staggered entrance
- Integrate into TUI streaming worker
- Reference: crush `anim.go`, claude-code `Spinner.tsx`
- ไฟล์: new `src/tui/widgets/spinner.zig`, modify TUI streaming

### Phase 19: Gradient Text + Toast Notifications
**Goal:** Gradient header text and toast notification system
**ปัญหา**: TUI ดู basic — ไม่มี visual polish หรือ notification feedback
**ทำ**:
- สร้าง `src/tui/widgets/gradient.zig` — RGB interpolation across text
- Apply gradient to header title (Crushcode branding)
- สร้าง `src/tui/widgets/toast.zig` — Toast notification stack
  - Auto-dismiss with progress animation
  - Multiple severity levels (info, warning, error, success)
  - Stack management (max 5 visible)
- Wire budget alerts and permission results into toast system
- Reference: crush `grad.go`, claude-code `ToastStack.tsx`
- ไฟล์: new gradient.zig, toast.zig, modify chat_tui_app.zig

### Phase 20: Diff Word Highlighting + Typewriter Streaming
**Goal:** Word-level diff highlighting and typewriter text reveal for streaming
**ปัญหา**: Diff ไม่ highlight คำที่เปลี่ยน, streaming text แสดงทีเดียวทั้งก้อน
**ทำ**:
- Diff: highlight individual changed words within diff lines (not just whole lines)
- Typewriter: per-character text reveal with randomized delay (30-80ms)
- Blinking cursor at end of revealed text
- Integrate typewriter into AI streaming response rendering
- Reference: claude-code `StructuredDiff.tsx`, opencode `typewriter.tsx`
- ไฟล์: modify `src/diff/visualizer.zig`, new `src/tui/widgets/typewriter.zig`

---

## ลำดับการทำ
```
v0.6.0 Phase 16 → Phase 17 → Phase 18 → Phase 19 → Phase 20
        (registry)  (widgets)  (spinner)  (gradient)  (diff+typewriter)
```

## v0.7.0 — Full AI Agent (Integration + Intelligence)

**ปัญหา**: ทุก component มีแล้ว แต่ไม่ได้ wire เข้าด้วยกัน — MCP tools ไม่ถึง agent loop, context compaction ไม่ทำงาน, system prompt ยัง basic, diff algorithm เป็น stub

### Phase 21: MCP → Agent Loop + Tool Unification
**Goal:** Wire MCP tools into TUI agent loop so AI can use ANY discovered MCP server tool; unify duplicate tool implementations
**ปัญหา**: TUI's `executeInlineTool()` dispatches only 6 hardcoded tools. MCP client can discover/call tools but TUI never routes to it. 250 lines of duplicate inline tool code.
**ทำ**:
- Create unified `ToolDispatcher` that checks builtin tools first, then MCP tools
- Wire MCPBridge into TUI Model init (discover + connect servers on startup)
- Replace `executeInlineTool()` with call to shared `tool_executors.zig`
- Add MCP tool schemas to system prompt `## Available Tools` section
- Show MCP server status in sidebar
- ไฟล์: modify `chat_tui_app.zig` (wire MCP, replace inline tools), `tool_executors.zig` (add MCP dispatch)

**Plans:** 2 plans
Plans:
- [ ] 21-01-PLAN.md — MCP tool dispatch + unify tool implementations
- [ ] 21-02-PLAN.md — MCP server lifecycle (auto-discover, connect, health-check) + sidebar status

### Phase 22: Smart Context + Auto-Compact ✅ DONE
**Goal:** Relevance-scored context selection and automatic context compaction when window fills
**ปัญหา**: Knowledge graph dumps ALL indexed files into system prompt. No token budget awareness. `/compact` returns "not implemented" even though compaction.zig has full logic.
**ทำ**:
- Wire `ContextCompactor` from compaction.zig into TUI streaming loop ✅ (already wired)
- Add token budget tracking — auto-compact when >70% context used ✅ (commit 555aaa0)
- Implement `/compact` slash command using existing `compact()` method ✅ (already existed)
- Relevance-based context selection — score files by query similarity, not dump all ✅ (graph.zig scoreNodesByQuery)
- Token-aware system prompt — truncate context to fit within model limits ✅ (8000 token budget)
- Show context usage in header: `ctx: 45% | 14 files` ✅ (already in header)
- ไฟล์: modify `chat_tui_app.zig` (wire compaction, auto-compact trigger), `graph/graph.zig` (relevance scoring)

**Plans:** 2 plans
Plans:
- [x] 22-01-PLAN.md — Wire compaction + auto-compact trigger + /compact command ✅
- [x] 22-02-PLAN.md — Relevance-based context selection + token-aware system prompt ✅

### Phase 23: Myers Diff + Edit Preview ✅ DONE
**Goal:** Real diff algorithm and edit preview before applying changes
**ปัญญา**: visualizer.zig is naive line-by-line compare that breaks on insertions/deletions. AI edits files directly with no preview — user can't see what will change.
**ทำ**:
- Implement Myers diff algorithm in `src/diff/myers.zig` (O(ND) diff) ✅ (596 lines)
- Replace naive visualizer with Myers-based hunk generation ✅
- Edit preview: show diff before apply, user confirms with [y/n] ✅ (diff_preview.zig, 274 lines)
- Wire `validated_edit.zig` hash-based edits into TUI edit tool ✅ (220 lines)
- Show diff in TUI with proper coloring (+ green, - red, context dimmed) ✅ (diff.zig, 311 lines)

**Plans:** 2 plans
Plans:
- [x] 23-01-PLAN.md — Myers diff algorithm + hunk generation ✅
- [x] 23-02-PLAN.md — Edit preview flow (diff display + confirm/reject) + hash validation ✅

### Phase 24: System Prompt Engineering + Project Config ✅ DONE
**Goal:** Rich system prompt with project-specific instructions, AGENTS.md support, and .crushcode/ project config
**ปัญญา**: System prompt is just "You are a helpful AI coding assistant" + raw compressed context. No project-specific instructions, no coding guidelines, no AGENTS.md support.
**ทำ**:
- Load `AGENTS.md` from project root → inject into system prompt ✅
- Support `.crushcode/instructions.md` for custom project instructions ✅
- Enhance base system prompt with coding best practices (tool usage guidelines, edit safety, etc.) ✅ (17 guidelines)
- Project detection: auto-detect language, framework, build system ✅ (6 languages)
- Dynamic tool descriptions based on project type ✅ (Zig/Rust/Go/JS/Python/C++)
- Multi-format context files (CLAUDE.md, GEMINI.md, .cursorrules, .github/copilot-instructions.md) ✅ (12+ formats)
- Structured XML injection of context files ✅
- ไฟล์: modify `chat_tui_app.zig` (prompt building), `src/config/project.zig` (context file loading)

**Plans:** 1 plan
Plans:
- [x] 24-01-PLAN.md — Rich system prompt + AGENTS.md + project config ✅

### Phase 25: Lifecycle Hooks + Code Quality ✅
**Goal:** Wire lifecycle hooks into agent loop and clean up code quality issues
**ปัญหา**: Lifecycle hooks framework exists (196 lines, 10 phases, 3 tiers) but ZERO hooks registered and ZERO call sites in production code. Also: tree_sitter.zig stub (438 lines of @panic).
**ทำ**:
- ~~Wire `LifecycleHooks` into TUI agent loop~~ — ALREADY DONE (7 call sites in streaming.zig + chat_tui_app.zig)
- ~~Implement core hooks~~ — ALREADY DONE (token_tracker, error_logger, tool_timer registered)
- ✅ Remove `tree_sitter.zig` stub — AST replaced by 3-tier (Regex + LSP + sg binary)
- ~~Clean up dead code in graph/types.zig~~ — clean, reserved enums intentional for Phase 26

**Plans:** None needed — most was already done, only tree_sitter.zig removal required.

### Research Sprint (completed 2026-04-27)
**Done (shipped in e6b825f, f54aa5a):**
- 41 reference repos deep-dived across 5 domains (agent orchestration, edit/safety, TUI, MCP/skills, AI providers)
- CheckpointManager wired to delete_file + move_file
- /undo command in TUI (calls rewindLast)
- Write-before-read guard on write_file + edit
- Token estimation LRU cache (src/cache/token_cache.zig, xxHash64 keys)
- HTTP connection reuse (shared std.http.Client threadlocal)
- Hashline Edit (src/edit/hashline_edit.zig, ~530 lines, LINE#ID from OhMyOpenAgent)
- AST marked REPLACED: 3-tier (Regex + LSP + sg binary)

---

## ลำดับการทำ
```
v0.7.0 Phase 21 → Phase 22 → Phase 23 → Phase 24 → Phase 25
         (MCP wire)  (context)  (diff)  (prompt)  (hooks)
```

## ไม่ทำ (defer indefinitely)
- Voice input
- Vim mode
- Package managers (deb/rpm/brew) — install command พอ
- IDE bridge (VS Code / JetBrains)
- Real AST parsing (tree-sitter) — REPLACED: 3-tier stack (Regex highlighting ✅ + LSP structural queries ✅ + spawn `sg` binary for AST search) — zero compile-time deps, covers all use cases

---

## v0.33.0 — Self-Improving Agent

**วัตถุประสงค์**: ทำให้ crushcode เรียนรู้จากการใช้งาน จำข้าม session และเสนอแผนก่อนแก้โค้ด

**แรงบันดาลใจจากงานวิจัย**: Hermes Agent (learning loop, skill gen, user model), Claude Code (plan mode, context scoring), SWE-Pruner (relevance scoring), Codex (plan items)

### Phase 26: Context Relevance Scoring ✅
**ปัญหา**: ตอนนี้ graph.zig ทิ้งไฟล์ทั้งหมดให้ AI — เปลือง token และ noise สูง
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ Relevance scoring in graph.zig: PageRank + keyword matching + file type weighting + recency bias + community bonus
- ✅ Smart context builder via `buildSmartContext()` with scored file selection
- ✅ Header shows `ctx:{d}% | {d}/{d} scored`

**Plans:** None needed — all already implemented.

### Phase 27: User Model (USER.md) ✅
**ปัญหา**: Agent ไม่จำความชอบของ user ข้าม session — ต้องสั่งซ้ำทุกครั้ง
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/agent/user_model.zig` (440 lines): persistent preferences to `~/.crushcode/USER.md`
- ✅ Tracks: coding style, tools, language, naming conventions with confidence scoring
- ✅ Loaded on startup, injected into system prompt, `/user` slash command
- ✅ 7 tests

**Plans:** None needed — all already implemented.

### Phase 28: Auto Skill Generation ✅
**ปัญหา**: Skills ต้องเขียนเองทุกอัน — agent ไม่เรียนรู้จาก pattern ที่ทำซ้ำ
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/skills/auto_gen.zig` (717 lines): pattern detection across sessions
- ✅ AutoSkillGenerator with TaskPattern struct, confidence scoring
- ✅ Wired into TUI (chat_tui_app.zig line 3349) and streaming (streaming.zig line 471)
- ✅ In build.zig as module

**Plans:** None needed — all already implemented.

### Phase 29: Plan Mode ✅
**ปัญหา**: Agent แก้โค้ดเลยโดยไม่ถาม — เหมือน dev ไฟลนก้น (ตามรีวิว Reddit)
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/commands/handlers/plan_handler.zig` (575 lines): structured plan format
- ✅ Plan steps with files affected + risk level
- ✅ Wired into TUI (plan_mod imported, used in chat_tui_app.zig + streaming.zig)
- ✅ In build.zig as module

**Plans:** None needed — all already implemented.

### Phase 30: Feedback Loop ✅
**ปัญหา**: Agent ไม่รู้ว่างานที่ทำไปดีหรือไม่ — ไม่มี mechanism ปรับปรุง
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/agent/feedback.zig` (737 lines): task outcome tracking with quality rating
- ✅ Stores outcomes in memory with confidence scores
- ✅ `/feedback` slash command to view stats
- ✅ Injected into system prompt (chat_tui_app.zig line 1330)
- ✅ In build.zig as module

**Plans:** None needed — all already implemented.

---

## v0.33.0 ลำดับการทำ ✅ ALL DONE
```
v0.33.0 Phase 26 → Phase 27 → Phase 28 → Phase 29 → Phase 30
          (scoring)  (user)   (auto-skill) (plan)  (feedback)
```

## v0.33.0+ Backlog (researched but deferred)
- Sub-agent delegation (Hermes delegate_tool.py)
- Graduated permission system (Parallax)
- Mixture-of-Agents reasoning (Hermes MoA)
- Skill hub integration (Hermes skills_hub.py)
- Expand builtin tools to 15+ (Claude Code has 29)
- Streaming diff preview (diffpane, tuicr)
- Sandboxed execution (gVisor/LXC)
- Multi-platform gateway (Telegram/Discord/Slack)

---

## v0.34.0 — Tool Expansion + Permissions + Delegation

**วัตถุประสงค์**: เพิ่ม builtin tools, ปรับ permission UX, เพิ่ม sub-agent delegation

**ลำดับตาม priority**: Tools → Permissions → Delegation (tools ต้องมีก่อน permission จะมีความหมาย)

### Phase 31: Expand Builtin Tools to 15+ ✅
**ปัญหา**: มีแค่ 6 tools — AI ทำอะไรไม่ได้มาก
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ All 9+ tools in tool_executors.zig: list_directory, create_file, move_file, copy_file, undo_edit, git_status, git_diff, git_log, search_files
- ✅ Registered in both tool registries (lines 508-517, 1807-1816)
- ✅ Checkpoint wiring on move_file, copy_file

**Plans:** None needed — all already implemented.

### Phase 32: Graduated Permission System ✅
**ปัญธา**: Permission ตอนนี้เป็น binary allow/deny — น่ารำคาญ
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/permission/tool_classifier.zig` (452 lines): tool categorization (read/write/destructive)
- ✅ `src/permission/auto_classifier.zig` (571 lines): auto-classification with tiers
- ✅ `src/permission/evaluate.zig` (780+ lines): graduated evaluation, session memory, auto-allow
- ✅ Full permission directory with 11 files (audit, governance, guardian, lists, security, types)

**Plans:** None needed — all already implemented.

### Phase 33: Sub-Agent Delegation ✅
**ปัญหา**: งานซับซ้อนต้องทำทีละอย่าง — ไม่มี parallel sub-task
**ทำ**: (ALL ALREADY IMPLEMENTED)
- ✅ `src/agent/delegate.zig` (605 lines): sub-agent spawning with scoped context
- ✅ Sub-agent gets subset of tools + focused prompt
- ✅ Parent collects and synthesizes results
- ✅ In build.zig as module

**Plans:** None needed — all already implemented.

---

## v0.34.0 ลำดับการทำ ✅ ALL DONE
```
v0.34.0 Phase 31 → Phase 32 → Phase 33
          (tools)  (perms)   (delegate)
```
