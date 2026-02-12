# `Opal.MCP.Servers.Weather`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/servers/weather.ex#L1)

Example MCP server that provides weather information via stdio JSON-RPC.

Implements the MCP protocol directly over stdin/stdout without depending
on Anubis server (which has a bug in its stdio transport message parsing).

Uses the free wttr.in API to fetch current weather for a given location.
Defaults to Seattle if no location is specified.

## Usage

Started as a stdio MCP server via `mix opal.mcp.weather`:

    mix opal.mcp.weather

Or reference it in `.mcp.json`:

    {
      "servers": {
        "weather": {
          "command": "mix",
          "args": ["opal.mcp.weather"]
        }
      }
    }

# `run`

Starts the stdio MCP server loop.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
