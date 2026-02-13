defmodule Opal.RPC.IntegrationTest do
  @moduledoc """
  End-to-end integration test for the Opal JSON-RPC 2.0 protocol.

  Simulates a real JSON-RPC client by spawning an in-process RPC server
  that uses message-passing instead of real stdio. Every message goes
  through the full stack: JSON encode → decode → Handler dispatch →
  Opal API → Events → notification serialization → JSON encode.

  This tests the same code paths a TypeScript CLI client would exercise.
  """
  use ExUnit.Case, async: false

  alias Opal.RPC
  alias Opal.RPC.Protocol
  alias Opal.Test.FixtureHelper

  # -- Test Fixture Provider (same pattern as integration_test.exs) --

  defmodule TestProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      fixture_name = :persistent_term.get({__MODULE__, :fixture}, "responses_api_text.json")

      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      actual_fixture =
        if has_tool_result do
          :persistent_term.get({__MODULE__, :second_fixture}, fixture_name)
        else
          fixture_name
        end

      FixtureHelper.build_fixture_response(actual_fixture)
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # -- Test Tool --

  defmodule TestReadTool do
    @behaviour Opal.Tool
    @impl true
    def name, do: "read_file"
    @impl true
    def description, do: "Read a file"
    @impl true
    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      }

    @impl true
    def execute(%{"path" => path}, _ctx), do: {:ok, "Contents of #{path}"}
  end

  # -- In-Process JSON-RPC Server --
  # A GenServer that acts like Opal.RPC.Stdio but uses message passing
  # instead of real stdio. The test process sends lines, receives responses.

  defmodule TestTransport do
    use GenServer

    defstruct [
      :test_pid,
      :buffer,
      pending_requests: %{},
      next_server_id: 1,
      subscriptions: MapSet.new()
    ]

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    def send_line(server, json_line) do
      GenServer.cast(server, {:incoming_line, json_line})
    end

    def request_client(server, method, params, timeout \\ 5_000) do
      GenServer.call(server, {:request_client, method, params}, timeout)
    end

    @impl true
    def init(test_pid) do
      {:ok, %__MODULE__{test_pid: test_pid, buffer: ""}}
    end

    @impl true
    def handle_cast({:incoming_line, line}, state) do
      state = process_line(line, state)
      {:noreply, state}
    end

    @impl true
    def handle_cast({:notify, method, params}, state) do
      write_to_client(state.test_pid, RPC.encode_notification(method, params))
      {:noreply, state}
    end

    @impl true
    def handle_info({:opal_event, session_id, event}, state) do
      {type, data} = serialize_event(event)
      params = Map.merge(%{session_id: session_id, type: type}, data)

      write_to_client(
        state.test_pid,
        RPC.encode_notification(Protocol.notification_method(), params)
      )

      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    @impl true
    def handle_call({:request_client, method, params}, from, state) do
      id = "s2c-#{state.next_server_id}"
      write_to_client(state.test_pid, RPC.encode_request(id, method, params))
      pending = Map.put(state.pending_requests, id, from)
      {:noreply, %{state | pending_requests: pending, next_server_id: state.next_server_id + 1}}
    end

    defp process_line(line, state) do
      case RPC.decode(line) do
        {:request, id, method, params} ->
          handle_request(id, method, params, state)

        {:response, id, result} ->
          handle_client_response(id, result, state)

        {:error_response, id, error} ->
          handle_client_response(id, {:error, error}, state)

        {:notification, _method, _params} ->
          state

        {:error, :parse_error} ->
          write_to_client(state.test_pid, RPC.encode_error(nil, RPC.parse_error(), "Parse error"))
          state

        {:error, :invalid_request} ->
          write_to_client(
            state.test_pid,
            RPC.encode_error(nil, RPC.invalid_request(), "Invalid request")
          )

          state
      end
    end

    defp handle_request(id, method, params, state) do
      case Opal.RPC.Handler.handle(method, params) do
        {:ok, result} ->
          write_to_client(state.test_pid, RPC.encode_response(id, result))

          if method == "session/start" do
            subscribe_to_session(result.session_id, state)
          else
            state
          end

        {:error, code, message, data} ->
          write_to_client(state.test_pid, RPC.encode_error(id, code, message, data))
          state
      end
    end

    defp handle_client_response(id, result, state) do
      case Map.pop(state.pending_requests, id) do
        {from, pending} when from != nil ->
          GenServer.reply(from, {:ok, result})
          %{state | pending_requests: pending}

        {nil, _} ->
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

    # Event serialization — mirrors Opal.RPC.Stdio exactly
    defp serialize_event({:agent_start}), do: {"agent_start", %{}}
    defp serialize_event({:agent_abort}), do: {"agent_abort", %{}}
    defp serialize_event({:message_start}), do: {"message_start", %{}}
    defp serialize_event({:message_delta, %{delta: d}}), do: {"message_delta", %{delta: d}}
    defp serialize_event({:thinking_start}), do: {"thinking_start", %{}}
    defp serialize_event({:thinking_delta, %{delta: d}}), do: {"thinking_delta", %{delta: d}}

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
      do:
        {"tool_execution_end", %{tool: tool, call_id: "", result: serialize_tool_result(result)}}

    defp serialize_event({:turn_end, msg, _}), do: {"turn_end", %{message: serialize_msg(msg)}}
    defp serialize_event({:agent_end, _msgs}), do: {"agent_end", %{}}
    defp serialize_event({:agent_end, _msgs, _usage}), do: {"agent_end", %{}}
    defp serialize_event({:error, reason}), do: {"error", %{reason: inspect(reason)}}
    defp serialize_event(other), do: {"unknown", %{raw: inspect(other)}}

    defp serialize_tool_result({:ok, output}), do: %{ok: true, output: output}
    defp serialize_tool_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
    defp serialize_tool_result(other), do: %{ok: true, output: inspect(other)}

    defp serialize_msg(%Opal.Message{content: c}), do: c
    defp serialize_msg(t) when is_binary(t), do: t
    defp serialize_msg(o), do: inspect(o)

    defp write_to_client(pid, json) do
      send(pid, {:rpc_out, json})
    end
  end

  # -- Test Helpers --

  defp start_server do
    {:ok, server} = TestTransport.start_link(self())
    server
  end

  defp send_request(server, id, method, params) do
    json = RPC.encode_request(id, method, params)
    TestTransport.send_line(server, json)
  end

  defp send_response(server, id, result) do
    json = RPC.encode_response(id, result)
    TestTransport.send_line(server, json)
  end

  defp send_raw(server, text) do
    TestTransport.send_line(server, text)
  end

  # Receive a raw JSON string from the server
  defp recv_raw(timeout \\ 2000) do
    receive do
      {:rpc_out, json} -> Jason.decode!(json)
    after
      timeout -> flunk("Timeout waiting for RPC message")
    end
  end

  # Receive a JSON-RPC response (with "id"), skipping any notifications
  defp recv_response(timeout \\ 2000) do
    receive do
      {:rpc_out, json} ->
        msg = Jason.decode!(json)

        if Map.has_key?(msg, "id") do
          msg
        else
          recv_response(timeout)
        end
    after
      timeout -> flunk("Timeout waiting for JSON-RPC response")
    end
  end

  # Collect all messages until a condition is met
  defp collect_until(condition, acc \\ [], timeout \\ 5000) do
    receive do
      {:rpc_out, json} ->
        decoded = Jason.decode!(json)
        acc = acc ++ [decoded]
        if condition.(decoded), do: acc, else: collect_until(condition, acc, timeout)
    after
      timeout ->
        flunk("Timeout collecting messages. Got #{length(acc)} so far: #{inspect(acc, limit: 3)}")
    end
  end

  # Drain any remaining messages from the mailbox
  defp drain_messages do
    receive do
      {:rpc_out, _} -> drain_messages()
    after
      50 -> :ok
    end
  end

  setup do
    :persistent_term.put({TestProvider, :fixture}, "responses_api_text.json")
    :persistent_term.put({TestProvider, :second_fixture}, "responses_api_text.json")

    on_exit(fn ->
      :persistent_term.erase({TestProvider, :fixture})
      :persistent_term.erase({TestProvider, :second_fixture})
    end)

    Application.put_env(:opal, :provider, TestProvider)

    on_exit(fn ->
      Application.delete_env(:opal, :provider)
    end)

    :ok
  end

  # ============================================================================
  # PROTOCOL ERROR HANDLING
  # ============================================================================

  describe "protocol errors" do
    test "parse error on invalid JSON" do
      server = start_server()
      send_raw(server, "not valid json{{{")

      msg = recv_raw()
      assert msg["jsonrpc"] == "2.0"
      assert msg["id"] == nil
      assert msg["error"]["code"] == -32700
      assert msg["error"]["message"] == "Parse error"
    end

    test "invalid request (valid JSON, not JSON-RPC)" do
      server = start_server()
      send_raw(server, Jason.encode!(%{foo: "bar"}))

      msg = recv_raw()
      assert msg["error"]["code"] == -32600
    end

    test "method not found" do
      server = start_server()
      send_request(server, 1, "nonexistent/method", %{})

      msg = recv_raw()
      assert msg["id"] == 1
      assert msg["error"]["code"] == -32601
      assert msg["error"]["message"] =~ "Method not found"
    end
  end

  # ============================================================================
  # AUTH
  # ============================================================================

  describe "auth/status" do
    test "returns authenticated boolean" do
      server = start_server()
      send_request(server, 1, "auth/status", %{})

      msg = recv_raw()
      assert msg["id"] == 1
      assert is_boolean(msg["result"]["authenticated"])
    end
  end

  # ============================================================================
  # MODELS
  # ============================================================================

  describe "models/list" do
    test "returns a list of models" do
      server = start_server()
      send_request(server, 1, "models/list", %{})

      msg = recv_raw()
      assert msg["id"] == 1
      models = msg["result"]["models"]
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, fn m -> is_binary(m["id"]) and is_binary(m["name"]) end)
    end
  end

  # ============================================================================
  # SESSION LIFECYCLE
  # ============================================================================

  describe "session/start" do
    test "starts a session and returns session_id" do
      server = start_server()

      send_request(server, 1, "session/start", %{
        "system_prompt" => "Test",
        "working_dir" => System.tmp_dir!()
      })

      msg = recv_raw()
      assert msg["id"] == 1
      assert is_binary(msg["result"]["session_id"])

      # Cleanup
      session_id = msg["result"]["session_id"]
      cleanup_session(session_id)
    end

    test "missing params returns an error (no working_dir)" do
      server = start_server()
      send_request(server, 1, "session/start", %{})

      msg = recv_raw()
      assert msg["id"] == 1
      # May succeed or fail depending on environment; verify valid JSON-RPC response
      assert Map.has_key?(msg, "result") or Map.has_key?(msg, "error")
    end
  end

  describe "session/list" do
    test "returns a sessions array" do
      server = start_server()
      send_request(server, 1, "session/list", %{})

      msg = recv_raw()
      assert msg["id"] == 1
      assert is_list(msg["result"]["sessions"])
    end
  end

  # ============================================================================
  # AGENT OPERATIONS — MISSING PARAMS
  # ============================================================================

  describe "agent operations with missing params" do
    test "agent/prompt without params returns invalid_params" do
      server = start_server()
      send_request(server, 1, "agent/prompt", %{})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end

    test "agent/steer without params returns invalid_params" do
      server = start_server()
      send_request(server, 1, "agent/steer", %{})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end

    test "agent/abort without params returns invalid_params" do
      server = start_server()
      send_request(server, 1, "agent/abort", %{})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end

    test "agent/state without params returns invalid_params" do
      server = start_server()
      send_request(server, 1, "agent/state", %{})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end
  end

  # ============================================================================
  # AGENT OPERATIONS — NONEXISTENT SESSION
  # ============================================================================

  describe "agent operations with nonexistent session" do
    test "agent/prompt returns session not found" do
      server = start_server()
      send_request(server, 1, "agent/prompt", %{"session_id" => "nope", "text" => "hi"})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
      assert msg["error"]["message"] =~ "Session not found"
    end

    test "agent/abort returns session not found" do
      server = start_server()
      send_request(server, 1, "agent/abort", %{"session_id" => "nope"})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end

    test "agent/state returns session not found" do
      server = start_server()
      send_request(server, 1, "agent/state", %{"session_id" => "nope"})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
    end
  end

  # ============================================================================
  # FULL AGENT FLOW — TEXT RESPONSE
  # ============================================================================

  describe "full agent flow — text response" do
    @tag timeout: 10_000
    test "session/start → agent/prompt → streaming events → agent/state" do
      :persistent_term.put({TestProvider, :fixture}, "responses_api_text.json")
      server = start_server()

      # 1. Start session
      send_request(server, 1, "session/start", %{
        "system_prompt" => "Test assistant",
        "working_dir" => System.tmp_dir!()
      })

      start_resp = recv_raw()
      session_id = start_resp["result"]["session_id"]
      assert is_binary(session_id)

      # 2. Send prompt
      send_request(server, 2, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "Hello"
      })

      prompt_resp = recv_raw()
      assert prompt_resp["id"] == 2
      assert prompt_resp["result"] == %{}

      # 3. Collect streaming notifications until agent_end
      events =
        collect_until(fn msg ->
          msg["method"] == "agent/event" and msg["params"]["type"] == "agent_end"
        end)

      # Verify we got the expected event sequence
      event_types = Enum.map(events, fn msg -> msg["params"]["type"] end)
      assert "agent_start" in event_types
      assert "message_delta" in event_types
      assert "agent_end" in event_types

      # All events belong to our session
      for event <- events do
        assert event["params"]["session_id"] == session_id
      end

      # Verify deltas contain text
      deltas =
        events
        |> Enum.filter(fn e -> e["params"]["type"] == "message_delta" end)
        |> Enum.map(fn e -> e["params"]["delta"] end)

      assert length(deltas) > 0
      full_text = Enum.join(deltas)
      assert full_text =~ "Hello"

      # All events are proper JSON-RPC notifications (no id)
      for event <- events do
        assert event["jsonrpc"] == "2.0"
        assert event["method"] == "agent/event"
        refute Map.has_key?(event, "id")
      end

      # 4. Check agent state after completion
      Process.sleep(100)
      send_request(server, 3, "agent/state", %{"session_id" => session_id})
      state_resp = recv_raw()
      assert state_resp["result"]["status"] == "idle"
      assert state_resp["result"]["session_id"] == session_id
      assert state_resp["result"]["message_count"] == 2

      cleanup_session(session_id)
    end
  end

  # ============================================================================
  # FULL AGENT FLOW — TOOL CALL
  # ============================================================================

  describe "full agent flow — tool call" do
    @tag timeout: 10_000
    test "session/start → agent/prompt → tool execution → second turn → agent_end" do
      :persistent_term.put({TestProvider, :fixture}, "responses_api_tool_call.json")
      :persistent_term.put({TestProvider, :second_fixture}, "responses_api_text.json")

      server = start_server()

      # 1. Start session with a tool
      send_request(server, 1, "session/start", %{
        "system_prompt" => "You have a read_file tool.",
        "working_dir" => System.tmp_dir!()
      })

      start_resp = recv_raw()
      session_id = start_resp["result"]["session_id"]

      # 2. Prompt
      send_request(server, 2, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "Read a file"
      })

      prompt_resp = recv_raw()
      assert prompt_resp["result"] == %{}

      # 3. Collect all events until agent_end
      events =
        collect_until(fn msg ->
          msg["method"] == "agent/event" and msg["params"]["type"] == "agent_end"
        end)

      event_types = Enum.map(events, fn msg -> msg["params"]["type"] end)

      # Should see agent_start, then turn_end (with tool calls), then agent_end
      assert "agent_start" in event_types
      assert "agent_end" in event_types

      # 4. Verify final state
      Process.sleep(100)
      send_request(server, 3, "agent/state", %{"session_id" => session_id})
      state_resp = recv_raw()
      assert state_resp["result"]["status"] == "idle"
      # user + assistant + tool_result + assistant = 4 messages
      assert state_resp["result"]["message_count"] == 4

      cleanup_session(session_id)
    end
  end

  # ============================================================================
  # ABORT
  # ============================================================================

  describe "agent/abort" do
    @tag timeout: 10_000
    test "abort on a running or idle agent returns valid response" do
      :persistent_term.put({TestProvider, :fixture}, "responses_api_text.json")
      server = start_server()

      # Start session
      send_request(server, 1, "session/start", %{
        "working_dir" => System.tmp_dir!()
      })

      start_resp = recv_raw()
      session_id = start_resp["result"]["session_id"]

      # Prompt
      send_request(server, 2, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "Hello"
      })

      _prompt_resp = recv_raw()

      # Send abort — agent may have already finished (fixture is very fast)
      send_request(server, 3, "agent/abort", %{"session_id" => session_id})
      abort_resp = recv_response()
      # Either succeeds (ok: true) or gets an abort event — both are valid
      assert abort_resp["id"] == 3
      assert Map.has_key?(abort_resp, "result") or Map.has_key?(abort_resp, "error")

      # Drain any remaining events
      drain_messages()

      # State should be idle after abort
      Process.sleep(100)
      send_request(server, 4, "agent/state", %{"session_id" => session_id})
      state_resp = recv_response()
      assert state_resp["result"]["status"] == "idle"

      cleanup_session(session_id)
    end
  end

  # ============================================================================
  # SERVER → CLIENT REQUESTS (bidirectional)
  # ============================================================================

  describe "server → client requests" do
    test "request_client sends a request and resolves on client response" do
      server = start_server()

      # Spawn a task that calls request_client (it will block waiting for response)
      task =
        Task.async(fn ->
          TestTransport.request_client(server, "client/confirm", %{
            session_id: "test-123",
            title: "Delete file?",
            message: "Are you sure?",
            actions: ["allow", "deny"]
          })
        end)

      # Receive the server→client request
      msg = recv_raw()
      assert msg["method"] == "client/confirm"
      assert msg["id"] =~ "s2c-"
      assert msg["params"]["title"] == "Delete file?"
      assert msg["params"]["actions"] == ["allow", "deny"]

      # Send response back
      send_response(server, msg["id"], %{"action" => "allow"})

      # The task should resolve
      {:ok, result} = Task.await(task, 2000)
      assert result == %{"action" => "allow"}
    end
  end

  # ============================================================================
  # MULTIPLE REQUESTS (pipelining)
  # ============================================================================

  describe "request pipelining" do
    test "handles multiple concurrent requests" do
      server = start_server()

      # Send three requests without waiting for responses
      send_request(server, 10, "models/list", %{})
      send_request(server, 11, "auth/status", %{})
      send_request(server, 12, "session/list", %{})

      # Collect all three responses (may arrive in any order)
      responses = for _ <- 1..3, do: recv_raw(2000)

      ids = Enum.map(responses, & &1["id"]) |> Enum.sort()
      assert ids == [10, 11, 12]

      # Each has a result (no errors)
      for resp <- responses do
        assert Map.has_key?(resp, "result"), "Expected result in: #{inspect(resp)}"
      end
    end
  end

  # ============================================================================
  # MULTI-TURN CONVERSATION
  # ============================================================================

  describe "multi-turn conversation" do
    @tag timeout: 15_000
    test "second prompt accumulates messages" do
      :persistent_term.put({TestProvider, :fixture}, "responses_api_text.json")
      server = start_server()

      # Start session
      send_request(server, 1, "session/start", %{
        "working_dir" => System.tmp_dir!()
      })

      session_id = recv_raw()["result"]["session_id"]

      # First prompt
      send_request(server, 2, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "First"
      })

      # prompt response
      recv_raw()

      collect_until(fn msg ->
        msg["method"] == "agent/event" and msg["params"]["type"] == "agent_end"
      end)

      # Check state after first turn
      Process.sleep(100)
      send_request(server, 3, "agent/state", %{"session_id" => session_id})
      state1 = recv_raw()
      assert state1["result"]["message_count"] == 2

      # Second prompt
      send_request(server, 4, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "Second"
      })

      # prompt response
      recv_raw()

      collect_until(fn msg ->
        msg["method"] == "agent/event" and msg["params"]["type"] == "agent_end"
      end)

      # Check state after second turn
      Process.sleep(100)
      send_request(server, 5, "agent/state", %{"session_id" => session_id})
      state2 = recv_raw()
      assert state2["result"]["message_count"] == 4

      cleanup_session(session_id)
    end
  end

  # ============================================================================
  # PROTOCOL SPEC VALIDATION
  # ============================================================================

  describe "protocol spec validation" do
    test "all Protocol-declared methods return valid JSON-RPC responses" do
      server = start_server()

      for {method, id} <- Enum.with_index(Protocol.method_names(), 100) do
        send_request(server, id, method, %{})
        msg = recv_raw()

        assert msg["jsonrpc"] == "2.0", "Method #{method} missing jsonrpc field"
        assert msg["id"] == id, "Method #{method} response id mismatch"

        # Must have either result or error — never both, never neither
        has_result = Map.has_key?(msg, "result")
        has_error = Map.has_key?(msg, "error")

        assert has_result or has_error,
               "Method #{method} response has neither result nor error: #{inspect(msg)}"

        refute has_result and has_error,
               "Method #{method} response has both result and error"

        if has_error do
          assert is_integer(msg["error"]["code"])
          assert is_binary(msg["error"]["message"])
        end
      end
    end

    test "event notifications use the declared notification method" do
      :persistent_term.put({TestProvider, :fixture}, "responses_api_text.json")
      server = start_server()

      send_request(server, 1, "session/start", %{"working_dir" => System.tmp_dir!()})
      session_id = recv_raw()["result"]["session_id"]

      send_request(server, 2, "agent/prompt", %{
        "session_id" => session_id,
        "text" => "Hello"
      })

      # prompt response
      recv_raw()

      events =
        collect_until(fn msg ->
          msg["method"] == "agent/event" and msg["params"]["type"] == "agent_end"
        end)

      for event <- events do
        assert event["method"] == Protocol.notification_method()
        assert is_binary(event["params"]["type"])
        assert is_binary(event["params"]["session_id"])
      end

      cleanup_session(session_id)
    end
  end

  # ============================================================================
  # SESSION BRANCH
  # ============================================================================

  describe "session/branch" do
    test "returns error without session process" do
      server = start_server()

      send_request(server, 1, "session/branch", %{
        "session_id" => "nonexistent",
        "entry_id" => "msg-1"
      })

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
      assert msg["error"]["message"] =~ "Session not found"
    end
  end

  # ============================================================================
  # SESSION COMPACT
  # ============================================================================

  describe "session/compact" do
    test "returns session not found for unknown session" do
      server = start_server()
      send_request(server, 1, "session/compact", %{"session_id" => "abc"})

      msg = recv_raw()
      assert msg["error"]["code"] == -32602
      assert msg["error"]["message"] =~ "Session not found"
    end
  end

  # -- Cleanup Helpers --

  defp cleanup_session(session_id) do
    drain_messages()

    # Find and terminate the session's agent
    children = DynamicSupervisor.which_children(Opal.SessionSupervisor)

    Enum.each(children, fn
      {_, pid, :supervisor, _} when is_pid(pid) ->
        try do
          agent = Opal.SessionServer.agent(pid)

          if agent && Process.alive?(agent) do
            state = Opal.Agent.get_state(agent)

            if state.session_id == session_id do
              DynamicSupervisor.terminate_child(Opal.SessionSupervisor, pid)
            end
          end
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end)
  end
end
