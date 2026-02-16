defmodule Opal.Agent.ParallelSubAgentToolCallsTest do
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Model
  alias Opal.Tool.SubAgent, as: SubAgentTool

  defmodule ParentAndSubProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      tool_calls = :persistent_term.get({__MODULE__, :tool_calls}, [])
      has_tool_results = Enum.any?(messages, &(&1.role == :tool_result))

      last_user =
        messages
        |> Enum.reverse()
        |> Enum.find(&(&1.role == :user))
        |> case do
          nil -> ""
          msg -> msg.content || ""
        end

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

        cond do
          has_tool_results ->
            send_text_events(caller, ref, "Parent done")

          last_user == "Run parent" ->
            send_tool_call_events(caller, ref, tool_calls)

          true ->
            # Simulate meaningful work so parallel sub-agent execution is observable.
            Process.sleep(250)
            send_text_events(caller, ref, "Sub done: #{last_user}")
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

        send(caller, {ref, {:data, added}})
        send(caller, {ref, {:data, done}})
      end

      completed =
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_parent_calls",
            "status" => "completed",
            "usage" => %{}
          }
        })

      send(caller, {ref, {:data, completed}})
      send(caller, {ref, :done})
    end

    defp send_text_events(caller, ref, text) do
      for event <- [
            sse(%{
              "type" => "response.output_item.added",
              "item" => %{"type" => "message", "id" => "item_text"}
            }),
            sse(%{"type" => "response.output_text.delta", "delta" => text}),
            sse(%{
              "type" => "response.completed",
              "response" => %{"id" => "resp_text", "status" => "completed", "usage" => %{}}
            })
          ] do
        send(caller, {ref, {:data, event}})
      end

      send(caller, {ref, :done})
    end

    defp sse(map), do: "data: #{Jason.encode!(map)}\n"
  end

  defp start_agent(tool_calls) do
    :persistent_term.put({ParentAndSubProvider, :tool_calls}, tool_calls)

    session_id = "parallel-subagent-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()
    {:ok, sub_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "test",
      tools: [SubAgentTool],
      provider: ParentAndSubProvider,
      config: Opal.Config.new(),
      tool_supervisor: tool_sup,
      sub_agent_supervisor: sub_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp make_sub_agent_call(id, prompt) do
    %{
      id: "item_#{id}",
      call_id: "call_#{id}",
      name: "sub_agent",
      arguments: %{"prompt" => prompt}
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

  test "multiple sub_agent tool calls from one response start before any completes" do
    tool_calls = [
      make_sub_agent_call("a", "Child A"),
      make_sub_agent_call("b", "Child B")
    ]

    %{pid: pid, session_id: session_id} = start_agent(tool_calls)

    Agent.prompt(pid, "Run parent")
    events = collect_tool_events(session_id)

    starts = Enum.filter(events, &match?({:tool_execution_start, "sub_agent", _, _, _}, &1))
    ends = Enum.filter(events, &match?({:tool_execution_end, "sub_agent", _, _}, &1))

    assert length(starts) == 2
    assert length(ends) == 2

    first_end_idx = Enum.find_index(events, &match?({:tool_execution_end, "sub_agent", _, _}, &1))
    assert first_end_idx != nil and first_end_idx >= 2

    assert Enum.all?(ends, fn {:tool_execution_end, "sub_agent", _call_id, result} ->
             match?({:ok, _}, result)
           end)
  end
end
