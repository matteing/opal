defmodule Opal.Agent.CompactionTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Compaction
  alias Opal.Agent.State
  alias Opal.Model

  defp base_state do
    %State{
      session_id: "comp-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: Opal.Config.new()
    }
  end

  describe "update_usage/2" do
    test "stores prompt and completion tokens" do
      usage = %{"prompt_tokens" => 100, "completion_tokens" => 50}
      state = Compaction.update_usage(usage, base_state())
      assert state.token_usage.prompt_tokens == 100
      assert state.token_usage.completion_tokens == 50
    end

    test "accumulates usage across multiple calls" do
      usage1 = %{"prompt_tokens" => 100, "completion_tokens" => 50}
      usage2 = %{"prompt_tokens" => 200, "completion_tokens" => 80}

      state = Compaction.update_usage(usage1, base_state())
      state = Compaction.update_usage(usage2, state)

      assert state.token_usage.prompt_tokens == 300
      assert state.token_usage.completion_tokens == 130
    end
  end

  describe "maybe_auto_compact/1" do
    test "returns state unchanged when under threshold" do
      state = base_state()
      assert Compaction.maybe_auto_compact(state) == state
    end
  end
end
