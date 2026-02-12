# `Opal.MCP.Supervisor`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/supervisor.ex#L1)

Supervisor for MCP client processes within a session.

Starts one `Opal.MCP.Client` child per configured MCP server using
a `:one_for_one` strategy — each server connection is independent,
so a crash in one doesn't affect others.

## Supervision tree placement

    SessionSupervisor (:rest_for_one)
    ├── Task.Supervisor      — tool execution
    ├── DynamicSupervisor    — sub-agents
    ├── Opal.MCP.Supervisor  — MCP clients
    │   ├── Client :server_a
    │   ├── Client :server_b
    │   └── ...
    ├── Opal.Session         — persistence (optional)
    └── Opal.Agent           — the agent loop

When the session shuts down, this supervisor cascades termination to
all Anubis client processes, which cleanly close their connections.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `running_clients`

```elixir
@spec running_clients(pid()) :: [atom() | String.t()]
```

Returns the list of running MCP client names from this supervisor.

# `start_link`

```elixir
@spec start_link(keyword()) :: Supervisor.on_start()
```

Starts the MCP supervisor with the given server configurations.

## Parameters

  * `opts` — keyword list with:
    * `:servers` — list of `%{name: atom | String.t(), transport: tuple}` maps
    * `:name` — optional process name (atom or via-tuple)

---

*Consult [api-reference.md](api-reference.md) for complete listing*
