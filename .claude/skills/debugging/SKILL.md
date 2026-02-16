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

The `debug_state` tool is for **self-diagnosis** — the agent inspecting its own state. For **external inspection** by a human, Opal also supports connecting a second terminal via Erlang distribution (`mise run inspect`). See `docs/inspecting.md` for that workflow.

The key difference: `debug_state` works within a turn and returns structured JSON the agent can reason about. External inspection gives a live event stream a human watches in real time.

## Integration testing with opal-server

Beyond unit tests (`mix test`) and the `debug_state` tool, you can spin up a real opal-server instance and interact with it programmatically. This lets you verify end-to-end behavior after making changes — e.g., "does session/start still work after I refactored config?"

All commands run from the repo root.

### One-off RPC calls

Use `scripts/opal-rpc.exs` to send a single JSON-RPC method and get a JSON response:

```bash
# Liveness check
mix run --no-start ../../scripts/opal-rpc.exs -- opal/ping

# Start a session and see the full response
mix run --no-start ../../scripts/opal-rpc.exs -- session/start '{"working_dir": "/tmp"}'

# Check auth status
mix run --no-start ../../scripts/opal-rpc.exs -- auth/status

# List saved sessions
mix run --no-start ../../scripts/opal-rpc.exs -- session/list

# Get agent state (use session_id from session/start)
mix run --no-start ../../scripts/opal-rpc.exs -- agent/state '{"session_id": "abc123"}'
```

The output is JSON with `ok: true/false` and either `result` or `error`. This is useful for testing RPC handler changes, config parsing, auth flow, etc.

### Full session lifecycle

Use `scripts/opal-session.exs` to start a session, send a prompt, and collect the complete event stream:

```bash
# Send a prompt and see the full event lifecycle
mix run --no-start ../../scripts/opal-session.exs -- "What tools do you have?"

# With a specific model
mix run --no-start ../../scripts/opal-session.exs -- "List files" --model copilot:gpt-4.1

# JSON event output (one event per line, for programmatic parsing)
mix run --no-start ../../scripts/opal-session.exs -- "Hello" --json --timeout 15000

# With a working directory (agent will discover context files there)
mix run --no-start ../../scripts/opal-session.exs -- "Read README.md" --working-dir /path/to/project
```

Human-readable mode prints events to stderr and the final response to stdout. JSON mode (`--json`) prints one JSON object per event line, useful for piping to `jq` or programmatic analysis.

### When to use these scripts

| Scenario | Tool |
|----------|------|
| Verify an RPC method works after changing handler.ex | `opal-rpc.exs` |
| Test session startup after config/builder changes | `opal-rpc.exs` with `session/start` |
| Verify auth flow changes | `opal-rpc.exs` with `auth/status` |
| Test end-to-end prompt→response→tool flow | `opal-session.exs` |
| Verify event stream after changing agent/events code | `opal-session.exs --json` |
| Reproduce a bug with a specific prompt | `opal-session.exs` |

### How they work

Both scripts boot the Opal OTP application in-process (no child process or stdio transport) and call `Opal.RPC.Handler.handle/2` directly. This means:

- No stdio pipe management or process lifecycle issues
- Fast startup (reuses compiled BEAM)
- Full access to the same code paths as the real server
- Distribution and RPC transport are disabled to avoid side effects

## Source files

- `lib/opal/tool/debug.ex` — The `debug_state` tool implementation
- `lib/opal/agent/event_log.ex` — In-memory bounded event log (ETS ring buffer)
- `lib/opal/agent/tool_runner.ex` — Where feature flags filter active tools
- `lib/opal/config.ex` — `Opal.Config.Features` struct with `:debug` toggle
- `scripts/opal-rpc.exs` — One-off RPC call script for integration testing
- `scripts/opal-session.exs` — Full session lifecycle script with event streaming
