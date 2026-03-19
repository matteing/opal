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
      tag_buffers: %{}
    }
  end

  defp msg(data), do: [%ReqSSE.Message{data: data}]

  describe "malformed SSE JSON" do
    test "invalid JSON is silently ignored" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg("{invalid json!!!}"), state)

      assert result.current_text == ""
      assert result.current_tool_calls == []
    end

    test "truncated JSON is ignored" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg(~s|{"type": "response.output_text.del|), state)
      assert result.current_text == ""
    end

    test "empty data is ignored" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg(""), state)
      assert result.current_text == ""
    end

    test "DONE marker is handled" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg("[DONE]"), state)
      assert result.current_text == ""
    end
  end

  describe "unknown event type" do
    test "unknown event type is silently ignored" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg(Jason.encode!(%{"type" => "response.unknown_event", "data" => "foo"})), state)
      assert result.current_text == ""
    end

    test "event with missing type field is ignored" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg(Jason.encode!(%{"no_type" => true})), state)
      assert result.current_text == ""
    end
  end

  describe "out-of-order events" do
    test "text delta before output_item.added still accumulates" do
      state = base_state()
      result = Stream.dispatch_sse_messages(msg(Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "hello"})), state)
      assert result.current_text == "hello"
    end

    test "tool_call_done without tool_call_start handles gracefully" do
      state = base_state()

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

      result = Stream.dispatch_sse_messages(msg(Jason.encode!(done)), state)
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

      result = Stream.dispatch_sse_messages(msg(Jason.encode!(completed)), state)
      assert result.current_text == ""
      assert result.current_tool_calls == []
    end
  end

  describe "multiple messages in single delivery" do
    test "processes multiple SSE messages in order" do
      state = base_state()

      messages = [
        %ReqSSE.Message{data: Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}})},
        %ReqSSE.Message{data: Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Hello "})},
        %ReqSSE.Message{data: Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "world"})}
      ]

      result = Stream.dispatch_sse_messages(messages, state)
      assert result.current_text == "Hello world"
    end
  end
end
