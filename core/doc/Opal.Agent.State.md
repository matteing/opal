# `Opal.Agent.State`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/agent.ex#L28)

Internal state for `Opal.Agent`.

Tracks conversation history, streaming state, accumulated response text
and tool calls, and the provider module used for LLM communication.

# `t`

```elixir
@type t() :: %Opal.Agent.State{
  active_skills: [String.t()],
  available_skills: [Opal.Skill.t()],
  config: Opal.Config.t(),
  context: String.t(),
  context_files: [String.t()],
  current_text: String.t(),
  current_tool_calls: [map()],
  last_chunk_at: term(),
  last_prompt_tokens: term(),
  mcp_servers: [map()],
  mcp_supervisor: atom() | pid() | nil,
  messages: [Opal.Message.t()],
  model: Opal.Model.t(),
  pending_steers: [String.t()],
  pending_tool_calls: MapSet.t(),
  provider: module(),
  session: pid() | nil,
  session_id: String.t(),
  status: :idle | :running | :streaming,
  stream_watchdog: term(),
  streaming_resp: Req.Response.t() | nil,
  sub_agent_supervisor: atom() | pid(),
  system_prompt: String.t(),
  token_usage: map(),
  tool_supervisor: atom() | pid(),
  tools: [module()],
  working_dir: String.t()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
