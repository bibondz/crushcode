---
id: providers
status: draft
created: 2026-02-06
updated: 2026-02-06
source: crushcode-extensibility
---

# AI Providers Specification

## Purpose

Crushcode SHALL provide unified access to 17 AI providers through a consistent interface, abstracting provider-specific differences while preserving unique capabilities.

## Overview

The provider system enables:
- Consistent API across all providers
- Provider-specific configuration
- Model selection and management
- Authentication handling
- Rate limiting and retries

## Requirements

### Requirement: Provider Abstraction
The system SHALL provide a unified interface for all AI providers.

#### Scenario: Switch Providers
- GIVEN user has configured multiple providers
- WHEN they specify `--provider openai`
- THEN the system SHALL use OpenAI's API
- AND SHALL maintain consistent response format

### Requirement: Model Discovery
Each provider SHALL expose available models through a common interface.

#### Scenario: List Models
- GIVEN user wants to see available models
- WHEN they run `crushcode list`
- THEN the system SHALL query all configured providers
- AND SHALL display models grouped by provider

### Requirement: Configuration Management
Each provider SHALL support provider-specific configuration.

#### Scenario: Provider Configuration
- GIVEN provider requires API key
- WHEN user runs `crushcode config set openai.api_key=sk-...`
- THEN the system SHALL store configuration securely
- AND SHALL use it for API calls

### Requirement: Streaming Support
The system SHALL support streaming responses where available.

#### Scenario: Stream Response
- GIVEN provider supports streaming
- WHEN user requests streaming chat
- THEN the system SHALL stream tokens as they arrive
- AND SHALL display them in real-time

### Requirement: Error Handling
The system SHALL handle provider-specific errors gracefully.

#### Scenario: API Error
- GIVEN provider returns an error
- WHEN the system receives the error
- THEN it SHALL translate to common error format
- AND SHALL provide helpful error message

## Architecture

### Provider Interface

```zig
pub const Provider = struct {
    const Self = @This();
    
    name: []const u8,
    type: ProviderType,
    
    // Configuration
    config: ProviderConfig,
    
    // API methods
    chat: *const fn(self: *Self, request: ChatRequest) !ChatResponse,
    stream_chat: *const fn(self: *Self, request: ChatRequest, handler: StreamHandler) !void,
    list_models: *const fn(self: *Self) ![]Model,
    
    // Lifecycle
    init: *const fn(config: ProviderConfig) !*Self,
    deinit: *const fn(self: *Self) void,
    
    // Health check
    check_health: *const fn(self: *Self) !HealthStatus,
};

pub const ProviderType = enum {
    openai,
    anthropic,
    google,
    xai,
    mistral,
    groq,
    deepseek,
    together,
    azure_openai,
    vertex_ai,
    bedrock,
    ollama,
    lm_studio,
    llama_cpp,
    openrouter,
    zai,
    vercel_gateway,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []Message,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: bool = false,
    tools: ?[]Tool = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []Choice,
    usage: Usage,
};

pub const StreamHandler = *const fn(token: []const u8) void;
```

### Provider Manager

```zig
pub const ProviderManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    providers: std.hash_map.StringHashMap(*Provider),
    config: Config,
    
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self;
    pub fn deinit(self: *Self) void;
    
    pub fn add_provider(self: *Self, name: []const u8, provider_type: ProviderType) !void;
    pub fn remove_provider(self: *Self, name: []const u8) !void;
    pub fn get_provider(self: *Self, name: []const u8) ?*Provider;
    
    pub fn chat(self: *Self, provider_name: []const u8, request: ChatRequest) !ChatResponse;
    pub fn stream_chat(self: *Self, provider_name: []const u8, request: ChatRequest, handler: StreamHandler) !void;
    pub fn list_all_models(self: *Self) !ModelList;
};
```

## Provider Implementations

### Remote Providers

#### OpenAI
```zig
pub const OpenAIProvider = struct {
    const Self = @This();
    
    base_url: []const u8 = "https://api.openai.com/v1",
    api_key: []const u8,
    organization: ?[]const u8 = null,
    
    pub fn init(config: ProviderConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .api_key = config.get("api_key"),
            .organization = config.get("organization"),
        };
        return self;
    }
    
    pub fn chat(self: *Self, request: ChatRequest) !ChatResponse {
        // Implementation for OpenAI chat completion
    }
    
    pub fn stream_chat(self: *Self, request: ChatRequest, handler: StreamHandler) !void {
        // Implementation for OpenAI streaming
    }
    
    pub fn list_models(self: *Self) ![]Model {
        // Implementation for OpenAI models
    }
};
```

#### Anthropic Claude
```zig
pub const AnthropicProvider = struct {
    const Self = @This();
    
    base_url: []const u8 = "https://api.anthropic.com/v1",
    api_key: []const u8,
    
    pub fn init(config: ProviderConfig) !*Self { /* ... */ }
    
    pub fn chat(self: *Self, request: ChatRequest) !ChatResponse {
        // Anthropic API has different request/response format
        // Need to convert between formats
    }
};
```

### Local Providers

#### Ollama
```zig
pub const OllamaProvider = struct {
    const Self = @This();
    
    host: []const u8 = "http://localhost:11434",
    
    pub fn init(config: ProviderConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .host = config.get("host") orelse "http://localhost:11434",
        };
        return self;
    }
    
    pub fn chat(self: *Self, request: ChatRequest) !ChatResponse {
        // Ollama has different API format
        // Need to handle locally running models
    }
    
    pub fn list_models(self: *Self) ![]Model {
        // Query Ollama for available models
    }
};
```

## Configuration

### Provider Configuration Schema

```toml
[providers.openai]
type = "openai"
api_key = "${OPENAI_API_KEY}"
base_url = "https://api.openai.com/v1"
organization = "org-..."
max_retries = 3
timeout = 30

[providers.anthropic]
type = "anthropic"
api_key = "${ANTHROPIC_API_KEY}"
base_url = "https://api.anthropic.com/v1"
max_retries = 3
timeout = 30

[providers.ollama]
type = "ollama"
host = "http://localhost:11434"
timeout = 60

[providers.custom]
type = "openai_compatible"
api_key = "${CUSTOM_API_KEY}"
base_url = "https://api.custom.com/v1"
```

### Environment Variables

- `OPENAI_API_KEY` - OpenAI API key
- `ANTHROPIC_API_KEY` - Anthropic API key
- `GOOGLE_API_KEY` - Google AI API key
- `XAI_API_KEY` - X.AI API key
- `CRUSHCODE_DEFAULT_PROVIDER` - Default provider
- `CRUSHCODE_DEFAULT_MODEL` - Default model

## CLI Integration

### Provider Commands

```bash
# List all providers and models
crushcode list

# List specific provider's models
crushcode list --provider openai

# Set default provider
crushcode config set default.provider=openai
crushcode config set default.model=gpt-4o

# Set provider-specific config
crushcode config set providers.openai.organization=org-123

# Test provider connection
crushcode test --provider openai

# Show provider status
crushcode status --provider openai
```

### Chat with Specific Provider

```bash
# Use specific provider for this request
crushcode chat --provider anthropic "Explain quantum computing"

# Use specific model
crushcode chat --provider openai --model gpt-4-turbo "Write Python code"

# Stream response
crushcode chat --provider ollama --model llama2 --stream "Hello"
```

## Error Handling

### Error Types

```zig
pub const ProviderError = error{
    AuthenticationFailed,
    RateLimited,
    ModelNotFound,
    InvalidRequest,
    NetworkError,
    Timeout,
    ProviderUnavailable,
    InvalidResponse,
    QuotaExceeded,
};
```

### Error Recovery

```zig
pub fn handle_provider_error(err: ProviderError, provider: []const u8) !void {
    switch (err) {
        ProviderError.RateLimited => {
            const backoff = calculate_backoff(provider);
            std.time.sleep(backoff);
            return retry_request();
        },
        ProviderError.AuthenticationFailed => {
            std.log.err("Authentication failed for {s}", .{provider});
            return error.ConfigError;
        },
        ProviderError.NetworkError => {
            return retry_with_timeout();
        },
        else => return err,
    }
}
```

## Performance Considerations

### Request Pooling
- Reuse HTTP connections where possible
- Implement connection pooling
- Support HTTP/2 for multiplexing

### Caching
- Cache model lists
- Cache configuration validation
- Cache provider capabilities

### Rate Limiting
- Implement per-provider rate limiting
- Track API usage
- Implement exponential backoff

## Testing

### Provider Testing

```zig
test "openai provider initialization" {
    const config = ProviderConfig.init(testing.allocator);
    defer config.deinit();
    
    try config.set("api_key", "test-key");
    
    const provider = try OpenAIProvider.init(config);
    defer provider.deinit();
    
    try testing.expectEqualStrings("openai", provider.name);
}

test "provider error handling" {
    // Test network errors
    // Test authentication errors
    // Test rate limiting
    // Test invalid responses
}
```

### Mock Providers for Testing

```zig
pub const MockProvider = struct {
    const Self = @This();
    
    name: []const u8 = "mock",
    responses: []const []const u8,
    
    pub fn init(responses: []const []const u8) Self {
        return Self{ .responses = responses };
    }
    
    pub fn chat(self: *Self, request: ChatRequest) !ChatResponse {
        // Return predefined response
    }
};
```

## Documentation Requirements

### Provider Guides
- Setup instructions for each provider
- API key management
- Rate limit information
- Model availability and capabilities

### Model Documentation
- Model comparison table
- Use case recommendations
- Cost comparison
- Performance benchmarks