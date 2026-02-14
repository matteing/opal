defmodule Opal.Agent.StreamTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.State
  alias Opal.Agent.Stream
  alias Opal.Model

  defp base_state do
    %State{
      session_id: "stream-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: Opal.Config.new()
    }
  end

  describe "tool call accumulation" do
    test "keeps interleaved deltas separated by tool identifier" do
      state =
        base_state()
        |> apply_event({:tool_call_start, %{call_id: "call_a", call_index: 0, name: "sub_agent"}})
        |> apply_event({:tool_call_start, %{call_id: "call_b", call_index: 1, name: "sub_agent"}})
        |> apply_event({:tool_call_delta, %{call_index: 0, delta: "A0"}})
        |> apply_event({:tool_call_delta, %{call_index: 1, delta: "B0"}})
        |> apply_event({:tool_call_delta, %{call_index: 0, delta: "A1"}})
        |> apply_event({:tool_call_delta, %{call_index: 1, delta: "B1"}})

      call_a = Enum.find(state.current_tool_calls, &(&1.call_id == "call_a"))
      call_b = Enum.find(state.current_tool_calls, &(&1.call_id == "call_b"))

      assert call_a.arguments_json == "A0A1"
      assert call_b.arguments_json == "B0B1"
    end

    test "matches done events by call_id instead of stack order" do
      state =
        base_state()
        |> apply_event({:tool_call_start, %{call_id: "call_a", call_index: 0, name: "sub_agent"}})
        |> apply_event({:tool_call_start, %{call_id: "call_b", call_index: 1, name: "sub_agent"}})
        |> apply_event(
          {:tool_call_done, %{call_id: "call_a", arguments: %{"prompt" => "Task A"}}}
        )
        |> apply_event(
          {:tool_call_done, %{call_id: "call_b", arguments: %{"prompt" => "Task B"}}}
        )

      call_a = Enum.find(state.current_tool_calls, &(&1.call_id == "call_a"))
      call_b = Enum.find(state.current_tool_calls, &(&1.call_id == "call_b"))

      assert call_a.arguments == %{"prompt" => "Task A"}
      assert call_b.arguments == %{"prompt" => "Task B"}
    end
  end

  defp apply_event(state, event), do: Stream.handle_stream_event(event, state)
end
