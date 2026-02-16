defmodule Opal.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias Opal.Provider.OpenAI
  alias Opal.Message

  # ============================================================
  # parse_chat_event/1
  # ============================================================

  describe "parse_chat_event/1 — text events" do
    test "text_delta from content" do
      event = %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]}
      assert [{:text_delta, "Hello"}] = OpenAI.parse_chat_event(event)
    end

    test "ignores empty content" do
      event = %{"choices" => [%{"delta" => %{"content" => ""}, "finish_reason" => nil}]}
      assert [] = OpenAI.parse_chat_event(event)
    end

    test "text_start on role announcement" do
      event = %{"choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]}
      assert [{:text_start, %{}}] = OpenAI.parse_chat_event(event)
    end

    test "text_start prepended when role + nil content" do
      event = %{
        "choices" => [
          %{"delta" => %{"role" => "assistant", "content" => nil}, "finish_reason" => nil}
        ]
      }

      assert [{:text_start, %{}}] = OpenAI.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — thinking events" do
    test "thinking_delta from reasoning_content" do
      event = %{
        "choices" => [
          %{"delta" => %{"reasoning_content" => "Let me think..."}, "finish_reason" => nil}
        ]
      }

      assert [{:thinking_delta, "Let me think..."}] = OpenAI.parse_chat_event(event)
    end

    test "ignores empty reasoning_content" do
      event = %{
        "choices" => [%{"delta" => %{"reasoning_content" => ""}, "finish_reason" => nil}]
      }

      assert [] = OpenAI.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — tool call events" do
    test "tool_call_start with id" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"id" => "call_abc", "function" => %{"name" => "read_file"}}]
            },
            "finish_reason" => nil
          }
        ]
      }

      assert [{:tool_call_start, %{call_id: "call_abc", name: "read_file"}}] =
               OpenAI.parse_chat_event(event)
    end

    test "tool_call_start includes call_index when present" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "call_def",
                  "function" => %{"name" => "sub_agent"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      assert [{:tool_call_start, %{call_id: "call_def", call_index: 1, name: "sub_agent"}}] =
               OpenAI.parse_chat_event(event)
    end

    test "tool_call_delta with arguments" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"function" => %{"arguments" => "{\"path\":"}}]
            },
            "finish_reason" => nil
          }
        ]
      }

      assert [{:tool_call_delta, %{delta: "{\"path\":"}}] = OpenAI.parse_chat_event(event)
    end

    test "tool_call_delta includes call identifiers when present" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_xyz",
                  "function" => %{"arguments" => "{\"prompt\":\"write tests\"}"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      assert [
               {:tool_call_start, %{call_id: "call_xyz", call_index: 0}},
               {:tool_call_delta,
                %{call_id: "call_xyz", call_index: 0, delta: "{\"prompt\":\"write tests\"}"}}
             ] = OpenAI.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — finish reasons" do
    test "tool_calls finish reason" do
      event = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert [{:response_done, %{stop_reason: :tool_calls}}] = OpenAI.parse_chat_event(event)
    end

    test "stop finish reason" do
      event = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      assert [{:response_done, %{stop_reason: :stop}}] = OpenAI.parse_chat_event(event)
    end

    test "nil finish reason produces no event" do
      event = %{"choices" => [%{"delta" => %{}, "finish_reason" => nil}]}
      assert [] = OpenAI.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — usage" do
    test "usage-only chunk" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
      }

      assert [{:usage, %{"prompt_tokens" => 100, "completion_tokens" => 50}}] =
               OpenAI.parse_chat_event(event)
    end

    test "empty choices with no usage" do
      assert [] = OpenAI.parse_chat_event(%{"choices" => []})
    end

    test "unknown event" do
      assert [] = OpenAI.parse_chat_event(%{"unknown" => true})
    end
  end

  # ============================================================
  # convert_messages/2
  # ============================================================

  describe "convert_messages/2" do
    test "converts system message" do
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}
      [result] = OpenAI.convert_messages([msg])
      assert result == %{role: "system", content: "Be helpful."}
    end

    test "converts user message" do
      msg = Message.user("Hello")
      [result] = OpenAI.convert_messages([msg])
      assert result == %{role: "user", content: "Hello"}
    end

    test "converts assistant message" do
      msg = Message.assistant("Sure!")
      [result] = OpenAI.convert_messages([msg])
      assert result == %{role: "assistant", content: "Sure!"}
    end

    test "converts assistant with nil content" do
      msg = Message.assistant(nil)
      [result] = OpenAI.convert_messages([msg])
      assert result.content == ""
    end

    test "converts tool_result message" do
      msg = Message.tool_result("call_1", "result text")
      [result] = OpenAI.convert_messages([msg])
      assert result == %{role: "tool", tool_call_id: "call_1", content: "result text"}
    end

    test "converts assistant with tool calls" do
      msg =
        Message.assistant("", [
          %{call_id: "call_1", name: "read_file", arguments: %{"path" => "/tmp"}}
        ])

      [result] = OpenAI.convert_messages([msg])
      assert result.role == "assistant"
      assert length(result.tool_calls) == 1
      assert hd(result.tool_calls).id == "call_1"
      assert hd(result.tool_calls).function.name == "read_file"
    end

    test "includes reasoning_content when thinking present" do
      msg = Message.assistant("Response", [], thinking: "Let me think...")
      [result] = OpenAI.convert_messages([msg])
      assert result.reasoning_content == "Let me think..."
    end

    test "omits reasoning_content when include_thinking: false" do
      msg = Message.assistant("Response", [], thinking: "Secret thoughts")
      [result] = OpenAI.convert_messages([msg], include_thinking: false)
      refute Map.has_key?(result, :reasoning_content)
    end

    test "no reasoning_content when thinking is nil" do
      msg = Message.assistant("Response")
      [result] = OpenAI.convert_messages([msg])
      refute Map.has_key?(result, :reasoning_content)
    end

    test "handles empty message list" do
      assert [] = OpenAI.convert_messages([])
    end
  end

  # ============================================================
  # reasoning_effort/1
  # ============================================================

  describe "reasoning_effort/1" do
    test "off returns nil" do
      assert OpenAI.reasoning_effort(:off) == nil
    end

    test "low returns string" do
      assert OpenAI.reasoning_effort(:low) == "low"
    end

    test "medium returns string" do
      assert OpenAI.reasoning_effort(:medium) == "medium"
    end

    test "high returns string" do
      assert OpenAI.reasoning_effort(:high) == "high"
    end

    test "max clamps to high" do
      assert OpenAI.reasoning_effort(:max) == "high"
    end
  end
end
