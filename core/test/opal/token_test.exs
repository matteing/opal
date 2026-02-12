defmodule Opal.TokenTest do
  use ExUnit.Case, async: true

  alias Opal.Token
  alias Opal.Message

  # -- estimate/1 -------------------------------------------------------------

  describe "estimate/1" do
    test "returns 0 for nil" do
      assert Token.estimate(nil) == 0
    end

    test "returns 0 for empty string" do
      assert Token.estimate("") == 0
    end

    test "estimates ~1 token per 4 characters" do
      # 12 bytes / 4 = 3
      assert Token.estimate("hello world!") == 3
    end

    test "uses byte_size not String.length for estimation" do
      # Multi-byte UTF-8: "café" is 5 bytes (é = 2 bytes), 5/4 = 1
      assert Token.estimate("café") == 1
    end

    test "handles large strings" do
      text = String.duplicate("x", 4000)
      assert Token.estimate(text) == 1000
    end
  end

  # -- estimate_message/1 ----------------------------------------------------

  describe "estimate_message/1" do
    test "simple user message" do
      msg = Message.user("Hello, how are you?")
      result = Token.estimate_message(msg)

      # Content tokens + overhead
      assert result > 0
      assert result >= 10  # at least the overhead
    end

    test "assistant message with tool calls" do
      tc = %{call_id: "c1", name: "read_file", arguments: %{"path" => "test.txt"}}
      msg = Message.assistant("Let me read that.", [tc])
      result = Token.estimate_message(msg)

      # Should include content + tool call tokens + overhead
      assert result > Token.estimate("Let me read that.")
    end

    test "message with nil tool_calls" do
      msg = %Message{id: "test", role: :user, content: "hello", tool_calls: nil}
      result = Token.estimate_message(msg)
      assert result > 0
    end

    test "message with empty tool_calls list" do
      msg = %Message{id: "test", role: :assistant, content: "ok", tool_calls: []}
      result = Token.estimate_message(msg)
      assert result > 0
    end

    test "message with nil content" do
      msg = %Message{id: "test", role: :assistant, content: nil, tool_calls: nil}
      result = Token.estimate_message(msg)
      # Should still have overhead
      assert result == 10
    end
  end

  # -- estimate_context/1 ----------------------------------------------------

  describe "estimate_context/1" do
    test "returns 0 for empty list" do
      assert Token.estimate_context([]) == 0
    end

    test "sums estimates for multiple messages" do
      msgs = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      total = Token.estimate_context(msgs)
      individual = Enum.sum(Enum.map(msgs, &Token.estimate_message/1))
      assert total == individual
    end

    test "handles large message lists" do
      msgs = for _ <- 1..100, do: Message.user("Test message content here")
      result = Token.estimate_context(msgs)
      assert result > 0
    end
  end

  # -- hybrid_estimate/2 -----------------------------------------------------

  describe "hybrid_estimate/2" do
    test "returns base tokens when no new messages" do
      assert Token.hybrid_estimate(50_000, []) == 50_000
    end

    test "adds trailing estimates to base tokens" do
      trailing = [
        Message.user("New user message"),
        Message.assistant("New response")
      ]

      result = Token.hybrid_estimate(50_000, trailing)
      assert result > 50_000
      assert result == 50_000 + Token.estimate_context(trailing)
    end

    test "works with zero base tokens (fresh session)" do
      msgs = [Message.user("First message")]
      result = Token.hybrid_estimate(0, msgs)
      assert result == Token.estimate_context(msgs)
    end

    test "produces reasonable estimates for tool-heavy conversations" do
      # Simulate a turn with several tool results
      tool_results =
        for i <- 1..5 do
          content = String.duplicate("output line #{i}\n", 50)
          Message.tool_result("call_#{i}", content)
        end

      result = Token.hybrid_estimate(100_000, tool_results)
      # Should be noticeably higher than the base
      assert result > 100_000
      assert result < 200_000
    end
  end
end
