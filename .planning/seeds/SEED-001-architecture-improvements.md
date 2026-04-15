---
id: SEED-001
created: 2026-04-14
status: consumed
consumed_milestone: v0.6.0
consumed_date: 2026-04-14
trigger_milestone: v0.6.0
trigger_condition: "When starting v0.6.0 planning — before any new features"
priority: high
effort_estimate: large
tags: [architecture, refactoring, tui, module-system]
---

# Architecture Improvements for v0.6.0

## Why This Matters Now

After building v0.5.0 (Phases 11-15), several architectural patterns emerged that will cause maintenance pain if not addressed before adding more features:

1. **Handler dispatch is O(n) if-else chain** — `main.zig` has 30+ `else if` branches for command routing. Adding new commands is error-prone.
2. **build.zig is 391 lines of manual module wiring** — every new file requires 3-5 edits across build.zig, handlers, and main. High friction.
3. **`std.ArrayList` vs `array_list_compat.ArrayList`** inconsistency — some files use std directly (lsp_manager.zig), others use the compat wrapper. Mixed patterns cause bugs.
4. **No module interface files** — every module exposes all internals. No clear public API contracts.
5. **TUI widget tree is monolithic** — chat_tui_app.zig is 4279 lines. Hard to navigate, test, or reuse widgets.

## Specific Improvements

### 1. Command Registry Pattern
Replace the if-else dispatch with a compile-time or runtime command registry:
```zig
// Each command module exports:
pub const command = Command{ .name = "auth", .handler = handleAuth };
// main.zig iterates registered commands
```

### 2. Build System Simplification
- Auto-discover modules by convention (src/commands/*.zig → command modules)
- Reduce build.zig to ~100 lines by using module dependency inference
- Consider a `modules.zig` manifest file

### 3. ArrayList Standardization
Pick ONE ArrayList API project-wide. Either:
- Migrate everything to `array_list_compat.ArrayList` (consistent API, no allocator in append/deinit)
- Or remove `array_list_compat` and use `std.ArrayList` everywhere (Zig standard)

### 4. TUI Widget Extraction
Break chat_tui_app.zig into widget modules:
- `src/tui/widgets/header.zig` — HeaderWidget
- `src/tui/widgets/sidebar.zig` — SidebarWidget
- `src/tui/widgets/input.zig` — InputWidget
- `src/tui/widgets/messages.zig` — MessageWidget, MessageContentWidget
- `src/tui/widgets/permission.zig` — PermissionDialogWidget
- `src/tui/widgets/palette.zig` — CommandPaletteWidget

### 5. Error Type Hierarchy
Create `src/errors.zig` with domain-specific error sets instead of using `error.Foo` everywhere.

## Breadcrumbs

### Files most affected by these changes:
- `build.zig` (391 lines) — needs major simplification
- `src/main.zig` (283 lines) — dispatch rewrite
- `src/commands/handlers.zig` (229 lines) — becomes thinner
- `src/tui/chat_tui_app.zig` (4279 lines) — widget extraction
- `src/compat/array_list.zig` (126 lines) — standardization decision

### Patterns to preserve:
- `array_list_compat.ArrayList` wrapper pattern (if keeping it)
- `imp()` / `addImports()` build.zig helpers
- `inline fn out()` output pattern in CLI commands
- Widget struct pattern: `fn widget()`, `fn draw()`, `fn typeErasedDrawFn()`

### Patterns to eliminate:
- Manual module registration in build.zig
- 30+ branch if-else command dispatch
- Mixed ArrayList usage
- 4000+ line single-file TUI

## Success Criteria

- [ ] New commands added with 1 file + 1 build.zig line (not 4 files + 3 edits)
- [ ] build.zig under 200 lines
- [ ] All files use same ArrayList API
- [ ] No single file over 1500 lines
- [ ] Command dispatch O(1) lookup (hash map or comptime switch)
