defmodule Opal.SessionServerTest do
  @moduledoc """
  Tests for the per-session supervisor tree.

  Verifies that `Opal.SessionServer` correctly builds its supervision tree,
  starts the expected children, and provides agent/session discovery.
  """
  use ExUnit.Case, async: false

  alias Opal.SessionServer
  alias Opal.Test.FixtureHelper

  # Provider that returns canned text responses
  defmodule TestProvider do
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

  defp start_session_server(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "ss-test-#{System.unique_integer([:positive])}")

    base_opts = [
      session_id: session_id,
      model: Opal.Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "Test prompt",
      tools: [],
      provider: TestProvider
    ]

    {:ok, sup} = SessionServer.start_link(Keyword.merge(base_opts, opts))
    %{sup: sup, session_id: session_id}
  end

  # ── Supervision Tree Structure ──────────────────────────────────────

  describe "supervision tree structure" do
    test "starts with expected children" do
      %{sup: sup} = start_session_server()

      children = Supervisor.which_children(sup)

      child_ids =
        Enum.map(children, fn
          {id, _pid, _type, _} -> id
        end)

      # Task.Supervisor and DynamicSupervisor register via Registry tuples
      assert Opal.Agent in child_ids
      assert Enum.any?(child_ids, fn id -> match?({Opal.Registry, {:tool_sup, _}}, id) end)
      assert Enum.any?(child_ids, fn id -> match?({Opal.Registry, {:sub_agent_sup, _}}, id) end)
    end

    test "children are all alive" do
      %{sup: sup} = start_session_server()

      children = Supervisor.which_children(sup)

      for {_id, pid, _type, _} <- children do
        assert is_pid(pid), "Child is not a pid: #{inspect(pid)}"
        assert Process.alive?(pid), "Child #{inspect(pid)} is not alive"
      end
    end

    test "uses rest_for_one strategy" do
      %{sup: sup} = start_session_server()

      # Verify by checking supervisor counts (rest_for_one is set in init)
      info = Supervisor.count_children(sup)
      assert info[:workers] >= 1
      assert info[:supervisors] >= 1
    end

    test "includes Session child when session: true" do
      %{sup: sup} = start_session_server(session: true)

      children = Supervisor.which_children(sup)
      child_modules = Enum.map(children, fn {mod, _pid, _type, _} -> mod end)

      assert Opal.Session in child_modules
    end

    test "excludes Session child when session option is absent" do
      %{sup: sup} = start_session_server()

      children = Supervisor.which_children(sup)
      child_modules = Enum.map(children, fn {mod, _pid, _type, _} -> mod end)

      refute Opal.Session in child_modules
    end
  end

  # ── Agent/Session Discovery ─────────────────────────────────────────

  describe "agent/1" do
    test "returns the Agent pid" do
      %{sup: sup} = start_session_server()

      agent = SessionServer.agent(sup)
      assert is_pid(agent)
      assert Process.alive?(agent)
    end

    test "agent responds to get_state" do
      %{sup: sup, session_id: session_id} = start_session_server()

      agent = SessionServer.agent(sup)
      state = Opal.Agent.get_state(agent)
      assert state.session_id == session_id
      assert state.status == :idle
    end
  end

  describe "session/1" do
    test "returns nil when no session child" do
      %{sup: sup} = start_session_server()
      assert SessionServer.session(sup) == nil
    end

    test "returns Session pid when session: true" do
      %{sup: sup} = start_session_server(session: true)

      session = SessionServer.session(sup)
      assert is_pid(session)
      assert Process.alive?(session)
    end

    test "session is functional" do
      %{sup: sup} = start_session_server(session: true)

      session = SessionServer.session(sup)
      :ok = Opal.Session.append(session, Opal.Message.user("hello"))
      path = Opal.Session.get_path(session)
      assert length(path) == 1
      assert hd(path).content == "hello"
    end
  end

  # ── Registry Discovery ──────────────────────────────────────────────

  describe "registry-based discovery" do
    test "tool supervisor is discoverable via Registry" do
      %{session_id: session_id} = start_session_server()

      [{pid, _}] = Registry.lookup(Opal.Registry, {:tool_sup, session_id})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "sub-agent supervisor is discoverable via Registry" do
      %{session_id: session_id} = start_session_server()

      [{pid, _}] = Registry.lookup(Opal.Registry, {:sub_agent_sup, session_id})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "session is discoverable via Registry when started" do
      %{session_id: session_id} = start_session_server(session: true)

      [{pid, _}] = Registry.lookup(Opal.Registry, {:session, session_id})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  # ── Agent Functionality Through Supervisor ──────────────────────────

  describe "agent functionality through supervisor" do
    test "agent can receive prompts and stream responses" do
      %{sup: sup, session_id: session_id} = start_session_server()

      agent = SessionServer.agent(sup)
      Opal.Events.subscribe(session_id)

      Opal.Agent.prompt(agent, "Hello")

      assert_receive {:opal_event, ^session_id, {:agent_start}}, 2000
      assert_receive {:opal_event, ^session_id, {:agent_end, _msgs, _usage}}, 2000

      state = Opal.Agent.get_state(agent)
      assert state.status == :idle
      assert length(state.messages) == 2
    end

    test "multiple prompts work sequentially" do
      %{sup: sup, session_id: session_id} = start_session_server()

      agent = SessionServer.agent(sup)
      Opal.Events.subscribe(session_id)

      Opal.Agent.prompt(agent, "First")
      assert_receive {:opal_event, ^session_id, {:agent_end, _, _}}, 2000

      Opal.Agent.prompt(agent, "Second")
      assert_receive {:opal_event, ^session_id, {:agent_end, _, _}}, 2000

      state = Opal.Agent.get_state(agent)
      assert length(state.messages) == 4
    end
  end

  # ── Supervisor Termination ──────────────────────────────────────────

  describe "termination" do
    test "stopping supervisor terminates all children" do
      %{sup: sup} = start_session_server()

      children = Supervisor.which_children(sup)
      child_pids = for {_, pid, _, _} <- children, is_pid(pid), do: pid

      # Monitor all children
      refs = Enum.map(child_pids, &Process.monitor/1)

      Supervisor.stop(sup, :normal)

      # All children should terminate
      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2000
      end
    end

    test "supervisor itself terminates" do
      %{sup: sup} = start_session_server()
      ref = Process.monitor(sup)

      Supervisor.stop(sup, :normal)
      assert_receive {:DOWN, ^ref, :process, ^sup, :normal}, 2000
    end
  end

  # ── DynamicSupervisor Integration ───────────────────────────────────

  describe "via DynamicSupervisor" do
    test "session server can be started under SessionSupervisor" do
      session_id = "dyn-test-#{System.unique_integer([:positive])}"

      {:ok, sup} =
        DynamicSupervisor.start_child(
          Opal.SessionSupervisor,
          {SessionServer,
           session_id: session_id,
           model: Opal.Model.new(:test, "test-model"),
           working_dir: System.tmp_dir!(),
           system_prompt: "",
           tools: [],
           provider: TestProvider}
        )

      assert is_pid(sup)
      agent = SessionServer.agent(sup)
      assert is_pid(agent)

      # Clean up
      DynamicSupervisor.terminate_child(Opal.SessionSupervisor, sup)
    end
  end
end
