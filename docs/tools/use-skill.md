# use_skill

Loads agent skill instructions into the active context on demand.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `skill_name` | string | yes | Name of the skill to load |

## Behavior

Skills are discovered during context discovery (AGENTS.md, SKILL.md files in `.claude/skills/`, `.opal/skills/`, etc.) but only their name and description are visible initially. This keeps the system prompt small.

When the LLM decides a skill is relevant, it calls `use_skill` to load the full instructions into the agent's context. The skill's content is injected as additional system context for all subsequent turns.

### Glob Auto-Activation

Skills can declare `globs` patterns in their SKILL.md frontmatter. When a file-modifying tool (`write_file`, `edit_file`) writes to a path matching a skill's glob, the skill is automatically loaded without requiring an explicit `use_skill` call.

```yaml
---
name: docs
description: Maintains project documentation.
globs: docs/**
---
```

Multiple patterns are supported as a YAML list:

```yaml
globs:
  - docs/**
  - "*.md"
```

## Responses

| Result | Meaning |
|--------|---------|
| `"Skill 'docs' loaded. Its instructions are now in your context."` | Instructions now active |
| `"Skill 'docs' is already loaded."` | Idempotent — no error |
| `"Skill 'docs' not found"` | No matching skill discovered |

## Progressive Disclosure

This is a context-efficiency pattern. Instead of loading all skill instructions upfront (which could consume thousands of tokens), only metadata is shown. The LLM loads full instructions when needed, keeping the base system prompt lean.

## Source

`lib/opal/tool/use_skill.ex`, `lib/opal/skill.ex`
