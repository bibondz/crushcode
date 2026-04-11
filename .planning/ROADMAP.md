# Roadmap: Crushcode v1

**Created:** 2026-04-11
**Granularity:** Coarse
**Parallelization:** true

---

## Phases

- [x] **Phase 1: Core Infrastructure** - Config, AI chat, CLI, build system
- [x] **Phase 2: Shell Execution** - Command execution with PTY and timeouts
- [x] **Phase 3: AI File Operations** - AI-driven file write/edit with glob patterns
- [ ] **Phase 4: Skills System** - Built-in commands and extensibility
- [ ] **Phase 5: Terminal UI** - Rich interactive interface
- [ ] **Phase 6: MCP Integration** - Model Context Protocol support

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

### Phase 7: MCP Authentication

**Goal:** OAuth 2.0 support for MCP servers with dynamic client registration

**Depends on:** Phase 6

**Requirements:** 
- OAuth callback server implementation
- Token storage and refresh
- Dynamic client registration
- CSRF state validation

**Success Criteria:**
1. OAuth flow completes for MCP servers requiring auth
2. Tokens are stored and automatically refreshed
3. CSRF protection prevents attacks

**Plans:** 1 plan
- [ ] 07-01-PLAN.md — OAuth authentication for MCP

---

### Phase 8: Permission System

**Goal:** Pattern-based permission allow/deny/ask rules for tool safety

**Depends on:** Phase 1

**Requirements:**
- Allowlist with pattern matching
- "tool:action" format support
- Wildcard patterns (* and **)
- User prompt for "ask" actions

**Success Criteria:**
1. Tools can be allowed/denied by pattern
2. User is prompted for confirmation when needed
3. Auto-approval works for trusted operations

**Plans:** 1 plan
- [ ] 08-01-PLAN.md — Permission evaluation system

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
- [ ] 09-01-PLAN.md — Skill loading system

---

### Phase 10: Tool Registry

**Goal:** Dynamic tool loading with feature flags and aliases

**Depends on:** Phase 6

**Requirements:**
- Tool registry with HashMap storage
- Feature-flag controlled loading
- Tool aliases for compatibility
- Concurrency safety flags

**Success Criteria:**
1. Tools load dynamically at runtime
2. Feature flags enable/disable tools
3. Aliases provide backward compatibility

**Plans:** 1 plan
- [ ] 10-01-PLAN.md — Dynamic tool registry

---

### Phase 11: Agent Framework

**Goal:** Enhanced agent with streaming, checkpoint, and memory

**Depends on:** Phase 1

**Requirements:**
- Streaming response handling
- File-based checkpoint system
- Conversation memory management
- Multi-agent coordination (future)

**Success Criteria:**
1. Streaming responses display in real-time
2. Checkpoints save/restore agent state
3. Memory persists across sessions

**Plans:** 1 plan
- [ ] 11-01-PLAN.md — Agent streaming and state

---

### Phase 12: Config Enhancement

**Goal:** Advanced config with file watching, backups, migrations

**Depends on:** Phase 1

**Requirements:**
- File watching for config changes
- Backup creation before changes
- Config migration system
- Environment variable integration

**Success Criteria:**
1. Config changes are watched and reloaded
2. Backups exist before dangerous changes
3. Migrations handle version upgrades

**Plans:** 1 plan
- [ ] 12-01-PLAN.md — Advanced configuration

---

### Phase 13: TurboQuant Integration

**Goal:** KV cache compression for memory-efficient AI inference with 3.8-6.4x compression ratios

**Depends on:** Phase 1 (Core Infrastructure), Phase 11 (Agent Framework)

**Requirements:**
- Quantization types and utilities
- Bit-packing and compression algorithms  
- KV cache manager with compression support
- AI client integration for compression options

**Success Criteria:**
1. Compression achieves 3.8x-6.4x ratios matching TurboQuant
2. Quality preserved (cos_sim > 0.94 for turbo4, > 0.997 for quality mode)
3. Inner product bias < 0.1% (unbiased estimation)
4. Memory savings enable 2x larger context windows
5. Integration works with existing providers

**Plans:** 1 plan
- [ ] 13-01-PLAN.md — KV cache compression with TurboQuant

---

*Last updated: 2026-04-11 (Phase 13: TurboQuant added)*