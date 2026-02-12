# `Opal.Config`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/config.ex#L170)

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
    Accepts `:bash`, `:zsh`, `:sh`, `:fish`, `:powershell`, or `:cmd`.
    Defaults to auto-detection based on the current platform.

  * `:default_model` — a `{provider_atom, model_id}` tuple specifying the
    LLM to use. Default: `{"copilot", "claude-sonnet-4-5"}`.

  * `:default_tools` — list of modules implementing `Opal.Tool` available
    to the agent. Default: `[Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell]`.

  * `:provider` — module implementing `Opal.Provider` for LLM communication.
    Default: `Opal.Provider.Copilot`.

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
      default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell],
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

# `t`

```elixir
@type t() :: %Opal.Config{
  auto_save: boolean(),
  auto_title: boolean(),
  copilot: Opal.Config.Copilot.t(),
  data_dir: String.t(),
  default_model: {atom(), String.t()},
  default_tools: [module()],
  features: Opal.Config.Features.t(),
  provider: module(),
  shell: Opal.Tool.Shell.shell()
}
```

# `auth_file`

```elixir
@spec auth_file(t()) :: String.t()
```

Path to the auth token file.

# `data_dir`

```elixir
@spec data_dir(t()) :: String.t()
```

Absolute path to the data directory.

# `default_data_dir`

```elixir
@spec default_data_dir() :: String.t()
```

Returns the default data directory for the current platform.

  - Linux:   `~/.opal`
  - macOS:   `~/.opal`
  - Windows: `%APPDATA%/opal` (e.g. `C:/Users/<user>/AppData/Roaming/opal`)

Uses `System.user_home!/0` on Unix and Erlang's `:filename.basedir/2`
on Windows to follow platform conventions.

# `ensure_dirs!`

```elixir
@spec ensure_dirs!(t()) :: :ok
```

Ensures the data directory tree exists.

# `logs_dir`

```elixir
@spec logs_dir(t()) :: String.t()
```

Path to the logs directory.

# `new`

```elixir
@spec new(map() | keyword()) :: t()
```

Builds a config struct from Application env + optional session overrides.

Session overrides are a map (or keyword list) whose keys match the struct
fields. Unknown keys are ignored.

    iex> Opal.Config.new(%{shell: :zsh, data_dir: "/tmp/opal"})
    %Opal.Config{shell: :zsh, data_dir: "/tmp/opal", ...}

# `sessions_dir`

```elixir
@spec sessions_dir(t()) :: String.t()
```

Path to sessions storage directory.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
