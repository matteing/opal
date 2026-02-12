# The Agent Loop

This document explains how `Opal.Agent` implements the agentic loop pattern
on top of OTP's `GenServer`, and how every phase of the loop maps to native
OTP concepts: casts, handle_info, selective receive, and supervised tasks.

---

## Overview

An agent loop is a cycle: **prompt → stream LLM → execute tools → repeat**.
The loop runs until the LLM produces a text-only response with no tool calls.

In Opal, this cycle is expressed entirely through GenServer state transitions
and OTP message passing — no spawned loops, no recursive spawns, no custom
schedulers. The BEAM scheduler *is* the scheduler.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> running : prompt cast
    running --> streaming : provider stream
    streaming --> streaming : handle_info SSE chunks
    streaming --> running : finalize response
    running --> idle : no tool calls, agent_end
    running --> running : tools, execute, run_turn

    note right of streaming : SSE chunks arrive\nvia handle_info
    note right of running : Tool execution blocks\nthen loops back
```

---

## State Machine

The Agent has three states, tracked by the `status` field:

| State        | Meaning                                    | Accepts prompts? |
|--------------|--------------------------------------------|------------------|
| `:idle`      | Waiting for user input                     | Yes              |
| `:running`   | Processing (building messages, dispatching)| Via steering     |
| `:streaming` | Receiving SSE chunks from the LLM          | Via steering     |

State transitions are driven by OTP callbacks:

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> running : prompt cast
    running --> streaming : provider stream

    streaming --> streaming : handle_info SSE chunks
    streaming --> idle : finalize, no tool calls
    streaming --> tool_execution : finalize, has tool calls

    tool_execution --> running : steering check, run_turn

    state tool_execution {
        [*] --> dispatched
        dispatched --> results : async_stream_nolink
    }
```

---

## Phase 1: Receiving the Prompt

```elixir
def handle_cast({:prompt, text}, %State{} = state) do
  user_msg = Opal.Message.user(text)
  state = append_message(state, user_msg)
  state = %{state | status: :running}
  broadcast(state, {:agent_start})
  run_turn(state)
end
```

**Why `cast` instead of `call`?**

A `call` would block the caller until the agent finishes — which could be
minutes if the LLM runs multiple tool-use turns. Using `cast`:

- The caller gets `:ok` immediately
- The caller observes progress via `Opal.Events` (pubsub)
- The GenServer is free to process `handle_info` messages (SSE chunks)
  without a caller hanging

**OTP mapping:** This is a standard GenServer `handle_cast`. The prompt is
appended to the conversation history, status transitions to `:running`, and
`run_turn/1` is called synchronously within the same callback — it returns
`{:noreply, state}` once the streaming response is set up.

---

## Phase 2: Starting the LLM Stream

```elixir
defp run_turn(%State{} = state) do
  all_messages = build_messages(state)
  tools = active_tools(state)

  case state.provider.stream(state.model, all_messages, tools) do
    {:ok, resp} ->
      state = %{state | streaming_resp: resp, status: :streaming, ...}
      {:noreply, state}

    {:error, reason} ->
      broadcast(state, {:error, reason})
      {:noreply, %{state | status: :idle}}
  end
end
```

`run_turn/1` is always the last call in a `handle_cast` or at the end of tool
execution. It calls the configured `Provider.stream/4` which initiates an
async HTTP request via `Req`.

**How Req async streaming works with GenServer:**

1. `Req` opens an HTTP connection and returns a `%Req.Response{}` immediately
2. As SSE chunks arrive over the wire, `Req` sends them as regular Erlang
   messages to the calling process (the Agent GenServer)
3. The Agent's `handle_info/2` receives these messages

This is the key integration point: **Req's async streaming maps directly to
GenServer's `handle_info`**. No polling, no separate receiver process, no
callbacks — just messages in the GenServer mailbox.

```mermaid
flowchart LR
    LLM["LLM API<br/><i>HTTP/SSE</i>"] --> Req["Req<br/><i>async</i>"]
    Req -- "Erlang messages<br/>{ref, chunk}" --> Agent["Agent mailbox<br/><i>handle_info</i>"]
```

---

## Phase 3: Processing the Stream

```elixir
def handle_info(message, %State{status: :streaming, streaming_resp: resp} = state)
    when resp != nil do
  case Req.parse_message(resp, message) do
    {:ok, chunks} ->
      state = Enum.reduce(chunks, state, fn
        {:data, data}, acc -> parse_sse_data(data, acc)
        :done, acc -> acc
        _other, acc -> acc
      end)

      if :done in chunks do
        finalize_response(state)
      else
        {:noreply, state}
      end

    :unknown ->
      {:noreply, state}
  end
end
```

Each `handle_info` invocation processes one batch of SSE chunks. The Agent
pattern-matches on `status: :streaming` to ensure it only processes stream
data when actually streaming.

**SSE event types and how they update state:**

| LLM Stream Event | State Mutation | Event Broadcast |
|---|---|---|
| `text_start` | (no state change) | `{:message_start}` |
| `text_delta "Hel"` | `current_text <> "Hel"` | `{:message_delta, %{delta: "Hel"}}` |
| `text_delta "lo"` | `current_text <> "lo"` | `{:message_delta, %{delta: "lo"}}` |
| `text_done "Hello"` | `current_text = "Hello"` | (none) |
| `tool_call_start` | append to `current_tool_calls` | (none) |
| `tool_call_delta` | append to `arguments_json` | (none) |
| `tool_call_done` | finalize tool call entry | (none) |
| `thinking_start` | (no state change) | `{:thinking_start}` |
| `thinking_delta` | (no state change) | `{:thinking_delta, ...}` |
| `response_done` | (no state change) | (none) |
| `:done` (Req) | triggers `finalize_response` | (see below) |

**OTP mapping:** Every SSE chunk is a `handle_info` call. Between chunks, the
GenServer is free to process other messages — including `abort` casts. The
BEAM scheduler interleaves chunk processing with any other work the VM needs
to do.

### Provider Abstraction

The raw SSE JSON is never interpreted by the Agent directly. Instead:

1. `Req.parse_message/2` extracts `{:data, iodata}` from the HTTP-level framing
2. The Agent calls `state.provider.parse_stream_event(json)` to get semantic events
3. The Agent dispatches on the semantic event type (`:text_delta`, `:tool_call_start`, etc.)

This means the Agent loop is **provider-agnostic**. The same GenServer handles
Anthropic's Responses API, OpenAI's Chat Completions API, or any custom provider.
The `Provider` behaviour defines the translation layer:

```mermaid
flowchart LR
    SSE["Raw SSE JSON<br/><i>wire format</i><br/><br/>Anthropic:<br/>content_block_delta<br/><br/>OpenAI:<br/>choices[0].delta"] --> Provider["Provider behaviour<br/><br/>parse_stream_event/1<br/><br/>Returns:<br/>{:text_delta, &quot;&quot;}"]
    Provider --> Agent["Agent loop<br/><br/>Handles:<br/>text_delta,<br/>tool_call_done,<br/>etc."]
```

---

## Phase 4: Finalizing the Response

When `:done` arrives in the chunk list, `finalize_response/1` is called:

```elixir
defp finalize_response(%State{} = state) do
  tool_calls = finalize_tool_calls(state.current_tool_calls)
  assistant_msg = Opal.Message.assistant(state.current_text, tool_calls)
  state = append_message(state, assistant_msg)

  if tool_calls != [] do
    broadcast(state, {:turn_end, assistant_msg, []})
    execute_tool_calls(tool_calls, state)
  else
    broadcast(state, {:agent_end, state.messages})
    {:noreply, %{state | status: :idle}}
  end
end
```

This is the branching point of the loop:

- **No tool calls** → The agent is done. Broadcast `agent_end`, go `:idle`.
  The GenServer sits in its mailbox waiting for the next `handle_cast`.

- **Has tool calls** → Execute them, then loop back to `run_turn`. The
  GenServer stays in `:running` status.

**OTP mapping:** `finalize_response` is called from within `handle_info`.
It returns `{:noreply, state}` either directly (no tools) or through
`execute_tool_calls` → `run_turn` (tools). In both cases, the GenServer
callback contract is satisfied — the return value is always `{:noreply, state}`.

---

## Phase 5: Concurrent Tool Execution

```elixir
defp execute_tool_calls(tool_calls, %State{} = state) do
  context = %{
    working_dir: state.working_dir,
    session_id: state.session_id,
    config: state.config,
    agent_pid: self(),
    agent_state: state          # ← snapshot, not a live reference
  }

  tasks = Enum.map(tool_calls, fn tc ->
    {tc, find_tool_module(tc.name, active_tools(state))}
  end)

  results =
    Task.Supervisor.async_stream_nolink(
      state.tool_supervisor,       # ← per-session supervisor
      tasks,
      fn {tc, tool_mod} -> ... end,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(tasks)
    |> Enum.map(fn ... end)

  state = append_messages(state, tool_result_messages)
  state = check_for_steering(state)
  run_turn(state)
end
```

This is the most OTP-integrated phase. Let's break down every decision:

### Why `Task.Supervisor.async_stream_nolink`?

This is an OTP primitive that provides exactly the semantics an agent loop
needs:

| Property          | What it means for agents                        |
|-------------------|-------------------------------------------------|
| **Supervised**    | Tasks run under a `Task.Supervisor`, not wild   |
| **Concurrent**    | All tool calls execute in parallel automatically|
| **Unlinked**      | A crashing tool doesn't crash the Agent         |
| **Ordered**       | Results arrive in input order                   |
| **Streaming**     | Results are consumed as they complete           |
| **Back-pressure** | The Agent blocks until all tools finish         |

Compare with alternatives:

| Alternative | Verdict | Why |
|---|---|---|
| `Task.async/1` | ✗ | Linked — crash propagates to Agent |
| `Task.async_stream/3` | ✗ | Linked |
| `spawn/1` | ✗ | Unsupervised, no result collection |
| GenServer pool | ✗ | Over-engineered for ephemeral work |
| `async_stream_nolink` | ✓ | Supervised, isolated, ordered |

### The Blocking Model

While tool tasks run, the Agent GenServer is **blocked** inside
`Enum.zip(results, tasks)` — it cannot process `handle_info` or `handle_cast`.

This is intentional:

1. The agent cannot stream a new LLM response while tools are running
2. Tool results must be collected before the next `run_turn`
3. The conversation must stay consistent — no interleaved mutations

But this blocking creates two constraints that require specific solutions:

### Constraint 1: No Calling Back to the Agent

Since the Agent is blocked, any `GenServer.call(agent_pid, ...)` from a tool
task would deadlock:

```mermaid
sequenceDiagram
    participant Agent as Agent (blocked)
    participant Task as Tool Task

    Agent->>Task: async_stream_nolink(...)
    Note over Agent: waiting for results...

    Task->>Agent: GenServer.call(agent_pid, :get_state)
    Note over Task: blocks waiting for reply

    Note over Agent,Task: ╳ DEADLOCK (5s timeout)
```

**Solution: State snapshot.** Before dispatching tasks, the Agent captures
its entire state into the context map:

```elixir
context = %{agent_state: state, ...}
```

Tools read from `context.agent_state` — a frozen snapshot — instead of
calling back to the live GenServer. The `SubAgent` tool uses
`spawn_from_state(context.agent_state, overrides)` instead of
`spawn(agent_pid, overrides)`.

### Constraint 2: Steering Messages

Users may want to inject guidance while tools are running ("actually, skip
that file"). Since the Agent is blocked, it can't process `handle_cast`
messages. But those messages still accumulate in the GenServer mailbox.

**Solution: Selective receive.** After tool execution completes, the Agent
performs a zero-timeout selective receive on its own mailbox:

```elixir
defp check_for_steering(%State{} = state) do
  receive do
    {:"$gen_cast", {:steer, text}} ->
      user_msg = Opal.Message.user(text)
      state = append_message(state, user_msg)
      check_for_steering(state)
  after
    0 -> state
  end
end
```

This reaches directly into the GenServer's internal message format
(`:"$gen_cast"`) to extract steering messages that arrived during tool
execution. The `after 0` clause ensures it never blocks — if no steering
messages are waiting, it returns immediately.

```mermaid
sequenceDiagram
    participant User
    participant Agent
    participant Tasks as Tool Tasks

    User->>Agent: cast(:prompt)
    Agent->>Tasks: async_stream_nolink(...)
    Note over Agent: blocked waiting for results

    User->>Agent: cast(:steer, "skip that file")
    Note over Agent: steer message queued in mailbox

    Tasks-->>Agent: results collected
    Note over Agent: check_for_steering drains mailbox
    Note over Agent: steer message appended to msgs
    Agent->>Agent: run_turn (with steering)
```

**OTP mapping:** This is a standard Erlang selective receive. OTP GenServers
process messages in order via `handle_*` callbacks, but within a callback
implementation, you can use `receive` to selectively pull specific messages
from the mailbox. The BEAM's per-process mailbox makes this a zero-cost
operation.

---

## The Full Cycle

Putting it all together, here's one complete agentic turn:

```mermaid
sequenceDiagram
    participant User
    participant Agent
    participant BEAM as BEAM Scheduler
    participant Provider as Provider/LLM
    participant TaskSup as Task.Supervisor

    User->>Agent: prompt "Fix the bug"
    Note over Agent: Append user message, idle to running

    Agent->>Provider: provider.stream
    Provider-->>Agent: {:ok, resp}
    Note over Agent: running to streaming
    Note over BEAM: GenServer yields to scheduler

    Provider-->>Agent: handle_info chunk_1
    Note over Agent: text_delta, broadcast message_delta

    Provider-->>Agent: handle_info chunk_2
    Note over Agent: text_delta, broadcast message_delta

    Provider-->>Agent: handle_info chunk_N with done
    Note over Agent: tool_call_done, finalize_response

    Note over Agent: streaming to running, broadcast turn_end

    Agent->>TaskSup: async_stream_nolink edit_call
    Note over Agent: blocked waiting for results
    TaskSup-->>Agent: results collected

    Note over Agent: Append tool_result, check_for_steering

    Agent->>Provider: provider.stream next turn
    Provider-->>Agent: stream text only, done

    Note over Agent: No tool calls, broadcast agent_end, idle

    Agent-->>User: GenServer idle, waiting for next cast
```

---

## Session Integration

When an `Opal.Session` process is attached, every message append is mirrored
to it:

```elixir
defp append_message(%State{session: nil} = state, msg) do
  %{state | messages: state.messages ++ [msg]}
end

defp append_message(%State{session: session} = state, msg) do
  Opal.Session.append(session, msg)        # ← GenServer.call to Session
  %{state | messages: state.messages ++ [msg]}
end
```

The Agent maintains its own flat `messages` list for LLM context building
(fast, in-process), while the Session maintains a tree structure in ETS for
branching, persistence, and history. Both are always in sync.

```mermaid
graph TD
    subgraph agent["Agent state.messages (flat list for LLM)"]
        AM["[user, assistant, tool_result, assistant]"]
    end

    subgraph session["Session ETS table (tree for persistence)"]
        M1["msg_1 (user)"]
        M2["msg_2 (assistant)"]
        M3["msg_3 (tool_result)"]
        M4["msg_4 (assistant)"]
        M5["msg_5 (branch!)"]
        M1 --> M2
        M2 --> M3
        M3 --> M4
        M3 --> M5
    end
```

The Session is a sibling process under the same `SessionServer` supervisor.
If the Session crashes, the `:rest_for_one` strategy restarts the Agent too
(since it was started after the Session), ensuring they stay in sync.

---

## Message Types

The conversation uses four message roles that form a protocol between the
Agent, the LLM, and the tools:

```mermaid
sequenceDiagram
    participant User
    participant Agent
    participant LLM
    participant Tools

    User->>Agent: :user "Fix bug"
    Agent->>LLM: system + messages
    LLM-->>Agent: :assistant "I'll fix" + tool_calls [edit]
    Agent->>Tools: execute(args, ctx)
    Tools-->>Agent: {:ok, "Done"}
    Agent->>LLM: :tool_result "Done"
    LLM-->>Agent: :assistant "Fixed!"
    Agent-->>User: {:agent_end, msgs}
```

Each message is an `Opal.Message` struct with a unique `id` and optional
`parent_id` (used by Session for tree construction). The `call_id` field
links `:tool_call` entries in an assistant message to their corresponding
`:tool_result` messages — the LLM API requires this correlation.

---

## Auto-Save & Title Generation

When the agent goes idle and a Session is attached, two optional background
tasks fire:

```elixir
defp maybe_auto_save(%State{session: session, config: config} = state) do
  if config.auto_save do
    maybe_generate_title(state)
    Opal.Session.save(session, dir)
  end
end
```

Title generation is a fire-and-forget task started under the session's
`Task.Supervisor`:

```elixir
Task.Supervisor.start_child(state.tool_supervisor, fn ->
  generate_session_title(state, first_user_msg.content)
end)
```

This makes a separate LLM call to generate a concise title. It runs as a
supervised task — if it fails, nothing else is affected. The title is written
to Session metadata via `Session.set_metadata(session, :title, clean)`.

**OTP mapping:** `Task.Supervisor.start_child` starts a fire-and-forget task
(unlike `async` which expects the caller to await). The task runs under the
same per-session supervisor, so it's cleaned up if the session is terminated.

---

## Tool Behaviour

Tools are modules implementing the `Opal.Tool` behaviour:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()         # JSON Schema
@callback execute(args :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}
```

The Agent converts tool modules to JSON Schema for the LLM via
`Provider.convert_tools/1`. When the LLM requests a tool call, the Agent
looks up the module by name and calls `execute/2` inside a supervised task.

**Context map passed to every tool:**

| Key              | Type              | Purpose                           |
|------------------|-------------------|-----------------------------------|
| `working_dir`    | `String.t()`      | Base directory for file operations|
| `session_id`     | `String.t()`      | For event broadcasting            |
| `config`         | `Opal.Config.t()` | Runtime configuration             |
| `agent_pid`      | `pid()`           | Reference only — do not call!     |
| `agent_state`    | `State.t()`       | Frozen snapshot of agent state    |

The `agent_state` snapshot is the key to avoiding deadlocks. Tools can read
any agent state they need without calling back to the blocked GenServer.

---

## Error Handling

The Agent handles errors at every phase without crashing:

### Stream errors

```elixir
defp handle_stream_event({:error, reason}, state) do
  broadcast(state, {:error, reason})
  %{state | status: :idle, streaming_resp: nil}
end
```

A stream error (rate limit, network failure) resets the agent to `:idle`.
Subscribers see `{:error, reason}` and can retry.

### Tool crashes

```elixir
{{:exit, reason}, {tc, _tool_mod}} ->
  {tc, {:error, "Tool execution crashed: #{inspect(reason)}"}}
```

A crashing tool produces an error `tool_result` message. The LLM sees the
error and can decide how to proceed — retry, use a different tool, or explain
the failure to the user.

### Tool exceptions

```elixir
defp execute_single_tool(tool_mod, args, context) do
  tool_mod.execute(args, context)
rescue
  e -> {:error, "Tool raised an exception: #{Exception.message(e)}"}
end
```

Even if a tool raises (instead of crashing), the rescue converts it to an
error tuple. The tool task completes normally, and the Agent continues.

### Missing tools

```elixir
defp execute_single_tool(nil, _args, _context) do
  {:error, "Tool not found"}
end
```

If the LLM hallucinated a tool name, the Agent returns an error result. The
LLM learns the tool doesn't exist and adjusts.

**Design principle:** The Agent never crashes due to tool-layer failures.
Every error is converted to a message the LLM can reason about. The
supervision tree is the safety net for truly unexpected failures.
