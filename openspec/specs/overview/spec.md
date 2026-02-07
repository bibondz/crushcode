---
id: overview
status: draft
created: 2026-02-06
updated: 2026-02-06
source: openspec/changes/crushcode-category-proposal/proposal.md
---

# Crushcode Overview Specification

## Purpose

Crushcode is a Zig-based AI CLI application designed to provide unified access to multiple AI providers through a command-line interface with plugin architecture for extensibility.

## Overview

### Project Goals

1. **Multi-Provider Support**: Unified interface for 17 AI providers
2. **Performance**: Fast startup and execution (Zig's zero-cost abstractions)
3. **Extensibility**: Plugin system for custom functionality
4. **Configuration**: Flexible configuration management
5. **Cross-Platform**: Support for Windows, macOS, and Linux

### Key Features

#### Multi-Provider Architecture
- Remote providers: OpenAI, Anthropic, Google, XAI, Mistral, Groq, DeepSeek, Together AI, Azure OpenAI, Google Vertex AI, AWS Bedrock, OpenRouter, Z.ai, Vercel Gateway
- Local providers: Ollama, LM Studio, llama.cpp

#### Plugin System
- Dynamic plugin loading
- Plugin configuration
- Extension points for custom functionality

#### Configuration Management
- TOML-based configuration files
- Environment variable support
- CLI argument handling
- Provider-specific settings

#### CLI Interface
- Subcommands: chat, list, config, plugin
- Streaming responses
- Interactive and batch modes

## Requirements

### Requirement: Multi-Provider Support
The system SHALL provide unified access to multiple AI providers.

#### Scenario: Switch Between Providers
- GIVEN user has multiple provider accounts configured
- WHEN they use `--provider` flag
- THEN the system SHALL connect to the specified provider
- AND the API SHALL remain consistent

### Requirement: Plugin System
The system SHALL support dynamic plugin loading.

#### Scenario: Install Plugin
- GIVEN user has a plugin file
- WHEN they run `crushcode plugin install <plugin>`
- THEN the plugin SHALL be loaded dynamically
- AND its functionality SHALL be available

### Requirement: Configuration Management
The system SHALL support multiple configuration sources.

#### Scenario: Hierarchical Configuration
- GIVEN user has system, user, and project configs
- WHEN they run any command
- THEN the system SHALL merge configurations
- AND project config SHALL override system config

### Requirement: Performance
The system SHALL start quickly and handle concurrent requests.

#### Scenario: Fast Startup
- GIVEN user wants quick AI assistance
- WHEN they run `crushcode chat`
- THEN the CLI SHALL start within 200ms
- AND SHALL be ready for input

## Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   CLI Interface │───▶│  Command Router  │───▶│  Provider       │
└─────────────────┘    └──────────────────┘    │   Manager       │
         │                      │              └─────────────────┘
         ▼                      ▼                       │
┌─────────────────┐    ┌──────────────────┐             ▼
│  Configuration  │◀───│   Plugin System  │    ┌─────────────────┐
│    Manager      │    │                 │───▶│  HTTP Client    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                                                    │
         ▼                                                    ▼
┌─────────────────┐                                    ┌─────────────────┐
│  Config Files   │                                    │  Provider APIs  │
└─────────────────┘                                    └─────────────────┘
```

### Component Responsibilities

#### CLI Interface
- Parse command-line arguments
- Display help and version information
- Handle interactive input

#### Command Router
- Route commands to appropriate handlers
- Validate arguments
- Manage command execution

#### Configuration Manager
- Load and merge configurations
- Handle environment variables
- Manage provider settings

#### Plugin System
- Load and unload plugins
- Manage plugin lifecycle
- Provide plugin API

#### Provider Manager
- Abstract provider differences
- Handle provider-specific logic
- Manage API connections

#### HTTP Client
- Make HTTP requests to provider APIs
- Handle authentication
- Manage retries and timeouts

## Dependencies

### Build Dependencies
- Zig 0.15.2 or later
- Zig's built-in package manager

### Runtime Dependencies
- No external runtime dependencies
- Optional: Docker for local providers

## Security Considerations

### API Keys
- API keys SHALL NOT be hard-coded
- Support environment variables
- Support config files with proper permissions

### Plugin Security
- Plugins SHALL run with user privileges
- Plugin loading SHALL be configurable
- System SHALL validate plugin format

### Network Security
- Support HTTPS for all remote providers
- Support proxy configuration
- Handle SSL certificates properly

## Performance Targets

| Metric | Target | Measurement |
|---------|--------|-------------|
| CLI Startup | < 200ms | Time from exec to ready |
| First Response | < 500ms | Time to first token |
| Memory Usage | < 50MB | Resident set size |
| Plugin Load | < 100ms | Time to load plugin |

## Compatibility

### Supported Platforms
- Windows 10/11 (x64)
- macOS 10.15+ (x64, ARM64)
- Linux (x64, ARM64)

### Supported Providers
See providers specification for detailed list.

## Documentation Requirements

### User Documentation
- README.md with quick start guide
- Provider configuration examples
- Plugin development guide

### Developer Documentation
- API documentation for providers
- Plugin development API
- Architecture documentation