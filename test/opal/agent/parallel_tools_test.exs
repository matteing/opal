defmodule Opal.Agent.ParallelToolsTest do
  @moduledoc """
  Tests that tool calls from a single LLM response execute in parallel,
  not sequentially.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Model

  # A tool that sleeps for a configurable duration, proving parallelism by wall-clock time.
  defmodule SlowTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "slow_tool"

    @impl true
    def description, do: "A tool that sleeps for a while"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "task identifier"},
          "sleep_ms" => %{"type" => "integer", "description" => "milliseconds to sleep"}
        },
        "required" => ["id", "sleep_ms"]
      }
    end

    @impl true
    def execute(%{"id" => id, "sleep_ms" => sleep_ms}, _ctx) do
      Process.sleep(sleep_ms)
      {:ok, "done:#{id}"}
    end
  end

  # Provider that returns N tool calls in a single response, then text on the second turn.
  defmodule MultiToolProvider do
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
          send_text_events(caller, ref, "All tools completed")
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

        # output_item.added — starts tool call accumulator
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

        # output_item.done — finalizes tool call with parsed arguments
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

      # Complete the response
      completed =
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_multi",
            "status" => "completed",
            "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
          }
        })

      send(caller, {ref, {:data, completed}})
      Process.sleep(1)
      send(caller, {ref, :done})
    end

    defp send_text_events(caller, ref, text) do
      events = [
        sse(%{
          "type" => "response.output_item.added",
          "item" => %{"type" => "message", "id" => "item_done"}
        }),
        sse(%{"type" => "response.output_text.delta", "delta" => text}),
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_done",
            "status" => "completed",
            "usage" => %{}
          }
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

  defp start_agent(tool_calls) do
    :persistent_term.put({MultiToolProvider, :tool_calls}, tool_calls)

    session_id = "parallel-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()
    {:ok, sub_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "test",
      tools: [SlowTool],
      provider: MultiToolProvider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup,
      sub_agent_supervisor: sub_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp make_tool_call(id, sleep_ms) do
    %{
      id: "item_#{id}",
      call_id: "call_#{id}",
      name: "slow_tool",
      arguments: %{"id" => id, "sleep_ms" => sleep_ms}
    }
  end

  defp collect_tool_events(session_id, acc \\ []) do
    receive do
      {:opal_event, ^session_id, {:tool_execution_start, _name, _call_id, _args, _meta} = ev} ->
        collect_tool_events(session_id, [ev | acc])

      {:opal_event, ^session_id, {:tool_execution_end, _name, _call_id, _result} = ev} ->
        collect_tool_events(session_id, [ev | acc])

      {:opal_event, ^session_id, {:agent_end, _messages, _usage}} ->
        Enum.reverse(acc)

      {:opal_event, ^session_id, {:agent_end, _messages}} ->
        Enum.reverse(acc)

      {:opal_event, ^session_id, _other} ->
        collect_tool_events(session_id, acc)
    after
      10_000 -> flunk("Timed out collecting tool events. Got: #{inspect(Enum.reverse(acc))}")
    end
  end

  describe "parallel tool execution" do
    @tag timeout: 8_000
    test "multiple tool calls execute concurrently, not sequentially" do
      # 3 tools each sleeping 200ms. Sequential = ~600ms. Parallel = ~200ms.
      tool_calls = [
        make_tool_call("a", 200),
        make_tool_call("b", 200),
        make_tool_call("c", 200)
      ]

      %{pid: pid, session_id: session_id} = start_agent(tool_calls)

      start_time = System.monotonic_time(:millisecond)
      Agent.prompt(pid, "Run three tools")

      events = collect_tool_events(session_id)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Verify all 3 tools started and completed
      starts = Enum.filter(events, &match?({:tool_execution_start, _, _, _, _}, &1))
      ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _}, &1))

      assert length(starts) == 3
      assert length(ends) == 3

      # Parallel: ~200ms + overhead. Sequential would be ~600ms+.
      # Use 500ms as threshold — generous for CI but proves parallelism.
      assert elapsed < 500,
             "Tools took #{elapsed}ms — expected < 500ms for parallel execution of 3×200ms tools"
    end

    test "all tool results are returned to the LLM" do
      tool_calls = [
        make_tool_call("x", 10),
        make_tool_call("y", 10)
      ]

      %{pid: pid, session_id: session_id} = start_agent(tool_calls)

      Agent.prompt(pid, "Run two tools")
      events = collect_tool_events(session_id)

      ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _}, &1))

      results =
        Enum.map(ends, fn {:tool_execution_end, _name, _call_id, result} -> result end)

      assert {:ok, "done:x"} in results
      assert {:ok, "done:y"} in results
    end

    test "single tool call still works" do
      tool_calls = [make_tool_call("solo", 10)]

      %{pid: pid, session_id: session_id} = start_agent(tool_calls)

      Agent.prompt(pid, "Run one tool")
      events = collect_tool_events(session_id)

      starts = Enum.filter(events, &match?({:tool_execution_start, _, _, _, _}, &1))
      ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _}, &1))

      assert length(starts) == 1
      assert length(ends) == 1

      [{:tool_execution_end, _, _, result}] = ends
      assert result == {:ok, "done:solo"}
    end
  end
end
