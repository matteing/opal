defmodule Opal.RPC.Stdio do
  @moduledoc """
  JSON-RPC 2.0 transport over stdin/stdout.

  Reads newline-delimited JSON from stdin, dispatches via `Opal.RPC.Handler`,
  writes responses to stdout. Subscribes to `Opal.Events` and emits
  notifications for streaming events.

  The set of supported methods, event types, and server→client requests
  are declared in `Opal.RPC.Protocol` — the single source of truth for
  the Opal RPC specification.

  ## Server → Client Requests

  The server can send requests to the client (e.g., for user confirmations)
  via `request_client/3`. The response is delivered asynchronously when the
  client sends back a JSON-RPC response with the matching `id`.

  ## Wire Format

  Each message is a single JSON object followed by `\\n` on stdin/stdout.
  This matches the MCP stdio transport convention. All logging goes to stderr.
  """

  use GenServer
  require Logger

  defstruct [
    :reader,
    :stdout_port,
    pending_requests: %{},
    next_server_id: 1,
    subscriptions: MapSet.new()
  ]

  @doc "Starts the stdio transport GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a request to the connected client and waits for a response.

  Used for server→client requests like user confirmations and input prompts.
  The request ID is auto-generated with the `s2c-` prefix.

  ## Examples

      {:ok, result} = Opal.RPC.Stdio.request_client("client/confirm", %{
        session_id: "abc123",
        title: "Execute shell command?",
        message: "rm -rf node_modules/",
        actions: ["allow", "deny", "allow_session"]
      })
  """
  @spec request_client(String.t(), map(), timeout()) :: {:ok, term()} | {:error, :timeout}
  def request_client(method, params, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:request_client, method, params}, timeout)
  end

  @doc """
  Sends a notification to the connected client.

  Fire-and-forget — no response expected.
  """
  @spec notify(String.t(), map()) :: :ok
  def notify(method, params) do
    GenServer.cast(__MODULE__, {:notify, method, params})
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    # Read/write raw file descriptors directly, bypassing the Erlang I/O
    # system (user_drv / prim_tty). Going through IO.read(:stdio, :line)
    # routes through user_drv which tries to own the TTY and deadlocks
    # when stdio is piped from a parent process.
    #
    # We use :stream mode (not {:line, N}) because {:line, N} has
    # platform-dependent newline semantics. Instead we accumulate bytes
    # in the reader and split on \n ourselves.
    stdout_fd = :erlang.open_port({:fd, 1, 1}, [:binary, :out])
    parent = self()

    {:ok, reader} =
      Task.start_link(fn -> stdin_read_loop(parent) end)

    {:ok, %__MODULE__{reader: reader, stdout_port: stdout_fd}}
  end

  defp stdin_read_loop(parent) do
    # Open fd 0 (stdin) in binary stream mode. We accumulate chunks
    # and split on newlines to extract complete JSON-RPC messages.
    # The :eof option causes a {port, :eof} message instead of port
    # exit when stdin closes — critical for clean shutdown.
    port = :erlang.open_port({:fd, 0, 0}, [:binary, :stream, :eof])
    stdin_loop(port, parent, "")
  end

  defp stdin_loop(port, parent, buffer) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data
        {lines, rest} = extract_lines(buffer)

        for line <- lines do
          trimmed = String.trim(line)

          if trimmed != "" do
            send(parent, {:stdin_line, trimmed})
          end
        end

        stdin_loop(port, parent, rest)

      {^port, :eof} ->
        send(parent, :stdin_eof)
        :ok
    end
  end

  defp extract_lines(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        {more_lines, final_rest} = extract_lines(rest)
        {[line | more_lines], final_rest}

      [incomplete] ->
        {[], incomplete}
    end
  end

  # -- Incoming data from stdin --

  @impl true
  def handle_info(:stdin_eof, state) do
    # Parent CLI process closed stdin — shut down the VM so the server
    # doesn't linger as an orphan (e.g. after Ctrl+C in the terminal).
    Logger.info("stdin closed, shutting down")
    System.stop(0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:stdin_line, line}, state) do
    state = process_line(line, state)
    {:noreply, state}
  end

  # -- Opal Events → JSON-RPC notifications --

  def handle_info({:opal_event, session_id, event}, state) do
    notification = event_to_notification(session_id, event)
    write_stdout(state, notification)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Server→Client requests --

  @impl true
  def handle_call({:request_client, method, params}, from, state) do
    id = "s2c-#{state.next_server_id}"
    write_stdout(state, Opal.RPC.encode_request(id, method, params))
    pending = Map.put(state.pending_requests, id, from)

    {:noreply, %{state | pending_requests: pending, next_server_id: state.next_server_id + 1}}
  end

  # -- Outgoing notifications --

  @impl true
  def handle_cast({:notify, method, params}, state) do
    write_stdout(state, Opal.RPC.encode_notification(method, params))
    {:noreply, state}
  end

  # -- Internal --

  defp process_line(line, state) do
    case Opal.RPC.decode(line) do
      {:request, id, method, params} ->
        handle_request(id, method, params, state)

      {:response, id, result} ->
        handle_client_response(id, result, state)

      {:error_response, id, error} ->
        handle_client_error_response(id, error, state)

      {:notification, _method, _params} ->
        # Client notifications not currently handled
        state

      {:error, :parse_error} ->
        write_stdout(state, Opal.RPC.encode_error(nil, Opal.RPC.parse_error(), "Parse error"))
        state

      {:error, :invalid_request} ->
        write_stdout(state, Opal.RPC.encode_error(nil, Opal.RPC.invalid_request(), "Invalid request"))
        state
    end
  end

  defp handle_request(id, method, params, state) do
    try do
      case Opal.RPC.Handler.handle(method, params) do
        {:ok, result} ->
          write_stdout(state, Opal.RPC.encode_response(id, result))

          # Auto-subscribe to events for new sessions
          state =
            if method == "session/start" do
              subscribe_to_session(result.session_id, state)
            else
              state
            end

          state

        {:error, code, message, data} ->
          write_stdout(state, Opal.RPC.encode_error(id, code, message, data))
          state
      end
    rescue
      e ->
        Logger.error("RPC handler crashed: #{Exception.message(e)}")

        write_stdout(
          state,
          Opal.RPC.encode_error(
            id,
            Opal.RPC.internal_error(),
            "Internal error",
            Exception.message(e)
          )
        )

        state
    end
  end

  defp handle_client_response(id, result, state) do
    case Map.pop(state.pending_requests, id) do
      {from, pending} when from != nil ->
        GenServer.reply(from, {:ok, result})
        %{state | pending_requests: pending}

      {nil, _} ->
        Logger.warning("Received response for unknown request id: #{inspect(id)}")
        state
    end
  end

  defp handle_client_error_response(id, error, state) do
    case Map.pop(state.pending_requests, id) do
      {from, pending} when from != nil ->
        GenServer.reply(from, {:error, error})
        %{state | pending_requests: pending}

      {nil, _} ->
        Logger.warning("Received error response for unknown request id: #{inspect(id)}")
        state
    end
  end

  defp subscribe_to_session(session_id, state) do
    unless MapSet.member?(state.subscriptions, session_id) do
      Opal.Events.subscribe(session_id)
      %{state | subscriptions: MapSet.put(state.subscriptions, session_id)}
    else
      state
    end
  end

  # -- Event Serialization --

  defp event_to_notification(session_id, event) do
    {type, data} = serialize_event(event)
    params = Map.merge(%{session_id: session_id, type: type}, data)
    Opal.RPC.encode_notification(Opal.RPC.Protocol.notification_method(), params)
  end

  defp serialize_event({:agent_start}),
    do: {"agent_start", %{}}

  defp serialize_event({:agent_abort}),
    do: {"agent_abort", %{}}

  defp serialize_event({:message_start}),
    do: {"message_start", %{}}

  defp serialize_event({:message_delta, %{delta: delta}}),
    do: {"message_delta", %{delta: delta}}

  defp serialize_event({:thinking_start}),
    do: {"thinking_start", %{}}

  defp serialize_event({:thinking_delta, %{delta: delta}}),
    do: {"thinking_delta", %{delta: delta}}

  defp serialize_event({:tool_execution_start, tool, call_id, args, meta}),
    do: {"tool_execution_start", %{tool: tool, call_id: call_id, args: args, meta: meta}}

  defp serialize_event({:tool_execution_start, tool, args, meta}),
    do: {"tool_execution_start", %{tool: tool, call_id: "", args: args, meta: meta}}

  defp serialize_event({:tool_execution_start, tool, args}),
    do: {"tool_execution_start", %{tool: tool, call_id: "", args: args, meta: tool}}

  defp serialize_event({:tool_execution_end, tool, call_id, result}),
    do:
      {"tool_execution_end",
       %{tool: tool, call_id: call_id, result: serialize_tool_result(result)}}

  defp serialize_event({:tool_execution_end, tool, result}),
    do: {"tool_execution_end", %{tool: tool, call_id: "", result: serialize_tool_result(result)}}

  defp serialize_event({:sub_agent_start, %{model: model, label: label, tools: tools}}),
    do: {"sub_agent_start", %{model: model, label: label, tools: tools}}

  defp serialize_event({:sub_agent_event, parent_call_id, sub_session_id, inner_event}) do
    {inner_type, inner_data} = serialize_event(inner_event)

    {"sub_agent_event",
     %{
       parent_call_id: parent_call_id,
       sub_session_id: sub_session_id,
       inner: Map.put(inner_data, :type, inner_type)
     }}
  end

  defp serialize_event({:context_discovered, files}),
    do: {"context_discovered", %{files: files}}

  defp serialize_event({:skill_loaded, name, description}),
    do: {"skill_loaded", %{name: name, description: description}}

  defp serialize_event({:turn_end, message, _results}),
    do: {"turn_end", %{message: serialize_message_content(message)}}

  defp serialize_event({:agent_end, _messages}),
    do: {"agent_end", %{}}

  defp serialize_event({:agent_end, _messages, token_usage}),
    do: {"agent_end", %{usage: token_usage}}

  defp serialize_event({:usage_update, token_usage}),
    do: {"usage_update", %{usage: token_usage}}

  defp serialize_event({:status_update, message}),
    do: {"status_update", %{message: message}}

  defp serialize_event({:error, reason}),
    do: {"error", %{reason: inspect(reason)}}

  defp serialize_event({:agent_recovered}),
    do: {"agent_recovered", %{}}

  defp serialize_event(other),
    do: {"unknown", %{raw: inspect(other)}}

  defp serialize_tool_result({:ok, output}), do: %{ok: true, output: output}
  defp serialize_tool_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp serialize_tool_result(other), do: %{ok: true, output: inspect(other)}

  defp serialize_message_content(%Opal.Message{content: content}), do: content
  defp serialize_message_content(text) when is_binary(text), do: text
  defp serialize_message_content(other), do: inspect(other)

  # -- I/O --

  defp write_stdout(%__MODULE__{stdout_port: port}, json) do
    Port.command(port, json <> "\n")
  end
end
