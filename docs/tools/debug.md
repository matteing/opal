# debug_state

Returns a compact runtime snapshot of the current agent session for self-diagnosis. The tool is registered but **disabled by default** and only becomes callable when `features.debug` is enabled.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `event_limit` | integer | no | Max number of recent events to include (default: `50`, max: `500`) |
| `include_messages` | boolean | no | Include recent conversation messages (default: `false`) |
| `message_limit` | integer | no | Max messages when `include_messages=true` (default: `20`, max: `200`) |

## Output

The tool returns pretty-printed JSON with:

- session/runtime metadata (`session_id`, `status`, `model`, `provider`, `working_dir`)
- queue/tool state (`pending_steers`, tool call queue, enabled/disabled tools)
- token usage snapshot
- message counts (and optional recent message samples)
- recent agent events captured from in-memory debug event log

## Enabling

Enable at boot:

```json
{
  "method": "session/start",
  "params": {
    "features": { "debug": true }
  }
}
```

Enable at runtime:

```json
{
  "method": "opal/config/set",
  "params": {
    "session_id": "...",
    "features": { "debug": true }
  }
}
```

When debug is disabled, event capture is off and existing in-memory debug events are cleared.

## Source

- `packages/core/lib/opal/tool/debug.ex`
- `packages/core/lib/opal/agent/event_log.ex`
- `packages/core/lib/opal/agent/tool_runner.ex`
