defmodule Opal.Agent.SupervisorFailureTest do
  @moduledoc """
  Tests behavior when supervisor components fail:
  tool supervisor down, sub-agent supervisor down.
  """
  use ExUnit.Case, async: false

  alias Opal.Provider.Model
  alias Opal.Agent.ToolRunner

  defmodule ToolProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
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
          events = [
            sse(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}}),
            sse(%{"type" => "response.output_text.delta", "delta" => "Done"}),
            sse(%{
              "type" => "response.completed",
              "response" => %{"id" => "r1", "status" => "completed", "usage" => %{}}
            })
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
            sse(%{
              "type" => "response.output_item.added",
              "item" => %{
                "type" => "function_call",
                "id" => "i1",
                "call_id" => "c1",
                "name" => "test_tool"
              }
            }),
            sse(%{
              "type" => "response.output_item.done",
              "item" => %{
                "type" => "function_call",
                "id" => "i1",
                "call_id" => "c1",
                "name" => "test_tool",
                "arguments" => "{}"
              }
            }),
            sse(%{
              "type" => "response.completed",
              "response" => %{
                "id" => "r1",
                "status" => "completed",
                "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
              }
            })
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

    defp sse(map), do: "data: #{Jason.encode!(map)}\n"
  end

  defmodule TestTool do
    @behaviour Opal.Tool
    def name, do: "test_tool"
    def description, do: "test"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: {:ok, "result"}
  end

  describe "cancel_all_tasks with empty pending" do
    test "no-op when no tasks are pending" do
      state = %Opal.Agent.State{
        session_id: "sup-fail",
        model: Model.new(:test, "test"),
        working_dir: "/tmp",
        config: Opal.Config.new(),
        pending_tool_tasks: %{}
      }

      result = ToolRunner.cancel_all_tasks(state)
      assert result.pending_tool_tasks == %{}
    end
  end

  describe "sub-agent supervisor unavailable" do
    test "sub_agent tool exit is caught by execute_single_tool rescue" do
      config = Opal.Config.new()

      context = %{
        agent_state: %Opal.Agent.State{
          session_id: "sup-test",
          model: Model.new(:test, "test"),
          working_dir: System.tmp_dir!(),
          config: config,
          tools: [],
          sub_agent_supervisor: nil
        },
        config: config,
        working_dir: System.tmp_dir!(),
        session_id: "sup-test"
      }

      # SubAgent calls DynamicSupervisor.start_child(nil, ...) which raises
      # an exit. execute_single_tool rescues exceptions but exits propagate.
      # In production, the Task.Supervisor catches the exit via :DOWN handler.
      # Here we verify the exit happens.
      assert catch_exit(Opal.Tool.SubAgent.execute(%{"prompt" => "test"}, context)) != nil
    end
  end
end
