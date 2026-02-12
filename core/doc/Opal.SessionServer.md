# `Opal.SessionServer`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/session_server.ex#L1)

Per-session supervisor that owns the full session process tree.

Each session gets its own supervision subtree:

    Opal.SessionServer (Supervisor, :rest_for_one)
    ├── Task.Supervisor        — per-session tool execution
    ├── DynamicSupervisor      — per-session sub-agents
    ├── Opal.MCP.Supervisor    — MCP client connections (optional)
    ├── Opal.Session           — conversation persistence (optional)
    └── Opal.Agent             — the agent loop

Terminating the SessionServer cleans up everything: the agent, all
running tools, all sub-agents, MCP connections, and the session store.

The `:rest_for_one` strategy means if the Task.Supervisor,
DynamicSupervisor, or MCP.Supervisor crashes, the Agent (which depends
on them) restarts too.

# `agent`

```elixir
@spec agent(pid()) :: pid() | nil
```

Returns the Agent pid from a SessionServer supervisor.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `session`

```elixir
@spec session(pid()) :: pid() | nil
```

Returns the Session pid from a SessionServer supervisor, or nil.

# `start_link`

Starts a session supervisor with the given options.

## Required Options

  * `:session_id` — unique session identifier
  * `:model` — `Opal.Model.t()` struct
  * `:working_dir` — base directory for tool execution

## Optional Options

  * `:system_prompt` — system prompt string
  * `:tools` — list of `Opal.Tool` modules
  * `:config` — `Opal.Config.t()` struct
  * `:provider` — `Opal.Provider` module
  * `:session` — if `true`, starts an `Opal.Session` process

---

*Consult [api-reference.md](api-reference.md) for complete listing*
