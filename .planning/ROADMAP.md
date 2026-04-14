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
**ปัญหา**: WorkerItem struct มีแต่ไม่มี real thread spawning
**ทำ**:
- std.Thread.spawn() สำหรับ worker threads
- Thread-safe queue (std.Thread.Mutex + ArrayList) สำหรับ task/result
- Real AI request ใน background thread → result กลับมา main thread
- WorkerItem status update จาก thread (pending → running → done/error)
- ไฟล์: แก้ src/agent/parallel.zig — เพิ่ม real threading

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
**ปัญหา**: OAuth มีแค่ MCP auth ไม่มี AI provider auth
**ทำ**:
- Generalize OAuth จาก mcp/oauth.zig ให้ใช้กับ AI providers ได้
- Provider login flow (OpenRouter, etc.)
- Token refresh อัตโนมัติ
- ไฟล์: สร้าง src/auth/provider_oauth.zig — reuse mcp/oauth.zig patterns

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

v0.5.0 Phase 11 → Phase 12 → Phase 13 → Phase 14 → Phase 15
         (LSP)     (agents)   (git)     (oauth)    (budget)
```

## ไม่ทำ (defer indefinitely)
- Voice input
- Vim mode
- Package managers (deb/rpm/brew) — install command พอ
- IDE bridge (VS Code / JetBrains)
