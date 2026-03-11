# Phase 0 — SDK Extraction & Monorepo

> Extract the TypeScript SDK into `@unfinite/opal-sdk`, set up pnpm workspaces, and update the build pipeline.

## Goal

Before building Opal Desktop, the TypeScript SDK must become a standalone package that both the CLI and the desktop app can depend on. Today the SDK lives inside `cli/src/sdk/` and is published as part of `@unfinite/opal`. This phase extracts it into `@unfinite/opal-sdk`, introduces pnpm workspaces for monorepo orchestration, and updates the codegen pipeline to target the new location.

## Why This Matters

- **The CLI currently bundles the SDK** — `@unfinite/opal`'s `main` and `exports` point at `dist/sdk/index.js`. Consumers who `import { createSession } from "@unfinite/opal"` get the SDK. But the package also ships the entire CLI binary, Ink, React, Zustand, and every CLI dependency. That's wrong for library consumers.
- **The desktop app needs the same SDK** — duplicating the SDK source is not an option. It must be a shared dependency.
- **Codegen targets a hardcoded path** — `scripts/codegen_ts.exs` writes to `../cli/src/sdk/protocol.ts`. This must be updated.

## Current State

```
opal/                          # Elixir SDK + agent engine
├── lib/opal/rpc/protocol.ex   # Source of truth for RPC types
├── priv/rpc_schema.json       # Generated JSON Schema (intermediate)
cli/                           # CLI app (Ink/React TUI)
├── package.json               # @unfinite/opal — CLI + SDK bundled together
├── src/
│   ├── sdk/                   # ← The SDK we're extracting
│   │   ├── index.ts           # Barrel export (40+ exports)
│   │   ├── session.ts         # createSession(), Session class
│   │   ├── client.ts          # OpalClient (typed JSON-RPC)
│   │   ├── stream.ts          # AgentStream (AsyncIterable)
│   │   ├── match.ts           # Event matching utilities
│   │   ├── errors.ts          # Structured error hierarchy
│   │   ├── resolve.ts         # Server binary discovery
│   │   ├── transforms.ts      # snake_case ↔ camelCase
│   │   ├── protocol.ts        # AUTO-GENERATED — do not edit
│   │   ├── cli-state.ts       # CLI-only (stays in cli/)
│   │   ├── cli-history.ts     # CLI-only (stays in cli/)
│   │   ├── rpc/
│   │   │   ├── connection.ts  # JSON-RPC 2.0 connection
│   │   │   └── types.ts       # JSON-RPC type definitions
│   │   └── transport/
│   │       ├── transport.ts   # Transport interface
│   │       ├── stdio.ts       # Stdio transport (spawns opal-server)
│   │       └── memory.ts      # In-memory transport (testing)
│   ├── bin.ts                 # CLI entry point
│   ├── app.tsx                # Ink React app
│   ├── hooks/                 # CLI hooks (import from ../sdk/)
│   ├── state/                 # CLI state (import from ../sdk/)
│   ├── commands/              # CLI commands (import from ../sdk/)
│   └── components/            # Ink components
scripts/
├── codegen_ts.exs             # Writes to ../cli/src/sdk/protocol.ts
```

### Key Facts

- The SDK has **zero npm dependencies** — it uses only Node.js built-ins (`node:fs`, `node:path`, `node:os`, `node:child_process`, `node:readline`, `node:url`).
- `protocol.ts` is auto-generated from `opal/priv/rpc_schema.json` by `scripts/codegen_ts.exs`.
- `cli-state.ts` and `cli-history.ts` are CLI-specific (file-based preferences/history). They stay in `cli/`.
- 9 test files exist under `cli/src/__tests__/` for the SDK modules.
- The CLI currently uses **pnpm** for package management.
- There is no root `package.json` or `pnpm-workspace.yaml` — no workspace orchestration today.
- Build orchestration is handled by **mise** (`.mise.toml`).

## Target State

```
opal/                           # Elixir SDK (unchanged)
packages/
└── opal-sdk/                   # NEW — @unfinite/opal-sdk
    ├── package.json
    ├── tsconfig.json
    ├── src/
    │   ├── index.ts            # Barrel export
    │   ├── session.ts
    │   ├── client.ts
    │   ├── stream.ts
    │   ├── match.ts
    │   ├── errors.ts
    │   ├── resolve.ts
    │   ├── transforms.ts
    │   ├── protocol.ts         # AUTO-GENERATED
    │   ├── rpc/
    │   │   ├── connection.ts
    │   │   └── types.ts
    │   └── transport/
    │       ├── transport.ts
    │       ├── stdio.ts
    │       └── memory.ts
    └── tests/
        ├── session.test.ts
        ├── stream.test.ts
        ├── client.test.ts
        ├── rpc-connection.test.ts
        ├── errors.test.ts
        ├── match.test.ts
        ├── memory-transport.test.ts
        ├── transforms.test.ts
        └── resolve.test.ts
cli/                            # CLI app (depends on @unfinite/opal-sdk)
├── package.json                # @unfinite/opal — CLI only
├── src/
│   ├── cli-state.ts            # Moved from sdk/ (CLI-specific)
│   ├── cli-history.ts          # Moved from sdk/ (CLI-specific)
│   ├── bin.ts
│   ├── app.tsx
│   └── ...
app/                            # Desktop app (Phase 1+, depends on @unfinite/opal-sdk)
pnpm-workspace.yaml             # NEW — workspace root
package.json                    # NEW — root package.json
tsconfig.base.json              # NEW — shared TypeScript config
```

## Architecture Decisions

### 1. pnpm Workspaces for Monorepo Orchestration

**Why pnpm workspaces over Nx/Turborepo:**

- The CLI already uses pnpm. Zero new tooling to learn.
- pnpm workspaces provide exactly what we need: shared dependencies, `workspace:*` protocol, and recursive script execution.
- mise already handles the Elixir/TypeScript cross-language build pipeline. We don't need a JavaScript-specific build orchestrator on top of that.
- Nx/Turborepo add complexity (config files, plugins, caching infra) that isn't justified for 2-3 TypeScript packages.

**What pnpm workspaces give us:**

- `@unfinite/opal-sdk` is a workspace package — `cli` and `app` depend on it with `"@unfinite/opal-sdk": "workspace:*"`
- `pnpm install` at the root links everything
- `pnpm -r build` / `pnpm -r test` run scripts across all packages
- `workspace:*` resolves to the exact version at publish time (npm sees a real semver range)

### 2. Shared TypeScript Base Config

A root `tsconfig.base.json` provides shared compiler settings. Each package extends it:

```jsonc
// tsconfig.base.json (root)
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true
  }
}
```

```jsonc
// packages/opal-sdk/tsconfig.json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist"
  },
  "include": ["src"]
}
```

### 3. Codegen Targets the New Path

Update `scripts/codegen_ts.exs`:

```diff
- @output_path "../cli/src/sdk/protocol.ts"
+ @output_path "../packages/opal-sdk/src/protocol.ts"
```

The codegen pipeline remains:
1. `mix opal.gen.json_schema` → `opal/priv/rpc_schema.json`
2. `mix run ../scripts/codegen_ts.exs` → `packages/opal-sdk/src/protocol.ts`

### 4. SDK Package Configuration

```jsonc
// packages/opal-sdk/package.json
{
  "name": "@unfinite/opal-sdk",
  "version": "0.2.0",
  "description": "TypeScript client SDK for the Opal agent runtime",
  "license": "MIT",
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "files": ["dist"],
  "engines": {
    "node": ">=22"
  },
  "scripts": {
    "build": "tsc",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "test:coverage": "vitest run --coverage",
    "lint": "eslint src/",
    "lint:fix": "eslint src/ --fix",
    "format": "prettier --write src/",
    "format:check": "prettier --check src/",
    "clean": "rm -rf dist"
  },
  "devDependencies": {
    "@types/node": "^22",
    "@vitest/coverage-v8": "^4.0",
    "vitest": "^4.0"
  }
}
```

> **Zero runtime dependencies.** The SDK uses only Node.js built-ins. This is a feature — it means no transitive dependency hell for consumers.

### 5. CLI Package Updates

The CLI's `package.json` changes:

```diff
  {
    "name": "@unfinite/opal",
-   "main": "dist/sdk/index.js",
-   "types": "dist/sdk/index.d.ts",
-   "exports": {
-     ".": {
-       "import": "./dist/sdk/index.js",
-       "types": "./dist/sdk/index.d.ts"
-     }
-   },
+   "exports": {
+     ".": {
+       "import": "./dist/bin.js"
+     }
+   },
    "dependencies": {
+     "@unfinite/opal-sdk": "workspace:*",
      "ink": "^6.8.0",
      ...
    }
  }
```

All CLI imports change from relative paths to the package name:

```diff
- import { createSession } from "../sdk/session.js";
- import type { AgentEvent } from "../sdk/protocol.js";
+ import { createSession, type AgentEvent } from "@unfinite/opal-sdk";
```

### 6. Index.ts Self-Referencing Fix

The current `index.ts` has a self-referencing import quirk:

```typescript
// Current — references its own parent directory
export { Methods } from "../sdk/protocol.js";
```

After extraction, all imports become sibling-relative:

```typescript
// After extraction — clean relative import
export { Methods } from "./protocol.js";
```

## Workspace Configuration

### Root `pnpm-workspace.yaml`

```yaml
packages:
  - "packages/*"
  - "cli"
  - "app"      # future — Phase 1+
```

### Root `package.json`

```jsonc
{
  "private": true,
  "scripts": {
    "build": "pnpm -r build",
    "test": "pnpm -r test",
    "lint": "pnpm -r lint",
    "format": "pnpm -r format",
    "typecheck": "pnpm -r typecheck",
    "clean": "pnpm -r clean"
  },
  "devDependencies": {
    "prettier": "^3.8",
    "typescript": "~5.9"
  },
  "engines": {
    "node": ">=22"
  },
  "packageManager": "pnpm@10.x"
}
```

> Root-level devDependencies are shared tooling only (prettier, typescript). Package-specific deps live in each package's `package.json`.

### Updated `.mise.toml`

```diff
  [tasks.codegen]
  description = "Generate TS types from Elixir schemas"
  dir = "opal"
  depends = ["build:core"]
  run = "mix run ../scripts/codegen_ts.exs"

+ [tasks."build:sdk"]
+ description = "Compile TypeScript SDK"
+ depends = ["codegen"]
+ dir = "packages/opal-sdk"
+ run = "pnpm build"

  [tasks."build:cli"]
  description = "Compile TypeScript CLI"
- depends = ["codegen"]
+ depends = ["build:sdk"]
  dir = "cli"
- run = "npx tsc -p tsconfig.build.json"
+ run = "pnpm build"

  [tasks.build]
  description = "Full build: core → codegen → SDK → CLI"
  depends = ["build:cli"]

+ [tasks."test:sdk"]
+ description = "Run SDK tests"
+ dir = "packages/opal-sdk"
+ run = "pnpm test"

  [tasks."deps:cli"]
  description = "Install all JS dependencies"
  dir = "."
- run = "cd cli && pnpm install"
+ run = "pnpm install"
```

Build dependency chain becomes:

```
build:core → codegen → build:sdk → build:cli
                                  → build:app (Phase 1+)
```

## Files to Move

### From `cli/src/sdk/` → `packages/opal-sdk/src/`

| File | Action |
|------|--------|
| `index.ts` | Move + fix `../sdk/protocol.js` → `./protocol.js` |
| `session.ts` | Move |
| `client.ts` | Move |
| `stream.ts` | Move |
| `match.ts` | Move |
| `errors.ts` | Move |
| `resolve.ts` | Move |
| `transforms.ts` | Move |
| `protocol.ts` | Move (auto-generated, codegen path updated) |
| `rpc/connection.ts` | Move |
| `rpc/types.ts` | Move |
| `transport/transport.ts` | Move |
| `transport/stdio.ts` | Move |
| `transport/memory.ts` | Move |

### Stay in `cli/src/`

| File | Reason |
|------|--------|
| `cli-state.ts` | CLI-specific file persistence (preferences, last model) |
| `cli-history.ts` | CLI-specific command history |

These move from `cli/src/sdk/` to `cli/src/` (they're not part of the SDK API).

### Tests: From `cli/src/__tests__/` → `packages/opal-sdk/tests/`

Move all SDK-specific test files. Update import paths from relative (`../sdk/`) to package name (`@unfinite/opal-sdk`) or relative to the new test location.

## CLI Import Updates

Every file in `cli/src/` that imports from `../sdk/` or `./sdk/` must be updated. Affected files:

| File | Current Import | New Import |
|------|---------------|------------|
| `app.tsx` | `./sdk/index.js` | `@unfinite/opal-sdk` |
| `state/session.ts` | `../sdk/session.js`, `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `state/cli.ts` | `../sdk/cli-state.js`, `../sdk/cli-history.js` | `../cli-state.js`, `../cli-history.js` |
| `state/types.ts` | `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `state/models.ts` | `../sdk/session.js` | `@unfinite/opal-sdk` |
| `state/timeline.ts` | `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `state/auth.ts` | `../sdk/session.js` | `@unfinite/opal-sdk` |
| `hooks/use-session.ts` | `../sdk/session.js`, `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `hooks/use-models.ts` | `../sdk/session.js` | `@unfinite/opal-sdk` |
| `hooks/use-overlay.ts` | `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `components/config-panel.tsx` | `../sdk/protocol.js` | `@unfinite/opal-sdk` |
| `commands/session.ts` | `../sdk/client.js`, `../sdk/rpc/connection.js`, `../sdk/transport/stdio.js` | `@unfinite/opal-sdk` |
| `commands/version.ts` | `../sdk/client.js` | `@unfinite/opal-sdk` |

## Verification Checklist

After extraction, all of these must pass:

1. `pnpm install` — workspace links resolve correctly
2. `mise run codegen` — generates `packages/opal-sdk/src/protocol.ts`
3. `mise run codegen:check` — codegen is up-to-date
4. `mise run build:sdk` — SDK compiles cleanly
5. `mise run build:cli` — CLI compiles cleanly against `@unfinite/opal-sdk`
6. `mise run test:sdk` — all 9 SDK tests pass
7. `mise run test:cli` — all CLI tests pass
8. `mise run lint` — no lint errors
9. `mise run build` — full pipeline succeeds
10. `npm pack` in `packages/opal-sdk/` — produces a clean tarball with only `dist/`

## Publishing

The SDK is published independently from the CLI:

- **`@unfinite/opal-sdk`** — the TypeScript client library. Published to npm.
- **`@unfinite/opal`** — the CLI binary. Depends on `@unfinite/opal-sdk`. Published to npm.

When publishing, pnpm replaces `workspace:*` with the actual resolved version, so consumers get a real semver dependency.

## Phase 0 → Phase 1 Handoff

Once Phase 0 is complete:

- `@unfinite/opal-sdk` is a standalone package in `packages/opal-sdk/`
- pnpm workspaces are configured and working
- The desktop app (`app/`) can be scaffolded as a new workspace member with `"@unfinite/opal-sdk": "workspace:*"` in its dependencies
- The Phase 1 spec's import `@unfinite/opal` changes to `@unfinite/opal-sdk`

All Phase 1–5 specs reference the SDK via `@unfinite/opal-sdk` going forward.
