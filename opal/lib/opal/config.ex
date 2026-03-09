defmodule Opal.Config.Features do
  @moduledoc """
  Unified feature toggles for optional Opal subsystems.

  Groups all optional subsystem configuration under a single struct
  with consistent `enabled` toggles and subsystem-specific options.

  ## Subsystems

    * `:sub_agents` — child agent spawning via `Opal.Agent.Spawner`
    * `:context` — walk-up context file discovery (AGENTS.md, OPAL.md, etc.)
    * `:skills` — skill directory discovery and progressive disclosure
    * `:debug` — internal debug/introspection tooling (disabled by default)

  ## Usage

      # Disable sub-agents, customize context filenames
      features = Opal.Config.Features.new(%{
        sub_agents: %{enabled: false},
        context: %{filenames: ["AGENTS.md", "CUSTOM.md"]}
      })

      # Or via application config
      config :opal,
        features: %{
          sub_agents: %{enabled: true},
          context: %{filenames: ["AGENTS.md"]},
          skills: %{extra_dirs: ["/opt/skills"]},
          debug: %{enabled: false}
        }
  """

  @type t :: %__MODULE__{
          sub_agents: sub_agents_config(),
          context: context_config(),
          skills: skills_config(),
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
  Internal debug/introspection feature configuration.

    * `:enabled` — whether internal debug tooling is available. Default: `false`.
      When disabled, the debug tool is filtered out and no in-memory event log is kept.
  """
  @type debug_config :: %{enabled: boolean()}

  defstruct sub_agents: %{enabled: true},
            context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
            skills: %{enabled: true, extra_dirs: []},
            debug: %{enabled: false}

  @doc """
  Builds a Features struct from a map or keyword list.

  Each subsystem key accepts either a map of options or a boolean shorthand.
  Boolean shorthand sets only the `:enabled` flag, keeping other defaults.

  ## Examples

      # Full config
      Opal.Config.Features.new(%{sub_agents: %{enabled: false}})

      # Boolean shorthand
      Opal.Config.Features.new(%{sub_agents: false})
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

defmodule Opal.Config do
  @moduledoc """
  Typed configuration struct for Opal sessions.

  Built once via `Opal.Config.new/1`, then threaded through the system.
  Every config key has a known type and a sensible default.

  ## Priority (highest wins)

  1. Session overrides — keys passed to `Opal.Config.new/1` or `Opal.start_session/1`
  2. Environment variables — `OPAL_DATA_DIR`, `OPAL_SHELL`, `OPAL_COPILOT_DOMAIN`
  3. Application config — `config :opal, ...` in your `config.exs`
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
      to the agent. Default: `[Read, Write, Edit, Shell, SubAgent, Tasks, UseSkill, AskUser, Debug]`.

    * `:provider` — module implementing `Opal.Provider` for LLM communication.
      Default: `Opal.Provider.Copilot`.

    * `:auto_save` — when `true`, automatically persists the session to disk
      after the agent goes idle. Requires a `Session` process to be attached.
      Default: `true`.

    * `:auto_title` — when `true`, automatically generates a short session title
      from the first user message using the LLM. Default: `true`.

    * `:copilot_domain` — GitHub domain for Copilot authentication endpoints.
      Default: `"github.com"`. Change for GitHub Enterprise Server instances.
      The OAuth client ID lives in `Opal.Auth.Copilot`.

    * `:features` — an `Opal.Config.Features` struct controlling optional
      subsystems. Each subsystem has an `:enabled` toggle and subsystem-specific
      options. See `Opal.Config.Features` for full documentation.

      Subsystems: `:sub_agents`, `:context`, `:skills`, `:debug`.

  ## Application config example

      config :opal,
        data_dir: "~/.opal",
        shell: :zsh,
        default_model: {"copilot", "claude-sonnet-4.5"},
        default_tools: [Opal.Tool.ReadFile, Opal.Tool.WriteFile, Opal.Tool.EditFile, Opal.Tool.Grep,
                        Opal.Tool.Shell, Opal.Tool.SubAgent, Opal.Tool.Tasks,
                        Opal.Tool.UseSkill, Opal.Tool.AskUser, Opal.Tool.DebugState],
        copilot_domain: "github.com",
        features: %{
          sub_agents: %{enabled: true},
          context: %{filenames: ["AGENTS.md", "OPAL.md"]},
          skills: %{extra_dirs: []},
          debug: %{enabled: false}
        }
  """

  @type t :: %__MODULE__{
          data_dir: String.t(),
          shell: Opal.Tool.Shell.shell(),
          default_model: {atom(), String.t()},
          default_tools: [module()],
          provider: module(),
          copilot_domain: String.t(),
          auto_save: boolean(),
          auto_title: boolean(),
          features: Opal.Config.Features.t()
        }

  @enforce_keys []
  defstruct data_dir: nil,
            shell: nil,
            default_model: {"copilot", "claude-sonnet-4"},
            default_tools: [
              Opal.Tool.ReadFile,
              Opal.Tool.WriteFile,
              Opal.Tool.EditFile,
              Opal.Tool.Grep,
              Opal.Tool.Shell,
              Opal.Tool.SubAgent,
              Opal.Tool.Tasks,
              Opal.Tool.UseSkill,
              Opal.Tool.AskUser,
              Opal.Tool.DebugState
            ],
            provider: Opal.Provider.Copilot,
            auto_save: true,
            auto_title: true,
            features: %Opal.Config.Features{},
            copilot_domain: "github.com"

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

    merged = merge_attrs(base, app_env)

    # 3. Layer on environment overrides
    merged = merge_attrs(merged, env_overrides())

    # 4. Layer on session overrides (highest priority)
    merged = merge_attrs(merged, overrides)

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
    if data_dir = env_data_dir() do
      data_dir
    else
      if Opal.Platform.windows?() do
        :filename.basedir(:user_data, String.to_charlist("opal")) |> to_string()
      else
        Path.join(System.user_home!(), ".opal")
      end
    end
  end

  defp merge_attrs(acc, attrs) when is_list(attrs), do: merge_attrs(acc, Map.new(attrs))

  defp merge_attrs(acc, attrs) when is_map(attrs) do
    Enum.reduce(attrs, acc, fn
      {:features, val}, current when is_map(val) ->
        %{current | features: Opal.Config.Features.new(val)}

      {key, val}, current ->
        if Map.has_key?(current, key) and val != nil, do: %{current | key => val}, else: current
    end)
  end

  defp env_overrides do
    %{}
    |> maybe_put(:data_dir, env_data_dir())
    |> maybe_put(:shell, env_shell())
    |> maybe_put(:copilot_domain, env_copilot_domain())
  end

  defp env_data_dir do
    case System.get_env("OPAL_DATA_DIR") do
      nil -> nil
      "" -> nil
      dir -> dir
    end
  end

  defp env_shell do
    case System.get_env("OPAL_SHELL") do
      nil -> nil
      "" -> nil
      shell -> String.to_atom(shell)
    end
  end

  defp env_copilot_domain do
    case System.get_env("OPAL_COPILOT_DOMAIN") do
      nil -> nil
      "" -> nil
      domain -> domain
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
