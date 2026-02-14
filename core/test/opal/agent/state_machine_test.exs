defmodule Opal.Agent.StateMachineTest do
  @moduledoc """
  Tests for messages arriving in unexpected states: late tool results,
  stream data after state change, prompt while busy, unknown messages.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Model
  alias Opal.Test.FixtureHelper

  defmodule FastProvider do
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

  defmodule SlowProvider do
    @behaviour Opal.Provider
    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      delay = :persistent_term.get({__MODULE__, :delay}, 1000)
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
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Done"})}\n",
          "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "r1", "status" => "completed", "usage" => %{"input_tokens" => 10, "output_tokens" => 5}}})}\n"
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
    provider = Keyword.get(opts, :provider, FastProvider)
    session_id = "sm-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "Test",
      tools: [],
      provider: provider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp _wait_for_idle(pid, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Process.sleep(10)
      Agent.get_state(pid)
    end)
    |> Enum.find(fn state ->
      state.status == :idle or System.monotonic_time(:millisecond) > deadline
    end)
  end

  setup do
    on_exit(fn ->
      try do
        :persistent_term.erase({SlowProvider, :delay})
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "late tool result after abort" do
    test "unknown ref message while idle is ignored" do
      %{pid: pid} = start_agent()

      # Send a fake tool result with a random ref
      fake_ref = make_ref()
      send(pid, {fake_ref, {:ok, "late result"}})

      Process.sleep(50)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "DOWN message with unknown ref while idle is ignored" do
      %{pid: pid} = start_agent()

      fake_ref = make_ref()
      send(pid, {:DOWN, fake_ref, :process, self(), :normal})

      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "prompt while busy" do
    @tag timeout: 10_000
    test "prompt during streaming is queued as pending_steers" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent(provider: SlowProvider)

      Agent.prompt(pid, "First")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Send second prompt while busy
      Agent.prompt(pid, "Second while busy")

      # Wait for completion — steers are drained at turn boundary
      assert_receive {:opal_event, ^sid, {:agent_end, _msgs, _usage}}, 5000

      state = Agent.get_state(pid)
      assert state.pending_steers == []
    end

    @tag timeout: 10_000
    test "two prompts while busy are both queued" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent(provider: SlowProvider)

      Agent.prompt(pid, "First")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      Agent.prompt(pid, "Second")
      Agent.prompt(pid, "Third")

      # Wait for completion
      Process.sleep(3000)

      state = Agent.get_state(pid)
      assert state.pending_steers == []
      # All three prompts should have been processed
      user_messages = Enum.filter(state.messages, &(&1.role == :user))
      assert length(user_messages) >= 3
    end
  end

  describe "prompt + abort" do
    @tag timeout: 10_000
    test "queued prompt survives abort" do
      :persistent_term.put({SlowProvider, :delay}, 1000)
      %{pid: pid, session_id: sid} = start_agent(provider: SlowProvider)

      Agent.prompt(pid, "First")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      Agent.prompt(pid, "Queued")
      Agent.abort(pid)

      Process.sleep(100)
      state = Agent.get_state(pid)
      assert state.status == :idle

      # The queued prompt should still be in pending_steers
      assert length(state.pending_steers) >= 1
    end
  end

  describe "unknown messages" do
    test "random atoms don't crash the agent" do
      %{pid: pid} = start_agent()

      send(pid, :garbage)
      send(pid, {:weird_tuple, 1, 2, 3})
      send(pid, %{not: :expected})

      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "stream_watchdog while idle is no-op" do
      %{pid: pid} = start_agent()

      send(pid, :stream_watchdog)

      Process.sleep(50)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "retry_turn while idle is no-op" do
      %{pid: pid} = start_agent()

      send(pid, :retry_turn)

      Process.sleep(50)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  describe "configure during streaming" do
    @tag timeout: 10_000
    test "set_model during active stream changes model for next turn" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent(provider: SlowProvider)

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Change model while streaming
      new_model = Model.new(:test, "new-model")
      :ok = Agent.set_model(pid, new_model)

      # Wait for completion
      assert_receive {:opal_event, ^sid, {:agent_end, _msgs, _usage}}, 5000

      state = Agent.get_state(pid)
      assert state.model.id == "new-model"
    end
  end
end
