# Coding Conventions

**Analysis Date:** 2026-04-11

## Naming Patterns

**Files:**
- Pattern: `kebab-case.zig` (lowercase with hyphens)
- Example: `client.zig`, `error_handler.zig`, `string.zig`

**Structs:**
- Pattern: `PascalCase`
- Example: `AIClient`, `ChatResponse`, `ProviderRegistry`, `PluginManager`

**Functions:**
- Pattern: `camelCase`
- Example: `init()`, `deinit()`, `sendChat()`, `loadOrCreateConfig()`

**Variables:**
- Pattern: `camelCase` with `snake_case` for some internal fields
- Example: `allocator`, `api_key`, `provider_name`, `request_times`

**Constants/Error Sets:**
- Pattern: `PascalCase`
- Example: `AIClientError`, `ProviderType`, `RetryConfig`

## Error Handling

**Error Set Definition:**
```zig
pub const AIClientError = error{
    NetworkError,
    AuthenticationError,
    RateLimitError,
    // ... more errors
};
```

**Error Union Usage:**
- Functions return error unions: `pub fn sendChat(...) !ChatResponse`
- Pattern: `try` for propagating, `catch` for handling

**Error Handling Pattern:**
```zig
// Comprehensive error handling with user-friendly messages
const parsed_args = args_mod.Args.parse(allocator, &args_iter) catch |err| switch (err) {
    error.OutOfMemory => {
        std.debug.print("Error: Insufficient memory to parse command line arguments\n", .{});
        return error.OutOfMemory;
    },
};
```

**Error Checking:**
- Null checks with `if (value) |v| { ... }` pattern
- Uses `orelse` for default values: `args.provider orelse config.default_provider`

## Memory Management

**Primary Allocator:**
- Uses `std.heap.page_allocator` in most CLI entry points
- Passes allocator as first parameter to functions

**String Duplication:**
```zig
const key_copy = try self.allocator.dupe(u8, provider_name);
const value_copy = try self.allocator.dupe(u8, api_key);
```

**Cleanup Patterns:**
- `defer` statements for guaranteed cleanup:
  ```zig
  var client = try client_mod.AIClient.init(allocator, provider, model_name, api_key);
  defer client.deinit();
  ```
- `errdefer` for error rollback:
  ```zig
  const key_copy = try self.allocator.dupe(u8, provider_name);
  errdefer self.allocator.free(key_copy);
  ```

**Deep Clone Pattern (for JSON responses):**
```zig
// Clone id
const id_copy = try allocator.dupe(u8, original.id);

// Clone choices
const choices_copy = try allocator.alloc(ChatChoice, original.choices.len);
for (original.choices, 0..) |orig_choice, i| {
    const role_copy = try allocator.dupe(u8, orig_choice.message.role);
    // ...
}
```

## File Organization

**Directory Structure:**
```
src/
├── ai/              # AI client, registry, error handling
├── commands/        # CLI command handlers (chat, read, handlers)
├── config/          # Configuration loading
├── plugin/          # Plugin interface and protocol
├── plugins/         # Plugin implementations
├── fileops/         # File operations
├── utils/           # Utility functions
├── cli/             # CLI argument parsing
├── mcp/             # MCP client and discovery
└── main.zig         # Application entry point
```

**Module Organization:**
- Each `.zig` file defines one primary public type
- Files group related functionality by domain

## Import Patterns

**Module Import:**
```zig
const std = @import("std");
const args_mod = @import("args");
const registry_mod = @import("registry");
```

**Relative Import:**
```zig
const error_handler_mod = @import("../ai/error_handler.zig");
const registry_mod = @import("../ai/registry.zig");
```

**Module Aliasing:**
```zig
const Config = config_mod.Config;
const Allocator = std.mem.Allocator;
```

## Struct Patterns

**Config/State Structs:**
```zig
pub const Config = struct {
    allocator: std.mem.Allocator,
    default_provider: []const u8,
    default_model: []const u8,
    api_keys: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config { ... }
    pub fn deinit(self: *Config) void { ... }
};
```

**Option Types:**
```zig
pub const ChatMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,  // Optional with default null
};
```

**Union Types:**
```zig
pub const BuiltInPlugin = union(enum) {
    pty: void,
    table_formatter: void,
    notifier: void,
    shell_strategy: void,
};
```

## Documentation Style

**Doc Comments:**
- Uses `///` for public function documentation
- Describes purpose, parameters, and behavior
- Example from `src/main.zig`:
  ```zig
  /// Helper function to safely cleanup parsed arguments with proper error handling
  fn cleanupParsedArgs(allocator: std.mem.Allocator, parsed_args: args_mod.Args) void {
  ```

**Inline Comments:**
- Used for validation and explanations
- Pattern: `// Early exit for empty command string (safety check)`

## Code Style

**Indentation:**
- 4 spaces, no tabs

**Variable Declaration:**
- Prefers `const` over `var`
- Only uses `var` for mutable state (rare)

**Control Flow:**
- Early exit pattern: `if (condition) return;`
- Uses `switch` for error handling

**Pattern Examples:**
```zig
// Early exit
if (parsed_args.command.len == 0) return;

// Null coalescing
const provider_name = args.provider orelse config.default_provider;

// String equality
if (std.mem.eql(u8, provider_name, "ollama")) { ... }

// Iteration
var iter = self.api_keys.iterator();
while (iter.next()) |entry| { ... }
```

---

*Convention analysis: 2026-04-11*