# @opal/types

Zod schemas and TypeScript types for the [Opal](https://github.com/scohen/opal) JSON-RPC 2.0 protocol (v0.2.0).

## Install

```bash
npm install zod @opal/types
```

## Usage

```typescript
import { AgentEventSchema, OpalMessageSchema } from "@opal/types";
import { spawn } from "node:child_process";
import * as readline from "node:readline";

const proc = spawn("./opal");

const rl = readline.createInterface({ input: proc.stdout });

rl.on("line", (line) => {
  const msg = OpalMessageSchema.parse(JSON.parse(line));

  if ("method" in msg && msg.method === "agent/event") {
    const event = AgentEventSchema.parse(msg.params);
    console.log(event.type, event);
  }
});

// Start a session
proc.stdin.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "session/start",
    params: { working_dir: process.cwd() },
  }) + "\n"
);
```

## Schemas

| Export | Description |
|--------|-------------|
| `AgentEventSchema` | Discriminated union of all ~18 agent event types |
| `OpalMessageSchema` | Any message from the opal binary (response, error, notification, server request) |
| `ClientRequestParamsSchema` | Discriminated union of `confirm` / `input` / `ask` server→client requests |
| `SessionStartParamsSchema` | Params for `session/start` |
| `SessionStartResultSchema` | Result of `session/start` |
| `TokenUsageSchema` | Token usage counters |
| `ModelSchema` | Model descriptor |
| `ToolResultSchema` | Tool execution result (ok or error) |

## Protocol

- **Transport**: stdin/stdout, newline-delimited JSON-RPC 2.0
- **Client→server methods**: 19 (session, agent, models, auth, settings, config)
- **Server→client**: `agent/event` (fire-and-forget) + `client/request` (round-trip)
- **Events**: 18 types (agent lifecycle, streaming text, tool execution, status)

See `opal/lib/opal/rpc/protocol.ex` for the authoritative Elixir source.
