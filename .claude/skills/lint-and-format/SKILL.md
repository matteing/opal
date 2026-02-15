---
name: lint-and-format
description: Runs linting and formatting checks before committing. Use this skill after writing or modifying code to ensure it passes all linters and formatters before creating a commit.
globs: "{packages/core,packages/cli}/**/*.{ex,exs,ts,tsx,js,json}"
---

# Lint & Format Skill

You ensure all code passes the project's linters and formatters before it gets committed. This mirrors the lefthook pre-commit hooks and CI checks so problems are caught immediately.

## When to act

- After writing or modifying any source file, **before creating a commit**.
- When the user asks to fix lint or formatting issues.
- When a commit or CI fails due to formatting.

## Commands

### Elixir (packages/core/)

```bash
# Check formatting (what CI runs)
pnpm nx run core:lint

# Auto-fix formatting
pnpm nx run core:format
```

### TypeScript/JavaScript (packages/cli/)

```bash
# ESLint check
pnpm nx run cli:lint

# ESLint auto-fix
pnpm nx run cli:lint:fix

# Prettier check
pnpm nx run cli:format:check

# Prettier auto-fix
pnpm nx run cli:format
```

### Run everything

```bash
# Check all (what CI runs)
pnpm lint

# Fix all
pnpm format
```

## Workflow

1. After making code changes, run the relevant lint/format check commands.
2. If there are failures, auto-fix them using the fix variants.
3. If auto-fix changes files, review the diff to make sure nothing unexpected changed.
4. Only then proceed with staging and committing.

## Rules

1. **Never commit code that fails linting or formatting checks.**
2. Prefer auto-fix (`pnpm format`, `lint:fix`) over manual edits when possible.
3. If a lint rule seems wrong for a specific case, discuss with the user before adding a suppression comment.
4. Do not disable or weaken lint rules without explicit approval.
