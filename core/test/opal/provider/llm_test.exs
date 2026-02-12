defmodule Opal.Provider.LLMTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.LLM
  alias Opal.Message
  alias Opal.Model

  # --- Test Tool Module ---

  defmodule TestTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "test_tool"

    @impl true
    def description, do: "A test tool for unit testing"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Test input"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context) do
      {:ok, "Result: #{input}"}
    end
  end

  # ============================================================
  # parse_stream_event/1 — Opal bridge format
  # ============================================================

  describe "parse_stream_event/1 — text events" do
    test "text_start event" do
      data = Jason.encode!(%{"_opal" => "text_start", "info" => %{}})
      assert [{:text_start, %{}}] = LLM.parse_stream_event(data)
    end

    test "text_delta event" do
      data = Jason.encode!(%{"_opal" => "text_delta", "text" => "Hello, world!"})
      assert [{:text_delta, "Hello, world!"}] = LLM.parse_stream_event(data)
    end

    test "text_delta with empty string" do
      data = Jason.encode!(%{"_opal" => "text_delta", "text" => ""})
      assert [{:text_delta, ""}] = LLM.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — thinking events" do
    test "thinking_start event" do
      data = Jason.encode!(%{"_opal" => "thinking_start", "info" => %{}})
      assert [{:thinking_start, %{}}] = LLM.parse_stream_event(data)
    end

    test "thinking_delta event" do
      data = Jason.encode!(%{"_opal" => "thinking_delta", "text" => "Let me think..."})
      assert [{:thinking_delta, "Let me think..."}] = LLM.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — tool call events" do
    test "tool_call_start event" do
      data = Jason.encode!(%{"_opal" => "tool_call_start", "call_id" => "call_123", "name" => "read_file"})
      assert [{:tool_call_start, %{call_id: "call_123", name: "read_file"}}] = LLM.parse_stream_event(data)
    end

    test "tool_call_delta event" do
      data = Jason.encode!(%{"_opal" => "tool_call_delta", "text" => "{\"path\":"})
      assert [{:tool_call_delta, "{\"path\":"}] = LLM.parse_stream_event(data)
    end

    test "tool_call_done event with parsed arguments" do
      data = Jason.encode!(%{
        "_opal" => "tool_call_done",
        "call_id" => "call_456",
        "name" => "write_file",
        "arguments" => %{"path" => "/tmp/out.txt", "content" => "hello"}
      })

      assert [{:tool_call_done, result}] = LLM.parse_stream_event(data)
      assert result.call_id == "call_456"
      assert result.name == "write_file"
      assert result.arguments == %{"path" => "/tmp/out.txt", "content" => "hello"}
    end
  end

  describe "parse_stream_event/1 — response events" do
    test "response_done with stop reason" do
      data = Jason.encode!(%{"_opal" => "response_done", "stop_reason" => "stop", "usage" => %{}})
      assert [{:response_done, result}] = LLM.parse_stream_event(data)
      assert result.stop_reason == :stop
    end

    test "response_done with tool_calls stop reason" do
      data = Jason.encode!(%{"_opal" => "response_done", "stop_reason" => "tool_calls", "usage" => %{}})
      assert [{:response_done, result}] = LLM.parse_stream_event(data)
      assert result.stop_reason == :tool_calls
    end

    test "usage event" do
      data = Jason.encode!(%{"_opal" => "usage", "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})
      assert [{:usage, usage}] = LLM.parse_stream_event(data)
      assert usage["prompt_tokens"] == 100
    end
  end

  describe "parse_stream_event/1 — error handling" do
    test "error event" do
      data = Jason.encode!(%{"_opal" => "error", "reason" => "Rate limited"})
      assert [{:error, "Rate limited"}] = LLM.parse_stream_event(data)
    end

    test "malformed JSON returns empty list" do
      assert [] = LLM.parse_stream_event("not json at all{{{")
    end

    test "empty string returns empty list" do
      assert [] = LLM.parse_stream_event("")
    end

    test "non-opal JSON returns empty list" do
      data = Jason.encode!(%{"choices" => []})
      assert [] = LLM.parse_stream_event(data)
    end
  end

  # ============================================================
  # convert_messages/2
  # ============================================================

  describe "convert_messages/2" do
    test "converts system message" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}

      [result] = LLM.convert_messages(model, [msg])
      assert result.role == "system"
      assert result.content == "Be helpful."
    end

    test "converts user message" do
      model = Model.new(:openai, "gpt-4o")
      messages = [Message.user("Hello there")]

      [result] = LLM.convert_messages(model, messages)
      assert result.role == "user"
      assert result.content == "Hello there"
    end

    test "converts assistant message" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      messages = [Message.assistant("Sure, I can help.")]

      [result] = LLM.convert_messages(model, messages)
      assert result.role == "assistant"
      assert result.content == "Sure, I can help."
    end

    test "converts assistant message with nil content to empty string" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      messages = [Message.assistant(nil)]

      [result] = LLM.convert_messages(model, messages)
      assert result.content == ""
    end

    test "converts tool_result message" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      messages = [Message.tool_result("call_10", "file contents here")]

      [result] = LLM.convert_messages(model, messages)
      assert result.role == "tool"
      assert result.tool_call_id == "call_10"
      assert result.content == "file contents here"
    end

    test "handles empty message list" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      assert [] = LLM.convert_messages(model, [])
    end
  end

  # ============================================================
  # convert_tools/1
  # ============================================================

  describe "convert_tools/1" do
    test "converts a tool module to function format" do
      [result] = LLM.convert_tools([TestTool])

      assert result.type == "function"
      assert result.function.name == "test_tool"
      assert result.function.description == "A test tool for unit testing"
      assert result.function.strict == false
    end

    test "handles empty tool list" do
      assert [] = LLM.convert_tools([])
    end
  end
end
