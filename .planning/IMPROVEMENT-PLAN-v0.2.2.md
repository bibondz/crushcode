# Crushcode v0.2.2 — Master Improvement Plan

**Date:** 2026-04-13
**Status:** Approved
**Source:** Analysis of 10 reference projects + Oracle-validated architecture review
**Oracle Session:** bg_cbadb477

---

## Overview

v0.2.2 focuses on two goals:
1. **Architecture reorganization** — reduce module overlap, split oversized files, simplify build graph
2. **High-value features** — cherry-picked from reference projects, no duplication, no bloat

**Scope guardrails:**
- No external dependencies (Zig stdlib only)
- No behavioral regressions — reorganize first, features second
- Oracle-validated: do NOT create one unified capability HashMap

---

## Reference Projects Analyzed

| # | Project | Key Takeaways |
|---|---------|--------------|
| 1 | Cavekit | Spec-driven dev, adversarial review, convergence detection, parallel build plans |
| 2 | Caveman | Output intensity levels, terse commits, input token compression, auto-clarity |
| 3 | claude-code-best-practice | Subagent patterns, hierarchical memory, agent teams |
| 4 | OpenCode | Session summarization, skill discovery, hierarchical config |
| 5 | Crush | Model hot-swap, session threading, TUI dialogs |
| 6 | open-claude-code | 1581 tests, hook system, slash commands, sandboxing |
| 7 | CheetahCLAWS | Brainstorm mode, checkpoint rewind, memory consolidation, plan mode |
| 8 | TurboQuant | QJL residual projection, hybrid decode ring buffer, Lloyd-Max codebooks |
| 9 | ripgrep | Parallel worker pattern, mmap choice, typed color specs, gitignore spec |
| 10 | LLM Wiki Guide | Tiered context loading, knowledge lint, source-tracking metadata |

---

## Part A: Architecture Reorganization

### Current State

- **76 createModule** calls in build.zig
- **158 addImport** calls in build.zig
- **814 lines** in build.zig
- **32,162 lines** of Zig source
- **61 modules** in compat loop (each gets file_compat + array_list_compat)

### Overlap Analysis

| Overlap | Severity | Decision |
|---------|----------|----------|
| Plugin Trinity (3 files, same job) | HIGH | Merge into plugin/mod.zig directory |
| 4 Registries (tools/plugins/skills/commands) | HIGH | Add thin CapabilityCatalog, keep separate ownership |
| Task Tracking (parallel.zig vs phase.zig) | MEDIUM | Extract shared task primitives |
| MCP vs Tool Registry | MEDIUM | MCP registers into catalog with namespaced IDs |
| Worktree vs Jobs (isolation) | MEDIUM | Share ExecutionContext abstraction |

### Oracle-Validated Decisions

1. **DO NOT** merge all registries into one HashMap — different lifecycles (tool=static, plugin=config, skill=file, MCP=session-scoped)
2. **DO NOT** merge skills/types.zig + commands/skills.zig — SKILL.md parser ≠ CLI built-ins
3. **DO** consolidate plugin namespace into one module directory with barrel mod.zig
4. **DO** add read-only CapabilityCatalog for "query one place" without owning storage
5. **DO** share task primitives between parallel.zig and phase.zig
6. Build.zig cleanup is for maintainability, not compile time (negligible improvement)

---

### Step 1: Extract Shared Task Primitives

**Risk:** Low (pure extraction, no behavior change)
**Lines saved:** ~150

Create `src/agent/task.zig`:
- `RunState` enum: pending, running, completed, failed, cancelled
- `TaskResult` struct: status, output, error_message, duration_ms
- `ExecutionContext` union: worktree, background, inline

Update consumers:
- `agent/parallel.zig`: replace `TaskStatus` with `RunState`, `TaskResult` with shared type
- `workflow/phase.zig`: use `RunState` for base states, keep phase-only states (`verified`, `skipped`) as wrapper
- `agent/worktree.zig`: use `ExecutionContext`
- `commands/jobs.zig`: use `ExecutionContext`

Build.zig: +1 module (`agent/task`)

---

### Step 2: Consolidate Plugin Trinity

**Risk:** Medium (update all consumers)
**Lines saved:** ~200

Current (3 separate modules):
- `plugin/interface.zig` — Plugin struct, PluginManager, JSON-RPC
- `plugin_manager.zig` — dispatches built-in plugins
- `plugins/registry.zig` — stores plugin configs, enable/disable

After (1 module directory):
```
src/plugin/
├── mod.zig          ← barrel file (public re-exports)
├── types.zig        ← Plugin struct, JSON-RPC protocol types
├── registry.zig     ← PluginRegistry HashMap, enable/disable
├── manager.zig      ← PluginManager lifecycle + dispatch
└── protocol.zig     ← unchanged
```

Build.zig: 3 modules → 1 module

---

### Step 3: Fix Skill Naming Collision

**Risk:** Low (rename + update references)
**Lines saved:** 0 (clarity win only)

| Current | Rename To | Why |
|---------|-----------|-----|
| `src/skills/types.zig` | `src/skills/loader.zig` | It loads SKILL.md files, not types |
| `src/commands/skills.zig` | `src/commands/builtins.zig` | It runs echo/date/whoami, not skills |

Build.zig: update module root_source_file paths only

---

### Step 4: Add CapabilityCatalog

**Risk:** Low (additive only)
**Lines added:** ~150

Create `src/capability/`:
```
src/capability/
├── catalog.zig      ← read-only index over all registries
└── types.zig        ← CapabilityDescriptor, CapabilityKind enum
```

```zig
pub const CapabilityKind = enum { tool, plugin, skill, mcp_tool, builtin };

pub const CapabilityDescriptor = struct {
    name: []const u8,
    kind: CapabilityKind,
    enabled: bool,
    description: []const u8,
};

pub const CapabilityCatalog = struct {
    pub fn listAll() []CapabilityDescriptor;
    pub fn find(name: []const u8) ?CapabilityDescriptor;
    pub fn listByKind(kind: CapabilityKind) []CapabilityDescriptor;
};
```

MCP integration: namespaced IDs `mcp:<server>/<tool>`, execution stays in mcp/bridge.zig
Agent loop: ToolExecutor queries catalog, doesn't care about source

Build.zig: +1 module

---

### Step 5: Split Oversized Files

**Risk:** Medium (behavioral equivalent refactors)
**Files affected:**

| File | Lines | Split |
|------|-------|-------|
| `mcp/client.zig` | 1,764 | → transport.zig + protocol.zig + client.zig |
| `handlers.zig` | 1,621 | → move impls to command files, keep dispatch |
| `chat.zig` | 1,478 | → chat/streaming.zig + chat.zig |
| `ai/client.zig` | 1,408 | → ai/streaming.zig + ai/client.zig |

---

### Step 6: Build.zig Cleanup

**Risk:** Low
**Approach:** Create helper function to reduce boilerplate

```zig
fn createStdModule(b: *std.Build, path: []const u8, target, opt, compat_mods) *std.Build.Module {
    const mod = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = opt });
    mod.addImport("array_list_compat", compat_mods.array_list);
    mod.addImport("file_compat", compat_mods.file);
    return mod;
}
```

Target: 76 → ~60 createModule, 814 → ~500 lines

---

## Part B: New Features from References

### Phase B: Quick-Win Features (Small, High Impact)

| # | Feature | Source | Effort | Value |
|---|---------|--------|--------|-------|
| F1 | Output Intensity Levels (lite/full/ultra) | Caveman | Low | High |
| F2 | Tiered Context Loading (index-first) | LLM Wiki | Low | High |
| F4 | Extended Thinking Streaming | CheetahCLAWS | Low | Medium |
| F14 | Convergence Detection | Cavekit | Low | High |
| F17 | Session History Autosave + Resume | CheetahCLAWS | Low | Medium |

### Phase C: Core Features (Medium Effort)

| # | Feature | Source | Effort | Value |
|---|---------|--------|--------|-------|
| F5 | XML Atomic Plan Format | GSD | Medium | High |
| F6 | Gap Closure Phases (decimal phases) | GSD | Low | High |
| F8 | Revision Loop + Stall Detection | GSD | Medium | High |
| F10 | Adversarial Dual-Model Review | Cavekit | Medium | High |
| F11 | Session Summarization + Diff | OpenCode | Medium | High |
| F13 | Model Hot-Swap Mid-Session | Crush | Medium | High |
| F15 | Markdown Custom Commands | OpenCode | Low | High |

### Phase D: Polish (If Time Permits)

| # | Feature | Source | Effort | Value |
|---|---------|--------|--------|-------|
| F16 | Interactive Slash Commands | open-claude-code | Medium | High |
| F18 | Knowledge Lint | LLM Wiki | Medium | Medium |
| F19 | Source-Tracking Metadata | LLM Wiki | Low | Medium |
| F22 | Typed Color Specs | ripgrep | Low | Medium |

### Deferred (Future, Not v0.2.2)

| Feature | Source | Why |
|---------|--------|-----|
| Agent Teams with Messaging | multica, oh-my-openagent | Needs solid parallel executor first |
| Cron Task Scheduling | open-claude-code | Background daemon needed |
| Swarm Registry | OpenHarness | Needs agent teams first |
| Docker Tool Isolation | claude-code | Container infrastructure |
| Vim Mode | claude-code | Major TUI rewrite |
| Leiden Clustering | graphify | Needs tree-sitter bindings |
| QJL Residual Projection | TurboQuant | Advanced, post-v0.2.2 |
| Hybrid Decode Ring Buffer | TurboQuant | Advanced, post-v0.2.2 |

---

## Execution Order

```
Phase A: Reorganize (stability first)
  Week 1: Steps 1-3 (task primitives, plugin trinity, skill naming)
  Week 2: Steps 4-5 (capability catalog, split oversized files)
  Week 3: Step 6 (build.zig cleanup)

Phase B: Quick-Win Features
  Week 3: F1, F2, F4, F14
  Week 4: F17

Phase C: Core Features
  Week 4-5: F5, F6, F8
  Week 5-6: F10, F11, F13, F15

Phase D: Polish
  Week 6+: F16, F18, F19, F22
```

---

## Validation Checklist

After each step:
- [ ] `zig build` succeeds (exit code 0)
- [ ] No new compiler warnings
- [ ] Existing tests pass (`zig build test`)
- [ ] Behavioral equivalence (same CLI output for same inputs)

---

## Rejected Ideas (Oracle-Validated)

| Idea | Why Rejected |
|------|-------------|
| One unified HashMap for all capabilities | Different lifecycles would need `switch(kind)` everywhere |
| Merge skills/types.zig + commands/skills.zig | SKILL.md parser ≠ CLI built-ins — conceptual bug |
| Merge for compile time improvement | Negligible improvement, maintainability is the real win |
| Merge agent/loop.zig + workflow/phase.zig | Different concerns — share primitives only |
| Lowest-common-denominator registry | Accumulates switch logic, harder to extend |
