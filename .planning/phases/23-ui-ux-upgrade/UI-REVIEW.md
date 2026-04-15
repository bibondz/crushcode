# UI-REVIEW.md: 6-Pillar Visual Audit

**Phase**: 23 - UI/UX Upgrade (Pre-Implementation Baseline)
**Date**: 2026-04-15
**Auditor**: Sisyphus (automated audit)
**Codebase**: `/mnt/d/crushcode/src/tui/`

---

## Grading Scale

| Grade | Meaning |
|-------|---------|
| **4** | Excellent — best-in-class, no issues |
| **3** | Good — minor issues, polish needed |
| **2** | Fair — significant gaps, needs work |
| **1** | Poor — critical issues, must fix |

---

## Pillar 1: Visual Hierarchy — Grade: 3/4 (Good)

**What works:**
- Header (2 rows) uses bold title + dim separator — clear visual dominance (`header.zig:27-31`)
- Gradient branding line provides strong identity cue (`chat_tui_app.zig:1213-1219`)
- Role labels in messages use distinct styles per role (`messages.zig:31-41`)
- Input prompt uses bold accent color — immediately draws eye (`input.zig:27`)

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| Sidebar panel background uses `header_bg` instead of dedicated panel token | `sidebar.zig:256` | Medium |
| No explicit min-width guard in header/main layout for very narrow terminals | `chat_tui_app.zig:1209-1219` | Low |
| Message content area lacks visual containment — flat text with no border/bg differentiation | `messages.zig:62-88` | Medium |

**Recommendations:**
1. Add `panel_bg` theme token for sidebar and panel backgrounds
2. Add min-width guard (>= 20 cols) in main draw function
3. Add subtle background tint or border to assistant message blocks

---

## Pillar 2: Consistency — Grade: 3/4 (Good)

**What works:**
- All widgets use `theme.*` tokens — no hardcoded colors found
- `drawBorder()` helper is used consistently across sidebar, palette, permission, toast (`helpers.zig:198-222`)
- Text styling patterns (`.bold`, `.dim`, `.fg`) are uniform across all 13 widget files
- Spacing uses row/col origin system consistently

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| Sidebar uses `header_bg` as panel bg; palette uses `code_bg`; permission uses `code_bg` — inconsistent panel backgrounds | `sidebar.zig:256` vs `palette.zig:356` vs `permission.zig:100` | Medium |
| No internal dividers between sidebar sections — relies on spacing only | `sidebar.zig:87-173` | Low |
| Header separator style (`dim`) differs from panel border style (`border`) — two different divider patterns | `header.zig:37` vs `helpers.zig:198` | Low |

**Recommendations:**
1. Standardize panel background: create `panel_bg` token, use everywhere
2. Add thin dividers between sidebar sections (Files → Session → Workers → Theme)
3. Consider unified divider approach (either dim lines or border chars, not both)

---

## Pillar 3: Feedback & Response — Grade: 3/4 (Good)

**What works:**
- Spinner with stall detection (5s threshold) + "Stalled..." text + red color (`spinner.zig:23, 97-101, 141-142`)
- Token count display during streaming (`spinner.zig:169-174`)
- Typewriter character reveal with blinking cursor (`typewriter.zig:14-16, 112-115`)
- Toast notifications with severity icons + progress bar + auto-dismiss (`toast.zig:21-36, 75-86`)
- Permission dialog with clear keyboard hints [y] yes [n] no [a] always (`permission.zig:84-90`)

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| Typewriter effect exists but is NOT wired to actual streaming messages — users see instant text, not character reveal | `messages.zig:62-88` vs `chat_tui_app.zig` streaming | **Critical** |
| No explicit "Connecting..." or "Authenticating..." state — spinner says "Thinking..." even during connection phase | `spinner.zig:141-142` | Medium |
| No elapsed time shown during streaming (elapsed only shown in spinner) | `spinner.zig:103-112` | Low |

**Recommendations:**
1. **P0**: Wire `TypewriterState` into `MessageContentWidget` during active streaming
2. Add connection-phase status text ("Connecting to {provider}...")
3. Show elapsed time in status bar during streaming

---

## Pillar 4: Error Handling & Prevention — Grade: 3/4 (Good)

**What works:**
- Streaming errors mapped to user-friendly messages (`chat_tui_app.zig:2137-2145`):
  - `AuthenticationError` → "No API key configured..."
  - `NetworkError` → "Network error..."
  - `TimeoutError` → "Request timed out..."
  - `ServerError` → "Provider returned an error..."
- Clean state reset after errors (spinner/typewriter cleared) (`chat_tui_app.zig:2170-2175`)
- Setup wizard validates empty API key per provider (`setup.zig:178-180`)
- Error feedback styling with distinct colors in setup (`setup.zig:119-129`)

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| No persistent error banner — errors appear as chat messages and scroll away | `chat_tui_app.zig:2137-2149` | Medium |
| No retry shortcut visible after error (user must re-type message) | `chat_tui_app.zig:2170-2175` | Medium |
| Provider fallback happens silently — user doesn't see "Failed with X, trying Y..." until toast appears | `chat_tui_app.zig:2036-2038` | Low |

**Recommendations:**
1. Add error summary in status bar (e.g., "⚠ Last request failed — Ctrl+R to retry")
2. Store last user message for easy retry on error
3. Show fallback progress in status bar during provider switching

---

## Pillar 5: Accessibility — Grade: 2/4 (Fair)

**What works:**
- Full keyboard operability — setup wizard, permission dialog, command palette all keyboard-driven
- Keyboard hints shown in UI: [y/n/a] in permission, ↑↓ in setup, shortcut in palette
- Text labels accompany most visual elements
- Mono theme provides high-contrast fallback

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| Toast severity relies on color only — same icon (ℹ/✔/⚠/✖) but no text prefix like "[ERROR]" | `toast.zig:21-27` | High |
| Spinner stall indicator is red color only — no shape/text change beyond "Stalled..." text | `spinner.zig:97-101` | Medium |
| Tool call status icons (●/✓/✗) convey meaning by color — no text fallback like "[pending]"/"[done]"/"[failed]" | `messages.zig` role styles | Medium |
| No high-contrast theme option beyond mono | `theme.zig` | Low |
| Gradient text is purely decorative — no text-based equivalent for screen readers | `gradient.zig` | Low |

**Recommendations:**
1. **High priority**: Add text prefixes to toasts: `[INFO]`, `[OK]`, `[WARN]`, `[ERROR]`
2. Add text fallbacks for tool status: `● pending` → `[pending]`, `✓` → `[done]`, `✗` → `[failed]`
3. Consider adding a 4th "high-contrast" theme with maximum contrast ratios
4. Gradient text is acceptable as decorative — ensure same text is readable without gradient

---

## Pillar 6: Aesthetics & Delight — Grade: 3/4 (Good)

**What works:**
- Gradient text branding with per-character color interpolation (`gradient.zig:53-68, 130-135`)
- Braille spinner animation with color cycling (`spinner.zig:8-9, 61-65`)
- Typewriter reveal effect with blinking cursor (`typewriter.zig:104-115`)
- Toast progress bars with severity-based coloring (`toast.zig:74-86, 249-251`)
- 3 cohesive themes (dark/light/mono) with 15+ color tokens each (`theme.zig:4-82`)
- Permission dialog with clean visual hierarchy (`permission.zig:47-90`)

**Issues found:**
| Issue | File:Line | Severity |
|-------|-----------|----------|
| Messages are visually flat — no borders, backgrounds, or visual containment | `messages.zig:62-88` | Medium |
| Only 3 themes — no popular options like Catppuccin, Tokyo Night, Gruvbox | `theme.zig` | Medium |
| No micro-animations on state changes (message appear, panel toggle, theme switch) | Multiple widgets | Low |
| Sidebar is functional but plain — no section icons, no visual hierarchy within | `sidebar.zig:87-173` | Low |

**Recommendations:**
1. Add rounded borders + subtle bg to assistant messages (as specified in UI-SPEC.md §3.2.8)
2. Add 2-3 more themes (Catppuccin, Tokyo Night minimum)
3. Add fade-in animation for new messages (200ms)
4. Add section icons to sidebar (📂 Files, 💬 Session, 🤖 Model)

---

## Overall Summary

| Pillar | Grade | Key Issue |
|--------|-------|-----------|
| 1. Visual Hierarchy | **3/4** | Messages lack visual containment |
| 2. Consistency | **3/4** | Panel backgrounds inconsistent across widgets |
| 3. Feedback & Response | **3/4** | Typewriter not wired to streaming (critical) |
| 4. Error Handling | **3/4** | No persistent error indicator, no retry shortcut |
| 5. Accessibility | **2/4** | Color-only indicators without text fallbacks |
| 6. Aesthetics | **3/4** | Flat messages, only 3 themes |

**Overall: 2.8/4** — Solid foundation, needs targeted improvements in accessibility and message visual treatment.

---

## Priority Fixes (from audit)

| # | Fix | Pillar | Effort | File(s) |
|---|-----|--------|--------|---------|
| 1 | Wire typewriter to streaming messages | 3 | Low | `messages.zig`, `chat_tui_app.zig` |
| 2 | Add text prefixes to toast severity | 5 | Low | `toast.zig` |
| 3 | Unify panel backgrounds with `panel_bg` token | 2 | Low | `theme.zig`, `sidebar.zig`, `palette.zig` |
| 4 | Add borders/bg to assistant messages | 1, 6 | Medium | `messages.zig` |
| 5 | Add text fallbacks for tool status icons | 5 | Low | `messages.zig` |
| 6 | Add retry shortcut after errors | 4 | Medium | `chat_tui_app.zig` |
| 7 | Add Catppuccin + Tokyo Night themes | 6 | Low | `theme.zig` |
| 8 | Add section icons + dividers to sidebar | 1, 6 | Medium | `sidebar.zig` |
