# `Opal.Config.Features`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/config.ex#L32)

Unified feature toggles for optional Opal subsystems.

Groups all optional subsystem configuration under a single struct
with consistent `enabled` toggles and subsystem-specific options.

## Subsystems

  * `:sub_agents` — child agent spawning via `Opal.SubAgent`
  * `:context` — walk-up context file discovery (AGENTS.md, OPAL.md, etc.)
  * `:skills` — skill directory discovery and progressive disclosure
  * `:mcp` — MCP (Model Context Protocol) client integration

## Usage

    # Disable sub-agents and MCP, customize context filenames
    features = Opal.Config.Features.new(%{
      sub_agents: %{enabled: false},
      mcp: %{enabled: false},
      context: %{filenames: ["AGENTS.md", "CUSTOM.md"]}
    })

    # Or via application config
    config :opal,
      features: %{
        sub_agents: %{enabled: true},
        context: %{filenames: ["AGENTS.md"]},
        skills: %{extra_dirs: ["/opt/skills"]},
        mcp: %{enabled: true, servers: [], config_files: []}
      }

# `context_config`

```elixir
@type context_config() :: %{enabled: boolean(), filenames: [String.t()]}
```

Context file discovery configuration.

  * `:enabled` — whether walk-up context discovery runs at startup. Default: `true`.
  * `:filenames` — filenames to look for during walk-up discovery.
    Default: `["AGENTS.md", "OPAL.md"]`. Files found closer to the working
    directory take higher priority.

# `mcp_config`

```elixir
@type mcp_config() :: %{
  enabled: boolean(),
  servers: [map()],
  config_files: [String.t()]
}
```

MCP (Model Context Protocol) client configuration.

  * `:enabled` — whether MCP client integration is active. When `false`,
    no MCP servers are started and no `mcp.json` files are read. Default: `true`.
  * `:servers` — explicit list of MCP server configurations, each a map
    with `:name` (string) and `:transport` (tuple) keys. Default: `[]`.
  * `:config_files` — additional file paths to search for `mcp.json`
    configuration files (absolute or relative to the working directory).
    Searched in addition to standard locations (`.vscode/mcp.json`,
    `.github/mcp.json`, `.opal/mcp.json`, `.mcp.json`, `~/.opal/mcp.json`).
    Default: `[]`.

# `skills_config`

```elixir
@type skills_config() :: %{enabled: boolean(), extra_dirs: [String.t()]}
```

Skill directory discovery configuration.

  * `:enabled` — whether skill discovery runs at startup. Default: `true`.
  * `:extra_dirs` — additional directories to scan for skill subdirectories
    (each containing a `SKILL.md`). Searched in addition to the standard
    locations (`.agents/skills/`, `.github/skills/` in the project and
    `~/.agents/skills/`, `~/.opal/skills/` globally). Default: `[]`.

# `sub_agents_config`

```elixir
@type sub_agents_config() :: %{enabled: boolean()}
```

Sub-agent subsystem configuration.

  * `:enabled` — whether sub-agent spawning is allowed. Default: `true`.

# `t`

```elixir
@type t() :: %Opal.Config.Features{
  context: context_config(),
  mcp: mcp_config(),
  skills: skills_config(),
  sub_agents: sub_agents_config()
}
```

# `new`

```elixir
@spec new(map() | keyword()) :: t()
```

Builds a Features struct from a map or keyword list.

Each subsystem key accepts either a map of options or a boolean shorthand.
Boolean shorthand sets only the `:enabled` flag, keeping other defaults.

## Examples

    # Full config
    Opal.Config.Features.new(%{
      sub_agents: %{enabled: false},
      mcp: %{enabled: true, servers: [%{name: :fs, transport: {:stdio, command: "npx"}}]}
    })

    # Boolean shorthand
    Opal.Config.Features.new(%{sub_agents: false, mcp: false})

---

*Consult [api-reference.md](api-reference.md) for complete listing*
