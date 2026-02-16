# Conversation Integrity

LLM providers require strict message sequencing: every assistant message with `tool_calls` must be followed by matching `tool_result` messages, and every `tool_result` must reference a preceding `tool_call`. Violations cause the provider to reject the entire request with errors like `invalid_request_body`. The conversation integrity system ensures the message history is always valid before it reaches the provider, regardless of what went wrong.

## The Problem

Several runtime scenarios can corrupt the message sequence:

| Scenario | What breaks |
|----------|-------------|
| **User abort during tool execution** | Assistant message with `tool_calls` committed, but `tool_result` messages never added |
| **Stream error from provider** | `finalize_response` creates a broken assistant message from partial stream data |
| **Compaction** | Summary replacement can orphan `tool_result` messages whose parent assistant was removed |
| **Session reload** | Deserialized tool_calls with nil `call_id` or `name` fields |
| **Sub-agent abort** | Long-running sub_agent (120s timeout) is the most common abort trigger |

The most frequent trigger is aborting during `sub_agent` execution — it's the only built-in tool with a blocking receive loop that can run for minutes, making user aborts likely.

## Defense Layers

The fix uses three independent layers so that any single failure is caught by the next:

```mermaid
flowchart TD
    Abort["User aborts / error occurs"] --> Layer1
    Layer1["Layer 1: repair_orphaned_tool_calls<br/><small>Scans ALL assistant messages,<br/>appends synthetic results to state</small>"]
    Layer1 --> NextTurn["Next turn starts"]
    NextTurn --> Layer2["Layer 2: ensure_tool_results<br/><small>Walks chronological message list,<br/>injects results at correct position,<br/>strips orphaned results</small>"]
    Layer2 --> Layer3["Layer 3: stream_errored flag<br/><small>Prevents finalize_response from<br/>creating broken messages</small>"]
    Layer3 --> Provider["Clean messages → Provider API"]
```

### Layer 1: Full-Scan Orphan Repair

Called on every turn start and on every abort. Walks the message list (stored newest-first) and finds ALL assistant messages whose `tool_calls` lack matching `tool_result` messages anywhere after them. Injects synthetic error results.

```elixir
# In run_turn_internal, before building messages:
state = repair_orphaned_tool_calls(state)

# In cancel_tool_execution, after killing tasks:
state = repair_orphaned_tool_calls(state)
```

The key fix: `find_orphaned_calls` scans **every** assistant message in the conversation, not just the most recent. This catches "deep orphans" — orphaned tool_calls buried in history with valid turns after them.

**Source:** `lib/opal/agent/agent.ex` — `repair_orphaned_tool_calls/1`, `find_orphaned_calls/3`

### Layer 2: Positional Validation in `build_messages`

Even after Layer 1 repairs orphans by appending results, the appended results end up at the **end** of the chronological list — not immediately after the orphaned assistant message. Providers require tool results to directly follow their assistant message.

`ensure_tool_results/1` runs on the final chronological message list inside `build_messages`, right before messages are sent to the provider. It performs two operations:

1. **Inject missing results** — for each assistant with `tool_calls`, peek ahead to check if all call IDs have matching `tool_result` messages. If any are missing, inject synthetic error results immediately after the assistant.

2. **Strip orphaned results** — remove any `tool_result` message whose `call_id` doesn't match any assistant's `tool_calls` (can happen after compaction removes the parent assistant).

```elixir
# In build_messages:
[system_msg | ensure_tool_results(Enum.reverse(messages))]
```

**Source:** `lib/opal/agent/agent.ex` — `ensure_tool_results/1`

### Layer 3: Stream Error Guard

When the provider sends an error event mid-stream (e.g., `invalid_request_body`), the error handler sets `stream_errored: true` on the state. The SSE `handle_info` checks this flag **before** calling `finalize_response`:

```elixir
cond do
  state.stream_errored ->
    # Don't finalize — discard partial content, go idle
    {:noreply, %{state | status: :idle, stream_errored: false}}

  :done in chunks ->
    finalize_response(state)

  true ->
    {:noreply, state}
end
```

Without this guard, `finalize_response` would override `status: :idle` (set by the error handler) back to `:running`, create an assistant message from partial/empty stream data, and potentially start tool execution on malformed tool calls.

**Source:** `lib/opal/agent/agent.ex` (SSE handle_info), `lib/opal/agent/stream.ex` (error event handler), `lib/opal/agent/state.ex` (`stream_errored` field)

## Additional Hardening

### Malformed Tool Call Filtering

`finalize_tool_calls` rejects tool calls with empty `call_id` or `name` fields. These can occur when a stream is interrupted mid-tool-call (partial delta received, no `tool_call_done`).

```elixir
|> Enum.reject(fn tc -> tc.call_id == "" or tc.name == "" end)
```

**Source:** `lib/opal/agent/agent.ex` — `finalize_tool_calls/1`

### Session Deserialization Validation

`json_to_message` filters nil `call_id` or `name` entries when deserializing tool_calls from saved sessions. An assistant message whose tool_calls all had nil fields gets `tool_calls: nil` (treated as a plain text response).

**Source:** `lib/opal/session.ex` — `json_to_message/1`

## How It Works End-to-End

A typical abort recovery flow:

```mermaid
sequenceDiagram
    participant User
    participant Agent as Agent (gen_statem)
    participant Session as Session (ETS)
    participant Provider as LLM Provider

    Agent->>Session: append assistant(tool_calls: [A, B])
    Agent->>Agent: start_tool_execution([A, B])
    Note over Agent: status: executing_tools

    User->>Agent: abort
    Agent->>Agent: cancel_all_tasks (kill tool tasks)
    Agent->>Agent: repair_orphaned_tool_calls
    Note over Agent: Scans ALL messages<br/>Finds A, B without results<br/>Appends synthetic results
    Agent->>Session: append tool_result(A, "[Aborted]", error)
    Agent->>Session: append tool_result(B, "[Aborted]", error)
    Note over Agent: status: idle

    User->>Agent: new prompt
    Agent->>Agent: run_turn_internal
    Agent->>Agent: repair_orphaned_tool_calls (Layer 1, no-op)
    Agent->>Agent: build_messages → ensure_tool_results (Layer 2)
    Note over Agent: Validates all pairs intact<br/>No injection needed
    Agent->>Provider: clean message history ✅
    Provider-->>Agent: streaming response
```

## Testing

The conversation integrity test suite (`test/opal/agent/conversation_integrity_test.exs`) covers:

- Clean conversations (no-op validation)
- Single orphaned tool_call injection
- Deep orphans not in the most recent assistant message
- Multiple orphans in the same assistant message
- Multiple orphan batches across the conversation
- Empty and nil tool_calls (edge cases)
- Orphaned tool_results stripped (reverse problem)
- Stream error recovery (agent goes idle, no broken messages)
- Agent accepts new prompts after stream error (self-healing)

## Source

- `lib/opal/agent/agent.ex` — `repair_orphaned_tool_calls`, `find_orphaned_calls`, `ensure_tool_results`, `finalize_tool_calls`, stream error handling
- `lib/opal/agent/stream.ex` — `stream_errored` flag on error events
- `lib/opal/agent/state.ex` — `stream_errored` field
- `lib/opal/session.ex` — `json_to_message` validation
- `test/opal/agent/conversation_integrity_test.exs` — test suite
