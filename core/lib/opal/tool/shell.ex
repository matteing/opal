defmodule Opal.Tool.Shell do
  @moduledoc """
  Runs shell commands cross-platform with timeout support.

  The shell type is configurable per session via `context.shell`:

    - `:sh`         — POSIX sh (default on Unix)
    - `:bash`       — GNU Bash
    - `:zsh`        — Zsh
    - `:cmd`        — cmd.exe (default on Windows)
    - `:powershell` — PowerShell (cross-platform)

  The tool name and description exposed to the LLM change to match
  the configured shell, so the model generates appropriate commands.
  """

  @behaviour Opal.Tool

  @default_timeout 30_000

  # -- Truncation limits ------------------------------------------------------
  # Shell output beyond these thresholds is tail-truncated: the *end* is kept
  # because errors, test results, and exit messages appear last. Full output
  # is saved to a temp file so the LLM can reference it if needed.
  @max_lines 2_000
  @max_bytes 50 * 1024

  @type shell :: :sh | :bash | :zsh | :cmd | :powershell

  @shell_meta %{
    sh: %{
      name: "shell",
      description: "Run a command in a POSIX shell (sh). Use standard Unix commands and syntax."
    },
    bash: %{
      name: "bash",
      description:
        "Run a command in Bash. Supports Bash-specific syntax like arrays, process substitution, and [[ ]]."
    },
    zsh: %{
      name: "zsh",
      description:
        "Run a command in Zsh. Supports Zsh globbing, extended syntax, and Bash-compatible commands."
    },
    cmd: %{
      name: "cmd",
      description:
        "Run a command in Windows cmd.exe. Use Windows commands (dir, type, findstr) and batch syntax."
    },
    powershell: %{
      name: "powershell",
      description:
        "Run a command in PowerShell. Use PowerShell cmdlets and syntax (Get-ChildItem, Select-String, foreach, |)."
    }
  }

  # Returns {executable, args_list} for the given shell and command.
  defp shell_cmd(:sh, command), do: {"sh", ["-c", command]}
  defp shell_cmd(:bash, command), do: {"bash", ["-c", command]}
  defp shell_cmd(:zsh, command), do: {"zsh", ["-c", command]}
  defp shell_cmd(:cmd, command), do: {"cmd", ["/C", command]}

  defp shell_cmd(:powershell, command),
    do: {"powershell", ["-NoProfile", "-NonInteractive", "-Command", command]}

  # -- Behaviour callbacks (zero-arity use platform default) --

  @impl true
  @spec name() :: String.t()
  def name, do: name(default_shell())

  @impl true
  @spec description() :: String.t()
  def description, do: description(default_shell())

  @impl true
  def meta(%{"command" => command}) do
    truncated =
      if String.length(command) > 60, do: String.slice(command, 0, 57) <> "...", else: command

    "Run `#{truncated}`"
  end

  def meta(_), do: "Run command"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The shell command to execute"},
        "timeout" => %{
          "type" => "integer",
          "description" => "Timeout in milliseconds (default: 30000)"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"command" => command} = args, %{working_dir: working_dir} = context) do
    timeout = Map.get(args, "timeout", @default_timeout)

    shell_type =
      case context do
        %{config: %{shell: shell}} when shell != nil -> shell
        _ -> default_shell()
      end

    {executable, shell_args} = shell_cmd(shell_type, command)

    opts = [stderr_to_stdout: true, cd: working_dir]
    emit = Map.get(context, :emit)
    run_command(executable, shell_args, opts, timeout, emit)
  end

  def execute(%{"command" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, _context), do: {:error, "Missing required parameter: command"}

  # -- Config-aware variants (called by the agent with session config) --

  @doc "Returns the tool name for the given shell type."
  @spec name(shell()) :: String.t()
  def name(shell_type), do: Map.fetch!(@shell_meta, shell_type).name

  @doc "Returns the tool description for the given shell type."
  @spec description(shell()) :: String.t()
  def description(shell_type), do: Map.fetch!(@shell_meta, shell_type).description

  # -- Internals --

  @doc "Returns the default shell for the current platform."
  @spec default_shell() :: shell()
  def default_shell do
    case :os.type() do
      {:unix, _} -> :sh
      {:win32, _} -> :cmd
    end
  end

  defp run_command(shell, args, opts, timeout, emit) do
    task =
      Task.async(fn ->
        if emit do
          run_streaming(shell, args, opts, emit)
        else
          System.cmd(shell, args, opts)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, truncate_shell_output(output)}

      {:ok, {output, exit_code}} ->
        {:error, "Command exited with status #{exit_code}\n#{truncate_shell_output(output)}"}

      nil ->
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  # Runs a command via Port, emitting output chunks as they arrive.
  defp run_streaming(shell, args, opts, emit) do
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, args}
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        dir -> [{:cd, String.to_charlist(dir)} | port_opts]
      end

    port = Port.open({:spawn_executable, System.find_executable(shell)}, port_opts)
    collect_port_output(port, emit, [])
  end

  defp collect_port_output(port, emit, acc) do
    receive do
      {^port, {:data, data}} ->
        emit.(data)
        collect_port_output(port, emit, [data | acc])

      {^port, {:exit_status, status}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {output, status}
    end
  end

  # -- Output truncation ------------------------------------------------------
  #
  # Tail-truncation: keeps the *end* of shell output (where errors and results
  # live). Saves full output to a temp file for reference.

  defp truncate_shell_output(output) do
    lines = String.split(String.replace(output, "\r\n", "\n"), "\n")
    total = length(lines)

    cond do
      # Too many lines — keep the last @max_lines
      total > @max_lines ->
        tmp_path = save_full_output(output)
        kept = Enum.slice(lines, total - @max_lines, @max_lines)
        start = total - @max_lines + 1
        text = Enum.join(kept, "\n")

        "[Showing lines #{start}-#{total} of #{total}. " <>
          "Full output: #{tmp_path}]\n\n#{text}"

      # Under line limit but over byte limit — keep the tail bytes
      byte_size(output) > @max_bytes ->
        tmp_path = save_full_output(output)
        drop = byte_size(output) - @max_bytes
        truncated = binary_part(output, drop, @max_bytes)

        # Find first newline to avoid splitting mid-line
        tail =
          case :binary.match(truncated, "\n") do
            {pos, _} ->
              binary_part(truncated, pos + 1, byte_size(truncated) - pos - 1)

            :nomatch ->
              truncated
          end

        "[Output truncated. Full output: #{tmp_path}]\n\n#{tail}"

      # Within limits — pass through unchanged
      true ->
        output
    end
  end

  # Writes full output to a temp file so the LLM can reference it later.
  defp save_full_output(output) do
    id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "opal-shell-#{id}.log")
    File.write!(path, output)
    path
  end
end
