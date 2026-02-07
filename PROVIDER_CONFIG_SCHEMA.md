# Provider Configuration Schema for Crushcode

## Configuration Format

Crushcode uses TOML configuration files for AI provider settings. The configuration supports:

### File Locations
1. **Global:** `~/.crushcode/providers.toml`
2. **Project:** `./crushcode.toml` (overrides global)
3. **Environment:** `CRUSHCODE_PROVIDERS` (JSON string, overrides all)

### Structure

```toml
# Default provider and model
[default]
provider = "openai"
model = "gpt-4"

# Provider-specific settings
[providers.openai]
base_url = "https://api.openai.com/v1"
models = ["gpt-4", "gpt-3.5-turbo", "gpt-4-turbo"]
default_model = "gpt-4"

[providers.openai.rate_limits]
requests_per_minute = 60
tokens_per_minute = 150000
concurrent_requests = 5

[providers.openai.auth]
type = "api_key"
env_var = "OPENAI_API_KEY"
# OR
header_name = "Authorization"
header_value = "Bearer ${OPENAI_API_KEY}"

[providers.openai.headers]
User-Agent = "Crushcode/1.0"
X-Custom-Header = "custom-value"

# Local providers
[providers.ollama]
type = "local"
base_url = "http://localhost:11434"
models = ["llama2", "codellama", "mistral"]
default_model = "llama2"
timeout_seconds = 30

[providers.ollama.rate_limits]
requests_per_minute = 120
concurrent_requests = 3

# Custom provider
[providers.custom_llm]
type = "custom"
base_url = "https://api.custom-llm.com/v1"
models = ["custom-model-1", "custom-model-2"]
default_model = "custom-model-1"

[providers.custom_llm.rate_limits]
requests_per_minute = 30
tokens_per_minute = 100000
concurrent_requests = 2

[providers.custom_llm.auth]
type = "bearer_token"
header_name = "Authorization"
header_value = "Bearer ${CUSTOM_TOKEN}"

# Fallback configuration
[fallback]
enabled = true
providers = ["anthropic", "openai"]
switch_on_errors = ["rate_limit", "timeout", "server_error"]
retry_with_fallback = true

# Retry policy configuration
[retry_policy]
default_max_attempts = 3
default_backoff_factor = 2.0
max_backoff_seconds = 60
jitter = true

[retry_policy.provider_overrides]
openai = { max_attempts = 5, backoff_factor = 1.5 }
anthropic = { max_attempts = 2, backoff_factor = 3.0 }

# Error handling
[error_handling]
retry_on_errors = ["timeout", "connection_error", "rate_limit"]
fail_fast_on_errors = ["authentication", "invalid_request"]
log_all_errors = true
log_success = false

# Performance settings
[performance]
request_timeout = 30
connect_timeout = 10
keep_alive = true
compression = "gzip"
```

## Configuration Values

### Provider Types
- **`api`** - Standard REST API providers (OpenAI, Anthropic, etc.)
- **`local`** - Local LLM servers (Ollama, LM Studio, etc.)
- **`custom`** - Custom API implementations

### Rate Limits
- **`requests_per_minute`** - Maximum requests per minute
- **`tokens_per_minute`** - Maximum tokens per minute (if provider reports)
- **`concurrent_requests`** - Maximum simultaneous requests

### Authentication Types
- **`api_key`** - Standard API key (looks for `env_var`)
- **`bearer_token`** - Bearer token with custom header
- **`basic_auth`** - Basic authentication
- **`oauth`** - OAuth2 (future)

### Fallback Behavior
- Automatic switching to backup providers
- Preserves conversation context
- Optional retry with fallback

## Implementation Notes

### Hot-reload Support
The configuration is watched for changes and reloaded automatically:

1. **File change detected**
2. **New configuration parsed**
3. **Provider connections updated**
4. **Active requests complete with old settings**
5. **New requests use updated settings**

### Environment Variable Expansion
Configuration values support `${VAR}` syntax:
```toml
header_value = "Bearer ${OPENAI_API_KEY}"
base_url = "https://${HOST}/v1"
```

### Validation Rules
- `base_url` must be valid URL
- `models` list cannot be empty
- `default_model` must be in models list
- Rate limits must be positive integers
- Authentication must provide valid credentials

### Default Values
If not specified:
- `rate_limits.requests_per_minute` = 60
- `rate_limits.concurrent_requests` = 5
- `timeout_seconds` = 30
- `retry_policy.default_max_attempts` = 3
- `retry_policy.default_backoff_factor` = 2.0