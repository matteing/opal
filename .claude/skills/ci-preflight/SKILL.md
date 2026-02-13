---
name: ci-preflight
description: Runs the full CI check suite locally before pushing. Use this skill before pushing a branch or when the user asks to verify everything passes, to catch issues before they hit CI.
globs: "**/*"
---

# CI Preflight Skill

You run the same checks that GitHub Actions CI performs, but locally, to catch failures before pushing. This saves time and keeps the commit history clean.

## When to act

- Before pushing a branch to remote.
- When the user asks to "run CI", "check everything", or "preflight".
- After a large set of changes to verify nothing is broken.

## Check sequence

Run these in order. Stop and fix issues at each step before proceeding.

### 1. Elixir core

```bash
# Compile with warnings-as-errors (matches CI)
pnpm nx run core:build

# Check formatting
pnpm nx run core:lint

# Run tests
pnpm nx run core:test
```

### 2. TypeScript CLI

```bash
# Lint (ESLint)
pnpm nx run cli:lint

# Verify codegen is current
pnpm nx run cli:codegen:check

# Build (typecheck + compile)
pnpm nx run cli:build
```

### 3. Quick summary

Or run everything at once:

```bash
pnpm lint && pnpm build && pnpm test
```

## Rules

1. **Every check must pass before pushing.** If something fails, fix it first.
2. Report results clearly — list what passed and what failed.
3. For failures, diagnose the root cause and suggest or apply fixes.
4. If a test is flaky (passes on retry), flag it to the user rather than silently retrying.
