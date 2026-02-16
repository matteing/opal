defmodule Opal.Agent.UsageTrackerTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.State
  alias Opal.Agent.UsageTracker

  describe "update_usage/2" do
    setup do
      session_id = "usage-tracker-#{System.unique_integer([:positive])}"
      Opal.Events.subscribe(session_id)

      state = %State{
        session_id: session_id,
        model: Opal.Provider.Model.coerce({:copilot, "claude-sonnet-4"}),
        working_dir: File.cwd!(),
        config: Opal.Config.new(),
        messages: []
      }

      %{state: state}
    end

    test "extracts Chat Completions keys (prompt_tokens, completion_tokens)", %{state: state} do
      usage = %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
      result = UsageTracker.update_usage(usage, state)

      assert result.token_usage.prompt_tokens == 100
      assert result.token_usage.completion_tokens == 50
      assert result.token_usage.total_tokens == 150
      assert result.last_prompt_tokens == 100
    end

    test "extracts Responses API keys (input_tokens, output_tokens)", %{state: state} do
      usage = %{"input_tokens" => 200, "output_tokens" => 80}
      result = UsageTracker.update_usage(usage, state)

      assert result.token_usage.prompt_tokens == 200
      assert result.token_usage.completion_tokens == 80
      assert result.last_prompt_tokens == 200
    end

    test "handles atom keys", %{state: state} do
      usage = %{prompt_tokens: 300, completion_tokens: 100, total_tokens: 400}
      result = UsageTracker.update_usage(usage, state)

      assert result.token_usage.prompt_tokens == 300
      assert result.token_usage.completion_tokens == 100
      assert result.token_usage.total_tokens == 400
    end

    test "handles nil values in usage", %{state: state} do
      usage = %{"prompt_tokens" => nil, "completion_tokens" => nil, "total_tokens" => nil}
      result = UsageTracker.update_usage(usage, state)

      assert result.token_usage.prompt_tokens == 0
      assert result.token_usage.completion_tokens == 0
      assert result.token_usage.total_tokens == 0
    end

    test "handles empty usage map", %{state: state} do
      result = UsageTracker.update_usage(%{}, state)

      assert result.token_usage.prompt_tokens == 0
      assert result.token_usage.completion_tokens == 0
      assert result.token_usage.total_tokens == 0
    end

    test "accumulates across multiple calls", %{state: state} do
      usage1 = %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
      usage2 = %{"prompt_tokens" => 200, "completion_tokens" => 80, "total_tokens" => 280}

      state = UsageTracker.update_usage(usage1, state)
      state = UsageTracker.update_usage(usage2, state)

      assert state.token_usage.prompt_tokens == 300
      assert state.token_usage.completion_tokens == 130
      assert state.token_usage.total_tokens == 430
      # last_prompt_tokens is the most recent, not cumulative
      assert state.last_prompt_tokens == 200
    end

    test "broadcasts usage_update event", %{state: state} do
      usage = %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
      _result = UsageTracker.update_usage(usage, state)

      assert_receive {:opal_event, _, {:usage_update, update}}
      assert update.prompt_tokens == 100
      assert update.completion_tokens == 50
    end

    test "sets last_usage_msg_index to current message count", %{state: state} do
      messages = [Opal.Message.user("a"), Opal.Message.user("b")]
      state = %{state | messages: messages}
      usage = %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}

      result = UsageTracker.update_usage(usage, state)
      assert result.last_usage_msg_index == 2
    end
  end

  describe "maybe_auto_compact/1" do
    test "returns state unchanged when session is nil" do
      state = %State{
        session: nil,
        session_id: "no-session-#{System.unique_integer([:positive])}",
        model: Opal.Provider.Model.coerce({:copilot, "claude-sonnet-4"}),
        working_dir: File.cwd!(),
        config: Opal.Config.new()
      }

      assert UsageTracker.maybe_auto_compact(state) == state
    end
  end

  describe "handle_overflow_compaction/2 without session" do
    test "returns noreply with idle status and broadcasts error" do
      session_id = "overflow-test-#{System.unique_integer([:positive])}"
      Opal.Events.subscribe(session_id)

      state = %State{
        session: nil,
        session_id: session_id,
        model: Opal.Provider.Model.coerce({:copilot, "claude-sonnet-4"}),
        working_dir: File.cwd!(),
        config: Opal.Config.new(%{features: %{debug: %{enabled: true}}})
      }

      {:noreply, new_state} = UsageTracker.handle_overflow_compaction(state, :overflow)
      assert new_state.status == :idle
      assert_receive {:opal_event, ^session_id, {:error, {:overflow_no_session, :overflow}}}
    end
  end

  describe "estimate_current_tokens/2" do
    test "uses heuristic when no usage data" do
      state = %State{
        session_id: "est-#{System.unique_integer([:positive])}",
        model: Opal.Provider.Model.coerce({:copilot, "claude-sonnet-4"}),
        working_dir: File.cwd!(),
        config: Opal.Config.new(),
        messages: [Opal.Message.user("Hello")]
      }

      estimate = UsageTracker.estimate_current_tokens(state, 128_000)
      assert is_integer(estimate) and estimate > 0
    end

    test "uses hybrid estimate when usage data exists" do
      state = %State{
        session_id: "est-#{System.unique_integer([:positive])}",
        model: Opal.Provider.Model.coerce({:copilot, "claude-sonnet-4"}),
        working_dir: File.cwd!(),
        config: Opal.Config.new(),
        messages: [Opal.Message.user("Hello"), Opal.Message.assistant("Hi")],
        last_prompt_tokens: 500,
        last_usage_msg_index: 1
      }

      estimate = UsageTracker.estimate_current_tokens(state, 128_000)
      # Should be at least the base prompt tokens
      assert estimate >= 500
    end
  end
end
