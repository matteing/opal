defmodule Opal.Config.Copilot do
  @moduledoc """
  Copilot-specific configuration: OAuth client ID and GitHub domain.

  ## Fields

    * `:client_id` — OAuth App client ID for the Copilot device-code flow.
      Default: `"Iv1.b507a08c87ecfe98"` (the VS Code Copilot Chat extension's ID).

    * `:domain` — GitHub domain for authentication endpoints.
      Default: `"github.com"`. Change for GitHub Enterprise Server instances.
  """

  @type t :: %__MODULE__{
          client_id: String.t(),
          domain: String.t()
        }

  # NOTE: This is the GitHub Copilot Chat VS Code extension's OAuth App
  # client ID, borrowed from Pi's source. It works because Copilot's
  # device-code flow doesn't enforce redirect URIs. Replace with Opal's
  # own registered OAuth App client ID when one exists.
  defstruct client_id: "Iv1.b507a08c87ecfe98",
            domain: "github.com"

  @doc "Builds from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: struct(__MODULE__, attrs)
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, Map.to_list(attrs))
end

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
  """

  @type t :: %__MODULE__{
          sub_agents: sub_agents_config(),
          context: context_config(),
          skills: skills_config(),
          mcp: mcp_config()
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

  defstruct sub_agents: %{enabled: true},
            context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
            skills: %{enabled: true, extra_dirs: []},
            mcp: %{enabled: true, servers: [], config_files: []}

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

defmodule Opal.Config do
  @moduledoc """
  Typed configuration struct for Opal sessions.

  Built once via `Opal.Config.new/1`, then threaded through the system.
  Every config key has a known type and a sensible default.

  ## Priority (highest wins)

  1. Session overrides — keys passed to `Opal.Config.new/1` or `Opal.start_session/1`
  2. Application config — `config :opal, ...` in your `config.exs`
  3. Environment variables — via `config/runtime.exs`
  4. Built-in defaults in this struct

  ## Fields

    * `:data_dir` — root directory for Opal data (sessions, logs, auth token).
      Defaults to `~/.opal` on Unix or `%APPDATA%/opal` on Windows.

    * `:shell` — shell used by `Opal.Tool.Shell` for command execution.
      Accepts `:bash`, `:zsh`, `:sh`, `:powershell`, or `:cmd`.
      Defaults to auto-detection based on the current platform.

    * `:default_model` — a `{provider_atom, model_id}` tuple or a
      `"provider:model_id"` string specifying the LLM to use.
      Default: `{"copilot", "claude-sonnet-4"}`.

    * `:default_tools` — list of modules implementing `Opal.Tool` available
      to the agent. Default: `[Read, Write, EditLines, Shell, SubAgent, Tasks, UseSkill, AskUser]`.

    * `:provider` — module implementing `Opal.Provider` for LLM communication.
      Default: `Opal.Provider.Copilot`. Use `Opal.Provider.LLM` for ReqLLM-backed
      providers (Anthropic, OpenAI, Google, etc.).

    * `:auto_save` — when `true`, automatically persists the session to disk
      after the agent goes idle. Requires a `Session` process to be attached.
      Default: `false`.

    * `:auto_title` — when `true`, automatically generates a short session title
      from the first user message using the LLM. Default: `true`.

    * `:copilot` — an `Opal.Config.Copilot` struct with Copilot-specific
      settings (`:client_id` and `:domain`). Can be passed as a keyword list.

    * `:features` — an `Opal.Config.Features` struct controlling optional
      subsystems. Each subsystem has an `:enabled` toggle and subsystem-specific
      options. See `Opal.Config.Features` for full documentation.

      Subsystems: `:sub_agents`, `:context`, `:skills`, `:mcp`.

  ## Application config example

      config :opal,
        data_dir: "~/.opal",
        shell: :zsh,
        default_model: {"copilot", "claude-sonnet-4-5"},
        default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.EditLines, Opal.Tool.Shell,
                        Opal.Tool.SubAgent, Opal.Tool.Tasks, Opal.Tool.UseSkill, Opal.Tool.AskUser],
        copilot: [
          client_id: "Iv1.b507a08c87ecfe98",
          domain: "github.com"
        ],
        features: %{
          sub_agents: %{enabled: true},
          context: %{filenames: ["AGENTS.md", "OPAL.md"]},
          skills: %{extra_dirs: []},
          mcp: %{enabled: true, servers: [], config_files: []}
        }
  """

  @type t :: %__MODULE__{
          data_dir: String.t(),
          shell: Opal.Tool.Shell.shell(),
          default_model: {atom(), String.t()},
          default_tools: [module()],
          provider: module(),
          copilot: Opal.Config.Copilot.t(),
          auto_save: boolean(),
          auto_title: boolean(),
          features: Opal.Config.Features.t()
        }

  @enforce_keys []
  defstruct data_dir: nil,
            shell: nil,
            default_model: {"copilot", "claude-sonnet-4"},
            default_tools: [
              Opal.Tool.Read,
              Opal.Tool.Write,
              Opal.Tool.EditLines,
              Opal.Tool.Shell,
              Opal.Tool.SubAgent,
              Opal.Tool.Tasks,
              Opal.Tool.UseSkill,
              Opal.Tool.AskUser
            ],
            provider: Opal.Provider.Copilot,
            auto_save: false,
            auto_title: true,
            features: %Opal.Config.Features{},
            copilot: %Opal.Config.Copilot{}

  @doc """
  Builds a config struct from Application env + optional session overrides.

  Session overrides are a map (or keyword list) whose keys match the struct
  fields. Unknown keys are ignored.

      iex> Opal.Config.new(%{shell: :zsh, data_dir: "/tmp/opal"})
      %Opal.Config{shell: :zsh, data_dir: "/tmp/opal", ...}
  """
  @spec new(map() | keyword()) :: t()
  def new(overrides \\ %{})

  def new(overrides) when is_list(overrides), do: new(Map.new(overrides))

  def new(overrides) when is_map(overrides) do
    # 1. Start from struct defaults
    base = %__MODULE__{}

    # 2. Layer on Application env
    app_env = Application.get_all_env(:opal)

    merged =
      Enum.reduce(app_env, base, fn
        {:copilot, kw}, acc when is_list(kw) ->
          %{acc | copilot: Opal.Config.Copilot.new(kw)}

        {:features, val}, acc when is_map(val) ->
          %{acc | features: Opal.Config.Features.new(val)}

        {key, val}, acc ->
          if Map.has_key?(acc, key), do: %{acc | key => val}, else: acc
      end)

    # 3. Layer on session overrides (highest priority)
    merged =
      Enum.reduce(overrides, merged, fn
        {:copilot, kw}, acc when is_list(kw) or is_map(kw) ->
          %{acc | copilot: Opal.Config.Copilot.new(kw)}

        {:features, val}, acc when is_map(val) ->
          %{acc | features: Opal.Config.Features.new(val)}

        {key, val}, acc ->
          if Map.has_key?(acc, key) and val != nil, do: %{acc | key => val}, else: acc
      end)

    # 4. Resolve runtime defaults
    merged = %{merged | shell: merged.shell || Opal.Tool.Shell.default_shell()}
    %{merged | data_dir: merged.data_dir || default_data_dir()}
  end

  @doc """
  Returns the default data directory for the current platform.

    - Linux:   `~/.opal`
    - macOS:   `~/.opal`
    - Windows: `%APPDATA%/opal` (e.g. `C:/Users/<user>/AppData/Roaming/opal`)

  Uses `System.user_home!/0` on Unix and Erlang's `:filename.basedir/2`
  on Windows to follow platform conventions.
  """
  @spec default_data_dir() :: String.t()
  def default_data_dir do
    case :os.type() do
      {:win32, _} ->
        :filename.basedir(:user_data, ~c"opal") |> to_string()

      {:unix, _} ->
        Path.join(System.user_home!(), ".opal")
    end
  end

  # -- Derived paths (all from data_dir) --

  @doc "Absolute path to the data directory."
  @spec data_dir(t()) :: String.t()
  def data_dir(%__MODULE__{data_dir: dir}), do: Path.expand(dir)

  @doc "Path to sessions storage directory."
  @spec sessions_dir(t()) :: String.t()
  def sessions_dir(%__MODULE__{} = c), do: Path.join(data_dir(c), "sessions")

  @doc "Path to the auth token file."
  @spec auth_file(t()) :: String.t()
  def auth_file(%__MODULE__{} = c), do: Path.join(data_dir(c), "auth.json")

  @doc "Path to the logs directory."
  @spec logs_dir(t()) :: String.t()
  def logs_dir(%__MODULE__{} = c), do: Path.join(data_dir(c), "logs")

  @doc "Ensures the data directory tree exists."
  @spec ensure_dirs!(t()) :: :ok
  def ensure_dirs!(%__MODULE__{} = c) do
    for dir <- [data_dir(c), sessions_dir(c), logs_dir(c)] do
      File.mkdir_p!(dir)
    end

    :ok
  end
end
