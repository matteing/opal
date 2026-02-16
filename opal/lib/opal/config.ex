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
      to the agent. Default: `[Read, Write, Edit, Shell, SubAgent, Tasks, UseSkill, AskUser, Debug]`.

    * `:provider` — module implementing `Opal.Provider` for LLM communication.
      Default: `Opal.Provider.Copilot`. Use `Opal.Provider.LLM` for ReqLLM-backed
      providers (Anthropic, OpenAI, Google, etc.).

    * `:auto_save` — when `true`, automatically persists the session to disk
      after the agent goes idle. Requires a `Session` process to be attached.
      Default: `true`.

    * `:auto_title` — when `true`, automatically generates a short session title
      from the first user message using the LLM. Default: `true`.

    * `:copilot` — an `Opal.Config.Copilot` struct with Copilot-specific
      settings (`:client_id` and `:domain`). Can be passed as a keyword list.

    * `:features` — an `Opal.Config.Features` struct controlling optional
      subsystems. Each subsystem has an `:enabled` toggle and subsystem-specific
      options. See `Opal.Config.Features` for full documentation.

      Subsystems: `:sub_agents`, `:context`, `:skills`, `:mcp`, `:debug`.

  ## Application config example

      config :opal,
        data_dir: "~/.opal",
        shell: :zsh,
        default_model: {"copilot", "claude-sonnet-4-5"},
        default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell,
                        Opal.Tool.SubAgent, Opal.Tool.Tasks, Opal.Tool.UseSkill, Opal.Tool.AskUser,
                        Opal.Tool.Debug],
        copilot: [
          client_id: "Iv1.b507a08c87ecfe98",
          domain: "github.com"
        ],
        features: %{
          sub_agents: %{enabled: true},
          context: %{filenames: ["AGENTS.md", "OPAL.md"]},
          skills: %{extra_dirs: []},
          mcp: %{enabled: true, servers: [], config_files: []},
          debug: %{enabled: false}
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
              Opal.Tool.Edit,
              Opal.Tool.Shell,
              Opal.Tool.SubAgent,
              Opal.Tool.Tasks,
              Opal.Tool.UseSkill,
              Opal.Tool.AskUser,
              Opal.Tool.Debug
            ],
            provider: Opal.Provider.Copilot,
            auto_save: true,
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
