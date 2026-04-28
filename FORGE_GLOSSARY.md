# Forge Glossary

Crushcode's Forge naming system provides thematic blacksmith/forge aliases for all major CLI commands. Original command names continue to work — Forge names are pure aliases.

## Command Aliases

| Forge Alias | Command | Description |
|-------------|---------|-------------|
| `forge` | `crush` | Auto-agentic: plan → execute → verify → commit |
| `strike` | `chat` | Start interactive chat session |
| `furnace` | `tui` | Launch terminal UI |
| `alloy` | `skill` | Run a skill command |
| `anvil` | `edit` | Edit or create a file |
| `bellows` | `shell` | Execute shell command |
| `blueprint` | `scaffold` | Project scaffolding |
| `ledger` | `usage` | Show token usage and costs |
| `smiths` | `agents` | Spawn multiple AI agents |
| `rack` | `tools` | List, enable, disable tools |
| `tongs` | `grep` | AST-grep pattern search |
| `reheat` | `sessions` | Manage chat sessions |
| `slag` | `diff` | Compare two files |
| `sparks` | `read` | Read file content |
| `smelt` | `write` | Write content to file |
| `quench` | `checkpoint` | Manage checkpoints |
| `foundry` | `mcp` | MCP tools management |

## Usage

```bash
# Original commands still work
crushcode chat --provider openai
crushcode tui
crushcode edit src/main.zig

# Forge aliases do the same thing
crushcode strike --provider openai
crushcode furnace
crushcode anvil src/main.zig
```

## Philosophy

The Forge naming system reflects the craft of software development:
- **Forging** is building — transforming raw material (code) into something useful
- **Striking** is engaging — each interaction shapes the result
- **Quenching** is preserving — saving your work at the right moment
- **Smelting** is creating — extracting value from raw input

## Forge Terminology (Extended)

Beyond CLI aliases, the Forge system extends to internal concepts:

| Concept | Forge Name | Description |
|---------|-----------|-------------|
| AI Provider | **Furnace** | The heat source — OpenAI, Anthropic, Ollama, etc. |
| AI Model | **Flame** | Type of fire — GPT-4, Claude, Llama, etc. |
| API Key | **Fuel** | What powers the furnace |
| Agent | **Smith** | One who works the forge |
| Main agent | **Master Smith** | Lead forge worker |
| Junior agent | **Apprentice** | Learning the trade |
| Research agent | **Prospector** | Finds raw materials (data) |
| Docs agent | **Archivist** | Keeps the records |
| Consultant | **Elder** | Wisdom from experience |
| Reviewer | **Inspector** | Quality control |
| Plan mode | **Blueprint** | Draw before you forge |
| Skill file | **Alloy.md** | SKILL.md equivalent — describes the metal mixture |
| MCP client | **Tongs** | Grasp external tools safely |
| Sandbox | **Quench** | Isolate command execution |
| Context pruning | **Temper** | Heat treatment — reduce brittleness |
| Session | **Anvil** | The work surface — persists between strikes |
| Permission system | **Foundry Rules** | Safety protocols |
| Todo list | **Strike List** | List of hits to make |
| Background job | **Bellows** | Air flow in background |
| Tool registry | **Tool Rack** | Available forging tools |
| Orchestration | **The Forge** | Whole system coordination |
| Conversation | **Heat** | Active session — keep the fire going |
| Compaction | **Slag** | Remove impurities — compress context |
| Checkpoint/undo | **Reheat** | Reheat to reshape — rollback |
| Streaming output | **Sparks** | Real-time — flying sparks |
| Error recovery | **Refine** | Purify through repeated heating |
| External files | **Ore Pile** | Raw materials outside the forge |
| Chat history | **Ledger** | Record of past work |
| Agent category | **Guild** | Specialty classification |
| Subagent task | **Shift** | A work assignment |
