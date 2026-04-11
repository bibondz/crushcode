# Testing Patterns

**Analysis Date:** 2026-04-11

## Test Framework

**Framework:** Built-in Zig testing (std.testing)
- No external testing libraries detected
- Using Zig's native `@test` blocks and `std.testing` utilities

**No test targets in build.zig:**
- The build file defines modules and executable but no `addTest` or test runner

**Run Commands:**
```bash
# No test target configured - would need to add manually
zig test src/   # Not currently configured
```

## Test File Organization

**Location:** None - no test files found

**Naming Pattern:** Not applicable (no tests exist)

**Structure:** No test directory or test files

## Test Structure

**No test blocks found in any `.zig` files.**

The codebase contains zero `@test` blocks:
```zig
// No pattern like this exists anywhere in codebase:
test "example test" {
    // test code
}
```

## Mocking

**No mocking framework used.**

**Current approach:** None - direct testing not implemented

**What would need mocking:**
- HTTP client calls (in `src/ai/client.zig`)
- File system operations (in `src/config/config.zig`)
- Plugin subprocess spawning (in `src/plugin/interface.zig`)

## Fixtures and Factories

**Test Data:** Not applicable - no tests exist

**Location:** No test fixtures directory

## Coverage

**Requirements:** None enforced

**Coverage:** 0% - no tests exist

**View Coverage:** Not configured

## Test Types

**Unit Tests:** Not implemented

**Integration Tests:** Not implemented

**E2E Tests:** Not implemented

## Common Patterns

**Async Testing:** Not applicable (no tests)

**Error Testing:** Not applicable (no tests)

## Missing Test Areas

**Critical gaps requiring test coverage:**

1. **`src/ai/client.zig`** - HTTP client functionality
   - `sendChat()` - main entry point
   - `sendChatWithHistory()` - conversation history
   - `performHttpRequest()` - HTTP request handling
   - JSON parsing for Ollama and standard responses
   - Error retry logic

2. **`src/ai/error_handler.zig`** - Error handling
   - `calculateDelay()` - exponential backoff calculation
   - `isRetryableError()` - error classification
   - `parseHttpStatus()` - HTTP status mapping

3. **`src/ai/registry.zig`** - Provider registry
   - `getConfigForProvider()` - provider configuration
   - `registerProvider()` - provider registration
   - `fetchOpenCodeZenModels()` - model fetching

4. **`src/config/config.zig`** - Configuration
   - `parseToml()` - TOML parsing
   - `parseKeyValue()` - key-value parsing
   - `getConfigPath()` - path resolution

5. **`src/cli/args.zig`** - Argument parsing
   - Flag parsing (`--provider`, `--model`, etc.)
   - Command detection
   - Remaining arguments handling

6. **`src/commands/chat.zig`** - Chat command
   - `handleChat()` - single message mode
   - `handleInteractiveChat()` - interactive mode

7. **`src/plugin/interface.zig`** - Plugin system
   - `start()` - plugin spawning
   - `sendRequest()` - JSON-RPC communication
   - `PluginManager` lifecycle methods

8. **`src/plugins/registry.zig`** - Plugin registry
   - `registerBuiltIn()` / `registerExternal()`
   - `isPluginEnabled()` - enable check
   - `getPrioritizedPlugins()` - priority sorting

## Test Infrastructure Recommendations

**To add testing:**

1. **Add test target to `build.zig`:**
```zig
const test_module = b.addModule("test", .{
    .root_source_file = b.path("src/main.zig"),
    // ...
});

// Add tests for each module
const test_runner = b.addTest(.{
    .root_module = test_module,
});
b.registerTest("test-runner", test_runner);
```

2. **Add test blocks in source files:**
```zig
test "calculate delay with backoff" {
    const config = RetryConfig.default();
    const delay = calculateDelay(1, config);
    try std.testing.expect(delay >= config.base_delay_ms);
    try std.testing.expect(delay <= config.max_delay_ms);
}
```

3. **Create test utilities:**
- `test_utils.zig` - common test fixtures
- HTTP mocking for client tests
- File system test helpers

---

*Testing analysis: 2026-04-11*