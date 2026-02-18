# OTP in Opal

Opal is built on OTP — the Erlang framework for building concurrent, fault-tolerant systems. This document explains which OTP primitives Opal uses, why each was chosen, and how they fit together. For the supervision tree layout see [supervision.md](supervision.md).

## Why OTP for an Agent Harness

Most agent frameworks are written in TypeScript or Python and have to reinvent concurrency primitives from scratch — process management, supervision, message passing, graceful shutdown, and crash isolation all become application-level concerns. In OTP, these are built into the runtime.

An agent is naturally a process: it has long-lived state (conversation history, model config), reacts to events (user prompts, streaming chunks, tool results), and needs to be independently stoppable and restartable. A sub-agent is just another process under a supervisor. Tool execution is a supervised task. Event broadcasting is a registry dispatch. None of these required custom infrastructure — they fell out of OTP's existing primitives.

The result is significantly less code. Opal's entire agent loop, session management, tool execution, sub-agent spawning, and fault isolation fit in a few thousand lines of Elixir. An equivalent TypeScript system would need to build or import a process manager, a task queue, a pub/sub bus, graceful shutdown hooks, and crash recovery logic — each a source of bugs and maintenance burden.

This makes Opal a natural foundation for building something like an open-source Claude — the supervision and concurrency model scales from a single CLI agent to a multi-session server without architectural changes.

## Process Model

Every active session is a cluster of processes:

| Process | OTP Behaviour | Purpose |
|---------|--------------|---------|
| `Opal.Agent` | `:gen_statem` | Agent loop — LLM streaming, tool dispatch, explicit FSM |
| `Opal.Session` | GenServer | Conversation tree — message storage, branching, compaction |
| `Opal.RPC.Stdio` | GenServer | JSON-RPC transport over stdin/stdout |
| `Opal.SessionServer` | Supervisor | Per-session supervisor (`:rest_for_one`) |
| `Opal.MCP.Supervisor` | Supervisor | Per-session MCP client group (`:one_for_one`) |
| Tool tasks | Task (under Task.Supervisor) | Supervised non-blocking tool execution |
| Sub-agents | Opal.Agent (under DynamicSupervisor) | Delegated child agents |

Each session is isolated. A crash in one session's agent cannot affect another session.

## State Machine and GenServer Patterns

### Agent — The Core Loop

`Opal.Agent` is implemented as a `:gen_statem` with `:handle_event_function` mode. The status field on `State` tracks which phase the agent is in (`idle`, `running`, `streaming`, `executing_tools`). All events flow through a single `handle_event/4` callback:

**Casts** for fire-and-forget actions from the CLI:
- `{:prompt, text}` — start a new turn
- `{:steer, text}` — inject guidance mid-turn (queued if busy)
- `:abort` — cancel the current streaming response

**Calls** for synchronous queries:
- `:get_state` — snapshot for sub-agent spawning
- `{:set_model, id}` — runtime model swap
- `{:load_skill, name}` — activate a skill

**Info messages** for system events:
- Stream chunks from `Req` HTTP responses (SSE parsing)
- `:stream_watchdog` — periodic timeout check during streaming
- `:retry_turn` — exponential backoff after transient failures
- Tool task completion messages

The key insight is unchanged: async commands for user intent, calls for coordination, and mailbox-driven I/O for streaming/tool completion. The explicit FSM makes legal transitions first-class and easier to reason about.

### Session — Tree in a Process

`Opal.Session` wraps an ETS table in a GenServer. All operations are synchronous (`handle_call`) because conversation state must be consistent — you can't have concurrent appends racing to set `current_id`.

Operations like `:get_path` (walk parent pointers from leaf to root) and `{:replace_path_segment, ...}` (compaction) are pure data transforms on the ETS table, serialized through the GenServer mailbox.

### Stdio — Async I/O with Request Tracking

`Opal.RPC.Stdio` manages the stdin/stdout Port. It does three things:

1. **Receives** newline-delimited JSON from stdin via Port messages (`handle_info`)
2. **Sends** JSON-RPC notifications to stdout (event broadcasts, also `handle_info`)
3. **Tracks** pending server→client requests with auto-incrementing IDs (`handle_call`)

The Port is opened with `{:fd, 0, 1}` — raw file descriptors, no shell wrapper.

## Registry — Process Discovery Without Atoms

Opal uses two `Registry` instances started in `Opal.Application`:

### Unique Registry (`Opal.Registry`)

Maps structured keys to process PIDs. This replaces named processes (which would leak atoms for each session ID):

```elixir
# Register
{:via, Registry, {Opal.Registry, {:session, session_id}}}

# Lookup
[{pid, _}] = Registry.lookup(Opal.Registry, {:tool_sup, session_id})
```

Key types:
- `{:session, id}` → Session process
- `{:tool_sup, id}` → Task.Supervisor for tool execution
- `{:sub_agent_sup, id}` → DynamicSupervisor for sub-agents
- `{:mcp_sup, id}` → MCP.Supervisor
- `{:mcp_client, name}` → Individual MCP client
- `{:mcp_transport, name}` → MCP transport process

### Duplicate Registry (`Opal.Events.Registry`)

Pub/sub backbone. Multiple processes can register under the same session ID:

```elixir
# Subscribe
Registry.register(Opal.Events.Registry, session_id, [])

# Broadcast
Registry.dispatch(Opal.Events.Registry, session_id, fn entries ->
  for {pid, _} <- entries, do: send(pid, {:opal_event, session_id, event})
end)
```

The `:all` key is a wildcard — subscribers receive events from every session. `Opal.RPC.Stdio` subscribes to specific session IDs after `session/start`.

## ETS and DETS

### ETS — Conversation Messages

`Opal.Session` creates a private ETS table per session:

```elixir
:ets.new(:session, [:set, :private])
```

Messages are keyed by UUID. The table is private (only the owning process can access it), which is fine because all access goes through the GenServer. ETS was chosen over a map in GenServer state because conversation trees can grow large and ETS avoids copying data on every state update.

The table is deleted in `terminate/2` — when the session supervisor shuts down, the Session process terminates and its ETS table is reclaimed.

### DETS — Task Persistence

`Opal.Tool.Tasks` uses DETS (disk-backed ETS) at `.opal/tasks.dets` for the task tracker. Unlike ETS, DETS survives process restarts. This is intentional — tasks represent cross-session work plans.

DETS is opened/closed per tool invocation rather than held open in a process. This is simpler than wrapping it in a GenServer and acceptable for the low-frequency access pattern of task management.

## Task.Supervisor — Tool Execution

Each session has a `Task.Supervisor` registered under `{:tool_sup, session_id}`. When the agent needs to run tools:

```elixir
Task.Supervisor.async_nolink(tool_supervisor, fn ->
  tool_module.execute(params, context)
end)
```

Tool calls are dispatched sequentially per turn, but each tool runs in a supervised async task so the agent loop stays responsive. Results are delivered back through mailbox messages, and if the session supervisor crashes, the Task.Supervisor's children are automatically terminated.

This is safer than spawning raw processes: supervised tasks are tracked, limited, and cleaned up on shutdown.

## DynamicSupervisor — Sub-Agents

Sub-agents are full `Opal.Agent` processes started under a per-session DynamicSupervisor:

```elixir
DynamicSupervisor.start_child(sub_agent_supervisor, {Opal.Agent, opts})
```

The DynamicSupervisor is chosen over a static Supervisor because sub-agents are created on demand (the agent decides at runtime whether to delegate). Sub-agents inherit the parent's config but run independently — they have their own streaming connections, tool supervisors, and state.

Depth is limited to one level by excluding `Opal.Tool.SubAgent` from the sub-agent's tool list.

## Supervision Strategies

| Supervisor | Strategy | Rationale |
|-----------|----------|-----------|
| Application | `:one_for_one` | Registry and SessionSupervisor are independent |
| SessionSupervisor | `:one_for_one` (Dynamic) | Sessions are independent of each other |
| SessionServer | `:rest_for_one` | If infrastructure (Task.Supervisor, DynamicSupervisor) crashes, restart the Agent that depends on it |
| MCP.Supervisor | `:one_for_one` | MCP server connections are independent |

The `:rest_for_one` strategy in SessionServer is the key design choice. Children are ordered: Task.Supervisor → DynamicSupervisor → [MCP.Supervisor] → [Session] → Agent. If the Task.Supervisor crashes, the Agent restarts (it can't function without tool execution). But if the Agent crashes, the Task.Supervisor stays up — tasks in flight are collected when the Agent restarts.

## Port — External I/O

`Opal.RPC.Stdio` opens a Port for stdin/stdout:

```elixir
Port.open({:fd, 0, 1}, [:binary, :stream, {:line, @max_line}])
```

Port messages arrive as `{port, {:data, {:eol, line}}}` in `handle_info`. This integrates stdin into OTP's message-passing model — the GenServer processes JSON-RPC requests from stdin the same way it processes internal Erlang messages.

The `:line` mode handles buffering: partial reads become `{:noeol, chunk}` messages that are accumulated until a full line arrives.

## Message Passing Patterns

### Event Broadcasting

The agent broadcasts events during a turn:

```
Agent (state machine transition)
  → Opal.Events.broadcast(session_id, {:message_delta, %{delta: "hello"}})
    → Registry.dispatch sends {:opal_event, ...} to all subscribers
      → Stdio.handle_info serializes to JSON, writes to stdout
        → CLI receives and renders
```

This is a fan-out pattern. The agent doesn't know or care who is listening. The Registry handles delivery.

### Streaming

LLM responses arrive as HTTP Server-Sent Events. The `Req` library delivers chunks as regular Erlang messages to the requesting process (the Agent). The Agent parses SSE frames in `handle_info`, accumulates text/tool-call deltas, and broadcasts events to subscribers.

This turns HTTP streaming into OTP message passing — the Agent's mailbox is the integration point between the network and the process world.

### Retry with Backoff

When a turn fails (rate limit, network error), the Agent schedules a retry:

```elixir
Process.send_after(self(), :retry_turn, delay_ms)
```

`Process.send_after` is an OTP primitive that delivers a message after a delay. The Agent increments `retry_count` and computes exponential backoff. When `:retry_turn` arrives, the turn restarts. This keeps retry logic inside the agent state machine — no external timer process needed.

## Source Files

| File | Contains |
|------|----------|
| `lib/opal/application.ex` | Application startup, root supervisor children |
| `lib/opal/agent/agent.ex` | Agent `:gen_statem` loop |
| `lib/opal/session.ex` | Session GenServer with ETS |
| `lib/opal/session_server.ex` | Per-session Supervisor |
| `lib/opal/events.ex` | Pub/sub helpers (subscribe, broadcast) |
| `lib/opal/rpc/stdio.ex` | JSON-RPC transport GenServer |
| `lib/opal/sub_agent.ex` | Sub-agent spawning helpers |
| `lib/opal/mcp/supervisor.ex` | MCP client supervision |
| `lib/opal/mcp/client.ex` | MCP client (Anubis-based) |
