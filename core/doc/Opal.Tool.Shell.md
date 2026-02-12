# `Opal.Tool.Shell`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/tool/shell.ex#L1)

Runs shell commands cross-platform with timeout support.

The shell type is configurable per session via `context.shell`:

  - `:sh`         — POSIX sh (default on Unix)
  - `:bash`       — GNU Bash
  - `:zsh`        — Zsh
  - `:cmd`        — cmd.exe (default on Windows)
  - `:powershell` — PowerShell (cross-platform)

The tool name and description exposed to the LLM change to match
the configured shell, so the model generates appropriate commands.

# `shell`

```elixir
@type shell() :: :sh | :bash | :zsh | :cmd | :powershell
```

# `default_shell`

```elixir
@spec default_shell() :: shell()
```

Returns the default shell for the current platform.

# `description`

```elixir
@spec description(shell()) :: String.t()
```

Returns the tool description for the given shell type.

# `name`

```elixir
@spec name(shell()) :: String.t()
```

Returns the tool name for the given shell type.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
