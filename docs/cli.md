# CLI

The CLI is a TypeScript terminal application built with [Ink](https://github.com/vadimdemedes/ink) (React for the terminal). It connects to the Elixir server over JSON-RPC via stdio and renders a full interactive coding agent UI.

## Architecture

```mermaid
graph TD
    Bin["bin.ts<br/><small>parse CLI args</small>"]
    App["app.tsx<br/><small>main layout</small>"]
    Hook["useOpal() hook<br/><small>state + actions</small>"]
    Session["Session<br/><small>high-level API</small>"]
    Client["OpalClient<br/><small>JSON-RPC transport</small>"]
    Resolve["resolveServer()<br/><small>find opal-server</small>"]
    Server["opal-server<br/><small>Elixir subprocess</small>"]

    Bin --> App --> Hook
    Hook --> Session --> Client
    Client --> Resolve --> Server
    Server -- "events (notifications)" --> Client
    Client -- "applyEvent reducer" --> Hook
    Hook -- "React re-render" --> App
```

The CLI spawns the Elixir server as a child process and communicates over stdin/stdout using newline-delimited JSON-RPC. All streaming events flow back as notifications and are reduced into React state.

## Server Resolution

The SDK finds the opal-server binary in three ways, tried in order:

1. **PATH** — `opal-server` installed globally
2. **Bundled binary** — `releases/opal_server_<platform>_<arch>` inside the npm package
3. **Dev mode** — Monorepo: runs `elixir -S mix run --no-halt` in `../core/`

Platform mapping: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`.

## CLI Arguments

```
opal [options]

--model <id>          Model to use (e.g. claude-sonnet-4, anthropic:claude-sonnet-4)
--working-dir, -C     Working directory (default: cwd)
--auto-confirm        Auto-allow all tool executions
--verbose, -v         Pipe server stderr to terminal
--help, -h            Show usage
```

Working directory resolution: `OPAL_CWD` env → `INIT_CWD` (npm/pnpm sets this) → `process.cwd()`.

## UI Layout

```
┌─────────────────────────────────────────────┐
│ Header        workingDir · nodeName         │
├─────────────────────────────────────────────┤
│ MessageList                                 │
│   ● Loaded AGENTS.md                        │
│   ● Loaded skill: docs                      │
│                                             │
│   ❯ You                                     │
│     fix the failing test                    │
│                                             │
│   ✦ opal                                    │
│     I'll look at the test file...           │
│   ● read_file test/app_test.exs             │
│   ● edit_file test/app_test.exs             │
│                                             │
│ (◕‿◕) Editing test file…                    │
├─────────────────────────────────────────────┤
│ ❯ [input field]                             │
│                                             │
│ /help │ ctrl+c exit │ ctrl+o tool output    │
│                              claude-4 · 12k │
└─────────────────────────────────────────────┘
```

### Components

| Component | Purpose |
|-----------|---------|
| `header.tsx` | Working directory and node name |
| `message-list.tsx` | Timeline: messages, tools, context, skills |
| `thinking.tsx` | Animated kaomoji spinner with status label |
| `bottom-bar.tsx` | Text input, help shortcuts, model + token usage |
| `confirm-dialog.tsx` | Tool execution approval modal |
| `model-picker.tsx` | Interactive model/thinking-level selector |
| `welcome.tsx` | Animated iridescent opal gem on startup |

## State Management

All UI state lives in the `useOpal()` hook, which returns `[OpalState, OpalActions]`.

### Key State Fields

| Field | Type | Purpose |
|-------|------|---------|
| `timeline` | `TimelineEntry[]` | Messages, tools, skills, context |
| `isRunning` | `boolean` | Agent is processing a turn |
| `thinking` | `string \| null` | Extended thinking text |
| `statusMessage` | `string \| null` | Current step description (from `<status>` tags) |
| `currentModel` | `string` | Active model ID |
| `tokenUsage` | `TokenUsage` | Context window utilization |
| `confirmation` | `ConfirmRequest \| null` | Pending tool approval |
| `sessionReady` | `boolean` | Server connection established |

### Actions

| Action | When |
|--------|------|
| `submitPrompt(text)` | User sends a message (idle) |
| `submitSteer(text)` | User sends guidance (running) |
| `abort()` | Cancel current turn |
| `compact()` | Compress conversation history |
| `runCommand(input)` | Process slash commands |
| `selectModel(id)` | Pick from model list |

## Slash Commands

| Command | Effect |
|---------|--------|
| `/help` | Show available commands |
| `/model` | Show current model |
| `/model <id>` | Switch model (e.g. `/model anthropic:claude-sonnet-4`) |
| `/models` | Open interactive model picker |
| `/compact` | Trigger conversation compaction |

## Keyboard Shortcuts

| Key | Context | Action |
|-----|---------|--------|
| `ctrl+c` | Running | Abort agent |
| `ctrl+c` | Idle | Exit CLI |
| `ctrl+o` | Any | Toggle tool output visibility |
| `↑` `↓` | Picker | Navigate options |
| `y` / `n` | Confirm | Quick allow/deny |

## Event Flow

Streaming events from the server drive all UI updates:

```mermaid
graph LR
    Server["Elixir Agent"] -- "SSE stream" --> Provider
    Provider -- "parsed events" --> Agent["Agent GenServer"]
    Agent -- "broadcast" --> Events["Events.Registry"]
    Events -- "JSON-RPC notification" --> Stdio["RPC.Stdio"]
    Stdio -- "stdout" --> Client["OpalClient"]
    Client -- "applyEvent()" --> Reducer["State Reducer"]
    Reducer -- "setState" --> React["UI Components"]
```

Key event types and their UI effects:

| Event | UI Change |
|-------|-----------|
| `agentStart` | Show running state |
| `messageStart` / `messageDelta` | Append assistant text |
| `thinkingStart` / `thinkingDelta` | Show thinking indicator |
| `statusUpdate` | Update thinking label |
| `toolExecutionStart` / `End` | Show tool with spinner → result |
| `usageUpdate` | Update token counter |
| `agentEnd` | Clear running state, ring bell |
| `subAgentEvent` | Nest sub-tasks under parent tool |

## SDK

The TypeScript SDK (`cli/src/sdk/`) can be used independently of the CLI for programmatic access:

```typescript
import { Session } from "@unfinite/opal";

const session = await Session.start({ model: "claude-sonnet-4" });

session.on("messageDelta", (delta) => process.stdout.write(delta));
session.on("agentEnd", () => console.log("\nDone"));

await session.prompt("Fix the failing test in app_test.exs");
```

See [sdk.md](sdk.md) for the full SDK documentation.

## Source Files

| File | Purpose |
|------|---------|
| `cli/src/bin.ts` | CLI entry point, argument parsing |
| `cli/src/app.tsx` | Main Ink application layout |
| `cli/src/hooks/use-opal.ts` | State management, event reducer, actions |
| `cli/src/components/*.tsx` | UI components |
| `cli/src/sdk/client.ts` | JSON-RPC transport over subprocess stdio |
| `cli/src/sdk/session.ts` | High-level session API |
| `cli/src/sdk/resolve.ts` | Server binary discovery |
| `cli/src/sdk/protocol.ts` | Auto-generated type definitions |
| `cli/src/sdk/transforms.ts` | snake_case ↔ camelCase conversion |
