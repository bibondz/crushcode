# UI-SPEC.md: Productivity-Focused libvaxis TUI Upgrade

**Phase**: 23 - UI/UX Upgrade
**Status**: Design Contract
**Framework**: libvaxis (vxfw widgets)
**Language**: Zig
**References**: `/mnt/d/crushcode-references/{crush,opencode,open-claude-code,claude-code}`

---

## 1. Design Goal

Transform single-pane chat into a multi-modal coding assistant TUI with:
- **Crush efficiency**: Responsive layout, stacked dialogs, keyboard-first
- **OpenCode orchestration**: Agent status, tool execution visuals
- **Claude usability**: Conversational flow, message actions, thinking indicators

---

## 2. Current State (What Exists)

```
┌──────────────────────────────────────────────┐
│ HEADER (2 rows): version | provider/model    │  ← WASTES 2 rows
│──────────────────────────────────────────────│
│ GRADIENT branding (1 row)                    │  ← WASTES 1 row (decorative only)
├──────────────────────────────────────────────┤
│                                              │
│  MESSAGE BODY (scrollable)                   │  ← Only ~17 rows on 24-row terminal
│  - RoleLabel + Markdown/Plain/Diff/ToolCall  │
│                                              │
├──────────────────────────────────────────────┤
│ FILES BAR (1 row): recent file paths         │  ← WASTES 1 row (rarely useful)
├──────────────────────────────────────────────┤
│ STATUS BAR (1 row): tokens/cost/turn/time    │
├──────────────────────────────────────────────┤
│ INPUT (1 row): "❯ " + TextField             │
└──────────────────────────────────────────────┘
  [SIDEBAR toggle Ctrl-B, 30 cols]

SPACE WASTE: 4 rows on chrome (header×2 + branding + files bar)
```

**Current problem**: 4 rows wasted on chrome → message body only gets ~17 rows on a 24-row terminal. User wants **maximum content area**.

**Working**: Streaming chat, tool execution (10 iterations), permission dialogs, command palette (Ctrl+P), session save/resume, provider fallback, markdown rendering (4 langs), diff visualization, gradient branding, animated spinner, toast notifications, typewriter effect, 3 themes, setup wizard.

**Critical Gaps**: Single-line input, no keyboard scroll, typewriter not wired to streaming, no message actions, no autocomplete.

---

## 3. Target State (After Upgrade)

### 3.0 Design Principle: Maximize Content Area

> **User requirement**: "อยากให้มีพื้นที่แสดงผลกว้างๆ — อนิเมชั่นไม่ต้องกินเนื้อที่มาก"

Every row and column is precious. The layout must:
- **Minimize chrome**: Header 1 row (not 2), no separate branding row, no files bar
- **Inline everything**: Animations live inside message content, not in separate rows
- **Sidebar on-demand only**: Hidden by default, toggled via Ctrl+B
- **Compact status**: Single row combining status + context bar + mode indicator

**Space budget per screen (24-row terminal, sidebar hidden):**

| Zone | Rows | Notes |
|------|------|-------|
| Header | 1 | provider/model + context bar merged |
| Message body | ~19 | **Maximum possible** — the main work area |
| Input | 3-4 | Multi-line, grows when needed |
| **Total chrome** | **1-2 rows** | Only header + input border |

### 3.1 Layout: Maximized Content Area

```
FULL MODE — SIDEBAR HIDDEN (default, all widths):
┌──────────────────────────────────────────────────┐
│ ollama/llama3.2 │ 68% (87K/128K) ██████░░ │ 12t │  ← 1 row header (merged)
├──────────────────────────────────────────────────┤
│                                                  │
│  MESSAGE BODY (maximum height ~19 rows)          │
│                                                  │
│  ✦ Here's the implementation...  ◠ Thinking...   │  ← animation INLINE
│  ✦ Tool: shell ██████░░ 67%                     │  ← progress INLINE
│  ✦ Done. [c]opy [r]e-run                        │  ← actions INLINE
│                                                  │
├──────────────────────────────────────────────────┤
│ ❯ multi-line input...                            │  ← 3-4 rows
│    with Shift+Enter for newlines                 │
│    /autocomplete popup here                      │
└──────────────────────────────────────────────────┘

FULL MODE — SIDEBAR SHOWN (Ctrl+B, >= 120 cols only):
┌──────────────────────────────────────┬───────────┐
│ ollama/llama3.2 │ 68% ██████░░ │ 12t │ Sessions  │  ← 1 row
├──────────────────────────────────────┤ • abc123  │
│                                      │ • def456  │
│  MESSAGE BODY (maximum height)       │ ──────── │
│                                      │ Workers  │
│                                      │ • none   │
│                                      │ ──────── │
│                                      │ Model    │
│                                      │ llama3.2 │
├──────────────────────────────────────┤ ──────── │
│ ❯ multi-line input...                │ [d]ark    │  ← 3-4 rows
└──────────────────────────────────────┴───────────┘

COMPACT MODE (< 120 cols or < 30 rows):
┌──────────────────────────────┐
│ llama3.2 │ 68% ████░░ │ 12t │  ← 1 row, ultra-compact
├──────────────────────────────┤
│ MESSAGE BODY (max height)    │
│                              │
│                              │
├──────────────────────────────┤
│ ❯ input...                   │  ← 2-3 rows
└──────────────────────────────┘
```

### 3.1.1 Animation Space Constraints

**Rule: Animations must be inline, never consume their own row.**

| Animation | How | Space Used |
|-----------|-----|------------|
| Spinner (Thinking) | `◠◡◔◕` inline with text: `✦ Thinking... ◠` | 0 extra rows — appended to message |
| Typewriter | Character-by-character reveal in existing message text | 0 extra rows — replaces message content |
| Tool progress | Inline bar: `Tool: shell ██████░░ 67%` | 0 extra rows — inside tool call widget |
| Toast | Overlaid on message body top-right corner, not a separate row | 0 extra rows — float overlay |
| Message appear | Fade-in on existing message row | 0 extra rows — style change only |
| Gradient branding | Removed from layout — branding goes into header title only | **-1 row saved** |

**Eliminated from layout** (was wasting space):
- ~~Gradient branding row~~ (1 row saved) → branding merged into header text
- ~~Files bar row~~ (1 row saved) → moved to sidebar only
- ~~Separate context bar row~~ (1 row saved) → merged into header

**Net result: +3 rows for message body compared to current layout.**

### 3.2 Component Specifications

---

#### 3.2.1 P0: Multi-line Input Editor

**Current**: `vxfw.TextField` (1 row, single line)
**Target**: Multi-line editor with 3-5 row height

| Feature | Spec | libvaxis Component |
|---------|------|--------------------|
| Height | 3 rows idle, 5 rows when content > 2 lines | Dynamic `TextField` height |
| Newline | Shift+Enter inserts newline, Enter sends | Key event handler in `onKey` |
| History | Up/Down arrow cycles input history | `input_history` ArrayList |
| Paste | Bracketed paste support (multi-line) | vaxis paste events |
| External editor | Ctrl+E opens $EDITOR for long input | `std.process.Child` spawn |
| Autocomplete | `/` triggers command completion popup | Custom `CompletionsPopup` widget |

**Reference**: Crush uses `\` line continuation + Ctrl+E external editor (ref: `crush/internal/ui/model/editor.go`)
**Reference**: OpenCode has attachment chips + busy state warning (ref: `opencode/internal/tui/components/chat/editor.go`)

**Implementation Files**:
- `src/tui/widgets/input.zig` → rewrite with multi-line support
- `src/tui/chat_tui_app.zig` → update `resetInputField`, `onSubmit`, key handling

---

#### 3.2.2 P0: Wire Typewriter to Streaming Messages

**Current**: `TypewriterState` exists but `MessageContentWidget` renders full `message.content` immediately
**Target**: Streaming messages reveal character-by-character via typewriter

| Spec | Detail |
|------|--------|
| Activate | When `request_active == true` and message is last assistant message |
| Reveal rate | 30-80ms per character (already implemented in `TypewriterState`) |
| Cursor | Blinking `▌` at reveal boundary |
| Completion | On stream end, reveal all remaining text instantly |
| Freeze | When message scrolls above viewport, freeze animation (OffscreenFreeze pattern) |

**Reference**: Claude Code's OffscreenFreeze pattern freezes timers for off-screen messages (ref: `claude-code-from-source.com/ch13-terminal-ui/`)

**Implementation Files**:
- `src/tui/widgets/messages.zig` → `MessageContentWidget.draw()` check if message == active streaming
- `src/tui/chat_tui_app.zig` → `handleStreamToken()` calls `typewriter.updateText()`

---

#### 3.2.3 P1: Keyboard Message Scroll

**Current**: Mouse wheel only (`wheel_scroll = 3`)
**Target**: Full keyboard navigation

| Key | Action |
|-----|--------|
| `j` / `↓` | Scroll down 3 lines |
| `k` / `↑` | Scroll up 3 lines |
| `PgDn` / `Space` | Scroll down 1 page |
| `PgUp` / `b` | Scroll up 1 page |
| `G` | Jump to bottom (latest) |
| `g` | Jump to top |
| `Enter` | If scrolled up, snap to bottom first |

**Constraint**: These keys must only activate when input field is NOT focused (or when in "scroll mode" via Escape)

**Reference**: Crush uses hjkl navigation in message list (ref: `crush/internal/ui/model/keys.go`)
**Reference**: OpenCode has similar scroll bindings

**Implementation Files**:
- `src/tui/chat_tui_app.zig` → add key handlers in `handleKeyEvent`

---

#### 3.2.4 P1: Context Window Progress Bar

**Current**: Status bar shows raw `usage:{d}%`
**Target**: Visual progress bar with color thresholds

```
CONTEXT BAR:
████████░░░░░░░ 52% (66K/128K)     ← green (0-70%)
████████████░░░ 85% (109K/128K)     ← yellow (70-90%)
███████████████ 95% (122K/128K)     ← red (90-100%) + ⚠ warning
```

| Color | Range | Meaning |
|-------|-------|---------|
| `theme.success` | 0-70% | Comfortable |
| `theme.warning` | 70-90% | Getting tight |
| `theme.error` | 90-100% | Need /compact or new session |

**Reference**: OpenCode shows token usage in status bar (ref: `opencode/internal/tui/theme/`)
**Reference**: Crush shows context percentage in header

**Implementation Files**:
- `src/tui/chat_tui_app.zig` → add `ContextBarWidget` or extend status bar drawing
- New: `src/tui/widgets/context_bar.zig`

---

#### 3.2.5 P1: Message Actions

**Current**: Messages are display-only
**Target**: Hover/select actions on messages

| Action | Trigger | Behavior |
|--------|---------|----------|
| Copy | `y` on selected message | Copy message content to clipboard |
| Edit | `e` on user message | Load message text into input for re-editing |
| Re-send | Enter on edited message | Submit edited message as new user message |
| Select | `v` or click | Enter visual selection mode |

**Reference**: Claude Code supports message editing and re-sending
**Reference**: Crush has text selection with UAX#29 word boundaries

**Implementation Files**:
- `src/tui/chat_tui_app.zig` → message selection state, action handlers
- `src/tui/widgets/messages.zig` → action indicators in draw

---

#### 3.2.6 P2: Command Autocomplete

**Current**: Command palette (Ctrl+P) with fuzzy filter
**Target**: Inline `/` autocomplete + enhanced palette

| Feature | Spec |
|---------|------|
| Trigger | Type `/` in input field |
| Popup | Shows matching commands below cursor |
| Navigate | Up/Down to select, Tab/Enter to complete |
| Dismiss | Escape or continue typing |
| Sort | Recent commands first, then alphabetical |

**Reference**: Crush's `@`-triggered completions with tiered priority (ref: `crush/internal/ui/completions/completions.go`)

**Implementation Files**:
- New: `src/tui/widgets/autocomplete.zig`
- `src/tui/widgets/input.zig` → integrate autocomplete trigger
- `src/tui/chat_tui_app.zig` → handle autocomplete events

---

#### 3.2.7 P2: Inline Tool Action Buttons

**Current**: Tool calls show status icon (●/✓/✗) only
**Target**: Interactive action buttons on completed tool calls

```
✓ Shell: ls -la
  ┌──────────────────────────────────────┐
  │ -rw-r--r-- 1 user user 4096 Apr 15.. │
  │ drwxr-xr-x 2 user user 4096 Apr 15.. │
  └──────────────────────────────────────┘
  [c]opy  [r]e-run  [e]xpand
```

| Button | Key | Action |
|--------|-----|--------|
| Copy | `c` | Copy tool output to clipboard |
| Re-run | `r` | Re-execute the tool call |
| Expand | `e` | Toggle full/minimized output |

**Reference**: Claude Code has inline action buttons on tool results
**Reference**: Crush has expandable tool outputs with click

**Implementation Files**:
- `src/tui/widgets/messages.zig` → `ToolCallWidget` add action buttons

---

#### 3.2.8 P2: Message Bubble Styling

**Current**: Messages are flat text with role label prefix
**Target**: Distinctive visual containers for each message type

```
 ┌─────────────────────────────────────────┐
 │ ✦ Assistant                              │
 │                                          │
 │ Here's the implementation for your       │
 │ request. The code uses zig stdlib...     │
 │                                          │
 │ ┌─ src/main.zig ──────────────────────┐ │
 │ │ const std = @import("std");          │ │
 │ │ pub fn main() !void {               │ │
 │ │     std.debug.print("hello", .{});  │ │
 │ │ }                                    │ │
 │ └──────────────────────────────────────┘ │
 └─────────────────────────────────────────┘

  You: can you fix the bug in auth?
       ^^^^ plain, no border, just dimmed role
```

| Element | Style |
|---------|-------|
| Assistant messages | Rounded border, subtle bg tint (`theme.code_bg`) |
| User messages | No border, left-aligned, compact |
| Tool calls | Solid border, monospace bg, status icon colored |
| Errors | Red-tinted border + background |
| Code blocks | Border with filename header, syntax highlighted |

**Reference**: Claude Code's message bubbles with distinct visual hierarchy
**Reference**: Crush's expandable tool output containers

**Implementation Files**:
- `src/tui/widgets/messages.zig` → add border/bg to `MessageContentWidget`

---

#### 3.2.9 P2: Role Icons & Status Indicators

**Current**: Plain text role labels ("You:", "✦:", "Error:")
**Target**: Rich visual indicators

| Role | Current | Target |
|------|---------|--------|
| Assistant | `✦` | Gradient animated icon + subtle glow effect |
| User | `You:` | `❯` in accent color |
| Error | `Error:` | `✗` in red with dimmed bg |
| Tool pending | `●` | Animated braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` |
| Tool success | `✓` | Green checkmark with subtle pulse |
| Tool failed | `✗` | Red X with error styling |

**Reference**: Crush uses color-cycling gradient spinners at 20 FPS (ref: `crush/internal/ui/model/`)
**Reference**: Current `widget_spinner.zig` already has braille animation — wire it into message rendering

**Implementation Files**:
- `src/tui/widgets/messages.zig` → update `RoleLabelWidget`
- `src/tui/widgets/helpers.zig` → add role icon definitions

---

#### 3.2.10 P3: Smooth Transitions & Micro-animations

**Current**: Instant state changes, no transitions
**Target**: Subtle animations that communicate state changes

| Animation | Trigger | Duration | Style |
|-----------|---------|----------|-------|
| Message appear | New message added | 200ms | Fade in (dim→normal) |
| Tool complete | Tool finishes executing | 300ms | Spinner → ✓ transition |
| Panel toggle | Ctrl+B sidebar | 150ms | Slide in/out |
| Theme switch | `/theme dark` | 100ms | Instant (no animation needed) |
| Input resize | Multi-line grows | 100ms | Height grows smoothly |

**Reference**: Crush's staggered character birth effects for streaming text
**Reference**: Claude Code's OffscreenFreeze pattern for performance

**Implementation**: Use existing 30 FPS tick loop — track `animation_start_ms` per element, compute progress `0.0-1.0`, apply opacity/position interpolation.

---

#### 3.2.11 P3: Enhanced Gradient Branding

**Current**: Static gradient text "Crushcode" in header
**Target**: Animated gradient that subtly shifts over time

```
Current:  C ru s h c o d e     (static gradient)
Target:   C ru s h c o d e     (gradient shifts hue slowly, ~10s cycle)
```

**Reference**: Current `widget_gradient.zig` already supports per-character gradient colors — add time-based hue rotation.

**Implementation Files**:
- `src/tui/widgets/gradient.zig` → add `tick()` method for hue rotation

---

#### 3.2.12 P3: More Built-in Themes

**Current**: 3 themes (dark, light, mono)
**Target**: 6-8 themes inspired by popular editor themes

| Theme | Inspiration | Palette Source |
|-------|-------------|----------------|
| Catppuccin Mocha | Popular warm dark | `opencode/internal/tui/theme/catppuccin.go` |
| Tokyo Night | Cool blue dark | OpenCode theme system |
| Gruvbox | Warm retro | OpenCode theme system |
| Dracula | Purple accent dark | OpenCode theme system |
| Nord | Blue-gray cool | OpenCode theme system |

**Reference**: OpenCode has 9 built-in themes with full color token sets (ref: `/mnt/d/crushcode-references/opencode/internal/tui/theme/`)

**Implementation Files**:
- `src/tui/theme.zig` → add theme presets

---

#### 3.2.13 P3: Sidebar Visual Polish

**Current**: Plain text sidebar with no visual hierarchy
**Target**: Well-structured sidebar with sections, icons, and separators

```
 SIDEBAR (28 cols):
 ┌────────────────────────────┐
 │ ⚡ Crushcode               │
 │ ────────────────────────── │
 │                            │
 │ 📂 Recent Files            │
 │   src/main.zig             │
 │   src/ai/client.zig        │
 │                            │
 │ 💬 Session                 │
 │   abc123 | 12 turns        │
 │   87K/128K tokens          │
 │   ████████░░ 68%           │
 │                            │
 │ 🤖 Model                   │
 │   ollama/llama3.2          │
 │                            │
 │ 🎨 Theme: dark             │
 │   [d]ark [l]ight [m]ono   │
 └────────────────────────────┘
```

| Element | Style |
|---------|-------|
| Section headers | Bold accent color + icon |
| Separators | Dim horizontal line |
| File paths | Truncated with `…` if too long |
| Token usage | Mini progress bar |
| Theme switcher | Inline key hints |

**Implementation Files**:
- `src/tui/widgets/sidebar.zig` → visual restructure

---

## 4. Keyboard Shortcut Map

### Global (always active)
| Key | Action |
|-----|--------|
| `Ctrl+P` | Command palette |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+C` | Cancel current request |
| `Ctrl+L` | Clear screen |

### Input Mode (default)
| Key | Action |
|-----|--------|
| `Enter` | Send message |
| `Shift+Enter` | New line |
| `Ctrl+E` | Open external editor |
| `Up/Down` | Input history |
| `Escape` | Switch to scroll mode |
| `/` | Trigger command autocomplete |

### Scroll Mode (after Escape)
| Key | Action |
|-----|--------|
| `j/k` | Scroll down/up |
| `PgDn/PgUp` | Page scroll |
| `G/g` | Jump to bottom/top |
| `y` | Yank (copy) selected message |
| `e` | Edit selected user message |
| `Escape/i` | Return to input mode |

---

## 5. Theme Tokens Required

Based on analysis of OpenCode's 9 built-in themes (ref: `opencode/internal/tui/theme/`):

```zig
// New tokens to add to theme.zig
pub const Theme = struct {
    // ... existing tokens ...

    // New tokens for UI upgrade
    context_bar_bg: Color,      // Progress bar background
    context_bar_fill: Color,    // Progress bar fill
    context_bar_warn: Color,    // Warning threshold (70-90%)
    context_bar_danger: Color,  // Danger threshold (90%+)

    action_button: Color,       // Inline action button text
    action_button_bg: Color,    // Inline action button background

    autocomplete_bg: Color,     // Autocomplete popup background
    autocomplete_selected: Color, // Autocomplete selected item
    autocomplete_border: Color, // Autocomplete popup border

    scroll_mode_indicator: Color, // Visual indicator when in scroll mode
};
```

---

## 6. Implementation Priority Order

### Usability (ความสะดวก)
| Priority | Feature | Effort | Impact | Files Changed |
|----------|---------|--------|--------|---------------|
| P0 | Multi-line input | Medium | Critical | `input.zig`, `chat_tui_app.zig` |
| P0 | Wire typewriter | Low | High | `messages.zig`, `chat_tui_app.zig` |
| P1 | Keyboard scroll | Low | High | `chat_tui_app.zig` |
| P1 | Context bar | Low | High | New `context_bar.zig` |
| P1 | Message actions | Medium | High | `messages.zig`, `chat_tui_app.zig` |
| P2 | Autocomplete | Medium | High | New `autocomplete.zig`, `input.zig` |
| P2 | Tool action buttons | Medium | Medium | `messages.zig` |

### Visual (ความสวย)
| Priority | Feature | Effort | Impact | Files Changed |
|----------|---------|--------|--------|---------------|
| P2 | Message bubble styling | Medium | High | `messages.zig` |
| P2 | Role icons & status indicators | Low | Medium | `messages.zig`, `helpers.zig` |
| P3 | Smooth transitions | Medium | Medium | `chat_tui_app.zig`, multiple widgets |
| P3 | Animated gradient branding | Low | Low | `gradient.zig` |
| P3 | More built-in themes | Low | Medium | `theme.zig` |
| P3 | Sidebar visual polish | Medium | Medium | `sidebar.zig` |

---

## 7. Acceptance Criteria

### P0 (Must Have)
- [ ] Input field supports 3-5 rows with Shift+Enter for newlines
- [ ] Streaming assistant messages reveal character-by-character with typewriter effect
- [ ] Typewriter animation completes instantly on stream end
- [ ] Build passes with `zig build`
- [ ] No regression in existing chat functionality

### P1 (Should Have)
- [ ] `j/k/PgUp/PgDn/G/g` scroll messages when in scroll mode
- [ ] Context bar shows visual progress with green/yellow/red thresholds
- [ ] `y` copies selected message, `e` edits user message
- [ ] Escape toggles between input and scroll mode

### P2 (Nice to Have)
- [ ] `/` triggers inline autocomplete popup for commands
- [ ] Tool call widgets show copy/re-run/expand action buttons
- [ ] Autocomplete popup navigable with Up/Down + Tab
- [ ] Assistant messages have rounded border + subtle bg tint
- [ ] Role labels use rich icons (❯ for user, gradient ✦ for assistant)
- [ ] Tool status uses animated braille spinner → ✓ transition

### P3 (Polish)
- [ ] Messages fade in on appear (200ms)
- [ ] Sidebar slides in/out on Ctrl+B toggle (150ms)
- [ ] Gradient branding slowly shifts hue over time
- [ ] At least 5 built-in themes (dark, light, mono, catppuccin, tokyo night)
- [ ] Sidebar has section headers with icons + separators

---

## 8. Reference Source Locations

| Pattern | Reference File |
|---------|---------------|
| Crush responsive layout | `/mnt/d/crushcode-references/crush/internal/ui/model/ui.go` |
| Crush dialog system | `/mnt/d/crushcode-references/crush/internal/ui/dialog/` |
| Crush completions | `/mnt/d/crushcode-references/crush/internal/ui/completions/` |
| Crush editor | `/mnt/d/crushcode-references/crush/internal/ui/model/editor.go` |
| Crush key bindings | `/mnt/d/crushcode-references/crush/internal/ui/model/keys.go` |
| OpenCode themes | `/mnt/d/crushcode-references/opencode/internal/tui/theme/` |
| OpenCode editor | `/mnt/d/crushcode-references/opencode/internal/tui/components/chat/editor.go` |
| OpenCode commands | `/mnt/d/crushcode-references/opencode/internal/tui/components/dialog/commands.go` |
| Claude Code rendering | `/mnt/d/crushcode-references/claude-code/` (React/Ink based) |

---

## 9. Out of Scope

- Vim mode (deferred - requires major TUI rewrite per improvement plan)
- Side-by-side diff viewer (existing unified diff is sufficient)
- Mouse text selection with UAX#29 (complex, low priority)
- Model hot-swap UI (already exists in core, needs TUI wiring separately)
- Theme marketplace (3 built-in themes sufficient for now)
