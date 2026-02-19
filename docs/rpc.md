# JSON-RPC Protocol

The CLI communicates with the Elixir server over JSON-RPC 2.0 on stdio (stdin/stdout). This is the same transport pattern used by LSP and MCP.

## Wire Format

Newline-delimited JSON. Each message is one JSON object per line:

```
→ {"jsonrpc":"2.0","method":"session/start","params":{...},"id":1}
← {"jsonrpc":"2.0","result":{...},"id":1}
← {"jsonrpc":"2.0","method":"agent/event","params":{"session_id":"abc123","type":"message_delta","delta":"Hello"}}
```

Requests have an `id` and get a response. Notifications (events) have no `id`.

## Methods

Client → Server requests:

| Method | Purpose |
|--------|---------|
| `session/start` | Start a new agent session |
| `agent/prompt` | Send a user message (queued if busy) |
| `agent/abort` | Cancel the current turn |
| `agent/state` | Get agent state (model, usage, status) |
| `session/list` | List saved sessions |
| `session/branch` | Branch conversation at a message |
| `session/compact` | Manually trigger compaction |
| `session/history` | Get message history for a session |
| `session/delete` | Delete a saved session |
| `models/list` | List available models |
| `model/set` | Switch the active model |
| `thinking/set` | Change reasoning effort level |
| `auth/status` | Probe all credential sources |
| `auth/login` | Start device-code OAuth flow |
| `auth/poll` | Poll for device-code authorization |
| `auth/set_key` | Save an API key for a provider |
| `tasks/list` | List tracked tasks for a session |
| `settings/get` | Get persistent user settings |
| `settings/save` | Save user settings (merged) |
| `opal/config/get` | Get runtime feature/tool configuration for a session |
| `opal/config/set` | Update runtime feature/tool configuration for a session |
| `opal/ping` | Liveness check |
| `opal/version` | Get server/protocol version information |

`session/start` also accepts optional boot-time controls:

- `features`: `{ sub_agents?: boolean, skills?: boolean, mcp?: boolean, debug?: boolean }`
- `tools`: explicit enabled tool names for the session

Server → Client requests:

| Method | Purpose |
|--------|---------|
| `client/confirm` | Ask user to approve a tool action |
| `client/input` | Ask user for freeform text input |
| `client/ask_user` | Ask user a question with optional choices |

## Events

The server streams agent events as notifications on `agent/event`. The CLI subscribes automatically when starting a session.

| Event | When |
|-------|------|
| `agent_start` | Agent begins processing |
| `message_start` | New assistant message begins |
| `message_delta` | Streaming text token |
| `message_queued` | Prompt queued while agent is busy |
| `message_applied` | Previously queued prompt was applied |
| `thinking_start` | Reasoning/thinking begins |
| `thinking_delta` | Streaming thinking token |
| `tool_execution_start` | Tool begins running |
| `tool_execution_end` | Tool finished |
| `turn_end` | LLM turn complete, tools follow |
| `usage_update` | Live token usage snapshot |
| `status_update` | Brief human-readable status of current work |
| `agent_end` | Agent done, returning to idle |
| `agent_abort` | Agent was cancelled |
| `agent_recovered` | Agent crashed and was restarted |
| `error` | Something went wrong |
| `context_discovered` | Project context files found |
| `skill_loaded` | Agent skill activated |
| `sub_agent_event` | Forwarded event from child agent |

## Protocol Spec

All methods, events, and their schemas are defined declaratively in `Opal.RPC.Protocol`:

```elixir
@methods [
  %{method: "session/start", params: [...], result: [...]},
  ...
]

@event_types [
  %{type: "message_delta", fields: [%{name: "delta", type: :string}]},
  ...
]
```

This module is the single source of truth. The codegen pipeline exports JSON Schema via `mix opal.gen.json_schema` and then generates TypeScript SDK types via `scripts/codegen_ts.exs`.

## Architecture

`Opal.RPC.Server` is started by default as part of the core supervision tree. To
use the core library as an embedded SDK without the stdio transport, disable it:

```elixir
config :opal, start_rpc: false
```

The default is `true`, preserving backward compatibility. The CLI relies on the
default and does not need any extra configuration.

```mermaid
graph LR
    stdin --> Server["Opal.RPC.Server<br/><small>stdio transport + dispatch</small>"]
    Server --> API["Opal API"]
    Server --> Codec["Opal.RPC<br/><small>JSON-RPC encode/decode</small>"]
    Agent["Agent"] -- "broadcasts" --> Events["Opal.Events.Registry"]
    Events -- "serialize events" --> Server
    Server -- "notifications" --> stdout
```

`Opal.RPC.Server` handles stdio transport, request dispatch, and event serialization. `Opal.RPC` provides transport-agnostic JSON-RPC encoding/decoding helpers used by the server.

## Source

- `opal/lib/opal/rpc/protocol.ex` — Method/event definitions, codegen source of truth
- `opal/lib/opal/rpc/server.ex` — Stdio server, dispatch, event serialization
- `opal/lib/opal/rpc/rpc.ex` — JSON-RPC encode/decode helpers
- `opal/lib/mix/tasks/opal.gen.json_schema.ex` — JSON Schema generation
- `scripts/codegen_ts.exs` — TypeScript type generation
