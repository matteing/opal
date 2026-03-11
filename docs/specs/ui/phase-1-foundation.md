# Phase 1 — Foundation

> Single-conversation agent UI with streaming, tool display, and basic input.

## Goal

Stand up a working desktop app that can start an Opal session, send prompts, stream responses, display tool executions, and handle approval dialogs. This is the "hello world" of the desktop app — one conversation, fully functional.

## Prerequisites

- Phase 0 complete (SDK extracted into `@unfinite/opal-sdk`, pnpm workspaces configured)

## Scope

### In Scope

- Electron app shell with React renderer
- SDK integration via `createSession()` from `@unfinite/opal-sdk`
- Single conversation view with streaming message display
- User input area with prompt submission
- Tool execution display (name, status, collapsible output)
- Tool approval dialog (`client/confirm` handling)
- Agent question dialog (`client/ask_user` handling)
- Thinking/reasoning indicator with streaming thought display
- Status messages from the agent
- Abort (cancel) current agent run
- Basic error display
- Context discovery display (AGENTS.md, skills loaded)

### Out of Scope

- Multiple sessions / sidebar (Phase 2)
- Rich tool rendering / diffs (Phase 3)
- Settings panel, model picker, auth UI (Phase 4)
- Scheduling (Phase 5)

## Architecture

### Process Model

```
┌──────────────────────────────────────────────┐
│  Electron Main Process (Node.js 24)          │
│  ┌────────────────────────────────────────┐  │
│  │  SDK Host                              │  │
│  │  - createSession() → Session instance  │  │
│  │  - Holds opal-server child process     │  │
│  │  - Routes events via IPC to renderer   │  │
│  │  - Validates all IPC inputs            │  │
│  └────────────────────────────────────────┘  │
│                    ↕ IPC (contextBridge)      │
│  ┌────────────────────────────────────────┐  │
│  │  Preload Script                        │  │
│  │  - contextIsolation: true              │  │
│  │  - Exposes typed opal API via          │  │
│  │    contextBridge.exposeInMainWorld()    │  │
│  └────────────────────────────────────────┘  │
│                    ↕                         │
│  ┌────────────────────────────────────────┐  │
│  │  Renderer Process (Chromium sandbox)   │  │
│  │  - React 19.2 + Vite 7                │  │
│  │  - Semantic HTML components            │  │
│  │  - Zustand 5 state management          │  │
│  │  - NO Node.js access                   │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
         ↕ JSON-RPC (stdio)
┌──────────────────────────────────────────────┐
│  opal-server (Elixir/OTP)                    │
│  - Agent loop, tools, providers              │
└──────────────────────────────────────────────┘
```

The Opal SDK runs in the **main process** (Node.js), not the renderer. This is important because:

1. The SDK spawns `opal-server` as a child process — this requires Node.js APIs (`child_process`).
2. The renderer is sandboxed and communicates with the main process via Electron IPC.
3. This mirrors how VS Code extensions work — heavy lifting in the extension host, UI in the webview.

### Security Configuration

Every `BrowserWindow` must enforce these settings:

```typescript
// electron/main.ts
const mainWindow = new BrowserWindow({
  webPreferences: {
    contextIsolation: true,       // REQUIRED — prevents prototype pollution
    nodeIntegration: false,       // REQUIRED — no Node.js in renderer
    sandbox: true,                // REQUIRED — Chromium-level sandboxing
    preload: path.join(__dirname, "preload.js"),
  },
});
```

These are non-negotiable. The renderer must never have direct access to Node.js APIs, the filesystem, or child processes. All privileged operations go through the IPC bridge with explicit validation on the main-process side.

### IPC Bridge

The main process exposes a **minimal, namespaced** IPC API via `contextBridge`. All inputs are validated in the main process before executing any privileged operation.

```typescript
// electron/preload.ts — Runs in isolated preload context
import { contextBridge, ipcRenderer } from "electron";

// Only expose the exact API surface the renderer needs
contextBridge.exposeInMainWorld("opal", {
  startSession: (opts: CreateSessionOpts) =>
    ipcRenderer.invoke("opal:session:start", opts),
  prompt: (text: string) =>
    ipcRenderer.invoke("opal:session:prompt", text),
  abort: () =>
    ipcRenderer.invoke("opal:session:abort"),
  steer: (text: string) =>
    ipcRenderer.invoke("opal:session:steer", text),

  // Event subscriptions (main → renderer)
  onEvent: (cb: (event: AgentEvent) => void) => {
    const handler = (_: unknown, event: AgentEvent) => cb(event);
    ipcRenderer.on("opal:agent:event", handler);
    return () => ipcRenderer.removeListener("opal:agent:event", handler);
  },
  onConfirm: (cb: (params: ConfirmRequest) => void) => {
    const handler = (_: unknown, params: ConfirmRequest) => cb(params);
    ipcRenderer.on("opal:agent:confirm", handler);
    return () => ipcRenderer.removeListener("opal:agent:confirm", handler);
  },
  onAskUser: (cb: (params: AskUserRequest) => void) => {
    const handler = (_: unknown, params: AskUserRequest) => cb(params);
    ipcRenderer.on("opal:agent:ask-user", handler);
    return () => ipcRenderer.removeListener("opal:agent:ask-user", handler);
  },

  // Dialog resolution (renderer → main)
  resolveConfirm: (id: string, action: string) =>
    ipcRenderer.invoke("opal:session:resolve-confirm", id, action),
  resolveAskUser: (id: string, answer: string) =>
    ipcRenderer.invoke("opal:session:resolve-ask-user", id, answer),
});
```

```typescript
// electron/ipc.ts — Main process handlers with input validation
ipcMain.handle("opal:session:start", async (_, opts) => {
  // Validate input — never trust renderer data
  if (typeof opts?.workingDir !== "string") {
    throw new Error("workingDir must be a string");
  }

  session = await createSession(opts);
  session.onEvent((event) => {
    mainWindow.webContents.send("opal:agent:event", event);
  });
  return { sessionId: session.id };
});

ipcMain.handle("opal:session:prompt", async (_, text) => {
  if (typeof text !== "string" || text.length === 0) {
    throw new Error("prompt text must be a non-empty string");
  }
  for await (const event of session.prompt(text)) {
    // Events forwarded via onEvent handler above
  }
});

ipcMain.handle("opal:session:abort", async () => {
  await session.abort();
});

ipcMain.handle("opal:session:steer", async (_, text) => {
  if (typeof text !== "string") throw new Error("steer text must be a string");
  return session.steer(text);
});
```

```typescript
// src/sdk/bridge.ts — Type-safe wrapper consumed by React components
// The renderer accesses `window.opal` which was exposed by the preload script

export const opalBridge = window.opal as {
  startSession: (opts: CreateSessionOpts) => Promise<{ sessionId: string }>;
  prompt: (text: string) => Promise<void>;
  abort: () => Promise<void>;
  steer: (text: string) => Promise<{ queued: boolean }>;
  onEvent: (cb: (event: AgentEvent) => void) => () => void;
  onConfirm: (cb: (params: ConfirmRequest) => void) => () => void;
  onAskUser: (cb: (params: AskUserRequest) => void) => () => void;
  resolveConfirm: (id: string, action: string) => Promise<void>;
  resolveAskUser: (id: string, answer: string) => Promise<void>;
};
```

> **IPC Best Practices Applied**:
> - Namespaced channels (`opal:session:*`) to avoid collisions
> - All IPC exposed via `contextBridge.exposeInMainWorld` — never raw `ipcRenderer`
> - Input validation on every `ipcMain.handle` — never trust renderer data
> - Event listener cleanup via returned unsubscribe functions (prevents memory leaks)
> - No `eval`, no `remote` module, no `shell.openExternal` with unvalidated URLs
```

### State Management

Zustand store, mirroring the CLI's `useOpal()` pattern but adapted for the desktop:

```typescript
// src/state/store.ts
interface AppState {
  // Connection
  sessionReady: boolean;
  error: string | null;

  // Conversation
  timeline: TimelineEntry[];
  isRunning: boolean;
  thinkingText: string;
  statusMessage: string;

  // Token usage
  currentModel: string | null;
  tokenUsage: { current: number; contextWindow: number } | null;

  // Dialogs
  confirmation: ConfirmRequest | null;
  askUser: AskUserRequest | null;

  // Actions
  applyEvent: (event: AgentEvent) => void;
  submitPrompt: (text: string) => void;
  abort: () => void;
}
```

The `applyEvent` reducer is structurally identical to the CLI's — it processes the same `AgentEvent` types and produces the same timeline shape.

## Components

All components use semantic HTML elements (`<article>`, `<section>`, `<header>`, `<details>`, `<dialog>`, `<form>`, `<output>`, etc.) with no styling framework. CSS is minimal and functional — just enough for layout.

### Layout

```
┌─────────────────────────────────────────────┐
│ <header>                                    │
│   Opal Desktop · working dir · model · usage│
├─────────────────────────────────────────────┤
│ <main>                                      │
│   <article role="log"> (conversation)       │
│     <section> user message </section>       │
│     <section> assistant message             │
│       <details> tool: read_file </details>  │
│       <details> tool: edit_file </details>  │
│       <p> response text </p>               │
│     </section>                              │
│     <output> thinking... </output>          │
│   </article>                                │
├─────────────────────────────────────────────┤
│ <footer>                                    │
│   <form>                                    │
│     <textarea> user input </textarea>       │
│     <button> Send / Stop </button>          │
│   </form>                                   │
│ </footer>                                   │
└─────────────────────────────────────────────┘

<!-- Overlays (when active) -->
<dialog> Tool approval </dialog>
<dialog> Agent question </dialog>
```

### Component Inventory

| Component | Element | Purpose |
|-----------|---------|---------|
| `AppHeader` | `<header>` | App title, working directory, model name, token usage bar |
| `Conversation` | `<article role="log">` | Scrollable conversation timeline |
| `UserMessage` | `<section>` | User prompt bubble |
| `AssistantMessage` | `<section>` | Assistant response with streaming text |
| `ToolExecution` | `<details>` | Collapsible tool call: name, args summary, output |
| `ThinkingIndicator` | `<output>` | Streaming thinking text with visual indicator |
| `StatusBar` | `<p>` | Current agent status message |
| `ContextBadge` | `<span>` | Loaded context files / skills |
| `InputArea` | `<form>` | Textarea + send/stop button |
| `ConfirmDialog` | `<dialog>` | Tool approval: allow / deny / always allow |
| `AskUserDialog` | `<dialog>` | Agent question with optional multiple-choice |
| `ErrorBanner` | `<aside role="alert">` | Error display |

### Conversation Timeline

The timeline is a flat list of `TimelineEntry` objects, same shape as the CLI:

```typescript
type TimelineEntry =
  | { type: "user"; text: string }
  | { type: "assistant"; text: string; isStreaming: boolean }
  | { type: "tool"; name: string; args: string; output: string | null; status: "running" | "done" | "error" }
  | { type: "thinking"; text: string }
  | { type: "context"; label: string }
  | { type: "skill"; name: string }
  | { type: "status"; message: string }
  | { type: "error"; message: string };
```

### Streaming Text Rendering

Assistant messages stream token-by-token via `messageDelta` events. The renderer appends deltas to the current assistant entry and auto-scrolls the conversation container.

Markdown rendering is deferred to Phase 3. In Phase 1, assistant text renders as `<pre>` with whitespace preserved. This avoids the complexity of incremental markdown parsing while streaming.

## Event Mapping

| SDK Event | UI Action |
|-----------|-----------|
| `agentStart` | Set `isRunning = true`, clear previous status |
| `messageStart` | Push new assistant entry to timeline |
| `messageDelta` | Append text to current assistant entry |
| `thinkingStart` | Show thinking indicator |
| `thinkingDelta` | Append to thinking text |
| `statusUpdate` | Update status message |
| `toolExecutionStart` | Push tool entry (status: running) |
| `toolExecutionEnd` | Update tool entry (status: done, add output) |
| `usageUpdate` | Update token usage display |
| `agentEnd` | Set `isRunning = false` |
| `agentAbort` | Set `isRunning = false`, show "Cancelled" |
| `error` | Show error banner |
| `contextDiscovered` | Push context badges |
| `skillLoaded` | Push skill badge |

## User Interactions

| Action | Trigger | Behavior |
|--------|---------|----------|
| Send prompt | Enter in textarea (or click Send) | Call `bridge.prompt(text)`. Shift+Enter for newlines. |
| Steer agent | Send while agent is running | Call `bridge.steer(text)` — queued and applied between tool calls |
| Abort | Click Stop button or Ctrl+C / Cmd+. | Call `bridge.abort()` |
| Approve tool | Click Allow in confirm dialog | `bridge.resolveConfirm(id, "allow")` |
| Deny tool | Click Deny | `bridge.resolveConfirm(id, "deny")` |
| Always allow | Click Always Allow | `bridge.resolveConfirm(id, "always_allow")` |
| Answer question | Submit in ask-user dialog | `bridge.resolveAskUser(id, answer)` |
| Toggle tool output | Click on tool `<details>` | Native HTML `<details>` expand/collapse |

## Project Setup

### Dependencies

```json
{
  "dependencies": {
    "react": "^19.2",
    "react-dom": "^19.2",
    "zustand": "^5.0",
    "@unfinite/opal-sdk": "workspace:*"
  },
  "devDependencies": {
    "electron": "^40",
    "electron-builder": "^26.8",
    "typescript": "~5.9",
    "vite": "^7.3",
    "@vitejs/plugin-react": "^5.1"
  }
}
```

> **Version notes (March 2026)**:
> - Electron 40 ships Chromium 144 and Node.js 24. Use the latest stable 40.x.
> - React 19.2 is the current stable. Avoid 19.3 canary in production.
> - Vite 7.3 is the latest stable. Vite 8 (Rolldown-powered) is in beta — evaluate once stable.
> - TypeScript 5.9 is the current stable release. TS 6.0 is RC — pin to 5.9.x until 6.0 goes GA.
> - Zustand 5.0 is stable. Use `useShallow` from `zustand/react/shallow` for derived selectors (no 2nd-arg equality function in v5).

### Build System

- **Vite 7** for the renderer (React/HTML) — Rolldown preview available but stick with stable config
- **TypeScript** compiled with `tsc` for the main process
- **electron-builder** for packaging and code signing

### Monorepo Integration

The app lives at `app/` in the repo root, as a pnpm workspace member alongside `cli/` and `packages/opal-sdk/`. It depends on the SDK via the workspace protocol.

```
opal/                    # Elixir SDK (agent engine)
packages/opal-sdk/       # TypeScript SDK (@unfinite/opal-sdk)
cli/                     # Terminal UI (existing)
app/                     # Desktop UI (new, this spec)
```

The app is added to `pnpm-workspace.yaml`:

```yaml
packages:
  - "packages/*"
  - "cli"
  - "app"
```

`mise` tasks are added for the desktop app:

```toml
[tasks."app:dev"]
run = "cd app && npx electron ."
description = "Run desktop app in dev mode"
depends = ["build:sdk"]

[tasks."app:build"]
run = "cd app && npx electron-builder"
description = "Build desktop app"
depends = ["build:sdk"]
```

## Acceptance Criteria

1. App launches and connects to opal-server
2. User can type a prompt and see streaming response
3. Tool executions appear in the timeline with collapsible output
4. Thinking text streams and is visually distinct
5. Tool approval dialog appears and can be resolved
6. Agent question dialog appears and can be answered
7. User can abort a running agent
8. User can steer the agent while it's running
9. Token usage displays and updates
10. Errors are surfaced in the UI
11. Context files and skills are shown when discovered

## Implementation Notes

- Start with `electron-vite` or `electron-forge` for quick scaffolding — both support Vite 7 + Electron 40
- The preload script exposes `window.opal` via `contextBridge.exposeInMainWorld` — never expose `ipcRenderer` directly
- `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true` on every `BrowserWindow` — non-negotiable
- Auto-scroll behavior: scroll to bottom when new content arrives, unless user has scrolled up. Use `IntersectionObserver` on a sentinel `<div>` at the bottom.
- The textarea grows vertically as the user types (like Codex/ChatGPT) — use `field-sizing: content` CSS property or a controlled height approach
- Working directory defaults to the app's launch directory, or a directory picker if launched from a shortcut
- Use `pnpm` for package management (matches the CLI workspace)
- TypeScript strict mode enabled (`strict: true` in tsconfig)
- Electron-builder configured with code signing and ASAR integrity checks for distribution
