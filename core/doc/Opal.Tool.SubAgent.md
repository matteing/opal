# `Opal.Tool.SubAgent`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/tool/sub_agent.ex#L1)

Tool that allows an agent to spawn a sub-agent for delegated tasks.

The sub-agent runs with its own conversation loop, executes tools, and
returns a structured result containing the final response and a log of
all tool calls made. Sub-agent events are forwarded to the parent session
for real-time observability.

## Depth Enforcement

Sub-agents are limited to one level — this tool is never included in the
sub-agent's tool list, preventing recursive spawning.

## Tool Selection

The parent agent can specify a subset of its own tools by name. If omitted,
the sub-agent inherits all of the parent's tools (minus this one).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
