# Opal Desktop — Cross-Platform Agent UI

> **Status**: Specification / Pre-implementation

This directory contains the phased specification for **Opal Desktop**, a cross-platform graphical application that brings the full power of the Opal agent harness to a desktop UI. Think OpenAI Codex, but powered by Opal's Elixir/OTP engine.

## Design Principles

- **Opal SDK as the engine** — The app is a thin UI shell over `@unfinite/opal-sdk`. All agent logic, tool execution, session management, and provider communication remain in the Elixir backend, consumed via JSON-RPC.
- **Semantic HTML + React first** — V1 uses unstyled semantic HTML and React for maximum flexibility. Styling is deferred to allow rapid iteration on layout and interaction design without premature aesthetic commitments.
- **Feature parity with Opal CLI** — Every feature in the terminal UI is available in the desktop app, reorganized for a graphical context.
- **Cross-platform** — macOS, Linux, and Windows from day one via Electron (or Tauri in future phases).
- **Phased delivery** — Each phase is self-contained and shippable. Later phases add polish and new capabilities without blocking earlier ones.

## Phases

| Phase | Title | Description |
|-------|-------|-------------|
| [0](./phase-0-sdk-extraction.md) | SDK Extraction & Monorepo | Extract SDK into `@unfinite/opal-sdk`, set up pnpm workspaces |
| [1](./phase-1-foundation.md) | Foundation | Project scaffolding, Opal SDK integration, single-conversation UI |
| [2](./phase-2-multi-session.md) | Multi-Session | Session management, sidebar, session persistence and resume |
| [3](./phase-3-tool-experience.md) | Tool Experience | Rich tool rendering, file diffs, approval workflows, sub-agent views |
| [4](./phase-4-settings-polish.md) | Settings & Polish | Settings panel, model picker, auth flows, keyboard shortcuts |
| [5](./phase-5-scheduling.md) | Scheduling | Scheduled conversations — start new or wake existing on a cron-like schedule (requires app to be open) |

## Best Practices

### Electron Security (Non-Negotiable)

Every `BrowserWindow` must set:

- `contextIsolation: true` — prevents prototype pollution between preload and renderer
- `nodeIntegration: false` — no Node.js APIs in the renderer
- `sandbox: true` — Chromium-level process sandboxing

The renderer communicates with the main process **exclusively** through `contextBridge.exposeInMainWorld()` in the preload script. Never expose raw `ipcRenderer`. Never use the `remote` module.

### IPC Design

- **Namespaced channels** — all channels prefixed with `opal:` (e.g., `opal:session:prompt`) to avoid collisions
- **Input validation** — every `ipcMain.handle` validates its arguments before executing. Never trust renderer data.
- **Cleanup** — all `ipcRenderer.on` subscriptions return an unsubscribe function to prevent memory leaks
- **Promise-based** — use `ipcRenderer.invoke` / `ipcMain.handle` (not `send`/`on`) for request-response patterns

### Dependency Versions (March 2026)

| Package | Version | Notes |
|---------|---------|-------|
| Electron | ^40 | Chromium 144, Node.js 24 |
| React | ^19.2 | Latest stable (avoid 19.3 canary) |
| Zustand | ^5.0 | Use `useShallow` for derived selectors |
| Vite | ^7.3 | Latest stable (Vite 8 Rolldown is beta) |
| TypeScript | ~5.9 | Pin until TS 6.0 goes GA |
| electron-builder | ^26.8 | Code signing + ASAR integrity |
| Shiki | ^4.0 | Syntax highlighting (Phase 3+) |

### React Patterns

- **Semantic HTML first** — use `<article>`, `<section>`, `<details>`, `<dialog>`, `<nav>`, `<header>`, `<footer>`, `<form>`, `<output>` before reaching for `<div>`
- **No styling framework in V1** — CSS is minimal and functional (layout only). This keeps the component tree clean for future design iterations.
- **Zustand v5** — `useStore(selector)` does NOT accept a 2nd equality arg. Use `useShallow` from `zustand/react/shallow` for object/array selectors.
- **Auto-scroll** — scroll to bottom on new content unless the user has manually scrolled up. Use `IntersectionObserver` on a sentinel element.

## Repository Layout

```
pnpm-workspace.yaml              # Workspace root
package.json                      # Root scripts + shared devDeps
tsconfig.base.json                # Shared TypeScript config
opal/                             # Elixir SDK (agent engine)
packages/
└── opal-sdk/                     # @unfinite/opal-sdk (Phase 0)
    ├── package.json
    ├── tsconfig.json
    ├── src/
    │   ├── index.ts              # Barrel export (40+ exports)
    │   ├── session.ts            # createSession(), Session class
    │   ├── client.ts             # OpalClient (typed JSON-RPC)
    │   ├── stream.ts             # AgentStream (AsyncIterable)
    │   ├── protocol.ts           # AUTO-GENERATED from Elixir
    │   ├── rpc/                  # JSON-RPC connection
    │   └── transport/            # Stdio + memory transports
    └── tests/
cli/                              # Terminal UI (@unfinite/opal)
app/                              # Desktop UI (new, this spec)
├── package.json
├── electron/                     # Electron main process
│   ├── main.ts                   # App lifecycle, window creation
│   ├── preload.ts                # contextBridge API (sandbox boundary)
│   ├── ipc.ts                    # IPC handlers with input validation
│   └── session-manager.ts        # Multi-session lifecycle (Phase 2+)
├── src/                          # React renderer (sandboxed)
│   ├── main.tsx                  # Entry point
│   ├── app.tsx                   # Root layout
│   ├── components/               # UI components (semantic HTML)
│   │   ├── sidebar/
│   │   ├── conversation/
│   │   ├── tools/
│   │   ├── settings/
│   │   └── common/
│   ├── hooks/                    # React hooks
│   │   ├── use-session.ts
│   │   ├── use-agent-events.ts
│   │   └── use-sessions-list.ts
│   ├── state/                    # State management (Zustand v5)
│   │   └── store.ts
│   ├── sdk/                      # SDK bridge layer (typed window.opal wrapper)
│   │   └── bridge.ts
│   └── types/                    # Shared type definitions
│       └── index.ts
├── tests/                        # Tests
├── vite.config.ts                # Vite 7 config for renderer
├── tsconfig.json                 # TypeScript 5.9 config
└── electron-builder.yml          # Packaging + code signing config
```

## Relationship to Existing Code

- **`packages/opal-sdk/`** — The TypeScript SDK, extracted from `cli/src/sdk/` in Phase 0. Published as `@unfinite/opal-sdk`. Both the CLI and desktop app depend on it via `"@unfinite/opal-sdk": "workspace:*"`.
- **`opal/`** — The Elixir server is spawned as a subprocess, identical to how the CLI does it today. No changes to the backend. The codegen pipeline generates `protocol.ts` into the SDK package.
- **`cli/`** — The terminal UI continues to exist independently. The desktop app is a sibling, not a replacement. Both share the SDK.
- **Monorepo** — pnpm workspaces orchestrate the TypeScript packages. mise orchestrates the cross-language build pipeline (Elixir → codegen → SDK → CLI/App).

## Non-Goals (V1)

- Custom theming or design system (semantic HTML only)
- Mobile support
- Cloud/remote agent hosting
- Multi-user collaboration
- Plugin/extension system
