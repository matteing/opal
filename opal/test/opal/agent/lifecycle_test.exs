defmodule Opal.Agent.LifecycleTest do
  @moduledoc """
  Tests for Agent OTP lifecycle: GenServer calls, state transitions,
  concurrent operations, and fault tolerance.

  These complement the streaming/fixture tests in agent_test.exs by
  focusing on the GenServer primitives: init, handle_call, handle_cast,
  handle_info, and the state machine transitions.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model
  alias Opal.Test.FixtureHelper

  defmodule LifecycleProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      fixture = :persistent_term.get({__MODULE__, :fixture}, "responses_api_text.json")
      FixtureHelper.build_fixture_response(fixture)
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # Slow provider that delays before sending events (for testing concurrent ops)
  defmodule SlowProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      delay = :persistent_term.get({__MODULE__, :delay}, 500)
      caller = self()
      ref = make_ref()

      resp = %Req.Response{
        status: 200,
        headers: %{},
        body: %Req.Response.Async{
          ref: ref,
          stream_fun: fn
            inner_ref, {inner_ref, {:data, data}} -> {:ok, [data: data]}
            inner_ref, {inner_ref, :done} -> {:ok, [:done]}
            _, _ -> :unknown
          end,
          cancel_fun: fn _ref -> :ok end
        }
      }

      spawn(fn ->
        Process.sleep(delay)

        events = [
          "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}})}\n",
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Slow response"})}\n",
          "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_slow", "status" => "completed", "usage" => %{"input_tokens" => 10, "output_tokens" => 5}}})}\n"
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  defp start_agent(opts \\ []) do
    provider = Keyword.get(opts, :provider, LifecycleProvider)
    fixture = Keyword.get(opts, :fixture, "responses_api_text.json")

    if provider == LifecycleProvider do
      :persistent_term.put({LifecycleProvider, :fixture}, fixture)
    end

    session_id = "lifecycle-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, Keyword.get(opts, :model_id, "test-model")),
      working_dir: System.tmp_dir!(),
      system_prompt: Keyword.get(opts, :system_prompt, "Test"),
      tools: Keyword.get(opts, :tools, []),
      provider: provider,
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp wait_for_idle(pid, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pid, deadline)
  end

  defp do_wait(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("Timed out")
    state = Agent.get_state(pid)

    if state.status == :idle,
      do: state,
      else:
        (
          Process.sleep(10)
          do_wait(pid, deadline)
        )
  end

  setup do
    on_exit(fn ->
      for mod <- [LifecycleProvider, SlowProvider] do
        try do
          :persistent_term.erase({mod, :fixture})
          :persistent_term.erase({mod, :delay})
        rescue
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # ── get_state/1 ─────────────────────────────────────────────────────

  describe "get_state/1" do
    test "returns initial state" do
      %{pid: pid, session_id: session_id} = start_agent()

      state = Agent.get_state(pid)
      assert state.session_id == session_id
      assert state.status == :idle
      assert state.messages == []
      assert state.model.id == "test-model"
    end

    test "state updates after prompt completes" do
      %{pid: pid} = start_agent()

      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)

      assert length(state.messages) == 2
      assert state.status == :idle
    end

    test "state includes token usage after response" do
      %{pid: pid} = start_agent()

      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)

      # The text fixture reports input_tokens: 10, output_tokens: 5
      assert state.last_prompt_tokens == 10
    end
  end

  # ── prompt/2 ────────────────────────────────────────────────────────

  describe "prompt/2" do
    test "prompt returns queued status immediately" do
      %{pid: pid} = start_agent()
      assert %{queued: false} = Agent.prompt(pid, "Hello")
    end

    test "prompt triggers agent_start event" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000
    end

    test "prompt triggers agent_end event with messages" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      assert length(messages) == 2
      assert hd(messages).role == :user
      assert List.last(messages).role == :assistant
    end

    test "messages accumulate across prompts" do
      %{pid: pid} = start_agent()

      Agent.prompt(pid, "First")
      wait_for_idle(pid)

      Agent.prompt(pid, "Second")
      state = wait_for_idle(pid)

      assert length(state.messages) == 4
      roles = Enum.map(state.messages, & &1.role)
      assert roles == [:assistant, :user, :assistant, :user]
    end
  end

  # ── abort/1 ─────────────────────────────────────────────────────────

  describe "abort/1" do
    test "abort on idle agent is no-op" do
      %{pid: pid} = start_agent()

      # Agent starts idle, abort should not crash
      Agent.abort(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "abort during streaming transitions to idle" do
      :persistent_term.put({SlowProvider, :delay}, 1000)
      %{pid: pid, session_id: sid} = start_agent(provider: SlowProvider)

      Agent.prompt(pid, "Hello")
      # Wait for agent to start streaming
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      Agent.abort(pid)

      # Should eventually become idle
      Process.sleep(100)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  # ── prompt/2 while idle ─────────────────────────────────────────────

  describe "prompt/2 while idle" do
    test "prompt on idle agent does not crash" do
      %{pid: pid} = start_agent()

      # Prompt while idle — should not crash
      Agent.prompt(pid, "Focus on tests")
      # Give it a moment to process (prompt triggers a turn)
      Process.sleep(100)
      assert Process.alive?(pid)
    end
  end

  # ── State Transitions ───────────────────────────────────────────────

  describe "state transitions" do
    test "idle → running → streaming → idle" do
      %{pid: pid, session_id: sid} = start_agent()

      state_before = Agent.get_state(pid)
      assert state_before.status == :idle

      Agent.prompt(pid, "Hello")

      # Should receive start event
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Should receive end event
      assert_receive {:opal_event, ^sid, {:agent_end, _msgs, _usage}}, 2000

      state_after = Agent.get_state(pid)
      assert state_after.status == :idle
    end

    test "agent stays functional after multiple turn cycles" do
      %{pid: pid} = start_agent()

      for i <- 1..5 do
        Agent.prompt(pid, "Turn #{i}")
        wait_for_idle(pid)
      end

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert length(state.messages) == 10
    end
  end

  # ── Event Broadcasting ──────────────────────────────────────────────

  describe "event broadcasting" do
    test "all expected events are broadcast for a text response" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")

      # Collect all events
      events = collect_events(sid, 2000)
      types = Enum.map(events, fn {:opal_event, _, event} -> elem(event, 0) end)

      assert :agent_start in types
      assert :agent_end in types
    end

    test "message_delta events contain text content" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")

      events = collect_events(sid, 2000)

      deltas =
        events
        |> Enum.filter(fn {:opal_event, _, event} -> elem(event, 0) == :message_delta end)
        |> Enum.map(fn {:opal_event, _, {:message_delta, %{delta: d}}} -> d end)

      assert length(deltas) > 0
      full_text = Enum.join(deltas)
      assert full_text =~ "Hello"
    end

    test "events are scoped to session_id" do
      %{pid: pid1, session_id: sid1} = start_agent()
      %{pid: _pid2, session_id: _sid2} = start_agent()

      Agent.prompt(pid1, "Hello")
      wait_for_idle(pid1)

      # Should only receive events for sid1
      events = collect_events(sid1, 500)
      assert length(events) > 0

      for {:opal_event, event_sid, _event} <- events do
        assert event_sid == sid1
      end
    end
  end

  # ── Process Isolation ───────────────────────────────────────────────

  describe "process isolation" do
    test "agent runs in its own process" do
      %{pid: pid} = start_agent()
      assert is_pid(pid)
      assert pid != self()
      assert Process.alive?(pid)
    end

    test "agent process is a GenServer" do
      %{pid: pid} = start_agent()
      info = Process.info(pid)
      assert info != nil
      # GenServer processes are started via proc_lib
      assert {:initial_call, {mod, :init_p, _}} = List.keyfind(info, :initial_call, 0)
      assert mod in [:proc_lib, :gen_server]
    end

    test "multiple agents run independently" do
      agents = for _ <- 1..3, do: start_agent()

      for %{pid: pid} <- agents do
        Agent.prompt(pid, "Hello")
      end

      for %{pid: pid} <- agents do
        wait_for_idle(pid)
        state = Agent.get_state(pid)
        assert length(state.messages) == 2
      end
    end
  end

  # ── Unknown Message Handling ────────────────────────────────────────

  describe "unknown message handling" do
    test "agent ignores unexpected messages without crashing" do
      %{pid: pid} = start_agent()

      # Send random messages to the agent
      send(pid, :unexpected_atom)
      send(pid, {:unexpected_tuple, "data"})
      send(pid, "unexpected string")

      # Agent should still be alive and functional
      Process.sleep(50)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp collect_events(session_id, timeout) do
    collect_events_loop(session_id, timeout, [])
  end

  defp collect_events_loop(session_id, timeout, acc) do
    receive do
      {:opal_event, ^session_id, _event} = msg ->
        acc = [msg | acc]

        case msg do
          {:opal_event, _, {:agent_end, _, _}} -> Enum.reverse(acc)
          {:opal_event, _, {:agent_end, _}} -> Enum.reverse(acc)
          _ -> collect_events_loop(session_id, timeout, acc)
        end
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
