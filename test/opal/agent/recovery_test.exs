defmodule Opal.Agent.RecoveryTest do
  @moduledoc """
  Tests session persistence and agent recovery: restart with/without session,
  orphaned tool_call repair, clean message passthrough.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Model
  alias Opal.Message
  alias Opal.Test.FixtureHelper

  defmodule RecoveryProvider do
    @behaviour Opal.Provider
    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      FixtureHelper.build_fixture_response("responses_api_text.json")
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  defp start_agent_with_session do
    session_id = "recovery-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()
    {:ok, session} = Opal.Session.start_link(session_id: session_id)

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "Test",
      tools: [],
      provider: RecoveryProvider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup,
      session: session
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id, session: session, tool_sup: tool_sup}
  end

  defp wait_for_idle(pid, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Process.sleep(10)
      Agent.get_state(pid)
    end)
    |> Enum.find(fn state ->
      state.status == :idle or System.monotonic_time(:millisecond) > deadline
    end)
  end

  describe "agent restart with session" do
    @tag timeout: 10_000
    test "recovers messages from surviving session" do
      # Trap exits so killing the agent doesn't crash the test
      Process.flag(:trap_exit, true)

      %{pid: pid, session_id: sid, session: session, tool_sup: tool_sup} =
        start_agent_with_session()

      # Run a prompt so there are messages
      Agent.prompt(pid, "Hello")
      wait_for_idle(pid)

      state = Agent.get_state(pid)
      msg_count = length(state.messages)
      assert msg_count >= 2

      # Kill the agent (simulating crash)
      Process.exit(pid, :kill)

      receive do
        {:EXIT, ^pid, :killed} -> :ok
      after
        1000 -> flunk("Expected EXIT from killed agent")
      end

      # Session should still be alive
      assert Process.alive?(session)

      # Start a new agent pointing at the same session
      {:ok, new_pid} =
        Agent.start_link(
          session_id: sid,
          model: Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "Test",
          tools: [],
          provider: RecoveryProvider,
          config: Opal.Config.new(),
          tool_supervisor: tool_sup,
          session: session
        )

      # New agent should have recovered messages
      new_state = Agent.get_state(new_pid)
      assert length(new_state.messages) == msg_count

      # Should have broadcast agent_recovered
      assert_receive {:opal_event, ^sid, {:agent_recovered}}, 2000
    end
  end

  describe "agent restart without session" do
    test "starts fresh with empty messages" do
      session_id = "recovery-nosess-#{System.unique_integer([:positive])}"
      {:ok, tool_sup} = Task.Supervisor.start_link()

      {:ok, pid} =
        Agent.start_link(
          session_id: session_id,
          model: Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "Test",
          tools: [],
          provider: RecoveryProvider,
          config: Opal.Config.new(),
          tool_supervisor: tool_sup
        )

      state = Agent.get_state(pid)
      assert state.messages == []
      assert state.session == nil
    end
  end

  describe "orphaned tool_call repair on turn start" do
    test "injects synthetic abort results for orphaned tool_calls" do
      session_id = "recovery-orphan-#{System.unique_integer([:positive])}"
      {:ok, tool_sup} = Task.Supervisor.start_link()

      {:ok, pid} =
        Agent.start_link(
          session_id: session_id,
          model: Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "Test",
          tools: [],
          provider: RecoveryProvider,
          config: Opal.Config.new(),
          tool_supervisor: tool_sup
        )

      # Inject messages with orphaned tool_calls via sync_messages
      user_msg = Message.user("Hello")

      assistant_msg =
        Message.assistant("", [
          %{call_id: "orphan_1", name: "read_file", arguments: %{"path" => "/tmp/x"}},
          %{call_id: "orphan_2", name: "write_file", arguments: %{"path" => "/tmp/y"}}
        ])

      Agent.sync_messages(pid, [user_msg, assistant_msg])
      Events.subscribe(session_id)

      # Prompt triggers run_turn_internal which calls repair_orphaned_tool_calls
      Agent.prompt(pid, "Continue")
      wait_for_idle(pid)

      state = Agent.get_state(pid)

      # Should have synthetic tool_results for the orphaned calls
      tool_results = Enum.filter(state.messages, &(&1.role == :tool_result))
      result_ids = Enum.map(tool_results, & &1.call_id)

      assert "orphan_1" in result_ids
      assert "orphan_2" in result_ids

      # Synthetic results should contain abort text
      abort_results =
        Enum.filter(tool_results, fn m ->
          m.call_id in ["orphan_1", "orphan_2"]
        end)

      assert Enum.all?(abort_results, fn m -> m.content =~ "Aborted" end)
    end
  end

  describe "clean messages not repaired" do
    test "messages with matching tool_calls and results are not modified" do
      session_id = "recovery-clean-#{System.unique_integer([:positive])}"
      {:ok, tool_sup} = Task.Supervisor.start_link()

      {:ok, pid} =
        Agent.start_link(
          session_id: session_id,
          model: Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "Test",
          tools: [],
          provider: RecoveryProvider,
          config: Opal.Config.new(),
          tool_supervisor: tool_sup
        )

      # Inject clean messages (tool_calls with matching results)
      user_msg = Message.user("Hello")

      assistant_msg =
        Message.assistant("", [
          %{call_id: "clean_1", name: "read_file", arguments: %{}}
        ])

      result_msg = Message.tool_result("clean_1", "file contents")

      Agent.sync_messages(pid, [user_msg, assistant_msg, result_msg])
      Events.subscribe(session_id)

      # Count messages before prompt
      state_before = Agent.get_state(pid)
      _result_count_before = Enum.count(state_before.messages, &(&1.role == :tool_result))

      Agent.prompt(pid, "Continue")
      wait_for_idle(pid)

      state = Agent.get_state(pid)
      # No additional synthetic results should have been added for clean_1
      clean_results =
        Enum.filter(state.messages, fn m ->
          m.role == :tool_result and m.call_id == "clean_1"
        end)

      assert length(clean_results) == 1, "Clean tool_call should not get duplicate results"
    end
  end
end
