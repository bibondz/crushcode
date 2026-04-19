# Insight: Crushcode Desktop Architecture

**Date:** 2026-04-18
**Status:** Insight captured for future planning (post-CLI completion)

---

## Case Study: OpenCode Desktop (Tauri → Electron Migration)

Brendan (OpenCode engineer, creator of prisma-client-rust, Spacedrive developer) migrated OpenCode Desktop from **Tauri (Rust)** to **Electron (Node.js)** because it was "faster and smoother."

### Why the migration happened:

1. **Frontend Performance**: System WebView (WebKitGTK on Linux, WebKit on macOS) has inconsistent rendering and worse performance than bundled Chromium. Chromium guarantees identical rendering across all platforms.

2. **Process Boundary Overhead**: Tauri couldn't embed the Node.js server in the main process. It had to spawn Bun/Node.js as a sidecar, causing:
   - Serialization/deserialization overhead (JS ↔ Rust)
   - Network hop (local IPC)
   - Process spawn latency

3. **Electron Solution**: Server logic runs in Node.js main process. Frontend communicates via IPC with JS↔JS (no serialization). Single process.

### Industry Pattern:

| App | Shell | Server Runtime | Pattern |
|-----|-------|---------------|---------|
| Claude Desktop | Electron | Bun.js | Embedded in process |
| OpenCode Desktop (beta) | Electron | Node.js | Embedded in process |
| Cursor | Electron | Node.js | Embedded in process |
| Goose | Electron | Go binary sidecar | Process boundary |
| Aider | Terminal only | Python | No process |

---

## Crushcode Desktop Plan

### Core Insight

Crushcode's backend is **Zig** (not JS/TS), so we can't follow the exact Claude/OpenCode pattern. But we can do better — the Zig binary IS the server, and the Electron shell is just a thin UI.

### Architecture: `crushcode serve` + Electron/Bun Shell

```
Electron/Bun shell (UI only — thin)
        ↓ HTTP/WebSocket (localhost)
crushcode serve (Zig binary — all heavy lifting)
        ↓
AI providers, filesystem, git, knowledge, memory...
```

- **Electron/Bun is just UI shell** — no business logic, no API calls, no state management
- **Zig binary handles everything** — AI model calls, file ops, knowledge graph, memory
- **Communication via localhost API** — REST + WebSocket, JSON payloads
- **No language boundary** — no Rust↔JS serialization, no FFI, no sidecar awkwardness
- **Zig advantages over Go (Goose)**: smaller binary, faster startup, zero dependencies, cross-platform single binary

### Roadmap

```
Phase 1: Complete CLI (current — phases 66-72)
    ↓
Phase 2: Add `crushcode serve` — expose AI/chat/knowledge API via HTTP+WebSocket
    ↓
Phase 3: Build web UI frontend (React/Vue/Svelte) talking to `crushcode serve`
    ↓
Phase 4: Wrap web UI in Electron + Bun.js (for Chromium rendering stability)
    ↓
Phase 5: Ship as desktop app
```

### Key Decisions

- **Why not Tauri**: Would repeat OpenCode's mistake — sidecar process boundary overhead
- **Why not pure Wasm**: Zig→Wasm has limitations (no filesystem, no network, no subprocess)
- **Why Electron + Bun**: Proven pattern (Claude, OpenCode, Cursor all use it), Chromium rendering consistency, Bun is faster than Node.js for server-side JS
- **Why HTTP/WS not IPC**: Language-agnostic, any frontend can connect, works with browser tab during development

---

## Additional Context from Brenden (2026-04-19)

Brenden wrote a follow-up explanation with more detail on the migration decision:

### 1. Inconsistent Webview Rendering
System Webview แต่ละ OS render ไม่เหมือนกัน (macOS WebKit vs Windows WebView2 vs Linux WebKitGTK) → CSS/layout ออกมาต่างกัน. Electron ใช้ Chromium bundled = rendering เหมือนกันทุก platform.

### 2. Already Planning Bun → Node.js Migration
ทีมมีแผนย้ายจาก Bun ไป Node.js อยู่แล้ว → stack ทั้งหมดจะเป็น Node.js + Electron ก็เลย fit กัน

### 3. Startup Time Problem
ต้อง start server แยกจาก main process ด้วย `opencode serve` → overhead เพิ่ม. Electron สามารถ embed server ใน main process ได้เลย (เหมือนที่ Claude Desktop และ Cursor ทำ)

### 4. Tauri IS Good — Just Not For This Case
- **Tauri เหมาะเมื่อ** logic หลักเป็น Rust อยู่แล้ว → ตัวอย่าง: **Cap** (Brenden's app) ใช้ Tauri + video encoding/rendering เป็น Rust ล้วน → CPU/GPU bound → ใช้ทรัพยากรได้อย่างมีประสิทธิภาพ
- **OpenCode ไม่เหมาะ** เพราะ code ทั้งหมดเป็น Node.js → Rust frontend layer ไม่ได้ช่วย performance ยกเว้นจะเขียน server ใหม่ทั้งหมดเป็น Rust (ซึ่งไม่ใช่ plan)

### 5. Tauri CEF Future
Tauri มีแผนรองรับ **CEF (Chromium Embedded Framework)** → จะแก้ปัญหา inconsistent rendering ได้ แต่ **ไม่มี timeline ที่ชัดเจน**

### Key Takeaway for Crushcode
เราใช้ Zig (ไม่ใช่ Node.js หรือ Rust) → architecture decision ต่างออกไป:
- ไม่มี webview consistency problem เพราะเราเป็น TUI (terminal)
- ไม่มี sidecar overhead เพราะ single binary
- ถ้าอนาคตอยากมี GUI → `crushcode serve` + Electron shell ยังเป็น plan ที่ดี (Zig binary = thin server, Electron = thin UI shell)
- CEF ใน Tauri น่าจับตามอง — ถ้าออกก่อนที่เราจะทำ GUI อาจเป็นตัวเลือกที่น่าสนใจ (Zig binary + Tauri CEF = no Node.js dependency)

---

## Reference

- Brendan's X post about OpenCode Electron migration
- Brenden's follow-up explanation (2026-04-19) — Webview inconsistency, Bun→Node plan, startup time, Cap app example, Tauri CEF
- Prisma also migrated from Rust to TS (same serialization reason)
- Claude Desktop uses Bun.js as runtime
- Goose uses Go binary + Electron (similar to our planned approach but with Go instead of Zig)
- Cap app (by Brenden) — Tauri + Rust video encoding — example of Tauri done right
