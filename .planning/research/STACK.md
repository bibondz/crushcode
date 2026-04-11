# Technology Stack: CLI Tool with AI Agent + Shell Execution in Zig

**Project:** Crushcode (brownfield CLI)
**Researched:** 2025-04-11
**Focus:** Zig stdlib capabilities for production CLI tools

---

## Executive Summary

Zig's stdlib provides first-class support for all core requirements of an AI-powered CLI tool. The existing codebase already uses the correct patterns. Key findings:

- **HTTP:** `std.http.Client.fetch()` is the recommended high-level API (not lower-level `open()`)
- **JSON:** `std.json.parseFromSlice()` + `std.json.stringify()` for static typing; `std.json.Value` for dynamic
- **Process:** `std.process.Child` for shell execution; PTY requires C interop (no stdlib alternative)
- **TUI:** No stdlib TUI—use external ZigZag or OpenTUI (used by OpenCode in production)
- **CLI args:** `std.process.ArgIterator` + manual parsing (as implemented in codebase)

---

## Recommended Stack

### Core Framework

| Component | Stdlib Module | Status | Notes |
|-----------|---------------|--------|-------|
| HTTP Client | `std.http.Client` | Stable | Use `.fetch()` API, NOT `.open()` |
| JSON Parsing | `std.json.parseFromSlice` | Stable | Static typing; use `.ignore_unknown_fields` |
| JSON Serialization | `std.json.stringify` | Stable | `std.json.Stringify` struct |
| Process Spawning | `std.process.Child` | Stable | Cross-platform |
| Args Parsing | `std.process.ArgIterator` | Stable | Manual parsing required |
| PTY/Shell | C interop (`@cImport`) | Required | No stdlib alternative—use openpty |
| Logging | `std.log` | Stable | Configured via build options |

### HTTP Client (`std.http`)

**Recommendation:** Use `std.http.Client.fetch()` — the high-level API.

```zig
// CORRECT: High-level fetch API (as seen in client.zig lines 211-226)
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

var response_buf = std.ArrayList(u8).init(allocator);
var headers_buf = std.ArrayList(std.http.Header).init(allocator);
try headers_buf.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = try allocator.dupe(u8, "application/json") });

const fetch_result = try client.fetch(.{
    .method = .POST,
    .location = .{ .uri = uri },
    .payload = json_body,
    .extra_headers = headers_buf.items,
    .response_storage = .{ .dynamic = &response_buf },
});

// Check status
if (fetch_result.status != .ok) {
    // Handle error
}
```

**Known Issues (0.15.x):**
- Large HTTPS payloads may block — workaround: set `.write_buffer_size = 8192`
- Fixed in 0.16.0-dev.27+

**Lower-level API (avoid unless needed):**
```zig
// NOT recommended for simple use cases
var req = try client.open(.GET, uri, .{
    .server_header_buffer = &buf,
    .extra_headers = headers,
});
defer req.deinit();
try req.send();
try req.finish();
try req.wait();
const body = try req.reader().readAllAlloc(allocator, 4096);
```

### JSON (`std.json`)

**Recommendation:** Use static parsing with `parseFromSlice()` when possible.

```zig
// Static parsing (as seen in client.zig lines 301-304)
var json_parsed = try std.json.parseFromSlice(ChatResponse, allocator, response_slice, .{
    .ignore_unknown_fields = true,
});
defer json_parsed.deinit();
const response = json_parsed.value;
```

**Dynamic parsing (when schema is unknown):**
```zig
// For runtime-inspectable JSON
var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
defer parsed.deinit();

switch (parsed.value) {
    .object => |obj| {
        if (obj.get("key")) |val| {
            // Handle value
        }
    },
    .string => |s| std.debug.print("{s}\n", .{s}),
    else => {},
}
```

**Serialization:**
```zig
// Stringify a struct
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();

try std.json.stringify(response, .{}, buf.writer());
// Output: {"id":"...","model":"...",...}
```

**Known Patterns from Codebase:**
- `std.json.ObjectMap` — used in PTYPlugin for session storage (line 9)
- `std.json.Value` — union type for dynamic values
- Always use `.ignore_unknown_fields = true` for API responses

### Process/Shell Execution (`std.process`)

**Recommendation:** Use `std.process.Child` for simple shell commands.

```zig
// Simple command execution (NOT used in codebase, but documented)
var child = std.process.Child.init(&.{ "ls", "-la" }, allocator);
defer child.deinit();

child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;

try child.spawn();
try child.collectOutput(&stdout, &stderr, 4096);

if (child.wait() catch |err|) {
    // Check exit code
}
```

**PTY/Shell (as in codebase):** Use C interop — no stdlib alternative exists.

```zig
// Current implementation (src/plugins/pty.zig lines 93-169)
const c = @cImport(@cInclude("sys/ioctl.h"));
const c = @cImport(@cInclude("unistd.h"));

// Unix PTY via openpty
if (c.openpty(&master_fd, &slave_fd, null, &winsize) != 0) {
    return error.PTYOpenFailed;
}

const pid = c.fork();
if (pid == 0) {
    // Child: setup PTY and exec
    c.setsid();
    c.ioctl(slave_fd, c.TIOCSCTTY, null);
    c.dup2(slave_fd, c.STDIN_FILENO);
    c.dup2(slave_fd, c.STDOUT_FILENO);
    c.dup2(slave_fd, c.STDERR_FILENO);
    c.execvp(argv[0], argv.ptr);
}
```

**Key Points:**
- `std.process.Child` does NOT support PTY natively
- Must use C interop for terminal control (`openpty`, `fork`, `ioctl`)
- Windows PTY requires different API (not implemented in codebase)

### CLI Arguments (`std.process`)

**Recommendation:** Use `std.process.ArgIterator` + manual parsing.

```zig
// Current implementation (src/cli/args.zig lines 12-76)
pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.ArgIterator) !Args {
    var remaining_list = std.ArrayListUnmanaged([]const u8){};

    var is_first_arg = true;
    while (args_iter.next()) |arg| {
        if (is_first_arg) {
            is_first_arg = false;
            continue;
        }

        // Parse --flags
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.startsWith(u8, arg, "--provider=")) {
                result.provider = arg[11..];
            } else if (std.mem.eql(u8, arg, "--provider")) {
                if (args_iter.next()) |next_arg| {
                    result.provider = next_arg;
                }
            }
            // ... more flags
        }
    }
}
```

**Key Points:**
- No argument parsing library in stdlib
- Manual parsing as implemented is correct pattern
- Consider alternatives: external `zig-clap` if complexity grows

### Terminal UI

**Status:** NO stdlib TUI exists. Options:

| Library | Stars | Use When |
|---------|-------|----------|
| [ZigZag](https://github.com/meszmate/zigzag) | 234 | Production—Elm architecture, powers OpenCode UI |
| [TUI.zig](https://github.com/muhammad-fiaz/tui.zig) | 42 | Modern widgets, 36+ components |
| [Tuile](https://github.com/akarpovskii/tuile) | 215 | Cross-platform, ncurses backend |
| [OpenTUI](https://opentui.com/) | N/A | TypeScript bindings, React support |

**Recommendation:** For AI agent CLI, use **ZigZag** or **OpenTUI** (powers OpenCode).

```zig
// If using ZigZag
const zz = @import("zigzag");

const App = struct {
    pub fn init() App { return .{} }
    pub fn update(self: *App, msg: zz.Msg) zz.Msg { /* ... */ }
    pub fn view(self: *App) zz.View { /* ... */ }
};
```

### Logging (`std.log`)

**Recommendation:** Use configured logging.

```zig
// Configure at build time in build.zig
const exe = b.addExecutable(.{
    .name = "crushcode",
    // Enable debug logging
});

exe.log_level = .debug;  // or .info, .warn, .err

// Use in code
std.log.debug("Starting up", .{});
std.log.info("Provider: {s}", .{provider});
std.log.err("Failed: {}", .{err});
```

---

## Current Codebase Usage (Reference)

| File | Stdlib Modules Used | Pattern |
|------|-----------------|---------|
| `src/ai/client.zig` | `std.http.Client`, `std.json`, `std.fmt` | HTTP fetch + JSON parse |
| `src/plugins/pty.zig` | `std.json.ObjectMap`, `std.process` | PTY via C interop |
| `src/cli/args.zig` | `std.process.ArgIterator`, `std.mem` | Manual argument parsing |
| `src/main.zig` | `std.process.argsWithAllocator` | Entry point |
| `src/plugin_manager.zig` | `@enumFromString` (custom) | Plugin routing |

---

## Patterns to Avoid

| Pattern | Why Avoid | Alternative |
|---------|---------|-----------|
| Lower-level `client.open()` | More error-prone, more code | Use `client.fetch()` |
| `std.json.parse()` (deprecated) | Removed in 0.12+ | Use `parseFromSlice()` |
| `@cImport` for basic types | Not needed | Use `std.os` wrappers |
| Blocking HTTP without timeout | Hangs on large payloads | Set `write_buffer_size` |

---

## Installation (Dependencies)

No external dependencies required for core functionality. For TUI:

```bash
# Add to build.zig.zon
.dependencies = .{
    .zigzag = .{
        .url = "https://github.com/meszmate/zigzag/archive/refs/heads/main.tar.gz",
        .hash = "...",  # Run `zig fetch` to get hash
    },
}
```

---

## Confidence Assessment

| Area | Confidence | Reason |
|------|------------|--------|
| HTTP Client | HIGH | Used in production codebase |
| JSON | HIGH | Multiple production uses |
| Process | HIGH | Standard stdlib |
| PTY | HIGH | Matches production shell implementations |
| Args | HIGH | Matches codebase pattern |
| TUI | MEDIUM | External libs—stdlib gap |

---

## Sources

- Zig stdlib (`std.http`, `std.json`, `std.process`) — Reference implementation
- [Zig NEWS: Easy web requests with Client.fetch](https://zig.news/andrewgossage/easy-web-requests-in-zig-with-clientfetch-k43)
- [Zig GitHub: std.http.Client fixes](https://github.com/ziglang/zig/issues/25015)
- [TigerBeetle shell.zig](https://github.com/tigerbeetle/tigerbeetle/blob/main/src/shell.zig) — Production shell patterns
- [ZigZag TUI](https://github.com/meszmate/zigzag) — Production TUI (234 stars)