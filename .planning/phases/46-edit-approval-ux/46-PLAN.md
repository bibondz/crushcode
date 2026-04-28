# Phase 46 — Edit Approval UX + Diff Preview

**Phase**: 46 | **Milestone**: v3.2.0 — Agent Core Live
**Status**: 🔥 Planning | **Depends**: Phase 45
**Goal**: Interactive approval prompt in TUI when AI wants to edit files. Show diff before apply.

## Context

The permission system (`src/permission/guardian.zig`) exists and the diff modules are built:
- `src/diff/myers.zig` — Myers diff algorithm
- `src/diff/visualizer.zig` — Diff visualization
- `src/diff/tui_diff.zig` — TUI diff preview component
- `src/edit/validated_edit.zig` — Hash-based conflict detection

But when AI calls `edit_file`, there's no interactive prompt that shows the user what will change and asks for approval.

## Plan Structure

3 plans in 2 waves:
- **Wave 1**: Plans 46-01 + 46-02 (approval prompt + diff preview — can be parallel)
- **Wave 2**: Plan 46-03 (auto-approve + permission modes — depends on Wave 1)

---

## Plan 46-01: Approval Prompt in TUI

**File**: `src/tools/executors/approval.zig` (NEW, ~200 lines)

### What
When AI calls a write tool (write_file, edit_file, shell), show an approval prompt before executing.

### Tasks
1. Create `ApprovalPrompt` that:
   - Detects when a tool call requires approval (write operations)
   - Displays: `[Agent wants to: {action}]` e.g., `[Agent wants to: edit src/main.zig]`
   - Shows diff preview if available (Plan 46-02)
   - Presents options: `[Y]es / [N]o / [E]dit / [A]lways allow`
   - Reads single keystroke (no Enter required)

2. Approval flow:
   ```
   ━━━ Agent wants to edit: src/main.zig ━━━
   -3 | const version = "3.1.0";
   +3 | const version = "3.2.0";
   
   Accept? [y/n/e/a]: 
   ```

3. Responses:
   - `y` → execute tool, return result
   - `n` → return error result "User denied edit"
   - `e` → open editor for user to modify the change, then apply modified version
   - `a` → add path to allowlist in config, execute, future edits to this path auto-approve

4. Integration point:
   - Called from `ToolDispatcher.execute()` (Phase 45-04) before executing write tools
   - Pass tool name + args to approval prompt
   - For edit_file: show diff preview (Plan 46-02)
   - For write_file: show first 20 lines of content
   - For shell: show command to be executed

### UAT
- [ ] AI calls edit_file → approval prompt shows
- [ ] User presses Y → edit executes, result returned to AI
- [ ] User presses N → error result returned to AI, AI sees "User denied edit"
- [ ] AI calls read_file → NO approval prompt (read-only)
- [ ] Non-interactive mode → auto-approve (no prompt)

---

## Plan 46-02: Diff Preview Before Apply

**File**: `src/tools/executors/diff_preview.zig` (NEW, ~150 lines)

### What
Show a colorized diff of what will change before asking for approval.

### Tasks
1. Create `generateDiffPreview()` that:
   - For `edit_file`: read current file content, apply replacement mentally, generate unified diff
   - Reuse `src/diff/myers.zig` for diff computation
   - Format with color codes: red for removed, green for added, cyan for context
   - Show 3 lines of context around each change

2. Diff format:
   ```
   ━━━ src/main.zig ━━━
    10 | const allocator = std.heap.page_allocator;
   -11 | const version = "3.1.0";
   +11 | const version = "3.2.0";
    12 | 
   ```

3. Handle edge cases:
   - File doesn't exist yet (write_file) → show "[NEW FILE]" + first 10 lines
   - Large diff (>50 lines) → show summary: "48 lines changed (+23/-25)" + first 20 lines + "... (28 more lines)"
   - Binary file → "[Binary file, cannot show diff]"

### UAT
- [ ] Single line change → 3-line context diff
- [ ] Multi-line change → unified diff with context
- [ ] New file → "[NEW FILE]" + content preview
- [ ] Large diff → truncated with summary
- [ ] Colors render correctly in terminal

---

## Plan 46-03: Auto-Approve for Whitelisted Paths + Permission Modes

**File**: `src/permission/modes.zig` (NEW, ~120 lines)

### What
Support different permission modes so users aren't prompted for every edit.

### Tasks
1. Define `PermissionMode` enum:
   ```zig
   pub const PermissionMode = enum {
       strict,      // approve every write
       auto_edit,   // auto-approve file edits, prompt for shell
       auto_all,    // auto-approve everything (yolo mode)
       plan_only,   // no execution, just plan
   };
   ```

2. Config integration:
   - `[permissions]` section in crushcode.toml
   - `mode = "strict"` (default)
   - `allowed_paths = ["src/**", "tests/**"]` — auto-approve edits in these paths
   - `blocked_paths = [".env", "*.secret"]` — always deny
   - CLI flag: `--permission <mode>` overrides config

3. Auto-approve logic:
   - If path matches `allowed_paths` glob → skip approval
   - If path matches `blocked_paths` → always deny
   - Otherwise → use current `mode` behavior

4. "Always allow" from approval prompt (Plan 46-01):
   - User presses `a` → add path to session allowlist (in-memory)
   - Session allowlist persists for duration of conversation

### UAT
- [ ] strict mode: every edit prompts
- [ ] auto_edit mode: file edits auto-approve, shell commands prompt
- [ ] auto_all mode: everything auto-approves
- [ ] Path in allowed_paths → auto-approve
- [ ] Path in blocked_paths → always deny
- [ ] `--permission auto_edit` CLI flag → overrides config

---

## Wave Execution Order

```
Wave 1 (parallel):
  46-01: Approval prompt
  46-02: Diff preview

Wave 2 (sequential):
  46-03: Permission modes + auto-approve
```

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `src/tools/executors/approval.zig` | NEW | ~200 |
| `src/tools/executors/diff_preview.zig` | NEW | ~150 |
| `src/permission/modes.zig` | NEW | ~120 |
| `build.zig` | MODIFY | +3 modules |
