# `Opal.SubAgent`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/sub_agent.ex#L1)

Spawns and manages child agents that work in parallel.

A sub-agent is another `Opal.Agent` started under `Opal.SessionSupervisor`.
It gets its own process, message history, and tool set. The supervision tree
ensures cleanup — if the parent session is torn down, sub-agents started by
tools within that session are cleaned up when those tool tasks terminate.

## Usage

    # From within a tool or the parent agent:
    {:ok, sub} = Opal.SubAgent.spawn(parent_agent, %{
      system_prompt: "You are a test-writing specialist.",
      tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Shell],
      model: {:copilot, "claude-haiku-3-5"}
    })

    {:ok, result} = Opal.SubAgent.run(sub, "Write tests for lib/opal/agent.ex")

Multiple sub-agents can be spawned in parallel, each working on different
files or tasks. If a sub-agent crashes, only that sub-agent is affected.

# `run`

```elixir
@spec run(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
```

Sends a prompt to a sub-agent and synchronously collects the response.

Subscribes to the sub-agent's events, sends the prompt, and waits for
`:agent_end`. Returns the accumulated text response.

## Options

  * `timeout` — maximum wait time in milliseconds (default: `120_000`)

# `spawn`

```elixir
@spec spawn(GenServer.server(), map()) :: {:ok, pid()} | {:error, term()}
```

Spawns a new sub-agent inheriting defaults from the parent agent.

The parent agent's config, working directory, model, provider, and tools
are used as defaults. Any key in `overrides` replaces the parent's value.

## Overrides

  * `:system_prompt` — system prompt for the sub-agent (default: parent's)
  * `:tools` — tool modules (default: parent's tools)
  * `:model` — `{provider, model_id}` tuple (default: parent's model)
  * `:working_dir` — working directory (default: parent's)
  * `:provider` — provider module (default: parent's)

Returns `{:ok, sub_agent_pid}` or `{:error, reason}`.

# `spawn_from_state`

```elixir
@spec spawn_from_state(Opal.Agent.State.t(), map()) :: {:ok, pid()} | {:error, term()}
```

Like `spawn/2`, but takes an already-captured `Opal.Agent.State` struct
instead of a pid. Use this from within tool execution to avoid calling
back into the blocked Agent GenServer (which would deadlock).

# `stop`

```elixir
@spec stop(pid()) :: :ok | {:error, :not_found}
```

Stops a sub-agent and cleans up its process.

Accepts either just the sub-agent pid (looks up the parent supervisor
from process ancestry) or the sub-agent pid and the supervisor to
terminate it from.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
