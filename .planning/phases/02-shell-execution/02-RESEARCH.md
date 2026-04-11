# Phase 2: Shell Execution - Research

**Phase:** 2 - Shell Execution  
**Requirements:** SH-01, SH-02, SH-03, SH-04  
**Date:** 2026-04-11

---

## Current State

### Existing Code (Partial Implementation)

1. **PTYPlugin** (`src/plugins/pty.zig`):
   - ✅ PTY spawn with openpty (Unix)
   - ✅ Session management (spawn, write, read, list, kill, resize)
   - ✅ Process kill with signal 9
   - ⚠️ Windows not implemented (returns error)
   - ⚠️ ReadFromTerminal returns mock data, not actual output

2. **ShellStrategyPlugin** (`src/plugins/shell_strategy.zig`):
   - ✅ Banned command list (vim, nano, less, etc.)
   - ✅ Non-interactive flag injection (apt -y, npm --yes)
   - ✅ Command validation
   - ⚠️ Not integrated with PTY or command execution

3. **Plugin Architecture** (`src/plugin/interface.zig`):
   - JSON-RPC 2.0 protocol
   - PluginManager for lifecycle
   - Not currently used by main CLI

4. **Main CLI** (`src/main.zig`):
   - Commands: chat, read, list, help, version
   - **NO shell command exists**

---

## Requirements Analysis

### SH-01: User can execute shell commands and see output

**What's needed:**
- New CLI command: `crushcode shell <command>` or `crushcode run <command>`
- Simple command execution without PTY (for non-interactive commands)
- Capture stdout/stderr and display to user
- Integration point: `src/commands/handlers.zig`

**Current gap:** No shell command in CLI

### SH-02: Command execution returns exit code

**What's needed:**
- Capture child process exit code
- Display exit code to user (or include in response for AI)
- Handle error propagation properly

**Current gap:** PTYPlugin doesn't return exit codes; simple execution not implemented

### SH-03: Support for interactive commands (PTY)

**What's needed:**
- Wire up existing PTYPlugin to the CLI
- Add command to spawn interactive terminal sessions
- Handle terminal I/O (read output, send input)

**Current gap:** PTYPlugin exists but not wired to CLI; read returns mock data

### SH-04: Command timeout support

**What's needed:**
- Configurable timeout per command
- Timeout handling: kill process after duration
- Display timeout message to user

**Current gap:** Not implemented anywhere

---

## Implementation Approach

### Plan Structure (Recommended)

1. **Plan 02-01: Shell Command Integration**
   - Add `shell` command to CLI
   - Simple command execution (non-PTY)
   - Capture and display output
   - Return exit codes

2. **Plan 02-02: PTY Integration**
   - Wire PTYPlugin to CLI
   - Interactive command support
   - Session management commands

3. **Plan 02-03: Timeout & Polish**
   - Add timeout support
   - Error handling improvements
   - Integration with chat context

---

## Zig-Specific Patterns

1. **Process execution:** Use `std.process.Child.init()` with `.Capture` for stdout/stderr
2. **PTY:** Use `c.openpty()` from `sys/ioctl.h` (already done in pty.zig)
3. **Non-blocking I/O:** Use `fcntl` with `O_NONBLOCK` (already done in pty.zig)
4. **Signal handling:** Use `c.kill(pid, signal)` for termination

---

## Integration Points

1. **CLI entry:** `src/main.zig` - add shell command dispatch
2. **Handlers:** `src/commands/handlers.zig` - route to shell handler
3. **New file:** `src/commands/shell.zig` - shell command implementation
4. **Plugins:** Can use PTYPlugin directly or through plugin system
5. **AI context:** Shell output needs to be formatted for chat context

---

## Atomic Commit Strategy

1. `feat(shell): add shell command skeleton` - CLI structure only
2. `feat(shell): implement basic command execution` - Non-PTY execution
3. `feat(shell): add exit code handling` - Capture and display exit codes
4. `feat(shell): integrate PTY plugin` - Interactive command support
5. `feat(shell): add timeout support` - Configurable timeouts
6. `chore(shell): add tests` - Test coverage

---

## TDD Approach

Each task should have:
1. Test file first (behavior-driven)
2. Implementation to pass tests
3. Integration with existing system

**Key test scenarios:**
- Non-interactive command execution returns output + exit code
- PTY session creation and I/O
- Timeout kills long-running command
- Error handling (command not found, permission denied)