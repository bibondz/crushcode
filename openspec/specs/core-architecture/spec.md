---
id: core-architecture
status: draft
created: 2026-02-06
updated: 2026-02-06
source: crushcode-extensibility
---

# Core Architecture Specification

## Purpose

Crushcode SHALL be built on a Zig-based architecture prioritizing performance, memory safety, and extensibility through a plugin system.

## Overview

The core architecture provides:
- Zero-cost abstractions for performance
- Memory safety without garbage collection
- Extensible plugin system
- Asynchronous I/O operations
- Cross-platform compatibility

## Requirements

### Requirement: Zero-Cost Abstractions
The system SHALL use Zig's compile-time features to eliminate runtime overhead.

#### Scenario: Compile-Time Configuration
- GIVEN user specifies provider configuration at build time
- WHEN Crushcode is compiled
- THEN configuration SHALL be compiled into binary
- AND runtime overhead SHALL be zero

### Requirement: Memory Safety
The system SHALL ensure memory safety without garbage collection.

#### Scenario: Memory Management
- GIVEN system allocates memory for API responses
- WHEN memory is no longer needed
- THEN it SHALL be freed immediately
- AND no memory leaks SHALL occur

### Requirement: Asynchronous Operations
The system SHALL support non-blocking I/O for concurrent operations.

#### Scenario: Concurrent API Calls
- GIVEN user sends multiple chat requests
- WHEN requests are processed
- THEN they SHALL be handled concurrently
- AND UI SHALL remain responsive

### Requirement: Plugin Integration
The core SHALL seamlessly integrate with plugin system.

#### Scenario: Plugin Hooking
- GIVEN plugin wants to intercept chat requests
- WHEN user sends a message
- THEN core SHALL route through plugin
- AND SHALL provide response to plugin

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Crushcode Core                         │
├─────────────────────────────────────────────────────────────┤
│  CLI Layer                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │    Args     │  │   Router    │  │   Output    │     │
│  │   Parser    │  │             │  │ Formatter   │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
├─────────────────────────────────────────────────────────────┤
│  Service Layer                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Config    │  │  Provider   │  │   Plugin    │     │
│  │  Manager    │  │   Manager   │  │   Manager   │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
├─────────────────────────────────────────────────────────────┤
│  Infrastructure Layer                                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   HTTP      │  │   Event     │  │   Async     │     │
│  │   Client    │  │    Bus      │  │  Scheduler  │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
├─────────────────────────────────────────────────────────────┤
│  Platform Layer                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Memory    │  │   File I/O  │  │   Network   │     │
│  │  Allocator  │  │  Manager    │  │   Abstr.    │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### Core Types

```zig
// Main application state
pub const Crushcode = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    config: Config,
    config_manager: ConfigManager,
    provider_manager: ProviderManager,
    plugin_manager: PluginManager,
    event_bus: EventBus,
    async_scheduler: AsyncScheduler,
    
    pub fn init(allocator: std.mem.Allocator) !Self;
    pub fn deinit(self: *Self) void;
    pub fn run(self: *Self, args: Args) !void;
    pub fn shutdown(self: *Self) void;
};

// Configuration structure
pub const Config = struct {
    const Self = @This();
    
    default_provider: []const u8,
    default_model: []const u8,
    providers: std.json.ObjectMap,
    plugins: std.json.ObjectMap,
    logging: LoggingConfig,
    performance: PerformanceConfig,
    
    pub fn load(allocator: std.mem.Allocator) !Self;
    pub fn save(self: *Self) !void;
    pub fn merge(self: *Self, other: *const Config) void;
};

// Event system
pub const Event = struct {
    const Self = @This();
    
    id: []const u8,
    source: []const u8,
    timestamp: i64,
    data: EventData,
    
    pub fn serialize(self: *const Self) ![]const u8;
    pub fn deserialize(data: []const u8) !Self;
};

// Async operation
pub const AsyncOperation = struct {
    const Self = @This();
    
    id: []const u8,
    operation: OperationType,
    state: OperationState,
    result: ?Result,
    error: ?Error,
    
    pub fn cancel(self: *Self) void;
    pub fn wait(self: *Self) !Result;
};
```

### Memory Management Strategy

```zig
// Custom allocator with tracking
pub const TrackedAllocator = struct {
    const Self = @This();
    
    backing_allocator: std.mem.Allocator,
    allocated_bytes: u64,
    allocation_count: u64,
    
    pub fn init(backing_allocator: std.mem.Allocator) Self;
    
    pub fn alloc(self: *Self, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const ptr = self.backing_allocator.alloc(len, log2_align, ret_addr);
        if (ptr) |p| {
            self.allocated_bytes += len;
            self.allocation_count += 1;
        }
        return p;
    }
    
    pub fn free(self: *Self, ptr: []u8, log2_align: u8, ret_addr: usize) void {
        self.allocated_bytes -= ptr.len;
        self.allocation_count -= 1;
        self.backing_allocator.free(ptr, log2_align, ret_addr);
    }
};

// Memory pool for frequently allocated objects
pub const MemoryPool = struct {
    const Self = @This();
    
    buffer: []u8,
    offset: usize,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, size: usize) !Self;
    pub fn alloc(self: *Self, size: usize) ![]u8;
    pub fn reset(self: *Self) void;
    pub fn deinit(self: *Self) void;
};
```

### Async Runtime

```zig
// Async task scheduler
pub const AsyncScheduler = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    completed_tasks: std.ArrayList(CompletedTask),
    running: bool,
    
    pub fn init(allocator: std.mem.Allocator) Self;
    pub fn deinit(self: *Self) void;
    
    pub fn schedule(self: *Self, task: Task) !TaskId;
    pub fn cancel(self: *Self, task_id: TaskId) bool;
    pub fn run(self: *Self) !void;
    
    pub fn wait_for_task(self: *Self, task_id: TaskId) !TaskResult;
    pub fn wait_for_all(self: *Self) ![]TaskResult;
};

// Async HTTP client
pub const AsyncHttpClient = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    connections: std.ArrayList(Connection),
    requests: std.ArrayList(Request),
    
    pub fn init(allocator: std.mem.Allocator) Self;
    pub fn deinit(self: *Self) void;
    
    pub fn request(self: *Self, req: HttpRequest) !AsyncResponse;
    pub fn request_stream(self: *Self, req: HttpRequest, handler: StreamHandler) !void;
    pub fn cancel_all(self: *Self) void;
};
```

## Performance Optimizations

### Compile-Time Features

```zig
// Compile-time plugin registration
pub const PLUGINS = struct {
    pub const plugin1 = PluginPlugin{
        .name = "plugin1",
        .init = plugin1_init,
        .deinit = plugin1_deinit,
    };
    
    pub const plugin2 = PluginPlugin{
        .name = "plugin2",
        .init = plugin2_init,
        .deinit = plugin2_deinit,
    };
};

// Compile-time provider configuration
pub const PROVIDERS = struct {
    pub const openai = OpenAIProvider{};
    pub const anthropic = AnthropicProvider{};
    pub const ollama = OllamaProvider{};
};

// Zero-cost abstractions
pub fn Response(comptime T: type) type {
    return struct {
        const Self = @This();
        
        data: T,
        error: ?Error,
        
        pub fn is_ok(self: *const Self) bool {
            return self.error == null;
        }
        
        pub fn is_err(self: *const Self) bool {
            return self.error != null;
        }
        
        pub fn unwrap(self: *const Self) T {
            if (self.error) |err| {
                std.debug.panic("Attempted to unwrap error response: {}", .{err});
            }
            return self.data;
        }
    };
}
```

### Memory Pooling

```zig
// Pooled string interning
pub const StringInterner = struct {
    const Self = @This();
    
    strings: std.hash_map.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    pool: MemoryPool,
    
    pub fn init(allocator: std.mem.Allocator, pool_size: usize) !Self;
    pub fn deinit(self: *Self) void;
    
    pub fn intern(self: *Self, s: []const u8) ![]const u8 {
        if (self.strings.get(s)) |interned| {
            return interned;
        }
        
        const copy = try self.pool.alloc(s.len);
        std.mem.copy(u8, copy, s);
        
        try self.strings.put(copy, copy);
        return copy;
    }
};

// Object pool for frequently created/destroyed objects
pub const ObjectPool = struct {
    const Self = @This();
    
    T: type,
    objects: std.ArrayList(T),
    available: std.ArrayList(bool),
    
    pub fn init(allocator: std.mem.Allocator, initial_size: usize) !Self;
    pub fn deinit(self: *Self) void;
    
    pub fn acquire(self: *Self) !*T;
    pub fn release(self: *Self, obj: *T) void;
};
```

## Cross-Platform Considerations

### Platform Abstraction

```zig
// Platform-specific interfaces
pub const Platform = struct {
    const Self = @This();
    
    // File system
    pub const FileSystem = struct {
        pub fn create_file(path: []const u8) !File;
        pub fn open_file(path: []const u8) !File;
        pub fn delete_file(path: []const u8) !void;
        pub fn list_directory(path: []const u8) ![]DirEntry;
    };
    
    // Network
    pub const Network = struct {
        pub fn create_socket() !Socket;
        pub fn connect(socket: Socket, address: Address) !void;
        pub fn send(socket: Socket, data: []const u8) !usize;
        pub fn receive(socket: Socket, buffer: []u8) !usize;
    };
    
    // Dynamic loading
    pub const DynamicLibrary = struct {
        pub fn load(path: []const u8) !Library;
        pub fn get_symbol(library: Library, name: []const u8) ?*anyopaque;
        pub fn unload(library: Library) void;
    };
};

// Platform implementations
pub const platform_impl = switch (std.Target.current.os.tag) {
    .windows => @import("platform/windows.zig"),
    .macos => @import("platform/macos.zig"),
    .linux => @import("platform/linux.zig"),
    else => @compileError("Unsupported platform"),
};
```

### Configuration Paths

```zig
// Platform-specific configuration directories
pub const ConfigPaths = struct {
    pub const config_dir: []const u8 = switch (std.Target.current.os.tag) {
        .windows => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("APPDATA") orelse "C:\\Users\\Default", "Crushcode" }
        ),
        .macos => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("HOME") orelse "/Users/default", ".config", "crushcode" }
        ),
        .linux => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("HOME") orelse "/home/user", ".config", "crushcode" }
        ),
        else => unreachable,
    };
    
    pub const cache_dir: []const u8 = switch (std.Target.current.os.tag) {
        .windows => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("LOCALAPPDATA") orelse "C:\\Users\\Default\\AppData\\Local", "Crushcode\\Cache" }
        ),
        .macos => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("HOME") orelse "/Users/default", ".cache", "crushcode" }
        ),
        .linux => std.fs.path.join(
            std.heap.page_allocator,
            &[_][]const u8{ std.getenv("HOME") orelse "/home/user", ".cache", "crushcode" }
        ),
        else => unreachable,
    };
};
```

## Error Handling

### Error Types

```zig
pub const CoreError = error{
    OutOfMemory,
    InvalidConfiguration,
    PluginLoadFailed,
    ProviderNotFound,
    NetworkError,
    Timeout,
    Cancelled,
};

pub const ErrorContext = struct {
    const Self = @This();
    
    error_code: CoreError,
    message: []const u8,
    file: []const u8,
    line: u32,
    stack_trace: []const u8,
    
    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("{s}:{d}: {s}: {s}", .{
            self.file, self.line, @tagName(self.error_code), self.message
        });
    }
};
```

### Error Recovery

```zig
pub const ErrorHandler = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    logger: Logger,
    
    pub fn handle(self: *Self, err: anyerror, context: ErrorContext) !void {
        try self.logger.err("Error occurred: {}", .{context});
        
        switch (err) {
            CoreError.OutOfMemory => {
                // Trigger garbage collection
                // Free unused pools
                // Retry operation
            },
            CoreError.NetworkError => {
                // Retry with exponential backoff
                // Switch to offline mode if available
            },
            CoreError.PluginLoadFailed => {
                // Continue without plugin
                // Log warning
            },
            else => return err,
        }
    }
};
```

## Logging and Monitoring

### Logging System

```zig
pub const Logger = struct {
    const Self = @This();
    
    level: LogLevel,
    writers: std.ArrayList(LogWriter),
    
    pub fn init(level: LogLevel) Self;
    pub fn deinit(self: *Self) void;
    
    pub fn add_writer(self: *Self, writer: LogWriter) !void;
    pub fn remove_writer(self: *Self, writer: LogWriter) void;
    
    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void;
    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void;
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void;
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void;
};

pub const LogWriter = struct {
    const Self = @This();
    
    write_fn: *const fn(message: []const u8) anyerror!void,
    flush_fn: *const fn() anyerror!void,
};
```

### Metrics Collection

```zig
pub const Metrics = struct {
    const Self = @This();
    
    counters: std.hash_map.StringHashMap(u64),
    gauges: std.hash_map.StringHashMap(f64),
    histograms: std.hash_map.StringHashMap(Histogram),
    
    pub fn increment_counter(self: *Self, name: []const u8) void;
    pub fn set_gauge(self: *Self, name: []const u8, value: f64) void;
    pub fn record_histogram(self: *Self, name: []const u8, value: f64) void;
    
    pub fn get_metrics(self: *Self) !MetricsSnapshot;
    pub fn reset(self: *Self) void;
};
```

## Testing Framework

### Unit Testing

```zig
test "memory allocator tracking" {
    var tracked_allocator = TrackedAllocator.init(std.testing.allocator);
    defer tracked_allocator.deinit();
    
    const ptr = try tracked_allocator.alloc(1024, 0, @returnAddress());
    defer tracked_allocator.free(ptr, 0, @returnAddress());
    
    try testing.expect(tracked_allocator.allocated_bytes == 1024);
    try testing.expect(tracked_allocator.allocation_count == 1);
}

test "async task scheduling" {
    const allocator = std.testing.allocator;
    var scheduler = try AsyncScheduler.init(allocator);
    defer scheduler.deinit();
    
    const task_id = try scheduler.schedule(Task{
        .operation = .test_operation,
        .data = .{ .value = 42 },
    });
    
    const result = try scheduler.wait_for_task(task_id);
    try testing.expect(result.data.value == 42);
}
```

### Integration Testing

```zig
test "provider integration" {
    const allocator = std.testing.allocator;
    
    var config = try Config.load(allocator);
    defer config.deinit();
    
    var provider_manager = try ProviderManager.init(allocator, config);
    defer provider_manager.deinit();
    
    const provider = try provider_manager.get_provider("openai");
    try testing.expect(provider != null);
    
    const request = ChatRequest{
        .model = "gpt-3.5-turbo",
        .messages = &[_]Message{.{
            .role = .user,
            .content = "Hello, world!",
        }},
    };
    
    const response = try provider.?.chat(request);
    try testing.expect(response.choices.len > 0);
}
```

## Build Configuration

### Build Options

```zig
// build.zig
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    
    const exe = b.addExecutable(.{
        .name = "crushcode",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    // Build options
    const default_provider = b.option([]const u8, "default-provider", "Default AI provider");
    const enable_plugins = b.option(bool, "enable-plugins", "Enable plugin system") orelse true;
    const enable_telemetry = b.option(bool, "enable-telemetry", "Enable telemetry") orelse false;
    
    if (default_provider) |provider| {
        exe.defineCMacro("DEFAULT_PROVIDER", provider);
    }
    
    if (enable_plugins) {
        exe.defineCMacro("ENABLE_PLUGINS", "1");
    }
    
    if (enable_telemetry) {
        exe.defineCMacro("ENABLE_TELEMETRY", "1");
    }
    
    // Dependencies
    const zig_json = b.dependency("zig-json", .{});
    exe.addModule("json", zig_json.module("json"));
    
    b.installArtifact(exe);
}
```

### Conditional Compilation

```zig
// Compile-time feature flags
const ENABLE_PLUGINS = @import("build_options").enable_plugins;
const ENABLE_TELEMETRY = @import("build_options").enable_telemetry;
const DEFAULT_PROVIDER = @import("build_options").default_provider;

// Conditional code
pub const Crushcode = struct {
    // ...
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        
        if (ENABLE_PLUGINS) {
            self.plugin_manager = try PluginManager.init(allocator);
        }
        
        if (ENABLE_TELEMETRY) {
            self.telemetry = try Telemetry.init(allocator);
        }
        
        return self;
    }
};
```