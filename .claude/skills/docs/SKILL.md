---
name: docs
description: Maintains evergreen documentation in docs/. Use this skill when a major feature is added, changed, or removed to keep the corresponding explainer up to date. Also use when the user asks to document something or references this skill.
globs: docs/**
---

# Documentation Skill

You maintain the `docs/` directory as the source of truth for how Opal works. Each major feature or subsystem gets an evergreen explainer that stays current as the code changes.

## When to act

- A feature is added, significantly changed, or removed → update or create the relevant doc.
- The user explicitly asks to document something.
- A pull request changes behavior described in an existing doc.

## Format guidelines

Write docs that are **right-sized** — long enough to be useful, short enough to actually be read.

- **Start with a one-paragraph overview** of what the feature does and why it exists.
- **Show the interface** (tool schema, function signature, config keys) before explaining internals.
- **Use Mermaid diagrams** for pipelines, data flow, and architecture — never ASCII art. Wrap in ` ```mermaid ` fenced blocks.
- **Include a "How it works" section** with just enough detail to debug or extend the feature. Skip implementation trivia.
- **End with a References section** linking to external sources, blog posts, papers, or benchmarks that informed the design. Always include references the user has provided.
- **No timestamps or version numbers** — the doc describes the current state, not a changelog.

## File organization

```
docs/
├── ARCHITECTURE.md       # System-level overview
├── tools/
│   ├── edit.md           # Edit tool (hashline, str_replace history)
│   └── ...               # One file per major tool or tool concept
├── agent-loop.md         # Agent execution model
├── compaction.md         # Context compaction
├── supervision.md        # OTP supervision tree
└── ...                   # One file per subsystem
```

Place tool docs in `docs/tools/`. Place subsystem docs directly in `docs/`.

## Style

- Write for a developer who knows the language but not the codebase.
- Prefer concrete examples over abstract descriptions.
- Use code blocks for schemas, configs, and short snippets.
- Keep headings to 3 levels max (##, ###, no ####).
- Link to source files when referencing specific modules (e.g. `core/lib/opal/tool/edit_lines.ex`).

## References

When the user provides external references (blog posts, papers, benchmarks), always include them in a ## References section at the bottom of the doc with title, author/source, year, and a one-line description of relevance.
