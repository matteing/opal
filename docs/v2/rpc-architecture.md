# Opal Architecture — Single Binary

## The Idea

One Elixir app. One release. One binary called `opal`. It speaks
JSON-RPC 2.0 over stdio. That's it.

Any client — CLI, Electron, eval harness, SPA wrapper — spawns the
`opal` binary and pipes JSON to it. The binary is a cross-platform mix
release with embedded ERTS. No external dependencies at runtime.

```
┌──────────────────────┐
│  Client (any)        │   CLI, Electron, eval harness, SPA wrapper
│  TypeScript / Python │
└─────────┬────────────┘
          │ stdin/stdout (JSON-RPC 2.0, newline-delimited)
┌─────────┴────────────┐
│  opal                │   Single Elixir release binary
│  opal/               │   Agent + RPC + everything
│                      │   ~17,000 LOC
└──────────────────────┘
```

## Why Not Split core/ + rpc/

The split only makes sense if someone needs to embed the agent library
without the RPC layer. Nobody does. This is a binary you spawn, not a
library you import. Keeping it as one app means:

- No multi-project dependency graph
- No `Opal.Callbacks` indirection for `ask_user`
- One `mix compile`, one `mix test`, one `mix release`
- The RPC server is just another GenServer in the supervision tree —
  it belongs here

## What the Binary Does

The `opal` binary starts the OTP application and immediately begins
reading JSON-RPC from stdin and writing to stdout. Logger goes to
stderr and a file. When stdin closes, the process exits.

That's the entire contract:

```
spawn("./opal")
  → write JSON-RPC requests to stdin
  ← read JSON-RPC responses + notifications from stdout
  ← stderr is for logs (human-readable, not part of the protocol)
```

No CLI flags. No subcommands. No interactive mode. No REPL.
Just a stdio JSON-RPC server.

## What Gets Deleted

| Component | LOC | Why it dies |
|-----------|-----|-------------|
| `cli/` (TypeScript TUI) | ~8,300 | Replaced by any client that speaks JSON-RPC |
| `packages/opal-sdk/` (TS SDK) | ~2,400 | Replaced by Zod schemas + spawn logic |
| `scripts/codegen_ts.exs` | ~200 | No codegen needed |
| Codegen mise tasks | — | Gone |
| pnpm workspace infra | — | Gone |
| `tsconfig.base.json`, root `package.json` | — | Gone |

**Net deletion: ~11,000 LOC of TypeScript infrastructure.**

## What Stays

Everything in `opal/` stays, including the RPC layer:

```
opal/
├── lib/
│   ├── opal.ex                    # Public API facade
│   ├── opal/
│   │   ├── agent/                 # Agent FSM, streaming, tools
│   │   ├── session/               # Conversation state, compaction
│   │   ├── tool/                  # Built-in tools
│   │   ├── provider/              # LLM providers (Copilot)
│   │   ├── auth/                  # Copilot OAuth
│   │   ├── shell/                 # Shell process wrapper
│   │   ├── context/               # Skill/context discovery
│   │   ├── rpc/                   # JSON-RPC 2.0 server
│   │   │   ├── server.ex          # GenServer: stdio + dispatch + events
│   │   │   ├── protocol.ex        # Method/event type definitions
│   │   │   └── rpc.ex             # JSON-RPC 2.0 codec
│   │   ├── application.ex         # OTP application (starts RPC server)
│   │   ├── config.ex              # Configuration
│   │   ├── events.ex              # PubSub event broadcasting
│   │   └── util/                  # Utilities
│   └── mix/tasks/                 # Dev-only mix tasks
├── test/
├── config/
│   ├── config.exs                 # Base config (logger to stderr)
│   ├── dev.exs
│   ├── test.exs                   # start_rpc: false for unit tests
│   ├── prod.exs
│   └── runtime.exs                # Env var overrides
├── mix.exs                        # app: :opal, release: :opal
└── mix.lock
```

## The Release

Minimal. The mix release produces a self-contained `opal` binary with
embedded ERTS. Cross-platform (macOS, Linux, Windows).

```elixir
# mix.exs
defp releases do
  [
    opal: [
      applications: [opal: :permanent],
      include_erts: true,
      strip_beams: true,
      steps: [:assemble]
    ]
  ]
end
```

The release entrypoint starts the OTP application, which starts the
supervision tree, which includes `Opal.RPC.Server`. The server reads
stdin, dispatches methods, streams events to stdout. When stdin closes,
`System.stop(0)`.

```bash
# Build
MIX_ENV=prod mix release opal

# Run (a client would spawn this)
_build/prod/rel/opal/bin/opal start
```

### Cleanup in application.ex

Remove the `start_rpc` conditional. The RPC server always starts:

```elixir
children = [
  {Registry, keys: :unique, name: Opal.Registry},
  {Registry, keys: :duplicate, name: Opal.Events.Registry},
  Opal.Shell.Process,
  {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one},
  Opal.RPC.Server
]
```

For tests, `config :opal, start_rpc: false` stays — tests don't need
a stdio server. The `application.ex` keeps the conditional for this
one purpose: test isolation.

### Remove distribution code

`start_distribution`, `write_node_file`, `read_node_file`, and the
distribution cookie logic in `application.ex` should be removed. The
binary is spawned fresh by each client — no need for node discovery
or remote shell. If you want `iex --remsh` in dev, use
`iex -S mix run --no-halt` directly.

## Protocol Simplifications

| Change | Why |
|--------|-----|
| Remove `session/compact` | Dead code — never implemented |
| Remove `opal/ping` | Redundant — stdio EOF is the liveness check |
| Merge `thinking/set` into `model/set` | One method, one params shape |
| Remove distribution config from RPC | No distribution — delete entirely |
| Normalize event tuple arities | `tool_execution_start` has 3 arities → 1 |
| Consolidate 3 server→client methods → `client/request` | Less surface area |
| Rename `tool_execution_start/end` → `tool_start/end` | Shorter, cleaner |

**Result: 22 methods → 18.** Same capabilities.

### Protocol After Cleanup

#### Client → Server (15 methods)

**Session lifecycle:**
```
session/start    {working_dir, model?, system_prompt?, features?} → {session_id, ...}
session/list     {} → {sessions: [...]}
session/history  {session_id} → {messages: [...]}
session/delete   {session_id} → {}
session/branch   {session_id, entry_id} → {session_id}
```

**Agent operations:**
```
agent/prompt     {session_id, text} → {queued: bool}
agent/abort      {session_id} → {}
agent/state      {session_id} → {status, model, messages, ...}
```

**Models:**
```
models/list      {} → {models: [...]}
model/set        {session_id, model_id, thinking_level?} → {}
```

**Auth:**
```
auth/status      {} → {status, provider}
auth/login       {} → {verification_uri, user_code, device_code, ...}
auth/poll        {device_code, interval} → {status}
```

**Settings:**
```
settings/get     {} → {settings}
settings/save    {settings} → {}
```

#### Server → Client (2 methods)

```
agent/event      {session_id, type, ...data}   — notification (fire-and-forget)
client/request   {session_id, kind, params}     — request (expects response)
```

`client/request` replaces the 3 separate ask methods:
```json
{"kind": "confirm", "title": "Run command?", "message": "ls -la", "actions": [...]}
{"kind": "input",   "prompt": "Enter API key", "sensitive": true}
{"kind": "ask",     "question": "Which file?", "choices": [...]}
```

#### Events (~15 types)

```typescript
type AgentEvent =
  | { type: "agent_start" }
  | { type: "agent_end"; usage?: TokenUsage }
  | { type: "agent_abort" }
  | { type: "message_start" }
  | { type: "message_delta"; delta: string }
  | { type: "thinking_start" }
  | { type: "thinking_delta"; delta: string }
  | { type: "tool_start"; tool: string; call_id: string; args: unknown }
  | { type: "tool_end"; tool: string; call_id: string; result: ToolResult }
  | { type: "tool_output"; tool: string; call_id: string; chunk: string }
  | { type: "status_update"; message: string }
  | { type: "error"; reason: string }
  | { type: "turn_end"; message: string }
  | { type: "context_discovered"; files: string[] }
  | { type: "skill_loaded"; name: string; description: string }
  | { type: "usage_update"; usage: TokenUsage }
```

## Monorepo Structure (After Cleanup)

```
opal/
├── opal/                      # The Elixir app (agent + RPC)
│   ├── lib/
│   ├── test/
│   ├── config/
│   ├── mix.exs
│   └── mix.lock
│
├── docs/                      # Architecture, research
├── .mise.toml                 # Build orchestration
├── lefthook.yml               # Git hooks
├── LICENSE
└── README.md
```

That's it. One Elixir project. Clients live in their own repos or
get added later as separate directories (`cli/`, `ui/`, etc.).

## Build & Dev (mise)

```toml
[tools]
erlang = "28.3.1"
elixir = "1.19-otp-28"

[tasks.build]
description = "Compile Opal"
dir = "opal"
run = "mix compile --warnings-as-errors"

[tasks.test]
description = "Run all tests"
dir = "opal"
run = "mix test"

[tasks."lint:format"]
description = "Check formatting"
dir = "opal"
run = "mix format --check-formatted"

[tasks."lint:dialyzer"]
description = "Run dialyzer"
dir = "opal"
run = "mix dialyzer"

[tasks.lint]
description = "All lint checks"
depends = ["lint:*"]

[tasks.format]
description = "Format code"
dir = "opal"
run = "mix format"

[tasks.deps]
description = "Install dependencies"
dir = "opal"
run = "mix deps.get"

[tasks.release]
description = "Build release binary"
dir = "opal"
run = "MIX_ENV=prod mix release opal"

[tasks.precommit]
description = "Full CI preflight"
depends = ["deps"]
run = [
  "mise run lint",
  "mise run build",
  "mise run test",
]
```

## Migration Steps

### Step 1 — Clean mix.exs
- Rename release from `opal_server` to `opal`
- Remove RPC from ex_doc groups (it's just internal code now)
- Update description (remove "JSON-RPC 2.0 interface" language)

### Step 2 — Clean application.ex
- Remove `start_distribution`, `write_node_file`, `read_node_file`,
  `node_file_path`, `distribution_cookie`, `generate_cookie`
- Remove the `start_distribution` conditional block
- Keep `start_rpc` conditional (for test isolation only)
- Result: startup → logger → children → supervisor. That's it.

### Step 3 — Clean .mise.toml
- Remove all CLI/SDK/codegen tasks
- Single set of build/test/lint/format tasks for `opal/`
- Add `release` task

### Step 4 — Delete TypeScript infrastructure
- Delete `cli/`, `packages/`, `scripts/codegen_ts.exs`
- Delete `tsconfig.base.json`, root `package.json`, `pnpm-lock.yaml`
- Delete pnpm workspace config

### Step 5 — Protocol cleanup
- Simplify methods (see table above)
- Normalize event shapes
- Consolidate server→client methods

### Step 6 — Zod types
- Hand-write TypeScript Zod schemas for the protocol
- No codegen — protocol is small enough to maintain by hand
- Integration test validates Elixir events against Zod schemas

## Type Strategy — Hand-Written + Zod

No codegen. The protocol is 18 methods + 15 events — small enough to
maintain by hand. Zod gives runtime validation AND static types.

### Example: Event Schemas

```typescript
import { z } from "zod";

export const TokenUsageSchema = z.object({
  input: z.number(),
  output: z.number(),
  total: z.number(),
});

export const ToolResultSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), output: z.string(), meta: z.record(z.unknown()).optional() }),
  z.object({ ok: z.literal(false), error: z.string() }),
]);

export const AgentEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("agent_start") }),
  z.object({ type: z.literal("agent_end"), usage: TokenUsageSchema.optional() }),
  z.object({ type: z.literal("agent_abort") }),
  z.object({ type: z.literal("message_start") }),
  z.object({ type: z.literal("message_delta"), delta: z.string() }),
  z.object({ type: z.literal("thinking_start") }),
  z.object({ type: z.literal("thinking_delta"), delta: z.string() }),
  z.object({ type: z.literal("tool_start"), tool: z.string(), call_id: z.string(), args: z.unknown() }),
  z.object({ type: z.literal("tool_end"), tool: z.string(), call_id: z.string(), result: ToolResultSchema }),
  z.object({ type: z.literal("tool_output"), tool: z.string(), call_id: z.string(), chunk: z.string() }),
  z.object({ type: z.literal("status_update"), message: z.string() }),
  z.object({ type: z.literal("error"), reason: z.string() }),
  z.object({ type: z.literal("turn_end"), message: z.string() }),
  z.object({ type: z.literal("context_discovered"), files: z.array(z.string()) }),
  z.object({ type: z.literal("skill_loaded"), name: z.string(), description: z.string() }),
  z.object({ type: z.literal("usage_update"), usage: TokenUsageSchema }),
]);

export type AgentEvent = z.infer<typeof AgentEventSchema>;
```

### Keeping Elixir ↔ TypeScript in Sync

1. **Convention** — event types in `server.ex` and Zod schemas in
   `types/events.ts` are maintained side by side
2. **Integration test** — start agent, collect events, validate against
   Zod schemas. Shape mismatch = test failure.
3. **Protocol is small and stable.** 15 events. Add one in both places.
