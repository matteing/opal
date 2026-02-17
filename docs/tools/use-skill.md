# use_skill

Loads agent skill instructions into the active context on demand.

## Parameters

| Param        | Type   | Required | Description               |
| ------------ | ------ | -------- | ------------------------- |
| `skill_name` | string | yes      | Name of the skill to load |

## Behavior

Skills are discovered during context discovery (AGENTS.md, SKILL.md files in `.claude/skills/`, `.opal/skills/`, etc.) but only their name and description are visible initially. This keeps the system prompt small.

When the LLM decides a skill is relevant, it calls `use_skill` to load the full instructions into the agent's context. The skill's content is injected as additional system context for all subsequent turns.

## Responses

| Result                                                             | Meaning                      |
| ------------------------------------------------------------------ | ---------------------------- |
| `"Skill 'docs' loaded. Its instructions are now in your context."` | Instructions now active      |
| `"Skill 'docs' is already loaded."`                                | Idempotent — no error        |
| `"Skill 'docs' not found"`                                         | No matching skill discovered |

## Progressive Disclosure

This is a context-efficiency pattern. Instead of loading all skill instructions upfront (which could consume thousands of tokens), only metadata is shown. The LLM loads full instructions when needed, keeping the base system prompt lean.

## Spec Conformance

Opal's skill system closely follows the [Agent Skills](https://agentskills.io) spec. To reduce implementation complexity, we intentionally omit support for `globs`-based auto-activation — skills are always loaded explicitly via `use_skill`.

## Source

`lib/opal/tool/use_skill.ex`, `lib/opal/skill.ex`
