---
name: debugging
description: Guides use of the debug_state tool and runtime introspection to diagnose agent issues between turns. Load this skill when something goes wrong during a session and you need to inspect agent state, token usage, event history, or tool availability.
---

# Debugging Skill

You use the `debug_state` tool and Opal's runtime introspection to diagnose problems during a session. This skill teaches you when and how to self-diagnose.

## When to act

- A tool call fails unexpectedly or returns surprising results.
- The agent seems stuck in a loop or keeps retrying the same action.
- You suspect context is getting large and may be near the token limit.
- A feature (sub-agents, MCP, skills) doesn't seem to be working.
- The user asks you to debug yourself or inspect your own state.

## The debug feature is disabled by default

The `debug_state` tool and the in-memory event log are gated behind the `debug` feature flag, which is **off** by default. If you try to call `debug_state` and the tool isn't available, tell the user they need to enable it first.

### How the user enables debug mode

**From the TUI menu:** Press `Ctrl+\` (or the configured menu hotkey) to open the Opal Menu, then toggle **Debug introspection** on. This takes effect immediately for the current session.

**From Elixir code:**

```elixir
Opal.start_session(%{
  features: %{debug: %{enabled: true}}
})
```

**Via application config:**

```elixir
config :opal,
  features: %{debug: %{enabled: true}}
```

When debug is enabled, Opal keeps an in-memory event log (bounded ring buffer of the last 400 events) and exposes the `debug_state` tool. When debug is disabled, the event log is cleared and the tool is filtered out of the active tool set.

## Using debug_state

### Basic snapshot (no messages, no events)

```
debug_state({})
```

Returns: session ID, model info, provider, working directory, token usage, tool availability, and queue state.

### With recent events

```
debug_state({"event_limit": 100})
```

The `event_limit` parameter controls how many recent events to include (default: 50, max: 500). Events are returned newest-first and include a timestamp, event type, and a truncated data preview.

### With conversation messages

```
debug_state({"include_messages": true, "message_limit": 10})
```

When `include_messages` is true, the snapshot includes recent messages from the conversation (default: 20, max: 200). Each message shows its role, ID, and truncated content.

### Full diagnostic

```
debug_state({"event_limit": 200, "include_messages": true, "message_limit": 50})
```

Use this when you need the complete picture — events, messages, and state all together.

## What to look for

### Token pressure

Check `token_usage.current_context_tokens` against `token_usage.context_window`. If usage is above 80%, context compaction may be imminent. If it's above 90%, the agent may start losing earlier conversation context.

### Tool availability

The `tools` section shows three lists:

- `all` — every tool registered with the agent
- `enabled` — tools currently active (respects feature flags and disabled_tools)
- `disabled` — tool names explicitly disabled

If a tool you expect is missing from `enabled`, check whether its feature flag is off. For example, `debug_state` won't appear in `enabled` unless `features.debug.enabled` is true.

### Queue state

- `pending_steers` — steering messages waiting to be injected. Non-zero means the user sent a steer that hasn't been processed yet.
- `remaining_tool_calls` — tool calls from the LLM that haven't been executed. Non-zero during tool execution is normal; non-zero when idle suggests a stuck state.
- `has_pending_tool_task` — true when a tool is actively running in a background task.

### Event timeline

Events reveal the actual execution flow. Look for:

- **`request_start` → `request_end`** — one LLM round-trip. Check if there are excessive retries.
- **`tool_execution_start` → `tool_execution_end`** — tool lifecycle. Missing `end` events suggest a crash or timeout.
- **`error`** — any error events indicate failures.
- **`agent_abort`** — the user cancelled mid-execution.

### Common patterns

| Symptom | What to check |
|---------|---------------|
| Tool not available | `tools.enabled` list, feature flags |
| Slow responses | Event timestamps — look for gaps between `request_start` and `request_end` |
| Repeated errors | Recent events for `error` type entries |
| Context too large | `token_usage.current_context_tokens` vs `context_window` |
| Steer not working | `queues.pending_steers` — if non-zero, agent hasn't processed it yet |

## Relationship to external inspection

The `debug_state` tool is for **self-diagnosis** — the agent inspecting its own state. For **external inspection** by a human, Opal also supports connecting a second terminal via Erlang distribution (`pnpm inspect`). See `docs/inspecting.md` for that workflow.

The key difference: `debug_state` works within a turn and returns structured JSON the agent can reason about. External inspection gives a live event stream a human watches in real time.

## Source files

- `packages/core/lib/opal/tool/debug.ex` — The `debug_state` tool implementation
- `packages/core/lib/opal/agent/event_log.ex` — In-memory bounded event log (ETS ring buffer)
- `packages/core/lib/opal/agent/tool_runner.ex` — Where feature flags filter active tools
- `packages/core/lib/opal/config.ex` — `Opal.Config.Features` struct with `:debug` toggle
