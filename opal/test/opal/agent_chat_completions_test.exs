defmodule Opal.AgentChatCompletionsTest do
  @moduledoc """
  Tests the agent loop with Chat Completions SSE format.

  The regular AgentTest uses Responses API format. This module ensures
  Chat Completions format (used by Claude, Gemini, GPT-4o, etc.) works
  end-to-end through the agent.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model

  # Provider that emits Chat Completions format SSE and delegates
  # parsing to the real Copilot parser.
  defmodule ChatCompletionsProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      caller = self()
      ref = make_ref()
      scenario = :persistent_term.get({__MODULE__, :scenario}, :text)

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
        Process.sleep(5)
        send_scenario(caller, ref, scenario, messages)
      end)

      {:ok, resp}
    end

    # Use the REAL Copilot parser — this is what makes this an integration test
    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools

    defp send_scenario(caller, ref, :text, _messages) do
      events = [
        cc_line(%{
          "choices" => [
            %{"delta" => %{"role" => "assistant", "content" => ""}, "finish_reason" => nil}
          ]
        }),
        cc_line(%{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]}),
        cc_line(%{
          "choices" => [%{"delta" => %{"content" => " completions"}, "finish_reason" => nil}]
        }),
        cc_line(%{"choices" => [%{"delta" => %{"content" => "!"}, "finish_reason" => nil}]}),
        cc_line(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}),
        cc_line(%{"choices" => [], "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3}})
      ]

      send_events(caller, ref, events)
    end

    defp send_scenario(caller, ref, :tool_call, messages) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :text, messages)
      else
        events = [
          cc_line(%{
            "choices" => [
              %{
                "delta" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call_cc_001",
                      "type" => "function",
                      "function" => %{"name" => "echo_tool", "arguments" => ""}
                    }
                  ]
                },
                "finish_reason" => nil
              }
            ]
          }),
          cc_line(%{
            "choices" => [
              %{
                "delta" => %{"tool_calls" => [%{"function" => %{"arguments" => "{\"input\""}}]},
                "finish_reason" => nil
              }
            ]
          }),
          cc_line(%{
            "choices" => [
              %{
                "delta" => %{"tool_calls" => [%{"function" => %{"arguments" => ": \"test\"}"}}]},
                "finish_reason" => nil
              }
            ]
          }),
          cc_line(%{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]})
        ]

        send_events(caller, ref, events)
      end
    end

    defp send_events(caller, ref, events) do
      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp cc_line(data), do: "data: #{Jason.encode!(data)}\n"
  end

  # Test tool
  defmodule EchoTool do
    @behaviour Opal.Tool
    @impl true
    def name, do: "echo_tool"
    @impl true
    def description, do: "Echoes input"
    @impl true
    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"]
      }

    @impl true
    def execute(%{"input" => input}, _ctx), do: {:ok, "Echo: #{input}"}
  end

  defp set_scenario(scenario) do
    :persistent_term.put({ChatCompletionsProvider, :scenario}, scenario)
  end

  defp start_agent(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :text)
    set_scenario(scenario)

    session_id = "cc-test-#{System.unique_integer([:positive])}"

    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "claude-sonnet-4"),
      working_dir: System.tmp_dir!(),
      system_prompt: "Test prompt",
      tools: Keyword.get(opts, :tools, []),
      provider: ChatCompletionsProvider,
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp wait_for_idle(pid, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(pid, deadline)
  end

  defp wait_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for agent to become idle")
    end

    state = Agent.get_state(pid)

    if state.status == :idle do
      state
    else
      Process.sleep(10)
      wait_loop(pid, deadline)
    end
  end

  setup do
    on_exit(fn -> :persistent_term.erase({ChatCompletionsProvider, :scenario}) end)
    :ok
  end

  describe "Chat Completions — text response" do
    test "agent broadcasts text deltas and completes" do
      %{pid: pid, session_id: sid} = start_agent()
      Agent.prompt(pid, "Hello")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "Hello"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " completions"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "!"}}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 1000

      assert length(messages) == 2
      [user_msg, assistant_msg] = messages
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end

    test "accumulated text is correct" do
      %{pid: pid} = start_agent()
      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)

      assistant_msg = Enum.find(state.messages, &(&1.role == :assistant))
      assert assistant_msg.content == "Hello completions!"
    end
  end

  describe "Chat Completions — tool calls" do
    test "agent executes tool call and loops back" do
      %{pid: pid, session_id: sid} = start_agent(scenario: :tool_call, tools: [EchoTool])
      Agent.prompt(pid, "Use echo tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_start, "echo_tool", _call_id, %{"input" => "test"}, _meta}},
                     2000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "echo_tool", _call_id2, {:ok, "Echo: test"}}},
                     2000

      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant]
    end

    test "tool result has correct content" do
      %{pid: pid} = start_agent(scenario: :tool_call, tools: [EchoTool])
      Agent.prompt(pid, "Use echo tool")
      state = wait_for_idle(pid)

      tool_result = Enum.find(state.messages, &(&1.role == :tool_result))
      assert tool_result.content == "Echo: test"
      assert tool_result.call_id == "call_cc_001"
    end
  end
end
