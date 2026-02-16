defmodule Opal.IntegrationTest do
  @moduledoc """
  Integration tests using saved API response fixtures.

  These tests verify the full agent loop end-to-end: prompt → provider stream →
  SSE parsing → event broadcasting → tool execution → response finalization.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model
  alias Opal.Test.FixtureHelper

  # Provider that loads fixtures and delegates parsing to the real Copilot parser
  defmodule FixtureProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      fixture_name = :persistent_term.get({__MODULE__, :fixture}, "responses_api_text.json")

      # If there's a second-turn fixture, use it after tool results
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      actual_fixture =
        if has_tool_result do
          :persistent_term.get({__MODULE__, :second_fixture}, "responses_api_text.json")
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

  # Simple test tool
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

  defp start_agent(opts) do
    fixture = Keyword.get(opts, :fixture, "responses_api_text.json")
    second_fixture = Keyword.get(opts, :second_fixture, "responses_api_text.json")
    :persistent_term.put({FixtureProvider, :fixture}, fixture)
    :persistent_term.put({FixtureProvider, :second_fixture}, second_fixture)

    session_id = "integ-#{System.unique_integer([:positive])}"

    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, Keyword.get(opts, :model_id, "test-model")),
      working_dir: System.tmp_dir!(),
      system_prompt: Keyword.get(opts, :system_prompt, "Test prompt"),
      tools: Keyword.get(opts, :tools, []),
      provider: FixtureProvider,
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp wait_for_idle(pid, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(pid, deadline)
  end

  defp wait_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("Timed out")
    state = Agent.get_state(pid)

    if state.status == :idle,
      do: state,
      else:
        (
          Process.sleep(10)
          wait_loop(pid, deadline)
        )
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({FixtureProvider, :fixture})
      :persistent_term.erase({FixtureProvider, :second_fixture})
    end)

    :ok
  end

  # ── Responses API fixtures ──

  describe "Responses API — text response (fixture)" do
    test "full flow produces correct events and messages" do
      %{pid: pid, session_id: sid} = start_agent(fixture: "responses_api_text.json")
      Agent.prompt(pid, "Hello")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "Hello"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " from"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " fixture!"}}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 1000

      assert length(messages) == 2
      assistant = List.last(messages)
      assert assistant.role == :assistant
      assert assistant.content == "Hello from fixture!"
    end

    test "state is idle after completion" do
      %{pid: pid} = start_agent(fixture: "responses_api_text.json")
      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)
      assert state.status == :idle
      assert length(state.messages) == 2
    end
  end

  describe "Responses API — tool call (fixture)" do
    test "executes tool and loops back with second fixture" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "responses_api_tool_call.json",
          second_fixture: "responses_api_text.json",
          tools: [TestReadTool]
        )

      Agent.prompt(pid, "Read a file")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_start, "read_file", _call_id, %{"path" => "/tmp/test.txt"},
                       _meta}},
                     2000

      assert_receive {:opal_event, ^sid, {:tool_execution_end, "read_file", _call_id2, {:ok, _}}},
                     2000

      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant]

      tool_result = Enum.find(messages, &(&1.role == :tool_result))
      assert tool_result.content == "Contents of /tmp/test.txt"
      assert tool_result.call_id == "call_fix_001"
    end
  end

  # ── Chat Completions fixtures ──

  describe "Chat Completions — text response (fixture)" do
    test "full flow produces correct events" do
      %{pid: pid, session_id: sid} = start_agent(fixture: "chat_completions_text.json")
      Agent.prompt(pid, "Hello")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "Hello"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " from"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " completions!"}}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 1000

      assistant = List.last(messages)
      assert assistant.role == :assistant
      assert assistant.content == "Hello from completions!"
    end
  end

  describe "Chat Completions — tool call (fixture)" do
    test "executes tool and loops back" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "chat_completions_tool_call.json",
          second_fixture: "chat_completions_text.json",
          tools: [TestReadTool]
        )

      Agent.prompt(pid, "Read a file")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_start, "read_file", _call_id, %{"path" => "/tmp/test.txt"},
                       _meta}},
                     2000

      assert_receive {:opal_event, ^sid, {:tool_execution_end, "read_file", _call_id2, {:ok, _}}},
                     2000

      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant]
    end
  end

  # ── Error handling ──

  describe "error response (fixture)" do
    test "broadcasts error event and stays idle" do
      %{pid: pid, session_id: sid} = start_agent(fixture: "responses_api_error.json")
      Agent.prompt(pid, "Trigger error")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:error, %{"message" => "Rate limit exceeded", "code" => 429}}},
                     1000

      Process.sleep(50)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  # ── Multi-turn conversation ──

  describe "multi-turn conversation" do
    test "messages accumulate across multiple prompts" do
      %{pid: pid} = start_agent(fixture: "responses_api_text.json")

      Agent.prompt(pid, "First message")
      state = wait_for_idle(pid)
      assert length(state.messages) == 2

      Agent.prompt(pid, "Second message")
      state = wait_for_idle(pid)
      assert length(state.messages) == 4

      roles = state.messages |> Enum.reverse() |> Enum.map(& &1.role)
      assert roles == [:user, :assistant, :user, :assistant]
    end
  end

  # ── Auto-compaction ──

  describe "auto-compaction" do
    # Populates a session with large messages to ensure there's content to compact.
    # For model "test-model" (128k context), keep_recent_tokens = 32k = 128k chars.
    # We need total chars > 128k for the cut point to exist.
    defp populate_session(session, count, chars_per_msg) do
      for i <- 1..count do
        :ok =
          Opal.Session.append(
            session,
            Opal.Message.user("msg #{i} " <> String.duplicate("x", chars_per_msg))
          )

        :ok =
          Opal.Session.append(
            session,
            Opal.Message.assistant("reply #{i} " <> String.duplicate("y", chars_per_msg))
          )
      end
    end

    defp start_agent_with_session(opts) do
      fixture = Keyword.get(opts, :fixture, "responses_api_text.json")
      second_fixture = Keyword.get(opts, :second_fixture, "responses_api_text.json")
      :persistent_term.put({FixtureProvider, :fixture}, fixture)
      :persistent_term.put({FixtureProvider, :second_fixture}, second_fixture)

      session_id = "auto-compact-#{System.unique_integer([:positive])}"

      {:ok, session} = Opal.Session.start_link(session_id: session_id)
      {:ok, tool_sup} = Task.Supervisor.start_link()

      # Pre-populate with large messages
      pre_populate = Keyword.get(opts, :pre_populate, 0)
      chars_per_msg = Keyword.get(opts, :chars_per_msg, 20_000)
      if pre_populate > 0, do: populate_session(session, pre_populate, chars_per_msg)

      agent_opts = [
        session_id: session_id,
        model: Model.new(:test, Keyword.get(opts, :model_id, "test-model")),
        working_dir: System.tmp_dir!(),
        system_prompt: Keyword.get(opts, :system_prompt, ""),
        tools: [],
        provider: FixtureProvider,
        tool_supervisor: tool_sup,
        session: session
      ]

      {:ok, pid} = Agent.start_link(agent_opts)
      Events.subscribe(session_id)

      %{pid: pid, session_id: session_id, session: session}
    end

    test "triggers compaction when usage exceeds 80% threshold" do
      # 8 turns × 20k chars each = 320k chars total → well above 128k keep budget
      %{pid: pid, session_id: sid, session: session} =
        start_agent_with_session(
          fixture: "responses_api_high_usage.json",
          pre_populate: 8
        )

      session_count_before = length(Opal.Session.get_path(session))
      assert session_count_before == 16

      # First prompt: sets last_prompt_tokens = 110,000 (85.9% of 128k)
      Agent.prompt(pid, "first")
      wait_for_idle(pid)

      state_after_first = Agent.get_state(pid)
      assert state_after_first.last_prompt_tokens == 110_000

      # Switch to low-usage fixture for second turn (avoids summarization blocking)
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_text.json")

      # Second prompt: run_turn calls maybe_auto_compact, which should fire
      Agent.prompt(pid, "second")

      # Expect compaction events
      assert_receive {:opal_event, ^sid, {:compaction_start, _msg_count}}, 3000
      assert_receive {:opal_event, ^sid, {:compaction_end, _before, _after}}, 3000

      wait_for_idle(pid)

      # After compaction + second turn, session should have fewer messages
      # than before compaction (16 pre + 2 first turn = 18) + 2 second turn = 20
      final_path = Opal.Session.get_path(session)
      assert length(final_path) < 20
    end

    test "does not trigger compaction below 80% threshold" do
      %{pid: pid, session_id: sid} =
        start_agent_with_session(
          fixture: "responses_api_text.json",
          pre_populate: 4
        )

      # First prompt: text fixture has input_tokens: 10, well below threshold
      Agent.prompt(pid, "first")
      wait_for_idle(pid)

      state = Agent.get_state(pid)
      assert state.last_prompt_tokens == 10

      # Second prompt should NOT trigger compaction
      Agent.prompt(pid, "second")
      wait_for_idle(pid)

      refute_received {:opal_event, ^sid, {:compaction_start, _}}
    end

    test "session message count decreases after compaction" do
      %{pid: pid, session_id: sid, session: session} =
        start_agent_with_session(
          fixture: "responses_api_high_usage.json",
          pre_populate: 8
        )

      # First prompt adds 2 messages to session (user + assistant)
      Agent.prompt(pid, "first")
      wait_for_idle(pid)

      session_count_before = length(Opal.Session.get_path(session))
      # 16 pre-populated + 2 from first turn = 18
      assert session_count_before == 18

      # Switch fixture to avoid summarization stream issues inside GenServer
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_text.json")

      # Second prompt triggers auto-compaction
      Agent.prompt(pid, "second")

      assert_receive {:opal_event, ^sid, {:compaction_start, _}}, 3000
      assert_receive {:opal_event, ^sid, {:compaction_end, _, after_count}}, 3000
      assert after_count < session_count_before

      wait_for_idle(pid)

      # Session path should be compacted (summary + kept messages + second turn)
      final_session_count = length(Opal.Session.get_path(session))
      assert final_session_count < session_count_before
    end

    test "agent state syncs with session after compaction" do
      %{pid: pid, session_id: sid, session: session} =
        start_agent_with_session(
          fixture: "responses_api_high_usage.json",
          pre_populate: 8
        )

      Agent.prompt(pid, "first")
      wait_for_idle(pid)

      # Switch fixture for clean second turn
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_text.json")

      Agent.prompt(pid, "second")
      # Must wait for compaction_end (not just start) before calling wait_for_idle,
      # because collect_stream_text inside compaction uses a generic receive that
      # would consume the GenServer.call message from wait_for_idle.
      assert_receive {:opal_event, ^sid, {:compaction_start, _}}, 3000
      assert_receive {:opal_event, ^sid, {:compaction_end, _, _}}, 3000
      wait_for_idle(pid)

      # After compaction, agent's state.messages should match the session path
      agent_msgs = Agent.get_state(pid).messages
      session_path = Opal.Session.get_path(session)
      assert length(agent_msgs) == length(session_path)
    end

    test "survives when nothing to compact" do
      # Use only 1 turn of tiny messages — not enough content to exceed keep budget
      %{pid: pid} =
        start_agent_with_session(
          fixture: "responses_api_high_usage.json",
          pre_populate: 1,
          chars_per_msg: 100
        )

      # First prompt: sets last_prompt_tokens to 110k
      Agent.prompt(pid, "first")
      wait_for_idle(pid)

      # Switch fixture for second turn
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_text.json")

      # Second prompt: auto-compact fires but compact returns :ok (nothing to do)
      Agent.prompt(pid, "second")
      wait_for_idle(pid)

      # Agent should still be functional
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "does not compact when session is nil" do
      # Agent without a session process — maybe_auto_compact guard fails
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_high_usage.json")
      session_id = "no-session-#{System.unique_integer([:positive])}"
      {:ok, tool_sup} = Task.Supervisor.start_link()

      {:ok, pid} =
        Agent.start_link(
          session_id: session_id,
          model: Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "",
          tools: [],
          provider: FixtureProvider,
          tool_supervisor: tool_sup
        )

      Events.subscribe(session_id)

      # First prompt: sets last_prompt_tokens high
      Agent.prompt(pid, "first")
      wait_for_idle(pid)
      assert Agent.get_state(pid).last_prompt_tokens == 110_000

      # Switch fixture for second turn
      :persistent_term.put({FixtureProvider, :fixture}, "responses_api_text.json")

      # Second prompt: should NOT attempt compaction (no session)
      Agent.prompt(pid, "second")
      wait_for_idle(pid)

      refute_received {:opal_event, ^session_id, {:compaction_start, _}}
      assert Agent.get_state(pid).status == :idle
    end
  end

  # ── Fixture infrastructure ──

  describe "fixture helper" do
    test "load_fixture returns parsed JSON" do
      fixture = FixtureHelper.load_fixture("responses_api_text.json")
      assert is_map(fixture)
      assert is_list(fixture["events"])
      assert length(fixture["events"]) > 0
    end

    test "fixture_events returns formatted SSE lines" do
      events = FixtureHelper.fixture_events("responses_api_text.json")
      assert is_list(events)
      assert Enum.all?(events, &String.starts_with?(&1, "data: "))
    end

    test "save_fixture creates a fixture file" do
      tmp_name = "test_save_#{System.unique_integer([:positive])}.json"
      path = FixtureHelper.save_fixture(tmp_name, ["event1", "event2"])
      assert File.exists?(path)

      loaded = FixtureHelper.load_fixture(tmp_name)
      assert length(loaded["events"]) == 2
      assert hd(loaded["events"])["data"] == "event1"

      File.rm!(path)
    end
  end
end
