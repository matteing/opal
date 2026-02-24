defmodule Opal.Shell.Process do
  @moduledoc """
  Manages long-running shell processes for the checkpoint-based shell tool.

  Each running command gets an ID. The tool can start, wait, send input,
  or kill a process by ID. Output is buffered and returned at checkpoints.
  """

  use GenServer
  require Logger

  @max_buffer_bytes 256 * 1024

  defstruct [
    :id,
    :port,
    :os_pid,
    :command,
    :started_at,
    buffer: [],
    buffer_bytes: 0,
    exit_status: nil,
    waiters: []
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Starts a command and blocks up to `wait_ms`. Returns output or a handle."
  @spec run(String.t(), [String.t()], keyword(), pos_integer(), function() | nil) ::
          {:completed, String.t(), integer()} | {:running, String.t(), String.t()}
  def run(executable, args, port_opts, wait_ms, emit) do
    GenServer.call(__MODULE__, {:run, executable, args, port_opts, wait_ms, emit}, :infinity)
  end

  @doc "Waits on a running command for up to `wait_ms`."
  @spec wait(String.t(), pos_integer()) ::
          {:completed, String.t(), integer()} | {:running, String.t()} | {:error, String.t()}
  def wait(id, wait_ms) do
    GenServer.call(__MODULE__, {:wait, id, wait_ms}, :infinity)
  end

  @doc "Sends input to a running command's stdin, then waits."
  @spec input(String.t(), String.t(), pos_integer()) ::
          {:completed, String.t(), integer()} | {:running, String.t()} | {:error, String.t()}
  def input(id, text, wait_ms) do
    GenServer.call(__MODULE__, {:input, id, text, wait_ms}, :infinity)
  end

  @doc "Kills a running command."
  @spec kill(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def kill(id) do
    GenServer.call(__MODULE__, {:kill, id})
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{processes: %{}}}
  end

  @impl true
  def handle_call({:run, executable, args, port_opts, wait_ms, emit}, from, state) do
    id = Opal.Id.generate()

    full_opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args}
      ]
      |> then(&if Opal.Platform.windows?(), do: [{:hide, true} | &1], else: &1)
      |> Kernel.++(port_opts)

    port = Port.open({:spawn_executable, executable}, full_opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    proc = %__MODULE__{
      id: id,
      port: port,
      os_pid: os_pid,
      command: Enum.join([Path.basename(executable) | args], " "),
      started_at: DateTime.utc_now(),
      waiters: [{from, wait_ms, emit, System.monotonic_time(:millisecond), :run}]
    }

    state = put_in(state, [:processes, id], proc)
    schedule_check(id, wait_ms)
    {:noreply, state}
  end

  def handle_call({:wait, id, wait_ms}, from, state) do
    case get_in(state, [:processes, id]) do
      nil ->
        {:reply, {:error, "No running command with id: #{id}"}, state}

      %{exit_status: status} = proc when not is_nil(status) ->
        output = drain_buffer(proc)
        state = remove_process(state, id)
        {:reply, {:completed, output, status}, state}

      proc ->
        proc = %{
          proc
          | waiters:
              proc.waiters ++
                [{from, wait_ms, nil, System.monotonic_time(:millisecond), :wait}]
        }

        state = put_in(state, [:processes, id], proc)
        schedule_check(id, wait_ms)
        {:noreply, state}
    end
  end

  def handle_call({:input, id, text, wait_ms}, from, state) do
    case get_in(state, [:processes, id]) do
      nil ->
        {:reply, {:error, "No running command with id: #{id}"}, state}

      %{exit_status: status} = proc when not is_nil(status) ->
        output = drain_buffer(proc)
        state = remove_process(state, id)
        {:reply, {:completed, output, status}, state}

      %{port: port} = proc ->
        Port.command(port, text)

        proc = %{
          proc
          | waiters:
              proc.waiters ++
                [{from, wait_ms, nil, System.monotonic_time(:millisecond), :wait}]
        }

        state = put_in(state, [:processes, id], proc)
        schedule_check(id, wait_ms)
        {:noreply, state}
    end
  end

  def handle_call({:kill, id}, _from, state) do
    case get_in(state, [:processes, id]) do
      nil ->
        {:reply, {:error, "No running command with id: #{id}"}, state}

      proc ->
        kill_process(proc)
        output = drain_buffer(proc)
        state = remove_process(state, id)
        {:reply, {:ok, output}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {id, proc} ->
        emit = Enum.find_value(proc.waiters, fn {_, _, e, _, _} -> e end)
        if emit, do: emit.(data)

        new_bytes = proc.buffer_bytes + byte_size(data)

        proc =
          if new_bytes > @max_buffer_bytes do
            %{proc | buffer: [data], buffer_bytes: byte_size(data)}
          else
            %{proc | buffer: [data | proc.buffer], buffer_bytes: new_bytes}
          end

        {:noreply, put_in(state, [:processes, id], proc)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {id, proc} ->
        proc = %{proc | exit_status: status}
        output = drain_buffer(proc)

        for {from, _wait, _emit, _start, _origin} <- proc.waiters do
          GenServer.reply(from, {:completed, output, status})
        end

        state = remove_process(state, id)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:check_timeout, id}, state) do
    case get_in(state, [:processes, id]) do
      nil ->
        {:noreply, state}

      %{exit_status: status} = proc when not is_nil(status) ->
        output = drain_buffer(proc)

        for {from, _wait, _emit, _start, _origin} <- proc.waiters do
          GenServer.reply(from, {:completed, output, status})
        end

        state = remove_process(state, id)
        {:noreply, state}

      proc ->
        now = System.monotonic_time(:millisecond)

        {expired, remaining} =
          Enum.split_with(proc.waiters, fn {_from, wait, _emit, start, _origin} ->
            now - start >= wait
          end)

        if expired == [] do
          {:noreply, state}
        else
          output = drain_buffer(proc)

          idle_hint =
            if proc.buffer == [] do
              "\n\n(No output yet — this is normal for builds, tests, and installs. Wait again.)"
            else
              ""
            end

          reply_output = output <> idle_hint

          for {from, _wait, _emit, _start, origin} <- expired do
            case origin do
              :run -> GenServer.reply(from, {:running, id, reply_output})
              :wait -> GenServer.reply(from, {:running, reply_output})
            end
          end

          proc = %{proc | waiters: remaining, buffer: [], buffer_bytes: 0}
          state = put_in(state, [:processes, id], proc)
          {:noreply, state}
        end
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp schedule_check(id, wait_ms) do
    Process.send_after(self(), {:check_timeout, id}, wait_ms)
  end

  defp find_by_port(state, port) do
    Enum.find_value(state.processes, fn {id, proc} ->
      if proc.port == port, do: {id, proc}
    end)
  end

  defp drain_buffer(proc) do
    proc.buffer |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp remove_process(state, id) do
    %{state | processes: Map.delete(state.processes, id)}
  end

  defp kill_process(%{os_pid: nil}), do: :ok

  defp kill_process(%{os_pid: os_pid}) when is_integer(os_pid) and os_pid > 0 do
    if Opal.Platform.windows?() do
      System.cmd("taskkill", ["/PID", "#{os_pid}", "/T", "/F"], stderr_to_stdout: true)
    else
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp kill_process(_), do: :ok
end
