defmodule Opal.Agent.StreamTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.State
  alias Opal.Agent.Stream
  alias Opal.Provider.Model

  defp base_state do
    %State{
      session_id: "stream-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: Opal.Config.new()
    }
  end

  describe "handle_stream_event — text events" do
    test "text_start broadcasts message_start" do
      state = base_state()
      new_state = Stream.handle_stream_event({:text_start, %{}}, state)
      assert new_state == state
    end

    test "text_delta appends to current_text" do
      state = base_state()
      state = Stream.handle_stream_event({:text_delta, "hello "}, state)
      state = Stream.handle_stream_event({:text_delta, "world"}, state)
      assert state.current_text == "hello world"
    end

    test "text_done replaces current_text" do
      state = %{base_state() | current_text: "partial"}
      state = Stream.handle_stream_event({:text_done, "final text"}, state)
      assert state.current_text == "final text"
    end
  end

  describe "handle_stream_event — thinking events" do
    test "thinking_start initializes current_thinking" do
      state = base_state()
      state = Stream.handle_stream_event({:thinking_start, %{}}, state)
      assert state.current_thinking == ""
    end

    test "thinking_delta appends to current_thinking" do
      state = %{base_state() | current_thinking: ""}
      state = Stream.handle_stream_event({:thinking_delta, "step 1"}, state)
      state = Stream.handle_stream_event({:thinking_delta, " step 2"}, state)
      assert state.current_thinking == "step 1 step 2"
    end

    test "thinking_delta auto-emits thinking_start when current_thinking is nil" do
      state = base_state()
      assert is_nil(state.current_thinking)
      state = Stream.handle_stream_event({:thinking_delta, "auto"}, state)
      assert state.current_thinking == "auto"
    end
  end

  describe "handle_stream_event — tool call events" do
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

    test "tool_call_start creates new tool call entry" do
      state =
        apply_event(
          base_state(),
          {:tool_call_start, %{call_id: "c1", call_index: 0, name: "read_file"}}
        )

      assert length(state.current_tool_calls) == 1
      tc = hd(state.current_tool_calls)
      assert tc.call_id == "c1"
      assert tc.name == "read_file"
      assert tc.arguments_json == ""
    end

    test "legacy string tool_call_delta appends to last tool call" do
      state =
        base_state()
        |> apply_event({:tool_call_start, %{call_id: "c1", call_index: 0, name: "shell"}})
        |> apply_event({:tool_call_delta, "{\"com"})
        |> apply_event({:tool_call_delta, "mand\": \"ls\"}"})

      tc = hd(state.current_tool_calls)
      assert tc.arguments_json == "{\"command\": \"ls\"}"
    end

    test "legacy string tool_call_delta with no existing calls is a no-op" do
      state = apply_event(base_state(), {:tool_call_delta, "orphan"})
      assert state.current_tool_calls == []
    end

    test "tool_call_delta with unrecognized format is a no-op" do
      state = apply_event(base_state(), {:tool_call_delta, 12345})
      assert state.current_tool_calls == []
    end
  end

  describe "handle_stream_event — response/error/usage" do
    test "usage updates state via UsageTracker" do
      state =
        apply_event(base_state(), {:usage, %{"prompt_tokens" => 10, "completion_tokens" => 5}})

      assert state.token_usage.prompt_tokens == 10
    end

    test "response_done with usage processes usage" do
      state =
        apply_event(
          base_state(),
          {:response_done, %{usage: %{"prompt_tokens" => 20, "completion_tokens" => 10}}}
        )

      assert state.token_usage.prompt_tokens == 20
    end

    test "response_done without usage is a no-op on usage" do
      state = apply_event(base_state(), {:response_done, %{}})
      assert state.token_usage.prompt_tokens == 0
    end

    test "error sets status to idle and clears streaming_resp" do
      state = %{base_state() | status: :streaming, streaming_resp: :some_ref}
      state = apply_event(state, {:error, "rate limit"})
      assert state.status == :idle
      assert state.streaming_resp == nil
    end

    test "unknown event is a no-op" do
      state = base_state()
      assert state == apply_event(state, {:some_future_event, %{data: 1}})
    end
  end

  describe "extract_xml_tag/4 (generic)" do
    test "extracts complete tag and calls callback" do
      state = base_state()
      cb = fn text, st -> %{st | current_text: text} end
      {clean, state} = Stream.extract_xml_tag("<foo>hello</foo>rest", :foo, state, cb)
      assert clean == "rest"
      assert state.current_text == "hello"
    end

    test "passes through text without matching tag" do
      state = base_state()
      cb = fn _text, st -> st end
      {clean, _state} = Stream.extract_xml_tag("Hello world", :foo, state, cb)
      assert clean == "Hello world"
    end

    test "buffers partial opening tag" do
      state = base_state()
      cb = fn _text, st -> st end
      {clean, state} = Stream.extract_xml_tag("Hello<foo>partial", :foo, state, cb)
      assert clean == "Hello"
      assert state.tag_buffers[:foo] != ""
    end

    test "buffers potential tag start across chunks" do
      state = base_state()
      cb = fn _text, st -> st end
      {clean, state} = Stream.extract_xml_tag("Hello<fo", :foo, state, cb)
      assert clean == "Hello"
      assert state.tag_buffers[:foo] == "<fo"
    end

    test "completes buffered tag" do
      state = %{base_state() | tag_buffers: %{foo: "<foo>hello"}}
      cb = fn text, st -> %{st | current_text: text} end
      {clean, state} = Stream.extract_xml_tag("</foo>rest", :foo, state, cb)
      assert clean == "rest"
      assert state.current_text == "hello"
      assert state.tag_buffers[:foo] == ""
    end
  end

  describe "extract_status_tags/2" do
    test "extracts complete status tag" do
      state = base_state()
      {clean, _state} = Stream.extract_status_tags("<status>Thinking...</status>rest", state)
      assert clean == "rest"
    end

    test "passes through text without tags" do
      state = base_state()
      {clean, _state} = Stream.extract_status_tags("Hello world", state)
      assert clean == "Hello world"
    end

    test "buffers partial opening tag" do
      state = base_state()
      {clean, state} = Stream.extract_status_tags("Hello<status>partial", state)
      assert clean == "Hello"
      assert state.tag_buffers[:status] != ""
    end

    test "buffers potential tag start" do
      state = base_state()
      {clean, state} = Stream.extract_status_tags("Hello<st", state)
      assert clean == "Hello"
      assert state.tag_buffers[:status] == "<st"
    end
  end

  describe "partial_tag_length/1" do
    test "detects partial tag suffixes" do
      assert Stream.partial_tag_length("text<") == 1
      assert Stream.partial_tag_length("text<s") == 2
      assert Stream.partial_tag_length("text<st") == 3
      assert Stream.partial_tag_length("text<sta") == 4
      assert Stream.partial_tag_length("text<stat") == 5
      assert Stream.partial_tag_length("text<statu") == 6
      assert Stream.partial_tag_length("text<status") == 7
    end

    test "returns 0 for no partial tag" do
      assert Stream.partial_tag_length("hello") == 0
    end
  end

  describe "extract_title_tag/2" do
    test "extracts complete title tag" do
      state = base_state()
      {clean, _state} = Stream.extract_title_tag("<title>Fix auth bug</title>rest", state)
      assert clean == "rest"
    end

    test "passes through text without title tags" do
      state = base_state()
      {clean, _state} = Stream.extract_title_tag("Hello world", state)
      assert clean == "Hello world"
    end

    test "buffers partial opening title tag" do
      state = base_state()
      {clean, state} = Stream.extract_title_tag("Hello<title>partial", state)
      assert clean == "Hello"
      assert state.tag_buffers[:title] != ""
    end

    test "buffers potential title tag start" do
      state = base_state()
      {clean, state} = Stream.extract_title_tag("Hello<ti", state)
      assert clean == "Hello"
      assert state.tag_buffers[:title] == "<ti"
    end

    test "completes buffered title tag" do
      state = %{base_state() | tag_buffers: %{title: "<title>My Title"}}
      {clean, state} = Stream.extract_title_tag("</title>more text", state)
      assert clean == "more text"
      assert state.tag_buffers[:title] == ""
    end
  end

  describe "partial_title_tag_length/1" do
    test "detects partial title tag suffixes" do
      assert Stream.partial_title_tag_length("text<") == 1
      assert Stream.partial_title_tag_length("text<t") == 2
      assert Stream.partial_title_tag_length("text<ti") == 3
      assert Stream.partial_title_tag_length("text<tit") == 4
      assert Stream.partial_title_tag_length("text<titl") == 5
      assert Stream.partial_title_tag_length("text<title") == 6
    end

    test "returns 0 for no partial tag" do
      assert Stream.partial_title_tag_length("hello") == 0
    end
  end

  describe "parse_sse_data/2" do
    test "skips [DONE] sentinel" do
      state = base_state() |> Map.put(:provider, Opal.Provider.Copilot)
      result = Stream.parse_sse_data("data: [DONE]\n", state)
      assert result.current_text == ""
    end

    test "skips non-data lines" do
      state = base_state() |> Map.put(:provider, Opal.Provider.Copilot)
      result = Stream.parse_sse_data("event: ping\n: comment\n", state)
      assert result.current_text == ""
    end
  end

  defp apply_event(state, event), do: Stream.handle_stream_event(event, state)
end
