defmodule Opal.Agent.ProviderErrorsTest do
  @moduledoc """
  Tests that the agent correctly classifies and handles provider failures:
  transient → retry, permanent → idle, overflow → compact, stream interruption.
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model

  # ── Providers ──────────────────────────────────────────────────────────

  # Provider that always returns an error (configurable via persistent_term)
  defmodule ErrorProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      error = :persistent_term.get({__MODULE__, :error}, "unknown error")
      {:error, error}
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # Provider that fails N times then succeeds
  defmodule FlakeyProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      fail_count = :persistent_term.get({__MODULE__, :fail_count}, 1)
      error = :persistent_term.get({__MODULE__, :error}, "429 Too Many Requests")
      counter_key = {__MODULE__, :call_counter}
      count = :persistent_term.get(counter_key, 0) + 1
      :persistent_term.put(counter_key, count)

      if count <= fail_count do
        {:error, error}
      else
        Opal.Test.FixtureHelper.build_fixture_response("responses_api_text.json")
      end
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # Provider that starts streaming then abruptly dies
  defmodule StreamCrashProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
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
        Process.sleep(5)
        # Send one partial event then crash (no :done)
        event =
          "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}})}\n"

        send(caller, {ref, {:data, event}})
        Process.sleep(5)

        delta =
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "partial"})}\n"

        send(caller, {ref, {:data, delta}})
        # Simulate abrupt stream death — no :done sent, process exits
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

  # ── Setup ──────────────────────────────────────────────────────────────

  defp start_agent(opts \\ []) do
    provider = Keyword.get(opts, :provider, ErrorProvider)
    session_id = "provider-err-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts =
      [
        session_id: session_id,
        model: Model.new(:test, "test-model"),
        working_dir: System.tmp_dir!(),
        system_prompt: "Test",
        tools: Keyword.get(opts, :tools, []),
        provider: provider,
        tool_supervisor: tool_sup,
        config: Keyword.get(opts, :config, Opal.Config.new())
      ] ++ Keyword.take(opts, [:session])

    {:ok, pid} = Agent.start_link(agent_opts)

    # Override retry delays for fast tests (State defaults are 2s/60s)
    if Keyword.has_key?(opts, :max_retries) or Keyword.has_key?(opts, :retry_base_delay_ms) do
      :sys.replace_state(pid, fn {state_name, state} ->
        state =
          state
          |> then(fn s ->
            if r = Keyword.get(opts, :max_retries), do: %{s | max_retries: r}, else: s
          end)
          |> then(fn s ->
            if d = Keyword.get(opts, :retry_base_delay_ms),
              do: %{s | retry_base_delay_ms: d},
              else: s
          end)
          |> then(fn s ->
            if d = Keyword.get(opts, :retry_max_delay_ms),
              do: %{s | retry_max_delay_ms: d},
              else: s
          end)

        {state_name, state}
      end)
    end

    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
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

  defp collect_events(session_id, timeout) do
    collect_events_loop(session_id, timeout, [])
  end

  defp collect_events_loop(session_id, timeout, acc) do
    receive do
      {:opal_event, ^session_id, _event} = msg ->
        collect_events_loop(session_id, timeout, [msg | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  setup do
    on_exit(fn ->
      for mod <- [ErrorProvider, FlakeyProvider, StreamCrashProvider] do
        for key <- [:error, :fixture, :fail_count, :call_counter] do
          try do
            :persistent_term.erase({mod, key})
          rescue
            _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "transient error → retry with backoff" do
    @tag timeout: 15_000
    test "agent retries on 429 and broadcasts retry events" do
      :persistent_term.put({FlakeyProvider, :fail_count}, 2)
      :persistent_term.put({FlakeyProvider, :error}, "429 Too Many Requests")
      :persistent_term.put({FlakeyProvider, :call_counter}, 0)

      %{pid: pid, session_id: sid} =
        start_agent(
          provider: FlakeyProvider,
          max_retries: 5,
          retry_base_delay_ms: 50,
          retry_max_delay_ms: 200
        )

      Agent.prompt(pid, "Hello")

      # Should receive retry events, then eventually succeed
      events = collect_events(sid, 10_000)
      event_types = for {:opal_event, _, ev} <- events, do: elem(ev, 0)

      assert :retry in event_types, "Expected retry event, got: #{inspect(event_types)}"
      assert :agent_end in event_types, "Expected agent_end after recovery"

      state = Agent.get_state(pid)
      assert state.status == :idle
      assert state.retry_count == 0, "retry_count should reset after success"
    end
  end

  describe "max retries exhausted → idle with error" do
    @tag timeout: 15_000
    test "agent goes idle after max retries with transient error" do
      :persistent_term.put({ErrorProvider, :error}, "503 Service Unavailable")

      %{pid: pid, session_id: sid} =
        start_agent(
          max_retries: 2,
          retry_base_delay_ms: 20,
          retry_max_delay_ms: 50
        )

      Agent.prompt(pid, "Hello")

      events = collect_events(sid, 10_000)
      event_types = for {:opal_event, _, ev} <- events, do: elem(ev, 0)

      retry_events = Enum.filter(events, fn {:opal_event, _, ev} -> elem(ev, 0) == :retry end)
      assert length(retry_events) == 2, "Expected 2 retry attempts, got #{length(retry_events)}"

      assert :error in event_types, "Expected error event after exhausting retries"

      state = Agent.get_state(pid)
      assert state.status == :idle
    end
  end

  describe "permanent error → immediate idle" do
    test "context_length_exceeded is not retried" do
      :persistent_term.put({ErrorProvider, :error}, "context_length_exceeded")
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      events = collect_events(sid, 2000)
      event_types = for {:opal_event, _, ev} <- events, do: elem(ev, 0)

      # context_length_exceeded goes to overflow path, not retry path
      # Without a session, it surfaces as an error
      refute :retry in event_types, "Permanent error should not trigger retry"

      state = wait_for_idle(pid)
      assert state.status == :idle
    end

    test "unauthorized error goes straight to error" do
      :persistent_term.put({ErrorProvider, :error}, "unauthorized")
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      events = collect_events(sid, 2000)
      event_types = for {:opal_event, _, ev} <- events, do: elem(ev, 0)

      assert :error in event_types
      refute :retry in event_types
    end
  end

  describe "context overflow → compaction" do
    test "overflow without session surfaces raw error" do
      :persistent_term.put({ErrorProvider, :error}, "context_length_exceeded")
      %{pid: pid, session_id: sid} = start_agent()

      Agent.prompt(pid, "Hello")
      events = collect_events(sid, 2000)
      event_types = for {:opal_event, _, ev} <- events, do: elem(ev, 0)

      assert :error in event_types
      state = wait_for_idle(pid)
      assert state.status == :idle
    end
  end

  describe "stale retry after abort" do
    @tag timeout: 10_000
    test "retry_turn fired after abort is discarded" do
      :persistent_term.put({ErrorProvider, :error}, "429 Too Many Requests")

      %{pid: pid, session_id: sid} =
        start_agent(
          max_retries: 3,
          retry_base_delay_ms: 500,
          retry_max_delay_ms: 1000
        )

      Agent.prompt(pid, "Hello")

      # Wait for retry event (agent is now waiting for timer)
      assert_receive {:opal_event, ^sid, {:retry, 1, _delay, _reason}}, 3000

      # Abort while retry timer is pending
      Agent.abort(pid)

      # Wait for the retry timer to fire
      Process.sleep(800)

      # Agent should still be idle (timer discarded)
      state = Agent.get_state(pid)
      assert state.status == :idle
      assert Process.alive?(pid)
    end
  end

  describe "stream interruption mid-response" do
    @tag timeout: 30_000
    test "stream dies without :done, agent stays alive and can be aborted" do
      %{pid: pid, session_id: sid} = start_agent(provider: StreamCrashProvider)

      Agent.prompt(pid, "Hello")

      # Wait for streaming to start and data to arrive
      assert_receive {:opal_event, ^sid, {:message_delta, _}}, 5000

      # The stream sent partial data then the spawned process exited (no :done).
      # Agent should still be alive — stuck in :streaming
      Process.sleep(100)
      assert Process.alive?(pid)
      state = Agent.get_state(pid)
      assert state.status == :streaming

      # Rather than waiting for the slow watchdog, just abort to recover
      Agent.abort(pid)
      state = Agent.get_state(pid)
      assert state.status == :idle
      assert Process.alive?(pid)
    end
  end
end
