defmodule Opal.AgentTest do
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Agent.State
  alias Opal.Events
  alias Opal.Provider.Model

  # --- Test Provider Module ---
  # Simulates streaming by sending Req-compatible messages to the calling process.

  defmodule TestProvider do
    @behaviour Opal.Provider

    # The test provider looks up a scenario from the process dictionary
    # or an ETS table to decide what events to send.

    @impl true
    def stream(model, messages, tools, _opts \\ []) do
      caller = self()
      ref = make_ref()

      # Look up scenario from the process dictionary (set via Agent init)
      scenario = :persistent_term.get({__MODULE__, :scenario}, :simple_text)

      resp = build_mock_resp(ref, caller)

      # Spawn a task that sends mock SSE data to the caller
      spawn(fn ->
        # Small delay to let the agent process the return value first
        Process.sleep(5)
        send_scenario(caller, ref, scenario, model, messages, tools)
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, parsed} -> do_parse(parsed)
        {:error, _} -> []
      end
    end

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools

    # SSE event parsing (mirrors Copilot provider logic)
    defp do_parse(%{"type" => "response.output_item.added", "item" => item}) do
      case item["type"] do
        "message" ->
          [{:text_start, %{item_id: item["id"]}}]

        "function_call" ->
          [
            {:tool_call_start,
             %{item_id: item["id"], call_id: item["call_id"], name: item["name"]}}
          ]

        _ ->
          []
      end
    end

    defp do_parse(%{"type" => "response.output_text.delta", "delta" => delta}),
      do: [{:text_delta, delta}]

    defp do_parse(%{"type" => "response.output_text.done", "text" => text}),
      do: [{:text_done, text}]

    defp do_parse(%{"type" => "response.function_call_arguments.delta", "delta" => delta}),
      do: [{:tool_call_delta, delta}]

    defp do_parse(%{"type" => "response.function_call_arguments.done", "arguments" => args}) do
      case Jason.decode(args) do
        {:ok, parsed_args} -> [{:tool_call_done, %{arguments: parsed_args}}]
        {:error, _} -> [{:tool_call_done, %{arguments_raw: args}}]
      end
    end

    defp do_parse(%{
           "type" => "response.output_item.done",
           "item" => %{"type" => "function_call"} = item
         }) do
      args =
        case Jason.decode(item["arguments"] || "{}") do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      [
        {:tool_call_done,
         %{
           item_id: item["id"],
           call_id: item["call_id"],
           name: item["name"],
           arguments: args
         }}
      ]
    end

    defp do_parse(%{"type" => "response.completed", "response" => resp}),
      do: [{:response_done, %{usage: Map.get(resp, "usage", %{})}}]

    defp do_parse(%{"type" => "error"} = event),
      do: [{:error, Map.get(event, "error", event)}]

    defp do_parse(_), do: []

    # Build a mock Req.Response that Req.parse_message/2 can work with
    defp build_mock_resp(ref, _caller) do
      %Req.Response{
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
    end

    # --- Scenario Implementations ---

    defp send_scenario(caller, ref, :simple_text, _model, _messages, _tools) do
      # Simulate: text_start → text_delta × 3 → text_done → response_done → done
      events = [
        sse_line("response.output_item.added", %{
          "item" => %{"type" => "message", "id" => "item_1"}
        }),
        sse_line("response.output_text.delta", %{"delta" => "Hello"}),
        sse_line("response.output_text.delta", %{"delta" => " "}),
        sse_line("response.output_text.delta", %{"delta" => "world!"}),
        sse_line("response.output_text.done", %{"text" => "Hello world!"}),
        sse_line("response.completed", %{
          "response" => %{"id" => "resp_1", "status" => "completed", "usage" => %{}}
        })
      ]

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp send_scenario(caller, ref, :tool_call, _model, messages, _tools) do
      # Check if this is the second turn (after tool result)
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        # Second turn: respond with text
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        # First turn: respond with tool call
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_tc",
              "call_id" => "call_001",
              "name" => "echo_tool"
            }
          }),
          sse_line("response.function_call_arguments.delta", %{"delta" => ~s({"input":)}),
          sse_line("response.function_call_arguments.delta", %{"delta" => ~s( "test")}),
          sse_line("response.function_call_arguments.done", %{
            "arguments" => ~s({"input": "test"})
          }),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_tc",
              "call_id" => "call_001",
              "name" => "echo_tool",
              "arguments" => ~s({"input": "test"})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_tc", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :tool_error, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_tc2",
              "call_id" => "call_err",
              "name" => "failing_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{
            "arguments" => ~s({})
          }),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_tc2",
              "call_id" => "call_err",
              "name" => "failing_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_err", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :side_effect_tool, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_side",
              "call_id" => "call_side",
              "name" => "side_effect_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_side",
              "call_id" => "call_side",
              "name" => "side_effect_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_side", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :provider_error, _model, _messages, _tools) do
      events = [
        sse_line("error", %{
          "error" => %{"message" => "Rate limited", "code" => 429}
        })
      ]

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp send_scenario(caller, ref, :slow_stream, _model, _messages, _tools) do
      # Slow stream for testing abort
      events = [
        sse_line("response.output_item.added", %{
          "item" => %{"type" => "message", "id" => "item_slow"}
        })
      ]

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      # Wait a long time before sending more (agent should abort before this)
      Process.sleep(5000)
      send(caller, {ref, :done})
    end

    defp send_scenario(caller, ref, :crashing_tool, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_crash",
              "call_id" => "call_crash",
              "name" => "crashing_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_crash",
              "call_id" => "call_crash",
              "name" => "crashing_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_crash", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :raising_tool, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_raise",
              "call_id" => "call_raise",
              "name" => "raising_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_raise",
              "call_id" => "call_raise",
              "name" => "raising_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_raise", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :parallel_mixed, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        # Three parallel tool calls: one succeeds, one fails, one crashes
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_ok",
              "call_id" => "call_ok",
              "name" => "echo_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{
            "arguments" => ~s({"input": "hello"})
          }),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_ok",
              "call_id" => "call_ok",
              "name" => "echo_tool",
              "arguments" => ~s({"input": "hello"})
            }
          }),
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_fail",
              "call_id" => "call_fail",
              "name" => "failing_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_fail",
              "call_id" => "call_fail",
              "name" => "failing_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_crash2",
              "call_id" => "call_crash2",
              "name" => "crashing_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_crash2",
              "call_id" => "call_crash2",
              "name" => "crashing_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_par", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp send_scenario(caller, ref, :timeout_tool, _model, messages, _tools) do
      has_tool_result =
        Enum.any?(messages, fn
          %Opal.Message{role: :tool_result} -> true
          _ -> false
        end)

      if has_tool_result do
        send_scenario(caller, ref, :simple_text, nil, messages, nil)
      else
        events = [
          sse_line("response.output_item.added", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_timeout",
              "call_id" => "call_timeout",
              "name" => "timeout_tool"
            }
          }),
          sse_line("response.function_call_arguments.done", %{"arguments" => ~s({})}),
          sse_line("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "id" => "item_timeout",
              "call_id" => "call_timeout",
              "name" => "timeout_tool",
              "arguments" => ~s({})
            }
          }),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_to", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
      end
    end

    defp sse_line(type, fields) do
      data = Map.merge(%{"type" => type}, fields) |> Jason.encode!()
      "data: #{data}\n"
    end
  end

  # Error-returning provider for stream failure testing
  defmodule ErrorProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      # Use a permanent (non-retryable) error so the agent gives up immediately
      {:error, "unauthorized: invalid API key"}
    end

    @impl true
    def parse_stream_event(_data), do: []

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools
  end

  # --- Test Tool Modules ---

  defmodule EchoTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "echo_tool"

    @impl true
    def description, do: "Echoes input back"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context) do
      {:ok, "Echo: #{input}"}
    end
  end

  defmodule FailingTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "failing_tool"

    @impl true
    def description, do: "Always fails"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      {:error, "Tool failed intentionally"}
    end
  end

  defmodule SlowEchoTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "echo_tool"

    @impl true
    def description, do: "Echoes input back slowly"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context) do
      # Slow enough for queued message to arrive during execution
      Process.sleep(100)
      {:ok, "Echo: #{input}"}
    end
  end

  defmodule CrashingTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "crashing_tool"

    @impl true
    def description, do: "Crashes via exit"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      exit(:tool_crash_boom)
    end
  end

  defmodule RaisingTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "raising_tool"

    @impl true
    def description, do: "Raises an exception"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      raise RuntimeError, "kaboom from tool"
    end
  end

  defmodule TimeoutTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "timeout_tool"

    @impl true
    def description, do: "Hangs for a while then returns"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      Process.sleep(200)
      {:ok, "eventually done"}
    end
  end

  defmodule SideEffectTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "side_effect_tool"

    @impl true
    def description, do: "Sleeps and then writes a side-effect marker"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      Process.sleep(300)
      :persistent_term.put({__MODULE__, :ran}, true)
      {:ok, "side effect done"}
    end
  end

  # --- Helpers ---

  defp set_scenario(scenario) do
    :persistent_term.put({TestProvider, :scenario}, scenario)
  end

  defp start_agent(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :simple_text)
    set_scenario(scenario)

    session_id = "test-#{System.unique_integer([:positive])}"

    # Start a per-test Task.Supervisor for tool execution
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: Keyword.get(opts, :working_dir, System.tmp_dir!()),
      system_prompt: Keyword.get(opts, :system_prompt, "You are a test assistant."),
      tools: Keyword.get(opts, :tools, []),
      provider: Keyword.get(opts, :provider, TestProvider),
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
    on_exit(fn ->
      :persistent_term.erase({TestProvider, :scenario})
      :persistent_term.erase({SideEffectTool, :ran})
    end)

    :ok
  end

  # ============================================================
  # Agent Lifecycle
  # ============================================================

  describe "agent lifecycle" do
    test "start_link/1 starts the agent with valid config" do
      %{pid: pid} = start_agent()
      assert Process.alive?(pid)
    end

    test "get_state/1 returns the current state" do
      %{pid: pid} = start_agent()
      state = Agent.get_state(pid)
      assert %State{} = state
    end

    test "platform/0 returns the current OS platform" do
      start_agent()
      platform = Opal.Platform.os()
      assert platform in [:linux, :macos, :windows]
    end

    test "initial status is :idle" do
      %{pid: pid} = start_agent()
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "agent has correct model from config" do
      %{pid: pid} = start_agent()
      state = Agent.get_state(pid)
      assert state.model.provider == :test
      assert state.model.id == "test-model"
    end

    test "agent has correct tools from config" do
      %{pid: pid} = start_agent(tools: [EchoTool])
      state = Agent.get_state(pid)
      assert state.tools == [EchoTool]
    end

    test "agent has correct system_prompt from config" do
      %{pid: pid} = start_agent(system_prompt: "Custom prompt")
      state = Agent.get_state(pid)
      assert state.system_prompt == "Custom prompt"
    end

    test "agent messages start empty" do
      %{pid: pid} = start_agent()
      state = Agent.get_state(pid)
      assert state.messages == []
    end
  end

  # ============================================================
  # Prompt Flow — Simple Text Response
  # ============================================================

  describe "prompt flow — simple text response" do
    test "prompt/2 returns queued status immediately" do
      %{pid: pid} = start_agent()
      assert %{queued: false} = Agent.prompt(pid, "Hello")
    end

    test "agent broadcasts {:agent_start} event" do
      %{pid: pid, session_id: sid} = start_agent()
      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
    end

    test "agent broadcasts {:message_applied, text} before {:agent_start}" do
      %{pid: pid, session_id: sid} = start_agent()
      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:message_applied, "Hello"}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
    end

    test "agent broadcasts {:message_delta, %{delta: text}} events" do
      %{pid: pid, session_id: sid} = start_agent()
      Agent.prompt(pid, "Hello")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_start}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "Hello"}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: " "}}}, 1000
      assert_receive {:opal_event, ^sid, {:message_delta, %{delta: "world!"}}}, 1000
    end

    test "agent broadcasts {:agent_end, messages, usage} when response completes" do
      %{pid: pid, session_id: sid} = start_agent()
      Agent.prompt(pid, "Hello")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 1000
      assert is_list(messages)
      assert length(messages) == 2

      [user_msg, assistant_msg] = messages
      assert user_msg.role == :user
      assert user_msg.content == "Hello"
      assert assistant_msg.role == :assistant
      assert assistant_msg.content == "Hello world!"
    end

    test "after completion, status returns to :idle" do
      %{pid: pid} = start_agent()
      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)
      assert state.status == :idle
    end

    test "messages accumulate in state" do
      %{pid: pid} = start_agent()
      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)

      messages = Enum.reverse(state.messages)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == "Hello"
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).content == "Hello world!"
    end
  end

  # ============================================================
  # Prompt Flow — With Tool Calls
  # ============================================================

  describe "prompt flow — with tool calls" do
    test "agent executes tool call and loops back to LLM" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :tool_call,
          tools: [EchoTool]
        )

      Agent.prompt(pid, "Use the tool")

      # First: agent_start
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      # Tool execution events
      assert_receive {:opal_event, ^sid, {:turn_end, _msg, []}}, 2000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_start, "echo_tool", _call_id, %{"input" => "test"}, _meta}},
                     2000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "echo_tool", _call_id2, {:ok, "Echo: test"}}},
                     2000

      # Second turn: text response
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      assert is_list(messages)
      # user + assistant(tool_call) + tool_result + assistant(text)
      assert length(messages) == 4

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :assistant, :tool_result, :assistant]
    end

    test "tool result message includes correct output" do
      %{pid: pid} =
        start_agent(
          scenario: :tool_call,
          tools: [EchoTool]
        )

      Agent.prompt(pid, "Use the tool")
      state = wait_for_idle(pid)

      tool_result_msg = Enum.find(state.messages, &(&1.role == :tool_result))
      assert tool_result_msg != nil
      assert tool_result_msg.content == "Echo: test"
      assert tool_result_msg.call_id == "call_001"
    end

    test "broadcasts tool_execution_start and tool_execution_end" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :tool_call,
          tools: [EchoTool]
        )

      Agent.prompt(pid, "Use the tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_start, "echo_tool", _call_id, _args, _meta}},
                     2000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "echo_tool", _call_id2, {:ok, _result}}},
                     2000
    end
  end

  # ============================================================
  # Abort
  # ============================================================

  describe "abort" do
    test "abort/1 while agent is idle — no-op, stays idle" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.abort(pid)

      # Should broadcast abort event
      assert_receive {:opal_event, ^sid, {:agent_abort}}, 1000
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "abort/1 while agent is running — sets status to :idle" do
      %{pid: pid, session_id: sid} = start_agent(scenario: :slow_stream)

      Agent.prompt(pid, "Start something")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      # Give it a moment to start streaming
      Process.sleep(20)

      Agent.abort(pid)
      assert_receive {:opal_event, ^sid, {:agent_abort}}, 1000

      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "abort/1 during tool execution terminates the running tool task" do
      :persistent_term.erase({SideEffectTool, :ran})

      %{pid: pid, session_id: sid} =
        start_agent(scenario: :side_effect_tool, tools: [SideEffectTool])

      Agent.prompt(pid, "Run the tool")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid, {:tool_execution_start, "side_effect_tool", _, _, _}},
                     2000

      Agent.abort(pid)
      assert_receive {:opal_event, ^sid, {:agent_abort}}, 1000

      Process.sleep(400)

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert :persistent_term.get({SideEffectTool, :ran}, false) == false
    end
  end

  # ============================================================
  # Steering
  # ============================================================

  describe "steering" do
    test "prompt/2 while idle acts like prompt" do
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Steer message")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 2000

      [user_msg | _] = messages
      assert user_msg.role == :user
      assert user_msg.content == "Steer message"
    end

    test "prompt/2 while running — message is processed" do
      # When running, prompt call is queued and picked up by
      # drain_pending_messages between tool executions.
      %{pid: pid, session_id: sid} = start_agent(scenario: :tool_call, tools: [SlowEchoTool])

      Agent.prompt(pid, "Start")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      # Wait for tool execution to start (the tool takes 100ms)
      assert_receive {:opal_event, ^sid, {:tool_execution_start, "echo_tool", _, _, _}}, 2000

      # Send prompt while tool is executing — message sits in mailbox
      Agent.prompt(pid, "Also do this")

      # Wait for completion
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      # The queued message should be in the messages (picked up by drain_pending_messages)
      steer_msgs =
        Enum.filter(messages, fn m ->
          m.role == :user && m.content == "Also do this"
        end)

      assert length(steer_msgs) == 1
    end

    test "prompt/2 while running is queued instead of starting an overlapping turn" do
      %{pid: pid, session_id: sid} = start_agent(scenario: :tool_call, tools: [SlowEchoTool])

      Agent.prompt(pid, "Start")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:tool_execution_start, "echo_tool", _, _, _}}, 2000

      Agent.prompt(pid, "Queued prompt")

      refute_receive {:opal_event, ^sid, {:agent_start}}, 300
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      queued_msgs =
        Enum.filter(messages, fn m ->
          m.role == :user && m.content == "Queued prompt"
        end)

      assert length(queued_msgs) == 1
    end
  end

  # ============================================================
  # Error Handling
  # ============================================================

  describe "error handling" do
    test "tool execution failure creates error tool_result and continues" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :tool_error,
          tools: [FailingTool]
        )

      Agent.prompt(pid, "Use the failing tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "failing_tool", _call_id,
                       {:error, "Tool failed intentionally"}}},
                     2000

      # Agent continues and eventually completes
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 3000

      tool_result_msg = Enum.find(messages, &(&1.role == :tool_result))
      assert tool_result_msg != nil
      assert tool_result_msg.is_error == true
      assert tool_result_msg.content == "Tool failed intentionally"
    end

    test "provider stream error broadcasts error event and goes idle" do
      %{pid: pid, session_id: sid} = start_agent(provider: ErrorProvider)

      Agent.prompt(pid, "This will fail")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      # Permanent errors (auth failures) are not retried — the agent
      # broadcasts the error and goes idle immediately.
      assert_receive {:opal_event, ^sid, {:error, "unauthorized: invalid API key"}}, 1000

      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "SSE error event broadcasts error and sets idle" do
      %{pid: pid, session_id: sid} = start_agent(scenario: :provider_error)

      Agent.prompt(pid, "Trigger error")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid, {:error, %{"message" => "Rate limited", "code" => 429}}},
                     1000

      # Wait a bit for the done message to be processed
      Process.sleep(50)

      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "tool not found creates error result" do
      # Use tool_call scenario but don't register the tool
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :tool_call,
          # No tools registered
          tools: []
        )

      Agent.prompt(pid, "Use missing tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "echo_tool", _call_id, {:error, "Tool not found"}}},
                     2000

      assert_receive {:opal_event, ^sid, {:agent_end, _messages, _usage}}, 3000
    end
  end

  # ============================================================
  # Tool Failure Isolation
  # ============================================================

  describe "tool failure isolation — crashing tool" do
    test "tool that exits does not crash the agent" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :crashing_tool, tools: [CrashingTool])

      Agent.prompt(pid, "Use the crashing tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      # Agent should recover and complete
      assert_receive {:opal_event, ^sid, {:agent_end, _messages, _usage}}, 5000

      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "crashing tool produces error tool_result with correct call_id" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :crashing_tool, tools: [CrashingTool])

      Agent.prompt(pid, "Crash please")

      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      tool_result = Enum.find(messages, &(&1.role == :tool_result))
      assert tool_result != nil
      assert tool_result.call_id == "call_crash"
      assert tool_result.is_error == true
      assert tool_result.content =~ "crashed"
    end

    test "agent can accept new prompts after a tool crash" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :crashing_tool, tools: [CrashingTool])

      Agent.prompt(pid, "Crash it")
      assert_receive {:opal_event, ^sid, {:agent_end, _, _}}, 5000

      # Now send a normal prompt — agent should still work
      set_scenario(:simple_text)
      Agent.prompt(pid, "Hello after crash")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 3000

      last_user = messages |> Enum.filter(&(&1.role == :user)) |> List.last()
      assert last_user.content == "Hello after crash"
    end
  end

  describe "tool failure isolation — raising tool" do
    test "tool that raises does not crash the agent" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :raising_tool, tools: [RaisingTool])

      Agent.prompt(pid, "Raise an error")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, _messages, _usage}}, 5000

      assert Process.alive?(pid)
      assert Agent.get_state(pid).status == :idle
    end

    test "raising tool produces error tool_result with exception message" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :raising_tool, tools: [RaisingTool])

      Agent.prompt(pid, "Raise please")

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "raising_tool", _call_id, {:error, error_msg}}},
                     3000

      assert error_msg =~ "kaboom from tool"

      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      tool_result = Enum.find(messages, &(&1.role == :tool_result))
      assert tool_result.call_id == "call_raise"
      assert tool_result.is_error == true
    end
  end

  describe "tool failure isolation — parallel mixed results" do
    test "successful tool results are preserved when sibling tools fail" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :parallel_mixed,
          tools: [EchoTool, FailingTool, CrashingTool]
        )

      Agent.prompt(pid, "Run all three")

      # The echo tool should succeed
      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "echo_tool", _call_id, {:ok, "Echo: hello"}}},
                     3000

      # The failing tool returns an error tuple
      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "failing_tool", _call_id,
                       {:error, "Tool failed intentionally"}}},
                     3000

      # Agent completes despite mixed results
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      tool_results =
        messages
        |> Enum.filter(&(&1.role == :tool_result))
        |> Enum.sort_by(& &1.call_id)

      assert length(tool_results) == 3

      # call_crash2 — crashed
      crash_result = Enum.find(tool_results, &(&1.call_id == "call_crash2"))
      assert crash_result.is_error == true
      assert crash_result.content =~ "crashed"

      # call_fail — returned error
      fail_result = Enum.find(tool_results, &(&1.call_id == "call_fail"))
      assert fail_result.is_error == true
      assert fail_result.content == "Tool failed intentionally"

      # call_ok — succeeded
      ok_result = Enum.find(tool_results, &(&1.call_id == "call_ok"))
      assert ok_result.is_error == false
      assert ok_result.content == "Echo: hello"
    end

    test "each tool_result preserves its correct call_id after parallel execution" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :parallel_mixed,
          tools: [EchoTool, FailingTool, CrashingTool]
        )

      Agent.prompt(pid, "Parallel test")
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _usage}}, 5000

      tool_results = Enum.filter(messages, &(&1.role == :tool_result))
      call_ids = Enum.map(tool_results, & &1.call_id) |> Enum.sort()

      assert call_ids == ["call_crash2", "call_fail", "call_ok"]
    end

    test "agent is idle and alive after parallel mixed failures" do
      %{pid: pid, session_id: sid} =
        start_agent(
          scenario: :parallel_mixed,
          tools: [EchoTool, FailingTool, CrashingTool]
        )

      Agent.prompt(pid, "Mixed parallel")
      assert_receive {:opal_event, ^sid, {:agent_end, _, _}}, 5000

      assert Process.alive?(pid)
      assert Agent.get_state(pid).status == :idle
    end
  end

  describe "tool failure isolation — slow tool" do
    test "slow tool does not prevent agent from completing" do
      %{pid: pid, session_id: sid} =
        start_agent(scenario: :timeout_tool, tools: [TimeoutTool])

      Agent.prompt(pid, "Run slow tool")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:tool_execution_end, "timeout_tool", _call_id, {:ok, "eventually done"}}},
                     5000

      assert_receive {:opal_event, ^sid, {:agent_end, _, _}}, 5000
      assert Agent.get_state(pid).status == :idle
    end
  end

  describe "tool failure isolation — session-level" do
    test "one session's crashing tool does not affect another session" do
      # Session 1: will crash a tool
      %{pid: pid1, session_id: sid1} =
        start_agent(scenario: :crashing_tool, tools: [CrashingTool])

      # Session 2: normal operation
      set_scenario(:simple_text)
      %{pid: pid2, session_id: sid2} = start_agent(scenario: :simple_text)

      # Start crash in session 1
      set_scenario(:crashing_tool)
      Agent.prompt(pid1, "Crash it")

      # Start normal work in session 2
      set_scenario(:simple_text)
      Agent.prompt(pid2, "Hello")

      # Session 2 should complete normally
      assert_receive {:opal_event, ^sid2, {:agent_end, _, _}}, 3000
      assert Process.alive?(pid2)
      assert Agent.get_state(pid2).status == :idle

      # Session 1 should also recover
      assert_receive {:opal_event, ^sid1, {:agent_end, _, _}}, 5000
      assert Process.alive?(pid1)
      assert Agent.get_state(pid1).status == :idle
    end

    test "one session's raising tool does not affect another session" do
      %{pid: pid1, session_id: sid1} =
        start_agent(scenario: :raising_tool, tools: [RaisingTool])

      set_scenario(:simple_text)
      %{pid: pid2, session_id: sid2} = start_agent(scenario: :simple_text)

      set_scenario(:raising_tool)
      Agent.prompt(pid1, "Raise it")

      set_scenario(:simple_text)
      Agent.prompt(pid2, "Normal work")

      # Session 2 completes normally despite session 1's tool raising
      assert_receive {:opal_event, ^sid2, {:agent_end, _, _}}, 3000
      assert Process.alive?(pid2)

      assert_receive {:opal_event, ^sid1, {:agent_end, _, _}}, 5000
      assert Process.alive?(pid1)
    end
  end

  # ============================================================
  # Context & Skills Integration
  # ============================================================

  describe "context integration" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opal_ctx_agent_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{ctx_dir: dir}
    end

    test "agent discovers context files and stores in state", %{ctx_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Always be concise.")

      %{pid: pid} = start_agent(working_dir: dir)
      state = Agent.get_state(pid)
      assert Enum.any?(state.context_entries, &(&1.content =~ "Always be concise."))
    end

    test "agent discovers skills and includes summaries in context", %{ctx_dir: dir} do
      skills_dir = Path.join([dir, ".agents", "skills", "my-skill"])
      File.mkdir_p!(skills_dir)

      File.write!(Path.join(skills_dir, "SKILL.md"), """
      ---
      name: my-skill
      description: A helpful testing skill.
      ---

      Detailed instructions.
      """)

      %{pid: pid} = start_agent(working_dir: dir)
      state = Agent.get_state(pid)

      assert Enum.any?(state.context_entries, &(&1.content =~ "my-skill")) or
               Enum.any?(state.available_skills, &(&1.name == "my-skill"))

      assert Enum.any?(state.available_skills, &(&1.description =~ "A helpful testing skill."))
    end

    test "context is empty when no files or skills exist", %{ctx_dir: dir} do
      %{pid: pid} = start_agent(working_dir: dir)
      state = Agent.get_state(pid)
      assert state.context_entries == []
    end

    test "context is injected into system prompt messages", %{ctx_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "Project-specific instructions.")

      %{pid: pid} =
        start_agent(
          working_dir: dir,
          system_prompt: "You are a test bot."
        )

      Agent.prompt(pid, "Hello")
      state = wait_for_idle(pid)

      # The system message should contain both the original prompt and the context
      # Context entries are formatted into the system prompt by SystemPrompt.build/1
      context_text =
        state.context_entries
        |> Enum.map_join("\n", & &1.content)

      assert context_text =~ "Project-specific instructions."
    end
  end
end
