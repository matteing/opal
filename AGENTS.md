# Opal Project Guide

**Opal** is a coding agent harness built with Elixir/OTP for AI coding agents.

## Architecture

- **Everything is a Process** - Agent loops, sessions, and tools are GenServers
- **Cross-Platform** - Works on macOS, Linux, and Windows

## Components

- `opal/` - Elixir SDK (agent engine, tools, providers)
- `packages/opal-sdk/` - TypeScript client SDK (`@unfinite/opal-sdk`)
- `cli/` - Terminal UI application (`@unfinite/opal`)
- `app/` - Desktop UI application (Electron + React)

## Built-in Tools

- `read_file`, `write_file`, `edit_file` - File operations with hashline tags
- `grep` - Cross-platform search with glob filtering
- `shell` - Cross-platform command execution
- `sub_agent` - Spawn child agents for parallel work
- `tasks` - Task tracker for planning

## Build System

**mise is the sole entry point for all build, test, lint, and format tasks.**
Never run `pnpm -r build` or `pnpm build` directly — always use `mise run <task>`.
Package-level `pnpm` scripts exist only so mise can call them; they are not
developer-facing commands.

### Why mise, not pnpm scripts

- Opal is a **cross-language** monorepo (Elixir + TypeScript). pnpm only
  knows about JS packages — it can't orchestrate `mix compile` or codegen.
- mise handles the full dependency graph: `build:core → codegen → build:sdk → build:cli + build:app`.
- pnpm workspaces handle JS dependency resolution (`workspace:*` linking).
  mise handles task orchestration. Each does what it's good at.

### Task reference

```bash
# ── Build ──────────────────────────────────────────────
mise run build            # Full build: core → codegen → SDK → CLI + App
mise run build:core       # Compile Elixir
mise run codegen          # Generate TS types from Elixir protocol
mise run build:sdk        # Compile TypeScript SDK
mise run build:cli        # Compile TypeScript CLI
mise run build:app        # Build desktop app (Electron + React)

# ── Test ───────────────────────────────────────────────
mise run test             # Run all tests (parallel)
mise run test:core        # Elixir tests
mise run test:sdk         # SDK tests
mise run test:cli         # CLI tests

# ── Lint ───────────────────────────────────────────────
mise run lint             # Lint all projects (parallel)
mise run lint:core        # Elixir format + dialyzer
mise run lint:sdk         # SDK format-check + typecheck
mise run lint:cli         # CLI eslint + format-check
mise run lint:app         # App format-check + typecheck

# ── Format ─────────────────────────────────────────────
mise run format           # Format all projects (parallel)
mise run format:core      # mix format
mise run format:sdk       # prettier
mise run format:cli       # eslint --fix + prettier
mise run format:app       # prettier

# ── Dev ────────────────────────────────────────────────
mise run dev              # Build + launch CLI
mise run app:dev          # Launch desktop app with HMR
mise run server           # Start opal-server standalone
mise run inspect          # Connect to running instance via iex

# ── Dependencies ───────────────────────────────────────
mise run deps             # Install everything (Elixir + JS)
mise run deps:elixir      # mix deps.get
mise run deps:node        # pnpm install (all workspaces)

# ── CI / Release ───────────────────────────────────────
mise run precommit        # Full CI preflight
mise run codegen:check    # Verify codegen is up-to-date
mise run release          # Bump, commit, tag
```

### Convention for new tasks

- Namespace with `:` — `build:foo`, `test:foo`, `lint:foo`, `format:foo`
- Top-level aggregators (`build`, `test`, `lint`, `format`) use `depends = ["<task>:*"]`
  so new sub-tasks are automatically included
- Each sub-task sets `dir` to scope to its project directory
- Sub-tasks call `pnpm <script>` which runs the package-local script
- The dependency graph is encoded in `depends` — mise handles ordering
