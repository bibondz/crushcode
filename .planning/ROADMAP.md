# Roadmap: Crushcode v1

**Created:** 2026-04-11
**Granularity:** Coarse
**Parallelization:** true

---

## Phases

- [ ] **Phase 1: Core Infrastructure** - Config, AI chat, CLI, build system
- [ ] **Phase 2: Shell Execution** - Command execution with PTY and timeouts
- [ ] **Phase 3: AI File Operations** - AI-driven file write/edit with glob patterns

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

**Plans:** TBD

---

### Phase 3: AI File Operations

**Goal:** AI agent can write and edit files based on user requests

**Depends on:** Phase 1 (AI), Phase 2 (Shell for save operations)

**Requirements:** FO-02, FO-03

**Success Criteria** (what must be TRUE):
  1. User can ask AI to "write this file" and AI creates/modifies the file
  2. User can specify file targets using glob patterns (e.g., "edit all *.test.ts files")
  3. File operations succeed or return clear error messages

**Plans:** TBD

---

## Progress

| Phase | Plans Complete | Status | Completed |
|------|----------------|--------|-----------|
| 1. Core Infrastructure | 1/1 | Planned | - |
| 2. Shell Execution | 0/1 | Not started | - |
| 3. AI File Operations | 0/1 | Not started | - |

---

*Last updated: 2026-04-11*