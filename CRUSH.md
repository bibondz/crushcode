# CRUSH Naming Conventions

## Forge Alias System

Crushcode uses a **dual-name** command system:
- **Canonical names**: `chat`, `read`, `write`, `edit`, etc. — always work
- **Forge aliases**: `strike`, `sparks`, `smelt`, `anvil`, etc. — thematic alternatives

### Rules

1. **Never remove canonical names** — Forge aliases are additions, not replacements
2. **Forge aliases map 1:1** to canonical commands — no new behavior
3. **Help text shows both** — users discover Forge names naturally
4. **Description format**: `"Forge alias: {purpose} (→ {canonical})"` in registry

### Adding New Forge Aliases

When adding a new CLI command, optionally add a Forge alias:
1. Add canonical command entry to `src/cli/registry.zig` `commands` array
2. Add Forge alias entry with same handler, description format: `"Forge alias: {purpose} (→ {canonical})"`
3. Update FORGE_GLOSSARY.md table
4. Update help text in `src/commands/handlers.zig` `printHelp()`

### Forge Name Selection Criteria

Good Forge names relate to blacksmithing/metallurgy:
- Verbs for actions: `strike`, `smelt`, `quench`
- Nouns for objects: `anvil`, `furnace`, `bellows`
- Concepts: `forge`, `alloy`, `blueprint`

Avoid names that are:
- Already used as canonical commands
- Too similar to existing Forge aliases
- Ambiguous (e.g., `heat` could mean many things)

### Trademark Safety

The Forge naming system avoids trademarked terms from reference projects:
- Not "agent" (generic) → "smith" (unique)
- Not "skill" (generic) → "alloy" (unique branding)
- Not "plan mode" → "blueprint" (unique)
- Not "MCP" (protocol standard, safe to reference) → "tongs" (our wrapper name)

Generic technical terms (MCP, LSP, TOML, JSON, API, HTTP) remain as-is — they are open standards.
