defmodule Opal.Agent.ConcurrentSignalsTest do
  @moduledoc """
  Tests for race conditions between concurrent agent signals:
  abort during retry delay, steer+abort interleave, configure during
  streaming, multiple steers coalesce.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Model

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
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Response"})}\n",
          "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "r1", "status" => "completed", "usage" => %{"input_tokens" => 10, "output_tokens" => 5}}})}\n"
        ]

        for e <- events do
          send(caller, {ref, {:data, e}})
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

  defmodule ToolSlowProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      has_results = Enum.any?(messages, &(&1.role == :tool_result))
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
        Process.sleep(2)

        if has_results do
          events = [
            "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}})}\n",
            "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Done"})}\n",
            "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "r2", "status" => "completed", "usage" => %{}}})}\n"
          ]

          for e <- events,
              do:
                (
                  send(caller, {ref, {:data, e}})
                  Process.sleep(1)
                )

          send(caller, {ref, :done})
        else
          events = [
            "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "function_call", "id" => "i1", "call_id" => "c1", "name" => "slow_tool"}})}\n",
            "data: #{Jason.encode!(%{"type" => "response.output_item.done", "item" => %{"type" => "function_call", "id" => "i1", "call_id" => "c1", "name" => "slow_tool", "arguments" => Jason.encode!(%{"id" => "a", "sleep_ms" => 2000})}})}\n",
            "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "r1", "status" => "completed", "usage" => %{"input_tokens" => 20, "output_tokens" => 10}}})}\n"
          ]

          for e <- events,
              do:
                (
                  send(caller, {ref, {:data, e}})
                  Process.sleep(1)
                )

          send(caller, {ref, :done})
        end
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

  defmodule SlowTool do
    @behaviour Opal.Tool
    def name, do: "slow_tool"
    def description, do: "Sleeps"

    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "sleep_ms" => %{"type" => "integer"}
        },
        "required" => ["id", "sleep_ms"]
      }

    def execute(%{"id" => id, "sleep_ms" => ms}, _ctx) do
      Process.sleep(ms)
      {:ok, "done:#{id}"}
    end
  end

  defp start_agent(opts \\ []) do
    provider = Keyword.get(opts, :provider, SlowProvider)
    session_id = "concurrent-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "Test",
      tools: Keyword.get(opts, :tools, []),
      provider: provider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
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

  describe "steer + abort interleave" do
    @tag timeout: 10_000
    test "steers preserved after abort, not executed until next prompt" do
      :persistent_term.put({SlowProvider, :delay}, 1000)
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Queue a steer then abort
      Agent.steer(pid, "Focus on tests")
      Process.sleep(10)
      Agent.abort(pid)

      Process.sleep(100)
      state = Agent.get_state(pid)
      assert state.status == :idle
      # Steers should still be in the queue
      assert length(state.pending_steers) >= 1
    end
  end

  describe "multiple steers coalesce" do
    @tag timeout: 10_000
    test "three steers during tool execution all injected at boundary" do
      %{pid: pid, session_id: sid} =
        start_agent(provider: ToolSlowProvider, tools: [SlowTool])

      Agent.prompt(pid, "Run tool")

      # Wait for tool to start
      assert_receive {:opal_event, ^sid, {:tool_execution_start, _, _, _, _}}, 5000

      # Send three steers while tool is executing
      Agent.steer(pid, "Steer 1")
      Agent.steer(pid, "Steer 2")
      Agent.steer(pid, "Steer 3")

      # Wait for completion
      Process.sleep(5000)

      state = Agent.get_state(pid)
      assert state.pending_steers == []

      # All steers should be in messages as user messages
      user_msgs = Enum.filter(state.messages, &(&1.role == :user))
      contents = Enum.map(user_msgs, & &1.content)
      assert "Steer 1" in contents
      assert "Steer 2" in contents
      assert "Steer 3" in contents
    end
  end

  describe "configure during streaming" do
    @tag timeout: 10_000
    test "set_model during stream applies for next turn" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      new_model = Model.new(:test, "changed-model")
      :ok = Agent.set_model(pid, new_model)

      assert_receive {:opal_event, ^sid, {:agent_end, _msgs, _usage}}, 5000

      state = Agent.get_state(pid)
      assert state.model.id == "changed-model"
    end
  end
end
