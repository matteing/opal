# `Opal`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal.ex#L1)

Public API for the Opal coding agent SDK.

Provides functions to start agent sessions, send prompts (async and sync),
steer agents mid-run, and manage session lifecycle. All agent events are
broadcast via `Opal.Events` for real-time observability.

Session defaults (model, tools, shell, data_dir) come from `Opal.Config`
and can be overridden per-session.

## Quick Start

    {:ok, agent} = Opal.start_session(%{
      system_prompt: "You are a helpful coding assistant.",
      working_dir: "/path/to/project"
    })

    :ok = Opal.prompt(agent, "List all Elixir files")

    # Or synchronously:
    {:ok, response} = Opal.prompt_sync(agent, "What is 2 + 2?")

# `abort`

```elixir
@spec abort(GenServer.server()) :: :ok
```

Aborts the current agent run.

# `follow_up`

```elixir
@spec follow_up(GenServer.server(), String.t()) :: :ok
```

Sends a follow-up prompt to the agent. Convenience wrapper for `prompt/2`.

# `get_context`

```elixir
@spec get_context(pid()) :: [Opal.Message.t()]
```

Returns the full context window (system prompt + all messages) for a session.

# `prompt`

```elixir
@spec prompt(GenServer.server(), String.t()) :: :ok
```

Sends an asynchronous prompt to the agent.

Subscribe to `Opal.Events` with the session ID to receive streaming output.
Returns `:ok` immediately.

# `prompt_sync`

```elixir
@spec prompt_sync(GenServer.server(), String.t(), timeout()) ::
  {:ok, String.t()} | {:error, term()}
```

Sends a prompt and waits synchronously for the final response.

Subscribes to the agent's events, sends the prompt, and collects text
deltas until `:agent_end` is received. Returns the accumulated text.

## Options

  * `timeout` — maximum wait time in milliseconds (default: `60_000`)

# `set_model`

```elixir
@spec set_model(pid(), atom(), String.t(), keyword()) :: :ok
```

Changes the model on a running agent session.

The new model takes effect on the next prompt. Conversation history is preserved.

    Opal.set_model(agent, :copilot, "gpt-5")

# `start_session`

```elixir
@spec start_session(map()) :: {:ok, pid()} | {:error, term()}
```

Starts a new agent session with the given configuration.

All keys are optional — defaults come from `config :opal` via `Opal.Config`.

## Config Keys

  * `:model` — a `{provider_atom, model_id_string}` tuple
  * `:tools` — list of modules implementing `Opal.Tool`
  * `:system_prompt` — the system prompt string (default: `""`)
  * `:working_dir` — base directory for tool execution (default: current dir)
  * `:provider` — module implementing `Opal.Provider` (default: `Opal.Provider.Copilot`)
  * `:session` — if `true`, starts an `Opal.Session` process for persistence/branching
  * `:shell` — shell type for `Opal.Tool.Shell` (default: platform auto-detect)
  * `:data_dir` — override data directory (default: `~/.opal`)

## Examples

    # Minimal — everything from config :opal
    {:ok, agent} = Opal.start_session(%{working_dir: "/project"})

    # Override model for this session
    {:ok, agent} = Opal.start_session(%{
      model: {:copilot, "gpt-5"},
      working_dir: "/project"
    })

# `steer`

```elixir
@spec steer(GenServer.server(), String.t()) :: :ok
```

Steers the agent mid-run.

If idle, acts like `prompt/2`. If running, the message is picked up
between tool executions.

# `stop_session`

```elixir
@spec stop_session(pid()) :: :ok | {:error, :not_found}
```

Stops a session and cleans up.

Terminates the entire session supervision tree (agent, tools, sub-agents).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
