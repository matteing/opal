# `Opal.MCP.Resources`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/resources.ex#L1)

Discovers and reads resources from connected MCP servers.

MCP servers can expose resources (file contents, database schemas, etc.)
that can be injected into the agent's context. This module provides a
thin wrapper around Anubis client resource operations.

# `list`

```elixir
@spec list(atom() | String.t()) :: [map()]
```

Lists available resources from a named MCP client.

Returns a list of resource maps, or `[]` if discovery fails.

# `list_all`

```elixir
@spec list_all([map()]) :: [{atom() | String.t(), map()}]
```

Lists resources from all configured MCP servers.

Returns a flat list of `{server_name, resource}` tuples.

# `read`

```elixir
@spec read(atom() | String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
```

Reads a specific resource by URI from a named MCP client.

Returns `{:ok, contents}` or `{:error, reason}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
