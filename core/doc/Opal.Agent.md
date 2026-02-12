# `Opal.Agent`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/agent.ex#L1)

GenServer implementing the core agent loop.

Manages the lifecycle of an agent session: receiving user prompts, streaming
LLM responses via a provider, executing tool calls concurrently, and looping
until the model produces a final text response with no tool calls.

## Usage

    {:ok, pid} = Opal.Agent.start_link(
      session_id: "session-abc",
      system_prompt: "You are a coding assistant.",
      model: %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5"},
      tools: [Opal.Tool.Read, Opal.Tool.Write],
      working_dir: "/path/to/project"
    )

    :ok = Opal.Agent.prompt(pid, "List all files")

Events are broadcast via `Opal.Events` using the session ID, so any
subscriber can observe the full lifecycle in real time.

# `abort`

```elixir
@spec abort(GenServer.server()) :: :ok
```

Aborts the current agent run.

If streaming, cancels the response. Sets status to `:idle`.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `follow_up`

```elixir
@spec follow_up(GenServer.server(), String.t()) :: :ok
```

Sends a follow-up prompt to the agent. Convenience alias for `prompt/2`.

# `get_state`

```elixir
@spec get_state(GenServer.server()) :: Opal.Agent.State.t()
```

Returns the current agent state synchronously.

# `load_skill`

```elixir
@spec load_skill(GenServer.server(), String.t()) ::
  {:ok, String.t()} | {:already_loaded, String.t()} | {:error, String.t()}
```

Loads a skill by name into the agent's active context.

Returns `{:ok, skill_name}` if loaded, `{:already_loaded, skill_name}` if
already active, or `{:error, reason}` if the skill is not found.

# `platform`

```elixir
@spec platform(GenServer.server()) :: :linux | :macos | :windows
```

Returns the current platform as `:linux`, `:macos`, or `:windows`.

# `prompt`

```elixir
@spec prompt(GenServer.server(), String.t()) :: :ok
```

Sends an asynchronous user prompt to the agent.

Appends a user message, sets status to `:running`, and begins a new LLM turn.
Returns `:ok` immediately.

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts the agent GenServer.

## Options

  * `:session_id` — unique string identifier for this session (required)
  * `:system_prompt` — the system prompt string (default: `""`)
  * `:model` — an `Opal.Model.t()` struct (required)
  * `:tools` — list of modules implementing `Opal.Tool` (default: `[]`)
  * `:working_dir` — base directory for tool execution (required)
  * `:provider` — module implementing `Opal.Provider` (default: `Opal.Provider.Copilot`)

# `steer`

```elixir
@spec steer(GenServer.server(), String.t()) :: :ok
```

Injects a steering message into the agent.

If the agent is idle, this behaves like `prompt/2`. If the agent is running
or streaming, the steering message is queued in the GenServer mailbox and
picked up between tool executions.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
