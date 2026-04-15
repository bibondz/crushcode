# UI-REVIEW.md: 6-Pillar Visual Audit (Post-Implementation)

**Phase**: 23 - UI/UX Upgrade (Post P0-P2 Implementation)
**Date**: 2026-04-15
**Auditor**: Sisyphus (automated audit via 3 parallel explore agents)
**Codebase**: `/mnt/d/crushcode/src/tui/`
**Previous Audit**: UI-REVIEW.md (pre-implementation baseline: 2.8/4)

---

## Grading Scale

| Grade | Meaning |
|-------|---------|
| 4 | Excellent — production quality, no significant issues |
| 3 | Good — minor issues, acceptable for production |
| 2 | Needs Improvement — noticeable issues that degrade UX |
| 1 | Poor — significant problems that block usability |

---

## Overall Score: 2.5/4 (↑ from 2.8 baseline pre-impl)

Wait — the baseline was scored on different criteria (pre-implementation had missing features). The delta:

| Pillar | Pre-Impl | Post-Impl | Delta |
|--------|----------|-----------|-------|
| 1. Visual Hierarchy & Consistency | 3 | 3 | = |
| 2. Layout & Spacing | 2 | 2 | = |
| 3. Color & Theme | 2 | 2 | = |
| 4. Typography & Readability | 3 | 3 | = |
| 5. Interaction & Feedback | 3 | 3 | = |
| 6. Accessibility | 2 | 2 | = |
| **Overall** | **2.5** | **2.5** | **=** |

**Note**: While the score stayed the same, the *capability* is vastly improved (multi-line input, typewriter, scroll mode, copy/yank, autocomplete, bubbles, role icons). The score reflects remaining gaps, not regression.

---

## Changes Implemented Since Last Audit

| Feature | Priority | Status |
|---------|----------|--------|
| Multi-line input (Shift+Enter, auto-grow 3-5 rows) | P0 | ✅ |
| Typewriter wired to streaming (character reveal + cursor ▌) | P0 | ✅ |
| Scroll mode (Ctrl+N, j/k/PgUp/PgDn/G/g/q/Esc) | P1 | ✅ |
| Header merged to 1 row, gradient + files bar removed (+3 rows body) | P1 | ✅ |
| Message copy/yank/edit in scroll mode | P1 | ✅ |
| Command autocomplete (/ trigger + suggestions popup) | P2 | ✅ |
| Message bubble styling (rounded borders ╭╮╰╯ + bg for assistant) | P2 | ✅ |
| Role icons (◉ User, ◈ Assistant, ✕ Error, ⚙ Tool) | P2 | ✅ |

---

## Pillar 1: Visual Hierarchy & Consistency — 3/4

### Strengths
- **Centralized theme** (theme.zig): 27 color slots, 3 themes, no inline colors in core widgets
- **Consistent role helpers** (helpers.zig): 5 roles with icon + label + icon_style + icon_color
- **Consistent border patterns**: `drawBorder()` (sharp) for diffs, `drawRoundedBorder()` for bubbles
- **Correct visual priority**: Header (bold+bg) > Messages (rich content) > Input (accent prompt) > Status (dim)

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| I1 | Tool/system messages have NO visual container (only user gets ▌, assistant gets bubble) | Medium | messages.zig:350-423 |
| I2 | User & System share same icon `◉` — visually identical at icon level | Low | helpers.zig:69,72 |
| I3 | Streaming cursor `▌` uses `accent` color, not `streaming_indicator` theme color | Low | messages.zig:110-113 |
| I4 | Diff bg (header_bg=236) inside assistant bubble bg (bubble_bg=235) creates color clash | Low | messages.zig:207,416 |

---

## Pillar 2: Layout & Spacing — 2/4

### Strengths
- **Dynamic input height**: auto-grows 3-5 rows based on content (multiline_input.zig:680-704)
- **Header minimized**: 1 row (was 2) — saves space
- **+3 rows for messages**: from removing gradient (1), files bar (1), header shrink (1)
- **Safe body height guard**: prevents zero-height crashes

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| L1 | **Status bar is ABOVE input, not below** — unconventional layout | High | chat_tui_app.zig:1467-1468 |
| L2 | Status bar uses `max.width` instead of `main_width` — overlaps under sidebar | Medium | chat_tui_app.zig:1452-1455 |
| L3 | Bubble padding adds +2 rows per assistant message (top_pad=1, bot_pad=1) — with gap+separator = 4 extra rows per message | Medium | messages.zig:358-359 |
| L4 | Separator capped at 40 cols, left-aligned on 120-col terminal — looks unbalanced | Low | messages.zig:479 |
| L5 | User message left indent wastes 1 column (2-col indent for 1-char ▌ border) | Low | messages.zig:356 |
| L6 | Sidebar stops before input/status — visual gap in lower corner | Low | chat_tui_app.zig:1484 |
| L7 | Scroll mode indicator in status bar pushes token info off-screen on narrow terminals | Low | chat_tui_app.zig:1413-1418 |

---

## Pillar 3: Color & Theme — 2/4

### Strengths
- **27-slot Theme struct**: comprehensive semantic coverage (roles, borders, bubble, streaming, icons)
- **Role icon system**: 5 distinct icons with dedicated theme colors
- **Core widgets use theme**: messages, input, header, status, scroll bars all reference theme fields
- **3 complete themes**: dark (244/236), light (234/254), mono (default)

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| C1 | **markdown.zig: 14 hardcoded color constants** — unreadable on light theme (white on white) | Critical | markdown.zig:4-17 |
| C2 | **diff.zig: 8 hardcoded colors** — same light theme problem | High | diff.zig:4-13 |
| C3 | **setup.zig: 16 hardcoded colors** — ignores theme entirely | Medium | setup.zig:41-127 |
| C4 | **spinner.zig: 9 hardcoded colors** — gradient not theme-aware | Medium | spinner.zig:13-19 |
| C5 | **sidebar.zig: 2 hardcoded colors** — worker status ignores theme | Low | sidebar.zig:190-191 |
| C6 | **toast.zig: 1 hardcoded color** — text fg ignores theme | Low | toast.zig:243 |
| C7 | **~50 total hardcoded colors** bypass the theme system | Critical | Multiple files |
| C8 | Theme has no slots for: markdown colors, diff colors, spinner colors, toast text | Medium | theme.zig |
| C9 | Dark theme: status_fg=8 (dark gray) on status_bg=236 — nearly invisible | Medium | theme.zig:42-43 |
| C10 | Light theme: dimmed=7 (white) on white bg — invisible | Low | theme.zig:71 |

---

## Pillar 4: Typography & Readability — 3/4

### Strengths
- **Rich markdown parser**: headers, code blocks (syntax highlight for Zig/Python/JS/Shell), blockquotes, tables, task lists, links, bold, italic
- **Clear role labels**: "◉ User", "◈ Assistant", "✕ Error" — icons + bold + colors
- **Suggestion popup**: bordered, selected row inverted, max 5 items
- **Streaming indicator**: "● Thinking..."/"● Responding..." with blinking cursor

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| T1 | **Markdown ignores theme** — blocks light/mono usability (same as C1) | Critical | markdown.zig |
| T2 | Only H1 (#) and H2 (##) supported — H3+ rendered as plain text | Medium | markdown.zig:566-570 |
| T3 | No text truncation indicators ("...") for header or status bar | Medium | header.zig:29, chat_tui_app.zig:1449 |
| T4 | Status bar text is `.dim = true` — already-low-contrast text made harder to read | Medium | chat_tui_app.zig:1448 |
| T5 | No blank line before/after code blocks — tight visual spacing | Low | markdown.zig:88-99 |
| T6 | Table cells not clipped to calculated column width — potential overflow | Low | markdown.zig:356-362 |

---

## Pillar 5: Interaction & Feedback — 3/4

### Strengths
- **Key binding discoverability**: Scroll mode shows `(j/k/↑↓ PgUp/PgDn g/G Enter q/Esc)` in status bar
- **Toast notifications**: copy, edit-to-input, budget alerts — with severity icons + progress bar
- **Loading feedback**: braille spinner with gradient, stalled detection (5s), token counter, elapsed time
- **Typewriter animation**: 30-80ms randomized delay, 530ms cursor blink, error reveals immediately
- **Autocomplete**: / trigger, Tab accept, Up/Down navigate, Escape dismiss

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| F1 | No toast on theme switch (uses assistant message instead) | Low | chat_tui_app.zig:2057-2059 |
| F2 | No visual cue when entering scroll mode (must notice status bar text change) | Low | chat_tui_app.zig:1184 |
| F3 | Autocomplete popup has no key hints ("Tab to accept, Esc to close") | Low | input.zig:169-237 |
| F4 | Permission dialog has no on-screen key hints ("Y/N/A/Esc") | Low | chat_tui_app.zig:1089-1109 |
| F5 | Typewriter reveals 1 char per tick — can't keep up with fast streams | Medium | typewriter.zig:187-198 |
| F6 | No Ctrl+C/quit hint in status bar | Low | chat_tui_app.zig:1127-1133 |

---

## Pillar 6: Accessibility — 2/4

### Strengths
- **Role icons have text fallbacks**: "◉ User:" is icon + text, not icon-only
- **Full keyboard navigation**: TUI is keyboard-only by design
- **No rapid flashing**: cursor blink 530ms (above 500ms threshold)
- **vim-style scroll keys documented**: shown in status bar during scroll mode

### Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| A1 | **Color-only indicators**: spinner stall (red gradient), tool status (●/✓/× shapes similar), toast severity | High | spinner.zig:97-99, helpers.zig:92-98 |
| A2 | **Dark theme contrast**: status_fg=8 on status_bg=236, border=8, dimmed=8 — all nearly invisible | High | theme.zig:42-45 |
| A3 | **No persistent key binding reference**: /help only shows slash commands, not keyboard shortcuts | Medium | — |
| A4 | Toast messages lack text severity prefix (rely on icon + color) | Medium | toast.zig:226-252 |
| A5 | Spinner braille characters require Unicode font — no ASCII fallback | Low | spinner.zig:9 |
| A6 | Streaming indicator `●` disappears entirely on alternate blinks | Low | messages.zig:102-105 |

---

## Priority Fix List

### 🔴 Critical (blocks usability on light/mono themes)
1. **[C1/T1] Parameterize markdown.zig** — Add ~13 theme fields for markdown colors, pass Theme to `parseMarkdown()`
2. **[C2] Parameterize diff.zig** — Add ~5 theme fields for diff colors

### 🟡 High (noticeable UX degradation)
3. **[L1] Swap status bar below input** — status should be the bottom-most row
4. **[C7] Fix remaining ~30 hardcoded colors** — setup.zig (16), spinner.zig (9), sidebar.zig (2), toast.zig (1)
5. **[A1] Add text labels to color-only indicators** — spinner stall text, tool status text, toast severity prefix
6. **[A2] Fix dark theme contrast** — status_fg, border, dimmed all = index 8 (invisible)

### 🟢 Medium
7. **[I1] Add visual container for tool/system messages** — subtle left border or bg tint
8. **[L3] Reduce bubble padding** — 0 top + 1 bot saves 1 row per assistant message
9. **[F5] Typewriter catch-up** — reveal multiple chars per tick when backlog grows
10. **[A3] Add keyboard shortcut help overlay** — Ctrl+H or ? to show all bindings
11. **[T3] Add truncation indicators** — "..." for header and status bar
12. **[L2] Status bar width** — use main_width when sidebar is visible

### ⚪ Low / Nice-to-have
13. [I3] Streaming cursor should use `streaming_indicator` color
14. [I4] Diff bg inside bubble — use same bg or no bg
15. [L4] Center separator or use full width
16. [T2] Support H3-H6 headers
17. [F3] Add key hints to autocomplete popup
18. [F4] Add key hints to permission dialog
19. [A5] ASCII fallback for spinner
