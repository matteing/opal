defmodule Opal.Tool.Shell do
  @moduledoc """
  Runs shell commands cross-platform with checkpoint-based execution.

  Long-running commands don't hard-timeout — after `timeout` ms the tool
  returns partial output and a process ID. The agent can then `wait`,
  send `input`, or `kill` the process.

  The tool name and description adapt to the configured shell type
  (`:sh`, `:bash`, `:zsh`, `:cmd`, `:powershell`) so the LLM generates
  appropriate commands.
  """

  @behaviour Opal.Tool

  @default_wait 30_000
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

  defp shell_cmd(:sh, command), do: {"sh", ["-c", command]}
  defp shell_cmd(:bash, command), do: {"bash", ["-c", command]}
  defp shell_cmd(:zsh, command), do: {"zsh", ["-c", command]}
  defp shell_cmd(:cmd, command), do: {"cmd", ["/C", command]}

  defp shell_cmd(:powershell, command),
    do: {"powershell", ["-NoProfile", "-NonInteractive", "-Command", command]}

  # -- Behaviour callbacks --

  @doc "Returns all possible shell tool names across platforms."
  @spec shell_names() :: MapSet.t(String.t())
  def shell_names, do: @shell_meta |> Map.values() |> Enum.map(& &1.name) |> MapSet.new()

  @impl true
  @spec name() :: String.t()
  def name, do: name(default_shell())

  @impl true
  @spec description() :: String.t()
  def description, do: shell_description(default_shell())

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

  def meta(%{"action" => "wait", "id" => id}), do: "Waiting on #{id}"
  def meta(%{"action" => "input", "id" => id}), do: "Input to #{id}"
  def meta(%{"action" => "kill", "id" => id}), do: "Kill #{id}"
  def meta(_), do: "Run command"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The shell command to execute (required for run action)."
        },
        "action" => %{
          "type" => "string",
          "enum" => ["run", "wait", "input", "kill"],
          "description" =>
            "Action to perform. \"run\" (default) starts a command; " <>
              "\"wait\" checks on a running command (ALWAYS wait at least once before " <>
              "considering kill — builds, tests, and installs often produce no output for " <>
              "long periods); " <>
              "\"input\" sends text to stdin; " <>
              "\"kill\" terminates a running command (last resort — only use if the " <>
              "command is genuinely stuck, NOT just slow)."
        },
        "id" => %{
          "type" => "string",
          "description" => "Process ID from a previous run (required for wait/input/kill)."
        },
        "input" => %{
          "type" => "string",
          "description" =>
            "Text to send to the command's stdin (required for input action). Include \\n for Enter."
        },
        "timeout" => %{
          "type" => "integer",
          "description" =>
            "How long to wait for output in ms (default: 30000). " <>
              "If the command hasn't finished, partial output is returned with the process ID."
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "wait", "id" => id} = args, _context) do
    wait_ms = args["timeout"] || @default_wait

    case Opal.Shell.Process.wait(id, wait_ms) do
      {:completed, output, status} -> format_completed(output, status)
      {:running, output} -> {:ok, format_still_running(id, output)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "input", "id" => id, "input" => text}, _context) do
    case Opal.Shell.Process.input(id, text, @default_wait) do
      {:completed, output, status} -> format_completed(output, status)
      {:running, output} -> {:ok, format_still_running(id, output)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "input"}, _context),
    do: {:error, "Missing required parameters: id, input"}

  def execute(%{"action" => "kill", "id" => id}, _context) do
    case Opal.Shell.Process.kill(id) do
      {:ok, output} -> {:ok, "[Process #{id} killed]\n#{truncate_output(output)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "kill"}, _context),
    do: {:error, "Missing required parameter: id"}

  def execute(%{"command" => command} = args, %{working_dir: working_dir} = context) do
    shell_type =
      case context do
        %{config: %{shell: shell}} when shell != nil -> shell
        _ -> default_shell()
      end

    {executable, shell_args} = shell_cmd(shell_type, command)

    case System.find_executable(executable) do
      nil ->
        {:error, "Shell '#{executable}' not found in PATH"}

      exec_path ->
        wait_ms = args["timeout"] || @default_wait

        port_opts =
          case working_dir do
            nil -> []
            dir -> [{:cd, String.to_charlist(dir)}]
          end

        emit = Map.get(context, :emit)

        case Opal.Shell.Process.run(exec_path, shell_args, port_opts, wait_ms, emit) do
          {:completed, output, status} -> format_completed(output, status)
          {:running, id, output} -> {:ok, format_still_running(id, output)}
        end
    end
  end

  def execute(%{"command" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, %{working_dir: _}), do: {:error, "Missing required parameter: command"}
  def execute(_args, _context), do: {:error, "Missing required parameter: command"}

  # -- Config-aware variants --

  @doc "Returns the tool name for the given shell type."
  @spec name(shell()) :: String.t()
  def name(shell_type), do: Map.fetch!(@shell_meta, shell_type).name

  @doc "Returns the base description for the given shell type."
  @spec shell_description(shell()) :: String.t()
  def shell_description(shell_type), do: Map.fetch!(@shell_meta, shell_type).description

  @doc "Returns the default shell for the current platform."
  @spec default_shell() :: shell()
  def default_shell do
    if Opal.Platform.windows?(), do: :cmd, else: :sh
  end

  # -- Formatting --

  defp format_completed(output, 0), do: {:ok, truncate_output(output)}

  defp format_completed(output, status),
    do: {:error, "Command exited with status #{status}\n#{truncate_output(output)}"}

  defp format_still_running(id, output) do
    truncated = truncate_output(output)

    "[Command still running — id: #{id}]\n" <>
      truncated <>
      "\n\n" <>
      "Use action: \"wait\" with id: \"#{id}\" to check again (recommended — " <>
      "builds and tests often take minutes with no output). " <>
      "Use \"input\" to send text to stdin, or \"kill\" to terminate (only if stuck)."
  end

  # -- Output truncation --

  defp truncate_output(""), do: "(no output)"

  defp truncate_output(output) do
    lines = String.split(String.replace(output, "\r\n", "\n"), "\n")
    total = length(lines)

    cond do
      total > @max_lines ->
        tmp_path = save_full_output(output)
        kept = Enum.slice(lines, total - @max_lines, @max_lines)
        start = total - @max_lines + 1
        text = Enum.join(kept, "\n")

        "[Showing lines #{start}-#{total} of #{total}. " <>
          "Full output: #{tmp_path}]\n\n#{text}"

      byte_size(output) > @max_bytes ->
        tmp_path = save_full_output(output)
        drop = byte_size(output) - @max_bytes
        truncated = binary_part(output, drop, @max_bytes)

        tail =
          case :binary.match(truncated, "\n") do
            {pos, _} ->
              binary_part(truncated, pos + 1, byte_size(truncated) - pos - 1)

            :nomatch ->
              truncated
          end

        "[Output truncated. Full output: #{tmp_path}]\n\n#{tail}"

      true ->
        output
    end
  end

  defp save_full_output(output) do
    dir = Path.join(System.tmp_dir!(), "opal-shell")
    File.mkdir_p!(dir)

    id = Opal.Id.hex(6)
    path = Path.join(dir, "#{id}.log")
    File.write!(path, output)
    path
  end
end
