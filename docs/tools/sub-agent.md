# sub_agent

Spawns a child agent for delegated tasks. The sub-agent runs in parallel under the session's DynamicSupervisor and its events are forwarded to the parent session in real-time.

## Parameters

| Param           | Type     | Required | Description                                                        |
| --------------- | -------- | -------- | ------------------------------------------------------------------ |
| `prompt`        | string   | yes      | Task description for the sub-agent                                 |
| `tools`         | string[] | no       | Subset of tool names to make available (default: all parent tools) |
| `model`         | string   | no       | Model ID override (e.g. use a cheaper model for simple tasks)      |
| `system_prompt` | string   | no       | Custom system prompt override                                      |

## Behavior

1. Spawns a new `Opal.Agent` via `Opal.SubAgent.spawn_from_state/2`
2. Sub-agent inherits the parent's config, provider, and working directory
3. Sends the prompt and blocks until the sub-agent finishes (120s timeout)
4. Collects the sub-agent's final response text and a log of tool executions
5. Terminates the sub-agent process

## Depth Enforcement

Sub-agents are limited to **one level** — no recursive spawning. This is enforced by excluding `Opal.Tool.SubAgent` from the sub-agent's tool list. The LLM literally cannot request it because the tool doesn't exist in its schema.

## Event Forwarding

While the sub-agent runs, all its events (text deltas, tool executions, etc.) are re-broadcast to the parent session as `{:sub_agent_event, parent_call_id, sub_session_id, inner_event}`. The CLI renders these with visual nesting.

## Tool Filtering

If `tools` is specified, only those named tools are made available. This lets the parent agent restrict sub-agents to specific capabilities (e.g. read-only tasks).

`Opal.Tool.AskUser` is always removed from the sub-agent's tool list — sub-agents cannot ask the user questions. Only top-level agents have access to `ask_user`.

## Source

`lib/opal/tool/sub_agent.ex`, `lib/opal/sub_agent.ex`
