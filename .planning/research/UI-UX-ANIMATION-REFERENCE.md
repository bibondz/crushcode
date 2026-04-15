# UI/UX & Animation Reference — Research from References

Created: 2026-04-14
Sources: crush, opencode, claude-code, cavekit, open-claude-code, multica

---

## 1. Animation Patterns

### 1.1 Spinners & Loading Indicators

**Frame-based spinners** (crush, claude-code):
- `crush/internal/ui/anim/anim.go` — FPS-based animated spinners with gradient color cycling
  - Staggered entrance effects (elements appear one by one with delay)
  - Ellipsis animation (loading...)
  - Birth offset for smooth transitions
- `claude-code/src/components/Spinner.tsx` — Multi-state spinner
  - 10-frame character cycling with color interpolation
  - **Stalled detection**: transitions to red spinner when streaming stops (`useStalledAnimation.ts`)
  - Shimmer chars and flashing chars for visual variety
  - Token counter updates during loading
  - Elapsed time display

**Spinner architecture pattern** (cavekit):
- Periodic animation ticks via Bubble Tea `TickMsg`
- Separate tick rate for spinners vs toasts
- Animation pauses when terminal unfocused

**Adapt for crushcode:**
```
Spinner struct:
  frames: []const []const u8  // ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
  frame_idx: usize
  color_cycle: bool           // cycle through gradient colors
  stalled: bool               // red color when no update for N seconds
  birth_offset: u64           // delay before starting (ms)
  
  tick() → advances frame, checks stall timeout
  render() → current frame char with color
```

### 1.2 Text Reveal & Typewriter

**Typewriter effect** (opencode):
- `opencode/packages/ui/src/components/typewriter.tsx`
- Randomized character delays (30-100ms) for natural feel
- Cursor blinking at end of text
- Pause detection for thinking moments

**Text reveal with spring physics** (opencode):
- `opencode/packages/ui/src/components/text-reveal.tsx`
- Gradient mask for fade-in effect
- Spring-based smooth transitions
- Font loading detection before animation starts

**Adapt for crushcode:**
```
Typewriter struct:
  text: []const u8
  revealed: usize
  delay_ms: u64            // per-character delay
  randomize: bool          // add jitter to delays
  
  tick() → reveal next char
  render() → revealed text + blinking cursor
```

### 1.3 Number Animations

**Odometer-style counter** (opencode):
- `opencode/packages/ui/src/components/animated-number.tsx`
- Digits spin with directional transitions
- Used for token counts, costs, metrics

### 1.4 Entrance Animations

**Staggered fade-up** (opencode):
- `opencode/packages/ui/src/styles/animations.css`
- Elements fade in from below with increasing delays
- `animation-delay: calc(var(--i) * 50ms)` for CSS
- In TUI: apply delay per-message in list

## 2. Visual Design Systems

### 2.1 Color Palettes

**Charmtone palette** (crush):
- `crush/internal/ui/styles/styles.go` — comprehensive design system
- Semantic colors: `primary`, `secondary`, `success`, `warning`, `error`, `dimmed`
- Message-specific: `user_msg_fg`, `assistant_msg_fg`, `tool_call_fg`
- UI elements: `header_bg`, `border`, `selection`, `cursor`
- Gradient support for branding

**600+ CSS custom properties** (opencode):
- `opencode/packages/ui/src/styles/theme.css`
- Semantic palettes: yuzu (yellow), cobalt (blue), apple (green), ember (red)
- Alpha variants for backgrounds
- Typography scale, spacing system, shadow system

**Theme with diff colors** (claude-code):
- `claude-code/src/utils/theme.ts`
- Color palettes for diff: addition, deletion, modification
- Syntax highlighting colors for code blocks
- Light/dark/system mode detection

### 2.2 Gradient Text

**Gradient rendering** (crush):
- `crush/internal/ui/styles/grad.go`
- Horizontal color gradient on text
- Used for logo, titles, branding
- Algorithm: interpolate RGB between N color stops across string width

### 2.3 ASCII Art Logo

**Randomized logo** (crush):
- `crush/internal/ui/logo/logo.go`
- ASCII art with randomized stretching effects
- Gradient text coloring

## 3. Layout Patterns

### 3.1 Three-Panel Layout (crush)

```
┌──────────┬────────────────────────────────────┐
│ Sidebar  │  Header (model, status, cost)       │
│          ├────────────────────────────────────┤
│ Session  │                                      │
│ Model    │  Chat Messages                       │
│ Files    │  (scrollable, mouse support)          │
│ LSP ✓/✗  │                                      │
│ MCP ✓/✗  │                                      │
│          ├────────────────────────────────────┤
│          │  Input Area                          │
│          │  [type here...]                       │
├──────────┴────────────────────────────────────┤
│ Status Bar (help, notifications, keybinds)       │
└─────────────────────────────────────────────────┘
```

**Focus management**: sidebar ↔ editor ↔ dialogs
**Mouse support**: click, double-click, drag selection, wheel scroll

### 3.2 Sidebar (opencode)

- `opencode/packages/opencode/src/cli/cmd/tui/routes/session/sidebar.tsx`
- Scrollable content with title and footer slots
- Overlay positioning (slides over content or pushes)
- Sections: session info, model details, file list, status indicators

### 3.3 Status Bar (crush)

- `crush/internal/ui/model/status.go`
- Context-sensitive help (changes based on focus)
- Notification display with auto-dismiss
- Keybinding hints

## 4. Rich Content Rendering

### 4.1 Markdown (crush, opencode)

- **crush**: Glamour-based rendering with custom styles
  - `crush/internal/ui/common/markdown.go`
  - Code blocks with syntax highlighting
  - Tables, lists, blockquotes, links
  
- **opencode**: Rich markdown with streaming support
  - `opencode/packages/ui/src/components/markdown.tsx`
  - Copy-to-clipboard buttons on code blocks
  - Link detection with hover preview
  - Streaming: incremental rendering as tokens arrive

### 4.2 Syntax Highlighting (crush, claude-code)

- **crush**: Chroma-based highlighting
  - `crush/internal/ui/common/highlight.go`
  - Multiple themes (monokai, github, etc.)
  
- **claude-code**: Custom highlighter
  - `web/components/tools/SyntaxHighlight.tsx`
  - GitHub dark/light themes
  - Web worker for async highlighting

### 4.3 Diff View (crush, claude-code)

- **crush**: Unified + split diff
  - `crush/internal/ui/diffview/diffview.go` + `style.go`
  - Line numbers, syntax highlighting
  - Light/dark theme support
  - Added lines green, removed lines red, context dimmed
  
- **claude-code**: Structured diff
  - `src/components/StructuredDiff.tsx`
  - Word-level highlighting within changed lines
  - Expand/collapse for long diffs
  - Diff bars showing proportional changes

### 4.4 Image Display (crush)

- `crush/internal/ui/image/image.go`
- Kitty graphics protocol support
- Block character fallback for unsupported terminals
- Sixel protocol support

## 5. Interactive Components

### 5.1 Permission Dialogs (claude-code)

- Comprehensive permission system with 15+ permission types
- Each type has dedicated UI: bash, file write, file edit, web fetch, etc.
- Rule-based permission management
- "Always allow" with workspace scoping

### 5.2 Command Palette

- Fuzzy finder with syntax-highlighted preview (claude-code: `QuickOpenDialog.tsx`)
- Keyboard navigation, filtering, completion

### 5.3 Tool Call Visualization (claude-code)

- `src/components/tasks/renderToolActivity.tsx`
- Status indicators (pending/running/complete/error)
- Expand/collapse for tool details
- Background task management

### 5.4 Toast Notifications

- Auto-dismiss with progress bar
- Spring animations for enter/exit
- Stack management for multiple toasts

### 5.5 Progress Bars

- ASCII-based with filled/empty characters (cavekit)
- Configurable width and style
- Value labels with percentage

## 6. Key Files to Study in Detail

| Priority | File | Why |
|----------|------|-----|
| ⭐⭐⭐ | crush/internal/ui/anim/anim.go | Spinner + animation architecture |
| ⭐⭐⭐ | crush/internal/ui/styles/styles.go | Design system foundation |
| ⭐⭐⭐ | crush/internal/ui/styles/grad.go | Gradient text rendering |
| ⭐⭐⭐ | opencode/packages/ui/src/components/typewriter.tsx | Typewriter animation |
| ⭐⭐ | crush/internal/ui/model/status.go | Status bar pattern |
| ⭐⭐ | crush/internal/ui/diffview/diffview.go | Diff rendering |
| ⭐⭐ | claude-code/src/components/Spinner.tsx | Multi-state spinner |
| ⭐⭐ | claude-code/src/components/StructuredDiff.tsx | Word-level diff |
| ⭐⭐ | opencode/packages/ui/src/styles/theme.css | Design token system |
| ⭐ | crush/internal/ui/common/markdown.go | Markdown rendering |
| ⭐ | crush/internal/ui/image/image.go | Terminal image display |
| ⭐ | cavekit/internal/tui/progressbar.go | ASCII progress bar |

## 7. Priority Implementation Order for crushcode

1. **Animated spinner** — highest impact, simplest to implement
   - Frame-based with gradient colors
   - Stalled detection (turns red when no token received)
   
2. **Gradient text for header/logo** — visual polish
   - RGB interpolation across text width
   
3. **Diff word-level highlighting** — code review UX
   - Highlight changed words within diff lines
   
4. **Typewriter effect for streaming** — premium feel
   - Randomized per-character delay
   - Blinking cursor at end
   
5. **Toast notifications** — user feedback
   - Auto-dismiss with animation
   - Stack management
   
6. **Progress bars** — long operation UX
   - ASCII-based with percentage labels
   
7. **Staggered entrance for messages** — smooth feel
   - Messages fade in with increasing delay
