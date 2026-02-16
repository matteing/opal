defmodule Opal.Agent.AbortResilienceTest do
  @moduledoc """
  Tests abort/steer during every agent state and race conditions between
  concurrent signals: abort during streaming, tools, idle; steering
  during streaming; double abort; abort+retry race.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model
  alias Opal.Test.FixtureHelper

  # ── Providers ──────────────────────────────────────────────────────────

  # Slow provider — delays before sending events
  defmodule SlowProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      delay = :persistent_term.get({__MODULE__, :delay}, 2000)
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
          sse(%{
            "type" => "response.output_item.added",
            "item" => %{"type" => "message"}
          }),
          sse(%{"type" => "response.output_text.delta", "delta" => "Slow response"}),
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_slow",
              "status" => "completed",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            }
          })
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

    defp sse(map), do: "data: #{Jason.encode!(map)}\n"
  end

  # Provider that returns tool calls, then text
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
          send_text(caller, ref, "Done")
        else
          send_tool_call(caller, ref)
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

    defp send_tool_call(caller, ref) do
      added =
        sse(%{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "id" => "item_1",
            "call_id" => "call_1",
            "name" => "slow_tool"
          }
        })

      done =
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "id" => "item_1",
            "call_id" => "call_1",
            "name" => "slow_tool",
            "arguments" => Jason.encode!(%{"id" => "a", "sleep_ms" => 5000})
          }
        })

      completed =
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_tool",
            "status" => "completed",
            "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
          }
        })

      for event <- [added, done, completed] do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp send_text(caller, ref, text) do
      events = [
        sse(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}}),
        sse(%{"type" => "response.output_text.delta", "delta" => text}),
        sse(%{
          "type" => "response.completed",
          "response" => %{"id" => "resp_d", "status" => "completed", "usage" => %{}}
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

  # Fast provider for quick turns
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

  # Error provider for retry+abort test
  defmodule RetryErrorProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      {:error, "429 Too Many Requests"}
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # ── Tools ──────────────────────────────────────────────────────────────

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

  # ── Setup ──────────────────────────────────────────────────────────────

  defp start_agent(opts \\ []) do
    provider = Keyword.get(opts, :provider, SlowProvider)
    session_id = "abort-#{System.unique_integer([:positive])}"
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

    # Override retry config for fast tests
    if Keyword.has_key?(opts, :retry_base_delay_ms) do
      :sys.replace_state(pid, fn {state_name, state} ->
        state = %{
          state
          | retry_base_delay_ms: Keyword.get(opts, :retry_base_delay_ms, 2000),
            retry_max_delay_ms: Keyword.get(opts, :retry_max_delay_ms, 60_000),
            max_retries: Keyword.get(opts, :max_retries, 3)
        }

        {state_name, state}
      end)
    end

    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  setup do
    on_exit(fn ->
      for mod <- [SlowProvider, ToolProvider] do
        try do
          :persistent_term.erase({mod, :delay})
        rescue
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "abort during streaming" do
    @tag timeout: 10_000
    test "cancels stream, clears watchdog, returns to idle" do
      :persistent_term.put({SlowProvider, :delay}, 2000)
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Wait for streaming to begin
      Process.sleep(50)
      state = Agent.get_state(pid)
      # Agent should be running or streaming
      assert state.status in [:running, :streaming]

      Agent.abort(pid)
      assert_receive {:opal_event, ^sid, {:agent_abort}}, 2000

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert state.streaming_resp == nil
      assert state.streaming_ref == nil
      assert state.stream_watchdog == nil
    end
  end

  describe "abort during tool execution" do
    @tag timeout: 10_000
    test "kills running tools and transitions to idle" do
      %{pid: pid, session_id: sid} =
        start_agent(provider: ToolProvider, tools: [SlowTool])

      Agent.prompt(pid, "Run tool")

      # Wait for tool to start executing
      assert_receive {:opal_event, ^sid, {:tool_execution_start, "slow_tool", _, _, _}}, 5000

      Agent.abort(pid)
      assert_receive {:opal_event, ^sid, {:agent_abort}}, 2000

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert map_size(state.pending_tool_tasks) == 0
    end
  end

  describe "abort while idle" do
    test "no-op — agent stays idle" do
      %{pid: pid} = start_agent()

      Agent.abort(pid)
      Process.sleep(50)

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert Process.alive?(pid)
    end
  end

  describe "steer during streaming" do
    @tag timeout: 10_000
    test "steer is queued and drained at turn boundary" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent(provider: FastProvider)

      Agent.prompt(pid, "Hello")

      # Send steer while agent is processing
      Agent.steer(pid, "Focus on tests")

      # Wait for completion
      assert_receive {:opal_event, ^sid, {:agent_end, _msgs, _usage}}, 5000

      state = Agent.get_state(pid)
      assert state.status == :idle
      # Steers should have been consumed (either queued & drained, or triggered new turn)
      assert state.pending_steers == []
    end
  end

  describe "abort + retry timer race" do
    @tag timeout: 10_000
    test "retry_turn after abort is silently discarded" do
      %{pid: pid, session_id: sid} =
        start_agent(
          provider: RetryErrorProvider,
          retry_base_delay_ms: 500,
          retry_max_delay_ms: 1000,
          max_retries: 3
        )

      Agent.prompt(pid, "Hello")

      # Wait for first retry event
      assert_receive {:opal_event, ^sid, {:retry, 1, _delay, _reason}}, 3000

      # Abort while waiting for retry timer
      Agent.abort(pid)
      Process.sleep(50)

      state_after_abort = Agent.get_state(pid)
      assert state_after_abort.status == :idle

      # Wait for timer to fire
      Process.sleep(800)

      # Agent should still be idle (timer discarded)
      state_after_timer = Agent.get_state(pid)
      assert state_after_timer.status == :idle
      assert Process.alive?(pid)
    end
  end

  describe "double abort" do
    @tag timeout: 10_000
    test "two rapid aborts don't crash" do
      :persistent_term.put({SlowProvider, :delay}, 2000)
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      Agent.abort(pid)
      Agent.abort(pid)

      Process.sleep(100)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  describe "prompt while busy" do
    @tag timeout: 10_000
    test "prompt during streaming is queued as steer" do
      :persistent_term.put({SlowProvider, :delay}, 500)
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "First")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 2000

      # Send another prompt while the first is being processed
      Agent.prompt(pid, "Second while busy")

      # Wait for the first to complete
      Process.sleep(2000)

      state = Agent.get_state(pid)
      # The queued prompt should have been drained (it acts like a steer)
      assert state.pending_steers == []
    end
  end
end
