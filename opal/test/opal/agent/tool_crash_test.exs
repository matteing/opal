defmodule Opal.Agent.ToolCrashTest do
  @moduledoc """
  Tests that tool failures are isolated and don't break the agent loop.
  Covers: single tool crash, tool exit, all-crash batch, abort during tools,
  and invalid tool return values.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model

  # ── Tools ──────────────────────────────────────────────────────────────

  defmodule GoodTool do
    @behaviour Opal.Tool
    def name, do: "good_tool"
    def description, do: "Always succeeds"

    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      }

    def execute(%{"id" => id}, _ctx), do: {:ok, "ok:#{id}"}
  end

  defmodule CrashTool do
    @behaviour Opal.Tool
    def name, do: "crash_tool"
    def description, do: "Always crashes"

    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      }

    def execute(_args, _ctx), do: raise("boom!")
  end

  defmodule ExitTool do
    @behaviour Opal.Tool
    def name, do: "exit_tool"
    def description, do: "Exits the process"

    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      }

    def execute(_args, _ctx), do: Process.exit(self(), :kill)
  end

  defmodule SlowTool do
    @behaviour Opal.Tool
    def name, do: "slow_tool"
    def description, do: "Sleeps for a while"

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

  # ── Provider ───────────────────────────────────────────────────────────

  # Provider that emits configurable tool calls on turn 1, text on turn 2
  defmodule ToolTestProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      tool_calls = :persistent_term.get({__MODULE__, :tool_calls}, [])
      has_tool_results = Enum.any?(messages, fn m -> m.role == :tool_result end)
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

        if has_tool_results do
          send_text_events(caller, ref, "All done")
        else
          send_tool_call_events(caller, ref, tool_calls)
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

    defp send_tool_call_events(caller, ref, tool_calls) do
      for tc <- tool_calls do
        args_json = Jason.encode!(tc.arguments)

        added =
          sse(%{
            "type" => "response.output_item.added",
            "item" => %{
              "type" => "function_call",
              "id" => tc.id,
              "call_id" => tc.call_id,
              "name" => tc.name
            }
          })

        send(caller, {ref, {:data, added}})
        Process.sleep(1)

        done =
          sse(%{
            "type" => "response.output_item.done",
            "item" => %{
              "type" => "function_call",
              "id" => tc.id,
              "call_id" => tc.call_id,
              "name" => tc.name,
              "arguments" => args_json
            }
          })

        send(caller, {ref, {:data, done}})
        Process.sleep(1)
      end

      completed =
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_tools",
            "status" => "completed",
            "usage" => %{"input_tokens" => 50, "output_tokens" => 20}
          }
        })

      send(caller, {ref, {:data, completed}})
      Process.sleep(1)
      send(caller, {ref, :done})
    end

    defp send_text_events(caller, ref, text) do
      events = [
        sse(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}}),
        sse(%{"type" => "response.output_text.delta", "delta" => text}),
        sse(%{
          "type" => "response.completed",
          "response" => %{"id" => "resp_done", "status" => "completed", "usage" => %{}}
        })
      ]

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp sse(map), do: "data: #{Jason.encode!(map)}\n"
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  defp start_agent(tool_calls, tools) do
    :persistent_term.put({ToolTestProvider, :tool_calls}, tool_calls)

    session_id = "tool-crash-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "test",
      tools: tools,
      provider: ToolTestProvider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp make_tool_call(name, id, args \\ %{}) do
    %{
      id: "item_#{id}",
      call_id: "call_#{id}",
      name: name,
      arguments: Map.put(args, "id", id)
    }
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

  defp collect_tool_events(session_id, timeout \\ 5000) do
    collect_loop(session_id, timeout, [])
  end

  defp collect_loop(session_id, timeout, acc) do
    receive do
      {:opal_event, ^session_id, {:tool_execution_end, _name, _call_id, _result} = ev} ->
        collect_loop(session_id, timeout, [ev | acc])

      {:opal_event, ^session_id, {:agent_end, _messages, _usage}} ->
        Enum.reverse(acc)

      {:opal_event, ^session_id, _other} ->
        collect_loop(session_id, timeout, acc)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  setup do
    on_exit(fn ->
      try do
        :persistent_term.erase({ToolTestProvider, :tool_calls})
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "single tool crash in batch" do
    @tag timeout: 10_000
    test "one crash doesn't prevent other tools from completing" do
      tool_calls = [
        make_tool_call("good_tool", "a"),
        make_tool_call("crash_tool", "b"),
        make_tool_call("good_tool", "c")
      ]

      %{pid: pid, session_id: sid} = start_agent(tool_calls, [GoodTool, CrashTool])

      Agent.prompt(pid, "Run tools")
      events = collect_tool_events(sid)

      # All 3 tools should have end events
      assert length(events) == 3

      results =
        Enum.map(events, fn {:tool_execution_end, name, _cid, result} ->
          {name, elem(result, 0)}
        end)

      good_results = Enum.filter(results, fn {_, status} -> status == :ok end)
      error_results = Enum.filter(results, fn {_, status} -> status == :error end)

      assert length(good_results) == 2
      assert length(error_results) == 1

      state = wait_for_idle(pid)
      assert state.status == :idle
    end
  end

  describe "tool process exit" do
    @tag timeout: 10_000
    test "tool that exits with :kill is handled as error" do
      tool_calls = [make_tool_call("exit_tool", "x")]
      %{pid: pid, session_id: sid} = start_agent(tool_calls, [ExitTool])

      Agent.prompt(pid, "Run tool")
      events = collect_tool_events(sid)

      assert length(events) == 1
      [{:tool_execution_end, "exit_tool", _cid, result}] = events
      assert match?({:error, _}, result)

      state = wait_for_idle(pid)
      assert state.status == :idle
      assert Process.alive?(pid)
    end
  end

  describe "all tools crash" do
    @tag timeout: 10_000
    test "agent continues even when every tool in batch crashes" do
      tool_calls = [
        make_tool_call("crash_tool", "a"),
        make_tool_call("crash_tool", "b")
      ]

      %{pid: pid, session_id: sid} = start_agent(tool_calls, [CrashTool])

      Agent.prompt(pid, "Run tools")
      events = collect_tool_events(sid)

      assert length(events) == 2

      assert Enum.all?(events, fn {:tool_execution_end, _, _, result} ->
               match?({:error, _}, result)
             end)

      state = wait_for_idle(pid)
      assert state.status == :idle
      assert Process.alive?(pid)
    end
  end

  describe "tool abort during execution" do
    @tag timeout: 10_000
    test "abort kills running tools and repairs orphaned tool_calls" do
      tool_calls = [
        make_tool_call("slow_tool", "s", %{"sleep_ms" => 5000})
      ]

      %{pid: pid, session_id: sid} = start_agent(tool_calls, [SlowTool])

      Agent.prompt(pid, "Run slow tool")

      # Wait for tool to start
      assert_receive {:opal_event, ^sid, {:tool_execution_start, "slow_tool", _, _, _}}, 3000

      # Small delay to ensure tool is running
      Process.sleep(50)

      # Abort while tool is running
      Agent.abort(pid)

      Process.sleep(100)
      state = Agent.get_state(pid)
      assert state.status == :idle
      assert map_size(state.pending_tool_tasks) == 0
      assert Process.alive?(pid)

      # Verify message integrity: assistant with tool_calls should have
      # matching tool_results (either from execution or synthetic abort)
      assistant = Enum.find(state.messages, &(&1.role == :assistant))
      assert assistant != nil

      if is_list(assistant.tool_calls) and assistant.tool_calls != [] do
        # Every tool_call should have a corresponding tool_result
        call_ids = Enum.map(assistant.tool_calls, & &1.call_id)

        result_ids =
          state.messages
          |> Enum.filter(&(&1.role == :tool_result))
          |> Enum.map(& &1.call_id)

        for cid <- call_ids do
          assert cid in result_ids,
                 "tool_call #{cid} has no matching tool_result — orphan repair may have failed"
        end
      end
    end
  end

  describe "tool returns unexpected value" do
    test "execute_single_tool handles exception from bad return" do
      # Direct unit test of ToolRunner.execute_single_tool
      defmodule BadReturnTool do
        @behaviour Opal.Tool
        def name, do: "bad_return"
        def description, do: "Returns unexpected"
        def parameters, do: %{"type" => "object", "properties" => %{}}
        def execute(_args, _ctx), do: :not_a_valid_return
      end

      result =
        Opal.Agent.ToolRunner.execute_single_tool(
          BadReturnTool,
          %{},
          %{working_dir: "/tmp"}
        )

      # The raw return is passed through since execute_single_tool only rescues exceptions
      assert result == :not_a_valid_return
    end
  end
end
