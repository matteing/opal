defmodule Opal.Provider.LLMTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.LLM
  alias Opal.Message
  alias Opal.Provider.Model

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
  # parse_stream_event/1 — stub (EventStream bypasses SSE parsing)
  # ============================================================

  describe "parse_stream_event/1 — stub" do
    test "returns empty list (EventStream providers skip SSE parsing)" do
      assert [] = LLM.parse_stream_event("any data")
      assert [] = LLM.parse_stream_event("")
      assert [] = LLM.parse_stream_event(Jason.encode!(%{"text" => "hello"}))
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

  # ============================================================
  # convert_messages/2 — additional edge cases
  # ============================================================

  describe "convert_messages/2 edge cases" do
    test "converts tool_result with nil content to empty string" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      # Construct directly since tool_result/2 requires binary content
      msg = %Message{id: "tr1", role: :tool_result, call_id: "call_x", content: nil}
      messages = [msg]

      [result] = LLM.convert_messages(model, messages)
      assert result.content == ""
    end

    test "handles mixed message list" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")

      messages = [
        %Message{id: "s", role: :system, content: "system"},
        Message.user("hello"),
        Message.assistant("hi"),
        Message.tool_result("call_1", "output")
      ]

      results = LLM.convert_messages(model, messages)
      assert length(results) == 4
      assert Enum.map(results, & &1.role) == ["system", "user", "assistant", "tool"]
    end

    test "drops unknown message roles" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      messages = [%Message{id: "x", role: :unknown, content: "wat"}]

      assert [] = LLM.convert_messages(model, messages)
    end
  end
end
