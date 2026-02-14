defmodule Opal.Provider.CopilotTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.Copilot
  alias Opal.Message
  alias Opal.Model

  # --- Helpers ---

  defp sse_event(type, fields) do
    Map.merge(%{"type" => type}, fields) |> Jason.encode!()
  end

  defp make_model(opts) do
    thinking = Keyword.get(opts, :thinking_level, :off)
    id = Keyword.get(opts, :id, "test-model")
    Model.new(:copilot, id, thinking_level: thinking)
  end

  # Chat Completions model (default — most models)
  defp completions_model(opts \\ []),
    do: make_model(Keyword.put_new(opts, :id, "claude-sonnet-4"))

  # Responses API model (gpt-5 family)
  defp responses_model(opts \\ []), do: make_model(Keyword.put_new(opts, :id, "gpt-5"))

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

  defmodule EmptyParamsTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "empty_tool"

    @impl true
    def description, do: "A tool with no parameters"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context), do: {:ok, "done"}
  end

  # ============================================================
  # parse_stream_event/1
  # ============================================================

  describe "parse_stream_event/1 — output_item.added" do
    test "message type returns text_start" do
      data =
        sse_event("response.output_item.added", %{
          "item" => %{"type" => "message", "id" => "item_001"}
        })

      assert [{:text_start, %{item_id: "item_001"}}] = Copilot.parse_stream_event(data)
    end

    test "reasoning type returns thinking_start" do
      data =
        sse_event("response.output_item.added", %{
          "item" => %{"type" => "reasoning", "id" => "item_002"}
        })

      assert [{:thinking_start, %{item_id: "item_002"}}] = Copilot.parse_stream_event(data)
    end

    test "function_call type returns tool_call_start" do
      data =
        sse_event("response.output_item.added", %{
          "item" => %{
            "type" => "function_call",
            "id" => "item_003",
            "call_id" => "call_123",
            "name" => "read_file"
          }
        })

      assert [{:tool_call_start, %{item_id: "item_003", call_id: "call_123", name: "read_file"}}] =
               Copilot.parse_stream_event(data)
    end

    test "unknown item type returns empty list" do
      data =
        sse_event("response.output_item.added", %{
          "item" => %{"type" => "unknown_type", "id" => "item_004"}
        })

      assert [] = Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — text deltas" do
    test "output_text.delta returns text_delta" do
      data = sse_event("response.output_text.delta", %{"delta" => "Hello, world!"})
      assert [{:text_delta, "Hello, world!"}] = Copilot.parse_stream_event(data)
    end

    test "output_text.delta with empty string" do
      data = sse_event("response.output_text.delta", %{"delta" => ""})
      assert [{:text_delta, ""}] = Copilot.parse_stream_event(data)
    end

    test "output_text.done returns text_done" do
      data = sse_event("response.output_text.done", %{"text" => "Full response text"})
      assert [{:text_done, "Full response text"}] = Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — reasoning deltas" do
    test "reasoning_summary_text.delta returns thinking_delta" do
      data = sse_event("response.reasoning_summary_text.delta", %{"delta" => "Let me think..."})
      assert [{:thinking_delta, "Let me think..."}] = Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — function call events" do
    test "function_call_arguments.delta returns tool_call_delta" do
      data = sse_event("response.function_call_arguments.delta", %{"delta" => "{\"path\":"})
      assert [{:tool_call_delta, %{delta: "{\"path\":"}}] = Copilot.parse_stream_event(data)
    end

    test "function_call_arguments.delta includes identifiers when present" do
      data =
        sse_event("response.function_call_arguments.delta", %{
          "item_id" => "item_123",
          "output_index" => 2,
          "delta" => "{\"prompt\":"
        })

      assert [
               {:tool_call_delta, %{item_id: "item_123", call_index: 2, delta: "{\"prompt\":"}}
             ] = Copilot.parse_stream_event(data)
    end

    test "function_call_arguments.done with valid JSON returns parsed arguments" do
      data =
        sse_event("response.function_call_arguments.done", %{
          "arguments" => ~s({"path": "/tmp/test.txt"})
        })

      assert [{:tool_call_done, %{arguments: %{"path" => "/tmp/test.txt"}}}] =
               Copilot.parse_stream_event(data)
    end

    test "function_call_arguments.done with invalid JSON returns raw arguments" do
      data =
        sse_event("response.function_call_arguments.done", %{
          "arguments" => "not valid json"
        })

      assert [{:tool_call_done, %{arguments_raw: "not valid json"}}] =
               Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — output_item.done" do
    test "function_call item returns tool_call_done with full details" do
      data =
        sse_event("response.output_item.done", %{
          "item" => %{
            "type" => "function_call",
            "id" => "item_005",
            "call_id" => "call_456",
            "name" => "write_file",
            "arguments" => ~s({"path": "/tmp/out.txt", "content": "hello"})
          }
        })

      assert [{:tool_call_done, result}] = Copilot.parse_stream_event(data)
      assert result.item_id == "item_005"
      assert result.call_id == "call_456"
      assert result.name == "write_file"
      assert result.arguments == %{"path" => "/tmp/out.txt", "content" => "hello"}
    end

    test "function_call item with invalid arguments JSON defaults to empty map" do
      data =
        sse_event("response.output_item.done", %{
          "item" => %{
            "type" => "function_call",
            "id" => "item_006",
            "call_id" => "call_789",
            "name" => "some_tool",
            "arguments" => "broken json"
          }
        })

      assert [{:tool_call_done, result}] = Copilot.parse_stream_event(data)
      assert result.arguments == %{}
    end

    test "function_call item with nil arguments defaults to empty map" do
      data =
        sse_event("response.output_item.done", %{
          "item" => %{
            "type" => "function_call",
            "id" => "item_007",
            "call_id" => "call_000",
            "name" => "tool",
            "arguments" => nil
          }
        })

      assert [{:tool_call_done, result}] = Copilot.parse_stream_event(data)
      assert result.arguments == %{}
    end

    test "non-function_call item type returns empty list" do
      data =
        sse_event("response.output_item.done", %{
          "item" => %{"type" => "message", "id" => "item_008"}
        })

      assert [] = Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — response.completed" do
    test "returns response_done with usage, status, and id" do
      data =
        sse_event("response.completed", %{
          "response" => %{
            "id" => "resp_001",
            "status" => "completed",
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 50
            }
          }
        })

      assert [{:response_done, result}] = Copilot.parse_stream_event(data)
      assert result.id == "resp_001"
      assert result.status == "completed"
      assert result.usage == %{"input_tokens" => 100, "output_tokens" => 50}
    end

    test "handles missing usage gracefully" do
      data =
        sse_event("response.completed", %{
          "response" => %{"id" => "resp_002", "status" => "completed"}
        })

      assert [{:response_done, result}] = Copilot.parse_stream_event(data)
      assert result.usage == %{}
    end
  end

  describe "parse_stream_event/1 — error events" do
    test "error type returns error tuple" do
      data = sse_event("error", %{"error" => %{"message" => "Rate limited", "code" => 429}})

      assert [{:error, %{"message" => "Rate limited", "code" => 429}}] =
               Copilot.parse_stream_event(data)
    end

    test "response.failed returns error" do
      data =
        sse_event("response.failed", %{
          "response" => %{"error" => %{"message" => "Server error"}}
        })

      assert [{:error, %{"message" => "Server error"}}] = Copilot.parse_stream_event(data)
    end
  end

  describe "parse_stream_event/1 — edge cases" do
    test "unknown event type returns empty list" do
      data = sse_event("response.some_future_event", %{"data" => "whatever"})
      assert [] = Copilot.parse_stream_event(data)
    end

    test "malformed JSON returns empty list" do
      assert [] = Copilot.parse_stream_event("not json at all{{{")
    end

    test "empty string returns empty list" do
      assert [] = Copilot.parse_stream_event("")
    end

    test "[DONE] sentinel returns empty list" do
      assert [] = Copilot.parse_stream_event("[DONE]")
    end
  end

  # ============================================================
  # parse_stream_event/1 — Chat Completions format
  # ============================================================

  describe "parse_stream_event/1 — chat completions format" do
    test "parses text content delta" do
      data =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]
        })

      events = Copilot.parse_stream_event(data)
      assert {:text_delta, "Hello"} in events
    end

    test "parses role start" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{"delta" => %{"role" => "assistant", "content" => ""}, "finish_reason" => nil}
          ]
        })

      events = Copilot.parse_stream_event(data)
      assert {:text_start, %{}} in events
    end

    test "parses tool call start with id" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"id" => "call_1", "function" => %{"name" => "read_file", "arguments" => ""}}
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      assert {:tool_call_start, %{call_id: "call_1", name: "read_file"}} in events
    end

    test "parses tool call argument delta" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{"tool_calls" => [%{"function" => %{"arguments" => "{\"path\":"}}]},
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      assert {:tool_call_delta, %{delta: "{\"path\":"}} in events
    end

    test "parses finish_reason stop" do
      data =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        })

      events = Copilot.parse_stream_event(data)
      assert {:response_done, meta} = List.keyfind(events, :response_done, 0)
      assert meta.stop_reason == :stop
    end

    test "parses finish_reason tool_calls" do
      data =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
        })

      events = Copilot.parse_stream_event(data)
      assert {:response_done, meta} = List.keyfind(events, :response_done, 0)
      assert meta.stop_reason == :tool_calls
    end

    test "raw error without type field" do
      data =
        Jason.encode!(%{
          "error" => %{"message" => "model not supported", "code" => "model_not_supported"}
        })

      events = Copilot.parse_stream_event(data)

      assert [{:error, %{"message" => "model not supported", "code" => "model_not_supported"}}] =
               events
    end
  end

  # ============================================================
  # convert_messages/2 — Chat Completions format (non-gpt-5 models)
  # ============================================================

  describe "convert_messages/2 — user messages" do
    test "converts user message to plain content string (completions)" do
      model = completions_model()
      messages = [Message.user("Hello there")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "user"
      assert result.content == "Hello there"
    end

    test "converts user message to input_text format (responses)" do
      model = responses_model()
      messages = [Message.user("Hello there")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "user"
      assert [%{type: "input_text", text: "Hello there"}] = result.content
    end
  end

  describe "convert_messages/2 — assistant messages" do
    test "converts text-only assistant message (completions)" do
      model = completions_model()
      messages = [Message.assistant("Sure, I can help.")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "assistant"
      assert result.content == "Sure, I can help."
    end

    test "converts text-only assistant message (responses)" do
      model = responses_model()
      messages = [Message.assistant("Sure, I can help.")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.type == "message"
      assert result.role == "assistant"
      assert [%{type: "output_text", text: "Sure, I can help."}] = result.content
    end

    test "converts assistant message with nil content (completions)" do
      model = completions_model()
      messages = [Message.assistant(nil)]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "assistant"
      assert result.content == ""
    end

    test "converts assistant message with tool calls (completions)" do
      model = completions_model()
      tool_calls = [%{call_id: "call_1", name: "read_file", arguments: %{"path" => "/tmp/test"}}]
      messages = [Message.assistant("Let me read that.", tool_calls)]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "assistant"
      assert result.content == "Let me read that."
      assert length(result.tool_calls) == 1
      [tc] = result.tool_calls
      assert tc.id == "call_1"
      assert tc.type == "function"
      assert tc.function.name == "read_file"
    end

    test "converts assistant message with tool calls (responses)" do
      model = responses_model()
      tool_calls = [%{call_id: "call_1", name: "read_file", arguments: %{"path" => "/tmp/test"}}]
      messages = [Message.assistant("Let me read that.", tool_calls)]

      results = Copilot.convert_messages(model, messages)

      assert length(results) == 2
      [text_msg, call_msg] = results
      assert text_msg.type == "message"
      assert call_msg.type == "function_call"
      assert call_msg.call_id == "call_1"
    end

    test "assistant with tool calls but no text content (completions)" do
      model = completions_model()
      tool_calls = [%{call_id: "call_2", name: "shell", arguments: %{"command" => "ls"}}]
      messages = [Message.assistant(nil, tool_calls)]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "assistant"
      assert result.content == ""
      assert length(result.tool_calls) == 1
    end
  end

  describe "convert_messages/2 — tool_result messages" do
    test "converts tool_result (completions)" do
      model = completions_model()
      messages = [Message.tool_result("call_10", "file contents here")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.role == "tool"
      assert result.tool_call_id == "call_10"
      assert result.content == "file contents here"
    end

    test "converts tool_result (responses)" do
      model = responses_model()
      messages = [Message.tool_result("call_10", "file contents here")]

      [result] = Copilot.convert_messages(model, messages)

      assert result.type == "function_call_output"
      assert result.call_id == "call_10"
      assert result.output == "file contents here"
    end

    test "converts tool_result with nil content to empty string" do
      model = completions_model()
      msg = %Message{id: "test", role: :tool_result, call_id: "call_11", content: nil}

      [result] = Copilot.convert_messages(model, [msg])

      assert result.content == ""
    end
  end

  describe "convert_messages/2 — system prompt routing" do
    test "uses 'system' role for non-reasoning models" do
      model = completions_model(thinking_level: :off)
      msg = %Message{id: "sys2", role: :system, content: "You are a helpful assistant."}

      [result] = Copilot.convert_messages(model, [msg])

      assert result.role == "system"
      assert result.content == "You are a helpful assistant."
    end

    test "uses 'developer' role for reasoning models (responses API)" do
      model = responses_model(thinking_level: :high)
      msg = %Message{id: "sys1", role: :system, content: "You are a helpful assistant."}

      [result] = Copilot.convert_messages(model, [msg])

      assert result.role == "developer"
    end
  end

  describe "convert_messages/2 — multiple messages" do
    test "converts a full conversation (completions)" do
      model = completions_model()

      messages = [
        %Message{id: "s1", role: :system, content: "You are helpful."},
        Message.user("What's 2+2?"),
        Message.assistant("4"),
        Message.user("Thanks!")
      ]

      results = Copilot.convert_messages(model, messages)

      assert length(results) == 4
      assert Enum.at(results, 0).role == "system"
      assert Enum.at(results, 1).role == "user"
      assert Enum.at(results, 2).role == "assistant"
      assert Enum.at(results, 3).role == "user"
    end

    test "handles empty message list" do
      model = completions_model()
      assert [] = Copilot.convert_messages(model, [])
    end
  end

  # ============================================================
  # convert_tools/1
  # ============================================================

  describe "convert_tools/1" do
    test "converts a tool module to function format" do
      [result] = Copilot.convert_tools([TestTool])

      assert result.type == "function"
      assert result.function.name == "test_tool"
      assert result.function.description == "A test tool for unit testing"
      assert result.function.strict == false

      assert result.function.parameters == %{
               "type" => "object",
               "properties" => %{
                 "input" => %{"type" => "string", "description" => "Test input"}
               },
               "required" => ["input"]
             }
    end

    test "converts multiple tools" do
      results = Copilot.convert_tools([TestTool, EmptyParamsTool])

      assert length(results) == 2
      assert Enum.at(results, 0).function.name == "test_tool"
      assert Enum.at(results, 1).function.name == "empty_tool"
    end

    test "handles empty tool list" do
      assert [] = Copilot.convert_tools([])
    end

    test "tool with empty parameters" do
      [result] = Copilot.convert_tools([EmptyParamsTool])

      assert result.function.name == "empty_tool"
      assert result.function.parameters == %{"type" => "object", "properties" => %{}}
    end
  end
end
