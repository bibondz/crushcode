# Zig 0.15 Migration Gotchas: What Broke and How We Fixed It

**Date**: April 2026  
**Project**: [Crushcode](https://github.com/bibondz/crushcode) — AI coding CLI in Zig  
**Zig version**: 0.15.x (built against `master` branch stdlib)  
**Scope**: ~32K lines of Zig, 96 source files, 22 AI providers

We recently migrated crushcode from Zig 0.13 to 0.15. Here's everything that broke, why, and the working fix for each. If you're hitting the same issues, hopefully this saves you the debugging time.

---

## 1. `std.time.sleep` → `std.Thread.sleep`

**What broke:**
```zig
std.time.sleep(10 * std.time.ns_per_ms);
// error: root source file struct 'time' has no member named 'sleep'
```

**Fix:**
```zig
std.Thread.sleep(10 * std.time.ns_per_ms);
```

**Why:** `sleep` moved from `std.time` to `std.Thread` in 0.14+. The `std.time` module now only handles time measurement, not blocking.

---

## 2. `std.io.getStdOut()` → gone

**What broke:**
```zig
const stdout = std.io.getStdOut().writer();
// error: root source file struct 'Io' has no member named 'getStdOut'
```

**Fix:**
```zig
const stdout = std.io.getStdErr().writer(); // for stderr
// or use a helper function like out() from your codebase
```

**Why:** The `std.io` namespace was restructured. In 0.15, `getStdOut()` and `getStdErr()` moved. Check `std.posix` or use `std.process` for stdout/stderr access. Many codebases wrap this in a compat layer.

---

## 3. `std.json.stringify` → removed entirely

**What broke:**
```zig
try std.json.stringify(root_value, .{ .whitespace = .indent_2 }, writer);
// error: root source file struct 'json' has no member named 'stringify'
```

**Fix (format to string):**
```zig
const json_str = try std.fmt.allocPrint(
    allocator,
    "{f}",
    .{std.json.fmt(root_value, .{ .whitespace = .indent_2 })},
);
defer allocator.free(json_str);
try file.writeAll(json_str);
```

**Fix (direct allocation):**
```zig
const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{});
```

**Why:** `std.json.stringify` was a standalone function that wrote to an `OutStream`. In 0.15, serialization is handled through:
- `std.json.fmt(value, options)` — returns a format specifier for use with `{f}` in `std.fmt.allocPrint`
- `std.json.Stringify` — the underlying serializer type with `valueAlloc()` for heap allocation
- `std.json.Value.dump()` — for debug printing (no args, prints to stderr)

The `std.json.fmt` + `allocPrint` pattern is the most versatile for writing JSON to files, buffers, or network.

---

## 4. `json.Value.dump(allocator)` → `dump()`

**What broke:**
```zig
v.dump(testing.allocator);
// error: member function expected 0 argument(s), found 1
```

**Fix:**
```zig
v.dump(); // no arguments
```

**Why:** `dump()` was simplified to always print to stderr with no allocation options. It's a debug function — if you need controlled output, use `std.json.fmt` instead.

---

## 5. SQLITE_TRANSIENT in Zig — impossible at comptime

**What broke:**
```c
#define SQLITE_TRANSIENT ((void(*)(void*))-1)
```
We needed to pass `SQLITE_TRANSIENT` to `sqlite3_bind_text()` from Zig. Every approach failed:

| Approach | Error |
|----------|-------|
| `@ptrFromInt(-1)` | "pointer -1 has nonzero bits" |
| `@bitCast(@as(c_int, -1))` | "cannot bitCast to fn ptr" |
| `@ptrCast` from `?*anyopaque` | "alignment mismatch (1 vs 4 on aarch64)" |

**Fix: C helper function**

`vendor/sqlite3/zig_helpers.h`:
```c
#pragma once
int zig_sqlite3_bind_text_transient(void* stmt, int idx, const char* text, int len);
```

`vendor/sqlite3/zig_helpers.c`:
```c
#include "zig_helpers.h"
#include "sqlite3.h"

int zig_sqlite3_bind_text_transient(void* stmt, int idx, const char* text, int len) {
    return sqlite3_bind_text((sqlite3_stmt*)stmt, idx, text, len, SQLITE_TRANSIENT);
}
```

Then in `build.zig`, add the C file to your module:
```zig
sqlite_mod.addCSourceFile(.{
    .file = b.path("vendor/sqlite3/zig_helpers.c"),
    .flags = &.{},
});
```

And in Zig:
```zig
extern fn zig_sqlite3_bind_text_transient(stmt: *anyopaque, idx: c_int, text: [*c]const u8, len: c_int) c_int;
```

**Why:** Zig's comptime type system can't represent function pointers with misaligned addresses. `SQLITE_TRANSIENT` is `((void(*)(void*))-1)` — a sentinel that works in C because C allows casting arbitrary integers to function pointers (undefined behavior, but universally supported). Zig refuses this at comptime. The C compiler handles it natively, so we delegate.

This issue specifically affects **aarch64** targets where function pointer alignment is 4 bytes, making `@ptrFromInt` reject the address.

---

## 6. Optional slice coercion: `?[][]const u8` from array literal

**What broke:**
```zig
.args = &[_][]const u8{ "a", "b" },
// error: expected type '?[][]const u8', found '*const [2][]const u8'
```

**Fix:**
```zig
.args = @as(?[][]const u8, @constCast(&[_][]const u8{ "a", "b" })),
```

**Why:** Zig won't implicitly coerce a `*const [N]T` to `?[]T`. You need `@constCast` to drop the const qualifier, then `@as` for the optional wrapper. This is stricter than 0.13 which allowed more implicit coercions.

---

## 7. `_ = self` while `self` is still used — stricter analysis

**What broke:**
```zig
pub fn validateVariables(self: *RecipeRunner, ...) !void {
    _ = self;
    // ... later uses self.allocator
}
// error: pointless discard of function parameter
```

**Fix:**
```zig
pub fn validateVariables(self: *RecipeRunner, ...) !void {
    // remove the _ = self line
    // ... self.allocator works fine
}
```

**Why:** Zig 0.15 has stricter "pointless discard" analysis. If you discard a parameter with `_ =` but the compiler can see it's actually used later, it errors. This catches copy-paste mistakes where `_ = self` was added prematurely.

---

## 8. Cross-module enum type mismatch

**What broke:**
```zig
// auto_classifier.zig has its own RiskTier
// tool_classifier.zig has its own RiskTier
// Same enum values, different types
return tool_classifier.classifyShellCommand(arguments);
// error: expected type 'auto_classifier.RiskTier', found 'tool_classifier.RiskTier'
```

**Fix:**
```zig
const shell_tier = tool_classifier.classifyShellCommand(arguments);
return @enumFromInt(@intFromEnum(shell_tier));
```

**Why:** Zig doesn't do structural typing for enums — two enums with identical fields are still different types. Cast through `int` when they share the same value space. The real fix is to use a single shared enum, but that's a refactor; `@intFromEnum`/`@enumFromInt` is the quick bridge.

---

## Lessons Learned

1. **Zig 0.15 is stricter** — more implicit coercions removed, more compile-time checks. Code that compiled on 0.13 will likely need fixes.
2. **The `std.json` module changed dramatically** — `stringify` is gone, use `std.json.fmt` or `std.json.Stringify`.
3. **C interop still has edges** — especially around sentinel values like `SQLITE_TRANSIENT` that rely on C's looser casting rules.
4. **Test early, test often** — `zig build test` caught all of these immediately. Don't let test compilation errors fester.
5. **Read the stdlib source** — the changelog doesn't cover everything. `grep -rn "pub fn" /usr/local/zig/lib/std/json.zig` was more useful than any blog post.

---

*Building [crushcode](https://github.com/bibondz/crushcode) — a Zig AI coding CLI with 22 providers, zero dependencies, 3.5MB binary.*
