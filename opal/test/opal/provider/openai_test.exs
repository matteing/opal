defmodule Opal.Provider.SharedHelpersTest do
  use ExUnit.Case, async: true

  alias Opal.Provider
  alias Opal.Message

  # ============================================================
  # parse_chat_event/1
  # ============================================================

  describe "parse_chat_event/1 — text events" do
    test "text_delta from content" do
      event = %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]}
      assert [{:text_delta, "Hello"}] = Provider.parse_chat_event(event)
    end

    test "ignores empty content" do
      event = %{"choices" => [%{"delta" => %{"content" => ""}, "finish_reason" => nil}]}
      assert [] = Provider.parse_chat_event(event)
    end

    test "text_start on role announcement" do
      event = %{"choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]}
      assert [{:text_start, %{}}] = Provider.parse_chat_event(event)
    end

    test "text_start prepended when role + nil content" do
      event = %{
        "choices" => [
          %{"delta" => %{"role" => "assistant", "content" => nil}, "finish_reason" => nil}
        ]
      }

      assert [{:text_start, %{}}] = Provider.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — thinking events" do
    test "thinking_delta from reasoning_content" do
      event = %{
        "choices" => [
          %{"delta" => %{"reasoning_content" => "Let me think..."}, "finish_reason" => nil}
        ]
      }

      assert [{:thinking_delta, "Let me think..."}] = Provider.parse_chat_event(event)
    end

    test "ignores empty reasoning_content" do
      event = %{
        "choices" => [%{"delta" => %{"reasoning_content" => ""}, "finish_reason" => nil}]
      }

      assert [] = Provider.parse_chat_event(event)
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
               Provider.parse_chat_event(event)
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
               Provider.parse_chat_event(event)
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

      assert [{:tool_call_delta, %{delta: "{\"path\":"}}] = Provider.parse_chat_event(event)
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
             ] = Provider.parse_chat_event(event)
    end

    test "parallel tool calls in a single SSE chunk" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "id" => "call_1", "function" => %{"name" => "read_file"}},
                %{"index" => 1, "id" => "call_2", "function" => %{"name" => "grep"}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      events = Provider.parse_chat_event(event)

      starts = Enum.filter(events, fn {type, _} -> type == :tool_call_start end)
      assert length(starts) == 2

      assert Enum.any?(starts, fn {:tool_call_start, m} ->
               m.call_id == "call_1" and m.name == "read_file"
             end)

      assert Enum.any?(starts, fn {:tool_call_start, m} ->
               m.call_id == "call_2" and m.name == "grep"
             end)
    end

    test "tool_call with empty arguments emits only start" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"id" => "call_1", "function" => %{"name" => "shell", "arguments" => ""}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      events = Provider.parse_chat_event(event)
      assert [{:tool_call_start, %{call_id: "call_1", name: "shell"}}] = events
    end

    test "tool_call with no id and no name emits only delta" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "partial"}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      assert [{:tool_call_delta, %{call_index: 0, delta: "partial"}}] =
               Provider.parse_chat_event(event)
    end

    test "tool_call with nil function fields" do
      event = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"id" => "call_1", "function" => %{"name" => nil, "arguments" => nil}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      events = Provider.parse_chat_event(event)
      assert [{:tool_call_start, %{call_id: "call_1"}}] = events
    end

    test "tool_calls finish reason" do
      event = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert [{:response_done, %{stop_reason: :tool_calls}}] = Provider.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — realistic tool call sequence" do
    test "full single tool call streaming sequence" do
      # Chunk 1: role announcement
      chunk1 = %{
        "choices" => [
          %{"delta" => %{"role" => "assistant", "content" => nil}, "finish_reason" => nil}
        ]
      }

      # Chunk 2: tool call start with id + name
      chunk2 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "id" => "call_abc", "function" => %{"name" => "read_file"}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      # Chunk 3-4: argument fragments
      chunk3 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}]
            },
            "finish_reason" => nil
          }
        ]
      }

      chunk4 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "\"/tmp/test.txt\"}"}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      # Chunk 5: finish
      chunk5 = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      all_events =
        Enum.flat_map([chunk1, chunk2, chunk3, chunk4, chunk5], &Provider.parse_chat_event/1)

      assert {:text_start, %{}} in all_events

      assert Enum.any?(all_events, fn
               {:tool_call_start, %{call_id: "call_abc", name: "read_file"}} -> true
               _ -> false
             end)

      assert Enum.any?(all_events, fn
               {:response_done, %{stop_reason: :tool_calls}} -> true
               _ -> false
             end)

      deltas =
        Enum.filter(all_events, fn
          {:tool_call_delta, _} -> true
          _ -> false
        end)

      combined = Enum.map_join(deltas, fn {:tool_call_delta, %{delta: d}} -> d end)
      assert combined == "{\"path\":\"/tmp/test.txt\"}"
    end
  end

  describe "parse_chat_event/1 — finish reasons" do
    test "tool_calls finish reason" do
      event = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      assert [{:response_done, %{stop_reason: :tool_calls}}] = Provider.parse_chat_event(event)
    end

    test "stop finish reason" do
      event = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      assert [{:response_done, %{stop_reason: :stop}}] = Provider.parse_chat_event(event)
    end

    test "nil finish reason produces no event" do
      event = %{"choices" => [%{"delta" => %{}, "finish_reason" => nil}]}
      assert [] = Provider.parse_chat_event(event)
    end
  end

  describe "parse_chat_event/1 — usage" do
    test "usage-only chunk" do
      event = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
      }

      assert [{:usage, %{"prompt_tokens" => 100, "completion_tokens" => 50}}] =
               Provider.parse_chat_event(event)
    end

    test "empty choices with no usage" do
      assert [] = Provider.parse_chat_event(%{"choices" => []})
    end

    test "unknown event" do
      assert [] = Provider.parse_chat_event(%{"unknown" => true})
    end
  end

  # ============================================================
  # convert_messages_openai/2
  # ============================================================

  describe "convert_messages_openai/2" do
    test "converts system message" do
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}
      [result] = Provider.convert_messages_openai([msg])
      assert result == %{role: "system", content: "Be helpful."}
    end

    test "converts user message" do
      msg = Message.user("Hello")
      [result] = Provider.convert_messages_openai([msg])
      assert result == %{role: "user", content: "Hello"}
    end

    test "converts assistant message" do
      msg = Message.assistant("Sure!")
      [result] = Provider.convert_messages_openai([msg])
      assert result == %{role: "assistant", content: "Sure!"}
    end

    test "converts assistant with nil content" do
      msg = Message.assistant(nil)
      [result] = Provider.convert_messages_openai([msg])
      assert result.content == ""
    end

    test "converts tool_result message" do
      msg = Message.tool_result("call_1", "result text")
      [result] = Provider.convert_messages_openai([msg])
      assert result == %{role: "tool", tool_call_id: "call_1", content: "result text"}
    end

    test "converts assistant with tool calls" do
      msg =
        Message.assistant("", [
          %{call_id: "call_1", name: "read_file", arguments: %{"path" => "/tmp"}}
        ])

      [result] = Provider.convert_messages_openai([msg])
      assert result.role == "assistant"
      assert length(result.tool_calls) == 1
      assert hd(result.tool_calls).id == "call_1"
      assert hd(result.tool_calls).function.name == "read_file"
    end

    test "includes reasoning_content when thinking present" do
      msg = Message.assistant("Response", [], thinking: "Let me think...")
      [result] = Provider.convert_messages_openai([msg])
      assert result.reasoning_content == "Let me think..."
    end

    test "omits reasoning_content when include_thinking: false" do
      msg = Message.assistant("Response", [], thinking: "Secret thoughts")
      [result] = Provider.convert_messages_openai([msg], include_thinking: false)
      refute Map.has_key?(result, :reasoning_content)
    end

    test "no reasoning_content when thinking is nil" do
      msg = Message.assistant("Response")
      [result] = Provider.convert_messages_openai([msg])
      refute Map.has_key?(result, :reasoning_content)
    end

    test "handles empty message list" do
      assert [] = Provider.convert_messages_openai([])
    end
  end

  # ============================================================
  # reasoning_effort/1
  # ============================================================

  describe "reasoning_effort/1" do
    test "off returns nil" do
      assert Provider.reasoning_effort(:off) == nil
    end

    test "low returns string" do
      assert Provider.reasoning_effort(:low) == "low"
    end

    test "medium returns string" do
      assert Provider.reasoning_effort(:medium) == "medium"
    end

    test "high returns string" do
      assert Provider.reasoning_effort(:high) == "high"
    end

    test "max clamps to high" do
      assert Provider.reasoning_effort(:max) == "high"
    end
  end
end
