defmodule Opal.Tool.Shell do
  @moduledoc """
  Runs shell commands cross-platform with timeout support.

  The tool name and description adapt to the configured shell type
  (`:sh`, `:bash`, `:zsh`, `:cmd`, `:powershell`) so the LLM generates
  appropriate commands.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Args, as: ToolArgs

  @default_timeout 30_000
  @max_lines 2_000
  @max_bytes 50 * 1024

  @type shell :: :sh | :bash | :zsh | :cmd | :powershell

  @args_schema [
    command: [type: :string, required: true],
    timeout: [type: :integer, default: @default_timeout]
  ]

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

  @doc "Returns all possible shell tool names across platforms."
  @spec shell_names() :: MapSet.t(String.t())
  def shell_names, do: @shell_meta |> Map.values() |> Enum.map(& &1.name) |> MapSet.new()

  @impl true
  @spec name() :: String.t()
  def name, do: name(default_shell())

  @impl true
  @spec description() :: String.t()
  def description, do: shell_description(default_shell())

  @doc """
  Context-aware description that includes the working directory.

  When the tool context includes `:working_dir`, appends it to the
  description so the LLM knows commands already execute there and
  avoids prepending unnecessary `cd` commands.
  """
  @impl true
  @spec description(Opal.Tool.tool_context()) :: String.t()
  def description(%{working_dir: wd} = context) when is_binary(wd) and wd != "" do
    shell_type = Map.get(context, :shell, default_shell())

    base = shell_description(shell_type)

    base <>
      " Commands run in: #{wd}." <>
      " Do NOT prepend cd to this directory."
  end

  def description(%{} = context) do
    shell_type = Map.get(context, :shell, default_shell())
    shell_description(shell_type)
  end

  @impl true
  def meta(%{"command" => command}) do
    "Run `#{Opal.Util.Text.truncate(command, 57, "...")}`"
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
  def execute(args, %{working_dir: working_dir} = context) when is_map(args) do
    with {:ok, opts} <-
           ToolArgs.validate(args, @args_schema,
             required_message: "Missing required parameter: command"
           ) do
      shell_type =
        case context do
          %{config: %{shell: shell}} when shell != nil -> shell
          _ -> default_shell()
        end

      {executable, shell_args} = shell_cmd(shell_type, opts[:command])

      run_command(
        executable,
        shell_args,
        [stderr_to_stdout: true, cd: working_dir],
        opts[:timeout],
        Map.get(context, :emit)
      )
    end
  end

  def execute(%{"command" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, _context), do: {:error, "Missing required parameter: command"}

  # -- Config-aware variants (called by the agent with session config) --

  @doc "Returns the tool name for the given shell type."
  @spec name(shell()) :: String.t()
  def name(shell_type), do: Map.fetch!(@shell_meta, shell_type).name

  @doc "Returns the base description for the given shell type."
  @spec shell_description(shell()) :: String.t()
  def shell_description(shell_type), do: Map.fetch!(@shell_meta, shell_type).description

  # -- Internals --

  @doc "Returns the default shell for the current platform."
  @spec default_shell() :: shell()
  def default_shell do
    if Opal.Platform.windows?(), do: :cmd, else: :sh
  end

  defp run_command(shell, args, opts, timeout, emit) do
    caller = self()
    os_pid_ref = make_ref()

    task =
      Task.async(fn ->
        if emit do
          run_streaming(shell, args, opts, emit, caller, os_pid_ref)
        else
          System.cmd(shell, args, opts)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        flush_os_pid(os_pid_ref)
        {:ok, truncate_shell_output(output)}

      {:ok, {output, exit_code}} ->
        flush_os_pid(os_pid_ref)
        {:error, "Command exited with status #{exit_code}\n#{truncate_shell_output(output)}"}

      nil ->
        kill_orphaned_process(os_pid_ref)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  # Runs a command via Port, emitting output chunks as they arrive.
  defp run_streaming(shell, args, opts, emit, caller, os_pid_ref) do
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

    case System.find_executable(shell) do
      nil ->
        {"Shell '#{shell}' not found in PATH", 127}

      executable ->
        port = Port.open({:spawn_executable, executable}, port_opts)

        # Report the OS PID so the caller can kill it on timeout
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> send(caller, {os_pid_ref, pid})
          _ -> :ok
        end

        collect_port_output(port, emit, [])
    end
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
    dir = Path.join(System.tmp_dir!(), "opal-shell")
    File.mkdir_p!(dir)

    id = Opal.Id.hex(6)
    path = Path.join(dir, "#{id}.log")
    File.write!(path, output)
    path
  end

  # Drains the OS PID message after normal command completion.
  defp flush_os_pid(ref) do
    receive do
      {^ref, _os_pid} -> :ok
    after
      0 -> :ok
    end
  end

  # Kills an orphaned OS process after timeout.
  defp kill_orphaned_process(ref) do
    receive do
      {^ref, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        if Opal.Platform.windows?() do
          System.cmd("taskkill", ["/PID", "#{os_pid}", "/T", "/F"], stderr_to_stdout: true)
        else
          # Kill process and its children
          System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
        end

        :ok
    after
      0 -> :ok
    end
  end
end
