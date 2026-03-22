# Opal Desktop — Electron App

A minimal Electron app that spawns the `opal` binary and communicates over
stdio JSON-RPC 2.0. Start empty, add UI incrementally.

---

## Stack

| Layer | Choice |
|-------|--------|
| Framework | Electron (latest) |
| Renderer | React + Vite |
| Language | TypeScript (strict) |
| Build | electron-vite |
| Package | electron-builder |
| Styling | Tailwind CSS |
| State | Zustand |
| Protocol types | Zod |

## Project Layout

```
desktop/
├── electron.vite.config.ts
├── package.json
├── tsconfig.json
├── src/
│   ├── main/
│   │   ├── index.ts            # BrowserWindow, app lifecycle
│   │   ├── opal-process.ts     # spawn + manage the binary
│   │   ├── rpc-client.ts       # JSON-RPC 2.0 codec over stdio
│   │   ├── ipc-handlers.ts     # ipcMain registrations
│   │   └── binary.ts           # resolve binary path dev vs prod
│   ├── preload/
│   │   └── index.ts            # contextBridge → window.opal
│   └── renderer/
│       ├── index.html
│       ├── main.tsx
│       ├── protocol/           # Zod schemas + TS types
│       │   ├── events.ts
│       │   ├── methods.ts
│       │   └── index.ts
│       └── App.tsx             # start here: blank canvas
└── resources/
    └── opal                    # bundled binary (prod)
```

---

## RPC Layer

This is the only thing that must be right before you build anything else.

### Transport

The `opal` binary speaks **JSON-RPC 2.0 over newline-delimited stdio**:

```
spawn("opal")
  → write one JSON object per line to stdin
  ← read one JSON object per line from stdout
  ← stderr is human-readable logs (ignore or pipe to file)
```

Close stdin → binary exits cleanly.

### Wire Format

```
→ {"jsonrpc":"2.0","id":1,"method":"session/start","params":{"working_dir":"/tmp"}}\n
← {"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123",...}}\n
← {"jsonrpc":"2.0","method":"agent/event","params":{"session_id":"abc123","type":"message_delta","delta":"Hello"}}\n
```

Three message shapes:
- **Request** (client→server): `{jsonrpc, id, method, params}`
- **Response** (server→client): `{jsonrpc, id, result}` or `{jsonrpc, id, error}`
- **Notification** (server→client): `{jsonrpc, method, params}` — no `id`

Servers also send **server→client requests** (same shape as client requests,
but initiated by the server and expecting a client response):
- Method: `client/request`
- The client must respond with `{jsonrpc, id, result}` matching the request `id`

---

## Methods (Client → Server)

### Session

| Method | Params | Result |
|--------|--------|--------|
| `session/start` | `working_dir?`, `model?`, `system_prompt?`, `session_id?` | `{session_id, context_files, available_skills}` |
| `session/list` | — | `{sessions: [{id, title, modified}]}` |
| `session/history` | `session_id` | `{messages: [...]}` |
| `session/branch` | `session_id`, `entry_id` | `{}` |
| `session/delete` | `session_id` | `{ok: bool}` |

### Agent

| Method | Params | Result |
|--------|--------|--------|
| `agent/prompt` | `session_id`, `text` | `{queued: bool}` |
| `agent/abort` | `session_id` | `{}` |
| `agent/state` | `session_id` | `{status, model, message_count, token_usage}` |

### Models

| Method | Params | Result |
|--------|--------|--------|
| `models/list` | — | `{models: [{id, name, provider, supports_thinking}]}` |
| `model/set` | `session_id`, `model_id`, `thinking_level?` | `{model}` |

### Auth

| Method | Params | Result |
|--------|--------|--------|
| `auth/status` | — | `{authenticated: bool}` |
| `auth/login` | — | `{user_code, verification_uri, device_code, interval}` |
| `auth/poll` | `device_code`, `interval` | `{authenticated: bool}` |

### Config / Meta

| Method | Params | Result |
|--------|--------|--------|
| `settings/get` | — | `{settings}` |
| `settings/save` | `settings` | `{settings}` |
| `opal/config/get` | `session_id` | `{features, tools}` |
| `opal/config/set` | `session_id`, `features?`, `tools?` | `{features, tools}` |
| `opal/version` | — | `{server_version, protocol_version}` |

---

## Server → Client Requests

The server can send requests that the client **must respond to**:

```typescript
// Incoming from server (has an id — must be answered)
{ jsonrpc: "2.0", id: "s2c-1", method: "client/request",
  params: { session_id, kind, ...kindParams } }

// Client response
{ jsonrpc: "2.0", id: "s2c-1", result: { ...answer } }
```

| Kind | Server sends | Client returns |
|------|-------------|----------------|
| `confirm` | `title`, `message`, `actions: string[]` | `{action: string}` |
| `input` | `prompt`, `sensitive?: bool` | `{text: string}` |
| `ask` | `question`, `choices?: string[]` | `{answer: string}` |

---

## Events (Server → Client Notifications)

All arrive as `agent/event` notifications. The `type` field discriminates.

```
{ jsonrpc: "2.0", method: "agent/event",
  params: { session_id: "abc", type: "message_delta", delta: "Hello" } }
```

### Lifecycle

| Type | Fields |
|------|--------|
| `agent_start` | — |
| `agent_end` | `usage?: TokenUsage` |
| `agent_abort` | — |
| `agent_recovered` | — |

### Streaming text

| Type | Fields |
|------|--------|
| `message_start` | — |
| `message_delta` | `delta: string` |
| `thinking_start` | — |
| `thinking_delta` | `delta: string` |
| `turn_end` | `message: string` |

### Tools

| Type | Fields |
|------|--------|
| `tool_start` | `tool: string`, `call_id: string`, `args: unknown`, `meta?: unknown` |
| `tool_end` | `tool: string`, `call_id: string`, `result: ToolResult` |
| `tool_output` | `tool: string`, `call_id: string`, `chunk: string` |

### Session state

| Type | Fields |
|------|--------|
| `usage_update` | `usage: TokenUsage` |
| `status_update` | `message: string` |
| `error` | `reason: string` |
| `context_discovered` | `files: string[]` |
| `skill_loaded` | `name: string`, `description: string` |
| `message_queued` | `text: string` |
| `message_applied` | `text: string` |
| `compaction_start` | `message_count: number` |
| `compaction_end` | `before: number`, `after: number` |

### Sub-agents

| Type | Fields |
|------|--------|
| `sub_agent_start` | `model`, `label`, `tools` |
| `sub_agent_event` | `parent_call_id`, `sub_session_id`, `inner: AgentEvent` |

### Token usage shape

```typescript
type TokenUsage = {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  last_context_tokens: number;  // last provider-reported context size
  context_window: number;
};
```

### Tool result shape

```typescript
type ToolResult =
  | { ok: true;  output: string; meta?: Record<string, unknown> }
  | { ok: false; error: string };
```

---

## Zod Schemas

Define in `src/renderer/protocol/events.ts`. These give you runtime validation
**and** inferred TypeScript types for free.

```typescript
import { z } from "zod";

export const TokenUsageSchema = z.object({
  prompt_tokens: z.number(),
  completion_tokens: z.number(),
  total_tokens: z.number(),
  last_context_tokens: z.number(),
  context_window: z.number(),
});

export const ToolResultSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), output: z.string(), meta: z.record(z.unknown()).optional() }),
  z.object({ ok: z.literal(false), error: z.string() }),
]);

const AgentEventBase = z.discriminatedUnion("type", [
  z.object({ type: z.literal("agent_start") }),
  z.object({ type: z.literal("agent_end"), usage: TokenUsageSchema.optional() }),
  z.object({ type: z.literal("agent_abort") }),
  z.object({ type: z.literal("agent_recovered") }),
  z.object({ type: z.literal("message_start") }),
  z.object({ type: z.literal("message_delta"), delta: z.string() }),
  z.object({ type: z.literal("thinking_start") }),
  z.object({ type: z.literal("thinking_delta"), delta: z.string() }),
  z.object({ type: z.literal("turn_end"), message: z.string() }),
  z.object({ type: z.literal("tool_start"), tool: z.string(), call_id: z.string(), args: z.unknown(), meta: z.unknown().optional() }),
  z.object({ type: z.literal("tool_end"), tool: z.string(), call_id: z.string(), result: ToolResultSchema }),
  z.object({ type: z.literal("tool_output"), tool: z.string(), call_id: z.string(), chunk: z.string() }),
  z.object({ type: z.literal("usage_update"), usage: TokenUsageSchema }),
  z.object({ type: z.literal("status_update"), message: z.string() }),
  z.object({ type: z.literal("error"), reason: z.string() }),
  z.object({ type: z.literal("context_discovered"), files: z.array(z.string()) }),
  z.object({ type: z.literal("skill_loaded"), name: z.string(), description: z.string() }),
  z.object({ type: z.literal("message_queued"), text: z.string() }),
  z.object({ type: z.literal("message_applied"), text: z.string() }),
  z.object({ type: z.literal("compaction_start"), message_count: z.number() }),
  z.object({ type: z.literal("compaction_end"), before: z.number(), after: z.number() }),
  z.object({ type: z.literal("sub_agent_start"), model: z.unknown(), label: z.string(), tools: z.array(z.string()) }),
  // sub_agent_event wraps an inner event — use z.lazy for the recursive type
  z.object({ type: z.literal("sub_agent_event"), parent_call_id: z.string(), sub_session_id: z.string(), inner: z.unknown() }),
]);

export type AgentEvent = z.infer<typeof AgentEventBase>;

export const ClientRequestSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("confirm"), title: z.string(), message: z.string(), actions: z.array(z.string()) }),
  z.object({ kind: z.literal("input"), prompt: z.string(), sensitive: z.boolean().optional() }),
  z.object({ kind: z.literal("ask"), question: z.string(), choices: z.array(z.string()).optional() }),
]);

export type ClientRequest = z.infer<typeof ClientRequestSchema>;
```

---

## IPC Bridge (contextBridge)

Three primitives cross the process boundary. Nothing more.

```typescript
// src/preload/index.ts
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("opal", {
  // Send a JSON-RPC call, get the result back
  invoke: (method: string, params: unknown) =>
    ipcRenderer.invoke("opal:invoke", method, params),

  // Subscribe to agent/event notifications
  onEvent: (handler: (event: AgentEvent) => void) => {
    const listener = (_: unknown, event: AgentEvent) => handler(event);
    ipcRenderer.on("opal:event", listener);
    return () => ipcRenderer.off("opal:event", listener);  // unsubscribe
  },

  // Subscribe to client/request calls (confirm, input, ask)
  // handler must return the answer (promise ok)
  onRequest: (handler: (req: ClientRequest, id: string) => Promise<unknown>) => {
    const listener = (_: unknown, req: ClientRequest, id: string) => {
      handler(req, id).then((result) =>
        ipcRenderer.invoke("opal:respond", id, result)
      );
    };
    ipcRenderer.on("opal:request", listener);
    return () => ipcRenderer.off("opal:request", listener);
  },
});
```

```typescript
// Type declaration for renderer (src/renderer/env.d.ts)
import type { AgentEvent, ClientRequest } from "./protocol";

interface Window {
  opal: {
    invoke(method: string, params: unknown): Promise<unknown>;
    onEvent(handler: (event: AgentEvent) => void): () => void;
    onRequest(handler: (req: ClientRequest, id: string) => Promise<unknown>): () => void;
  };
}
```

---

## RpcClient (main process)

```typescript
// src/main/rpc-client.ts
import { EventEmitter } from "events";
import * as readline from "readline";
import type { ChildProcess } from "child_process";

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
}

export class RpcClient extends EventEmitter {
  private pending = new Map<number | string, Pending>();
  private nextId = 1;

  constructor(private proc: ChildProcess) {
    super();
    const rl = readline.createInterface({ input: proc.stdout! });
    rl.on("line", (line) => this.handleLine(line));
  }

  async call<T = unknown>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    this.proc.stdin!.write(msg + "\n");
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
    });
  }

  respond(id: string, result: unknown): void {
    const msg = JSON.stringify({ jsonrpc: "2.0", id, result });
    this.proc.stdin!.write(msg + "\n");
  }

  private handleLine(line: string): void {
    let msg: unknown;
    try { msg = JSON.parse(line); } catch { return; }
    if (typeof msg !== "object" || msg === null) return;
    const m = msg as Record<string, unknown>;

    if ("result" in m || "error" in m) {
      // Response to a pending call
      const pending = this.pending.get(m.id as number);
      if (!pending) return;
      this.pending.delete(m.id as number);
      if ("error" in m) pending.reject(m.error);
      else pending.resolve(m.result);
    } else if (m.method === "agent/event") {
      // Push notification
      this.emit("event", (m.params as Record<string, unknown>).session_id, m.params);
    } else if (m.method === "client/request") {
      // Server-initiated request — client must respond
      this.emit("request", m.id, m.params);
    }
  }
}
```

---

## OpalProcess (main process)

```typescript
// src/main/opal-process.ts
import { spawn, ChildProcess } from "child_process";
import { RpcClient } from "./rpc-client";
import { resolveOpalBinary } from "./binary";

export class OpalProcess {
  private proc: ChildProcess;
  public rpc: RpcClient;

  constructor() {
    this.proc = spawn(resolveOpalBinary(), [], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.stderr!.on("data", (d) => process.stderr.write(d));
    this.proc.on("exit", (code) => console.log(`opal exited: ${code}`));
    this.rpc = new RpcClient(this.proc);
  }

  shutdown(): void {
    this.proc.stdin!.end();  // closing stdin triggers clean exit
  }
}
```

---

## Binary Resolution

```typescript
// src/main/binary.ts
import { join } from "path";
import { app } from "electron";

export function resolveOpalBinary(): string {
  if (app.isPackaged) {
    return join(process.resourcesPath, "opal");
  }
  // Dev: local release build
  return join(__dirname, "../../../opal/_build/dev/rel/opal/bin/opal");
}
```

---

## Minimal Session Flow

```typescript
// The happy path every UI interaction builds on:

const process = new OpalProcess();
const rpc = process.rpc;

// 1. Start a session
const { session_id } = await rpc.call("session/start", {
  working_dir: "/path/to/project",
});

// 2. Subscribe to events
rpc.on("event", (sid, event) => {
  if (sid !== session_id) return;
  console.log(event.type, event);
});

// 3. Handle server requests (confirm / input / ask)
rpc.on("request", (id, params) => {
  // In a real app: show a dialog, then:
  rpc.respond(id, { action: "allow" });
});

// 4. Send a prompt
await rpc.call("agent/prompt", { session_id, text: "Hello!" });

// Events will stream: agent_start → message_delta × N → turn_end → agent_end
```

---

## Security

```typescript
// src/main/index.ts
new BrowserWindow({
  webPreferences: {
    contextIsolation: true,
    sandbox: true,
    nodeIntegration: false,
    preload: join(__dirname, "../preload/index.js"),
  },
});
```

The renderer only touches `window.opal`. No Node APIs, no filesystem, no
direct IPC. Everything flows through the typed bridge.
