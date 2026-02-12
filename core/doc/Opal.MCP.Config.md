# `Opal.MCP.Config`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/config.ex#L1)

Discovers and parses MCP server configuration files.

Searches multiple standard locations for `mcp.json` files following the
[VS Code MCP configuration format](https://code.visualstudio.com/docs/copilot/customization/mcp-servers#_configuration-format),
and converts them into the internal `%{name, transport}` maps that
`Opal.MCP.Supervisor` expects.

## Discovery paths (in order)

Project-local (relative to `working_dir`):
  1. `.vscode/mcp.json`
  2. `.github/mcp.json`
  3. `.opal/mcp.json`
  4. `.mcp.json`

User global:
  5. `~/.opal/mcp.json`

First definition wins per server name — project-local overrides global.

## VS Code format

```json
{
  "servers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"]
    },
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp"
    }
  }
}
```

Stdio servers use `command` + `args` + optional `env`/`envFile`.
HTTP/SSE servers use `type` ("http" or "sse") + `url` + optional `headers`.

# `discover`

```elixir
@spec discover(
  String.t(),
  keyword()
) :: [map()]
```

Discovers MCP server configurations from standard file locations.

## Options

  * `:extra_files` — additional file paths to search (absolute or relative to working_dir)

Returns a list of `%{name: atom, transport: tuple}` maps, deduplicated
by server name (first found wins).

# `parse_file`

```elixir
@spec parse_file(String.t()) :: [map()]
```

Parses a single mcp.json file and returns a list of server configs.

Returns `[]` if the file doesn't exist or is invalid.

# `parse_server`

```elixir
@spec parse_server(String.t(), map()) :: map() | nil
```

Parses a single server entry from VS Code format into internal format.

Returns `%{name: String.t(), transport: tuple}` or `nil` if invalid.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
