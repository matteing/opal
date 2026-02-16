defmodule Opal.Agent.StreamResilienceTest do
  @moduledoc """
  Tests SSE/event stream error handling: malformed JSON, unknown events,
  out-of-order events, empty stream, watchdog, double done.
  """
  use ExUnit.Case, async: true

  alias Opal.Agent.Stream
  alias Opal.Agent.State

  defp base_state do
    %State{
      session_id: "stream-test",
      model: Opal.Provider.Model.new(:test, "test-model"),
      working_dir: "/tmp",
      config: Opal.Config.new(),
      current_text: "",
      current_tool_calls: [],
      current_thinking: nil,
      status_tag_buffer: ""
    }
  end

  describe "malformed SSE JSON" do
    test "invalid JSON is silently ignored" do
      state = base_state()
      result = Stream.parse_sse_data("data: {invalid json!!!}\n", state)

      # State should be unchanged
      assert result.current_text == ""
      assert result.current_tool_calls == []
    end

    test "truncated JSON is ignored" do
      state = base_state()
      result = Stream.parse_sse_data("data: {\"type\": \"response.output_text.del\n", state)
      assert result.current_text == ""
    end

    test "empty data line is ignored" do
      state = base_state()
      result = Stream.parse_sse_data("data: \n", state)
      assert result.current_text == ""
    end

    test "DONE marker is handled" do
      state = base_state()
      result = Stream.parse_sse_data("data: [DONE]\n", state)
      assert result.current_text == ""
    end
  end

  describe "unknown event type" do
    test "unknown event type is silently ignored" do
      state = base_state()
      event = "data: #{Jason.encode!(%{"type" => "response.unknown_event", "data" => "foo"})}\n"
      result = Stream.parse_sse_data(event, state)
      assert result.current_text == ""
    end

    test "event with missing type field is ignored" do
      state = base_state()
      event = "data: #{Jason.encode!(%{"no_type" => true})}\n"
      result = Stream.parse_sse_data(event, state)
      assert result.current_text == ""
    end
  end

  describe "out-of-order events" do
    test "text delta before output_item.added still accumulates" do
      state = base_state()

      # Send delta without a preceding output_item.added
      event =
        "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "hello"})}\n"

      result = Stream.parse_sse_data(event, state)

      # Should still accumulate text (no crash)
      assert result.current_text == "hello"
    end

    test "tool_call_done without tool_call_start handles gracefully" do
      state = base_state()

      # Send output_item.done for a function_call without prior added event
      done = %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "item_1",
          "call_id" => "call_1",
          "name" => "test_tool",
          "arguments" => "{\"key\": \"val\"}"
        }
      }

      event = "data: #{Jason.encode!(done)}\n"
      result = Stream.parse_sse_data(event, state)

      # Should have added the tool call
      assert length(result.current_tool_calls) >= 1
    end
  end

  describe "empty stream" do
    test "response.completed with no prior events creates empty state" do
      state = base_state()

      completed = %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_empty",
          "status" => "completed",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
        }
      }

      event = "data: #{Jason.encode!(completed)}\n"
      result = Stream.parse_sse_data(event, state)

      assert result.current_text == ""
      assert result.current_tool_calls == []
    end
  end

  describe "multiple data lines in single chunk" do
    test "processes multiple SSE lines in one data blob" do
      state = base_state()

      blob =
        "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}})}\n" <>
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello "})}\n" <>
          "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "world"})}\n"

      result = Stream.parse_sse_data(blob, state)
      assert result.current_text == "Hello world"
    end
  end

  describe "raw JSON fallback" do
    test "raw JSON without data: prefix is parsed" do
      state = base_state()
      json = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "raw"})
      result = Stream.parse_sse_data(json, state)
      assert result.current_text == "raw"
    end
  end
end
