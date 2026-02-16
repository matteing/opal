defmodule Opal.Config.Features do
  @moduledoc """
  Unified feature toggles for optional Opal subsystems.

  Groups all optional subsystem configuration under a single struct
  with consistent `enabled` toggles and subsystem-specific options.

  ## Subsystems

    * `:sub_agents` — child agent spawning via `Opal.SubAgent`
    * `:context` — walk-up context file discovery (AGENTS.md, OPAL.md, etc.)
    * `:skills` — skill directory discovery and progressive disclosure
    * `:mcp` — MCP (Model Context Protocol) client integration
    * `:debug` — internal debug/introspection tooling (disabled by default)

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
          mcp: %{enabled: true, servers: [], config_files: []},
          debug: %{enabled: false}
        }
  """

  @type t :: %__MODULE__{
          sub_agents: sub_agents_config(),
          context: context_config(),
          skills: skills_config(),
          mcp: mcp_config(),
          debug: debug_config()
        }

  @typedoc """
  Sub-agent subsystem configuration.

    * `:enabled` — whether sub-agent spawning is allowed. Default: `true`.
  """
  @type sub_agents_config :: %{enabled: boolean()}

  @typedoc """
  Context file discovery configuration.

    * `:enabled` — whether walk-up context discovery runs at startup. Default: `true`.
    * `:filenames` — filenames to look for during walk-up discovery.
      Default: `["AGENTS.md", "OPAL.md"]`. Files found closer to the working
      directory take higher priority.
  """
  @type context_config :: %{enabled: boolean(), filenames: [String.t()]}

  @typedoc """
  Skill directory discovery configuration.

    * `:enabled` — whether skill discovery runs at startup. Default: `true`.
    * `:extra_dirs` — additional directories to scan for skill subdirectories
      (each containing a `SKILL.md`). Searched in addition to the standard
      locations (`.agents/skills/`, `.github/skills/` in the project and
      `~/.agents/skills/`, `~/.opal/skills/` globally). Default: `[]`.
  """
  @type skills_config :: %{enabled: boolean(), extra_dirs: [String.t()]}

  @typedoc """
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
  """
  @type mcp_config :: %{enabled: boolean(), servers: [map()], config_files: [String.t()]}

  @typedoc """
  Internal debug/introspection feature configuration.

    * `:enabled` — whether internal debug tooling is available. Default: `false`.
      When disabled, the debug tool is filtered out and no in-memory event log is kept.
  """
  @type debug_config :: %{enabled: boolean()}

  defstruct sub_agents: %{enabled: true},
            context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
            skills: %{enabled: true, extra_dirs: []},
            mcp: %{enabled: true, servers: [], config_files: []},
            debug: %{enabled: false}

  @doc """
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
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{})

  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    base = %__MODULE__{}

    base
    |> merge_subsystem(:sub_agents, attrs)
    |> merge_subsystem(:context, attrs)
    |> merge_subsystem(:skills, attrs)
    |> merge_subsystem(:mcp, attrs)
    |> merge_subsystem(:debug, attrs)
  end

  defp merge_subsystem(features, key, attrs) do
    case Map.get(attrs, key) do
      nil ->
        features

      # Boolean shorthand: `sub_agents: false` → %{enabled: false}
      enabled when is_boolean(enabled) ->
        current = Map.fetch!(features, key)
        %{features | key => %{current | enabled: enabled}}

      # Map: merge into existing defaults
      overrides when is_map(overrides) ->
        current = Map.fetch!(features, key)
        %{features | key => Map.merge(current, overrides)}
    end
  end
end
