# `Opal.MCP.Bridge`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/bridge.ex#L1)

Bridges MCP tools into the Opal tool system.

After Anubis clients connect and negotiate, `Bridge` queries each client
for its available tools and wraps them as anonymous modules that implement
the `Opal.Tool` behaviour interface. This lets the agent call MCP tools
exactly like native tools — no special dispatch needed.

## Tool naming

MCP tools keep their original names (e.g. `get_weather`, `search_issues`).
When two servers expose tools with the same name, the tool is prefixed
with the server name: `weather_get_weather`, `backup_get_weather`.

# `create_tool_module`

```elixir
@spec create_tool_module(atom() | String.t(), map(), String.t()) :: module()
```

Creates an Opal.Tool-compatible module for an MCP tool at runtime.

The generated module implements the `Opal.Tool` behaviour callbacks
(`name/0`, `description/0`, `parameters/0`, `execute/2`) and routes
execution through the Anubis client.

# `discover_all_tools`

```elixir
@spec discover_all_tools([map()]) :: [map()]
```

Discovers tools from all configured MCP servers.

Takes a list of server config maps (each with a `:name` key) and returns
a flat list of all discovered tools across all servers.

# `discover_tool_modules`

```elixir
@spec discover_tool_modules([map()], MapSet.t()) :: [module()]
```

Discovers tools from all MCP servers and returns them as runtime modules
implementing `Opal.Tool`.

Uses original tool names by default. When two servers expose tools with
the same name, both get prefixed with their server name to disambiguate.

The `existing_names` parameter is a `MapSet` of tool names already
registered (e.g. native tools), which also trigger prefixing.

# `discover_tools`

```elixir
@spec discover_tools(atom() | String.t()) :: [map()]
```

Discovers tools from a single named MCP client and returns them as
Opal-compatible tool maps.

Each returned map has:
  * `:name` — tool name (original, or `<server>_<tool>` on collision)
  * `:description` — tool description from the MCP server
  * `:parameters` — JSON Schema input schema
  * `:server` — the MCP server name (atom)
  * `:original_name` — the tool's original name on the MCP server

Returns `[]` if the client is not connected or tool discovery fails.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
