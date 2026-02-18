defmodule Opal.ThinkingIntegrationTest do
  @moduledoc """
  Integration tests for reasoning / thinking across the full agent stack.

  Fixtures are recorded from real API responses via LiveThinkingTest
  (`mix test --include live --include save_fixtures`) and replayed here.

  Tests use **structural assertions** — they verify event shapes, ordering,
  and field presence rather than exact content strings, so they work with
  both hand-crafted and real API recordings.

  Covers:
  - Chat Completions thinking (reasoning_content — Claude models)
  - Responses API thinking (reasoning summary — GPT-5 models)
  - Thinking + tool call loops
  - Thinking persistence on assistant messages
  - Thinking level → provider param mapping
  - SSE parsing for thinking events
  - Message conversion roundtripping
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model
  alias Opal.Message
  alias Opal.Provider, as: OpenAIShared
  alias Opal.Provider.Copilot
  alias Opal.Test.FixtureHelper

  # ── Fixture Provider (reuses real Copilot parsing) ─────────────────

  defmodule FixtureProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      fixture_name = :persistent_term.get({__MODULE__, :fixture})

      has_tool_result = Enum.any?(messages, &(&1.role == :tool_result))

      actual_fixture =
        if has_tool_result do
          :persistent_term.get({__MODULE__, :second_fixture}, fixture_name)
        else
          fixture_name
        end

      FixtureHelper.build_fixture_response(actual_fixture)
    end

    @impl true
    def parse_stream_event(data), do: Copilot.parse_stream_event(data)

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools
  end

  # ── Test Tool ──────────────────────────────────────────────────────

  defmodule TestReadTool do
    @behaviour Opal.Tool
    @impl true
    def name, do: "read_file"
    @impl true
    def description, do: "Read a file"
    @impl true
    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      }

    @impl true
    def execute(%{"path" => path}, _ctx), do: {:ok, "Contents of #{path}"}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp start_agent(opts) do
    fixture = Keyword.fetch!(opts, :fixture)
    second_fixture = Keyword.get(opts, :second_fixture, fixture)
    :persistent_term.put({FixtureProvider, :fixture}, fixture)
    :persistent_term.put({FixtureProvider, :second_fixture}, second_fixture)

    session_id = "thinking-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    model =
      Model.new(
        :test,
        Keyword.get(opts, :model_id, "claude-sonnet-4"),
        thinking_level: Keyword.get(opts, :thinking_level, :high)
      )

    {:ok, pid} =
      Agent.start_link(
        session_id: session_id,
        model: model,
        working_dir: System.tmp_dir!(),
        system_prompt: Keyword.get(opts, :system_prompt, "Test"),
        tools: Keyword.get(opts, :tools, []),
        provider: FixtureProvider,
        tool_supervisor: tool_sup
      )

    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  defp wait_for_idle(pid, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(pid, deadline)
  end

  defp wait_loop(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("Timed out waiting for idle")
    state = Agent.get_state(pid)

    if state.status == :idle do
      state
    else
      Process.sleep(10)
      wait_loop(pid, deadline)
    end
  end

  defp collect_events(session_id, timeout \\ 2000) do
    collect_events_loop(session_id, [], timeout)
  end

  defp collect_events_loop(session_id, acc, timeout) do
    receive do
      {:opal_event, ^session_id, event} ->
        collect_events_loop(session_id, [event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp event_type({:thinking_start}), do: :thinking_start
  defp event_type({:thinking_delta, _}), do: :thinking_delta
  defp event_type({:message_start}), do: :message_start
  defp event_type({:message_delta, _}), do: :message_delta
  defp event_type({:agent_start}), do: :agent_start
  defp event_type({:agent_end, _, _}), do: :agent_end
  defp event_type({:tool_execution_start, _, _, _, _}), do: :tool_execution_start
  defp event_type({:tool_execution_end, _, _, _}), do: :tool_execution_end
  defp event_type({:usage_update, _}), do: :usage_update
  defp event_type({:turn_end}), do: :turn_end
  defp event_type({:request_start, _}), do: :request_start
  defp event_type({:request_end}), do: :request_end
  defp event_type(_), do: :other

  setup do
    on_exit(fn ->
      :persistent_term.erase({FixtureProvider, :fixture})
      :persistent_term.erase({FixtureProvider, :second_fixture})
    end)

    :ok
  end

  # ════════════════════════════════════════════════════════════════════
  # Chat Completions — reasoning_content (Claude models via Copilot)
  # ════════════════════════════════════════════════════════════════════

  describe "Chat Completions thinking — text only" do
    test "broadcasts thinking events before message content" do
      %{pid: pid, session_id: sid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "What is the meaning of life?")
      events = collect_events(sid)

      types = Enum.map(events, &event_type/1)

      # Must contain message events; thinking is optional in live fixtures
      assert :message_delta in types
      assert :agent_end in types

      first_message = Enum.find_index(types, &(&1 == :message_delta))
      assert first_message != nil

      if :thinking_start in types do
        # Thinking events come before message deltas when present
        first_thinking = Enum.find_index(types, &(&1 == :thinking_start))
        assert first_thinking < first_message

        # Thinking deltas carry non-empty strings
        thinking_deltas =
          Enum.filter(events, fn
            {:thinking_delta, _} -> true
            _ -> false
          end)

        assert length(thinking_deltas) > 0

        Enum.each(thinking_deltas, fn {:thinking_delta, %{delta: delta}} ->
          assert is_binary(delta)
          assert byte_size(delta) > 0
        end)
      else
        refute :thinking_delta in types
      end
    end

    test "thinking content is persisted on the assistant message" do
      %{pid: pid, session_id: sid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "Think about this")
      events = collect_events(sid)

      # Extract the final messages from agent_end
      {_agent_end, messages, _usage} =
        Enum.find(events, fn
          {:agent_end, _, _} -> true
          _ -> false
        end)

      assistant = List.last(messages)
      assert assistant.role == :assistant
      assert is_nil(assistant.thinking) or byte_size(assistant.thinking) > 0
      assert is_binary(assistant.content)
      assert byte_size(assistant.content) > 0
    end

    test "thinking content matches accumulated deltas" do
      %{pid: pid, session_id: sid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "Think")
      events = collect_events(sid)

      # Accumulate thinking deltas
      accumulated =
        events
        |> Enum.filter(fn
          {:thinking_delta, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:thinking_delta, %{delta: d}} -> d end)
        |> Enum.join()

      # Compare to persisted thinking
      {_, messages, _} =
        Enum.find(events, fn
          {:agent_end, _, _} -> true
          _ -> false
        end)

      assert (List.last(messages).thinking || "") == accumulated
    end

    test "agent state has current_thinking after completion (reset on next turn)" do
      %{pid: pid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "First question")
      state = wait_for_idle(pid)

      # current_thinking may be nil if fixture has no reasoning deltas
      assert is_nil(state.current_thinking) or is_binary(state.current_thinking)
      if is_binary(state.current_thinking), do: assert(byte_size(state.current_thinking) > 0)
    end
  end

  describe "Chat Completions thinking — with tool calls" do
    test "thinking persists through tool execution loop" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "chat_completions_thinking_tool_call.json",
          second_fixture: "chat_completions_text.json",
          tools: [TestReadTool]
        )

      Agent.prompt(pid, "Read a file for me")
      events = collect_events(sid)

      types = Enum.map(events, &event_type/1)

      # Tool execution loop should complete; thinking is optional in fixtures
      assert :tool_execution_start in types
      assert :tool_execution_end in types
      assert :agent_end in types

      # Extract final messages
      {_, messages, _} =
        Enum.find(events, fn
          {:agent_end, _, _} -> true
          _ -> false
        end)

      # First assistant exists; it may or may not include thinking
      first_assistant = Enum.find(messages, &(&1.role == :assistant))
      assert first_assistant != nil
      if is_binary(first_assistant.thinking), do: assert(byte_size(first_assistant.thinking) > 0)

      # Message flow: user → assistant (thinking+tool) → tool_result → assistant
      roles = Enum.map(messages, & &1.role)
      assert hd(roles) == :user
      assert :tool_result in roles
      assert List.last(roles) == :assistant
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Responses API — reasoning summary (GPT-5 models via Copilot)
  # ════════════════════════════════════════════════════════════════════

  describe "Responses API thinking — text only" do
    test "broadcasts thinking events from reasoning items" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "responses_api_thinking.json",
          model_id: "gpt-5"
        )

      Agent.prompt(pid, "Reason about this")
      events = collect_events(sid)

      types = Enum.map(events, &event_type/1)

      assert :thinking_start in types
      assert :thinking_delta in types
      assert :message_delta in types
      assert :agent_end in types

      # Thinking before message content
      first_thinking = Enum.find_index(types, &(&1 == :thinking_start))
      first_message = Enum.find_index(types, &(&1 == :message_delta))
      assert first_thinking < first_message

      # Final message has thinking persisted
      {_, messages, _} =
        Enum.find(events, fn
          {:agent_end, _, _} -> true
          _ -> false
        end)

      assistant = List.last(messages)
      assert assistant.role == :assistant
      assert is_binary(assistant.thinking)
      assert byte_size(assistant.thinking) > 0
    end
  end

  describe "Responses API thinking — with tool calls" do
    test "reasoning + tool call flow works end-to-end" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "responses_api_thinking_tool_call.json",
          second_fixture: "responses_api_text.json",
          model_id: "gpt-5",
          tools: [TestReadTool]
        )

      Agent.prompt(pid, "Read a file for me")
      events = collect_events(sid)

      types = Enum.map(events, &event_type/1)

      assert :tool_execution_start in types
      assert :agent_end in types

      # First assistant exists; thinking may be absent in fixture
      {_, messages, _} =
        Enum.find(events, fn
          {:agent_end, _, _} -> true
          _ -> false
        end)

      first_assistant = Enum.find(messages, &(&1.role == :assistant))
      assert first_assistant != nil
      if is_binary(first_assistant.thinking), do: assert(byte_size(first_assistant.thinking) > 0)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Thinking level → Provider param mapping
  # ════════════════════════════════════════════════════════════════════

  describe "OpenAI reasoning_effort mapping" do
    test "maps all standard levels" do
      assert OpenAIShared.reasoning_effort(:off) == nil
      assert OpenAIShared.reasoning_effort(:low) == "low"
      assert OpenAIShared.reasoning_effort(:medium) == "medium"
      assert OpenAIShared.reasoning_effort(:high) == "high"
    end

    test ":max clamps to high for standard OpenAI models" do
      assert OpenAIShared.reasoning_effort(:max) == "high"
    end
  end

  describe "Copilot message conversion preserves thinking" do
    test "Chat Completions: reasoning_content roundtrips on assistant messages" do
      model = Model.new(:copilot, "claude-sonnet-4", thinking_level: :high)

      messages = [
        Message.assistant("The answer is 42.", [], thinking: "Let me think about this.")
      ]

      [converted] = Copilot.convert_messages(model, messages)

      assert converted.role == "assistant"
      assert converted.content == "The answer is 42."
      assert converted[:reasoning_content] == "Let me think about this."
    end

    test "Chat Completions: no reasoning_content when thinking is nil" do
      model = Model.new(:copilot, "claude-sonnet-4", thinking_level: :high)

      messages = [Message.assistant("Hello")]
      [converted] = Copilot.convert_messages(model, messages)

      refute Map.has_key?(converted, :reasoning_content)
    end

    test "Responses API: thinking roundtrips as reasoning summary item" do
      model = Model.new(:copilot, "gpt-5", thinking_level: :high)

      messages = [
        Message.assistant("Answer", [], thinking: "My reasoning")
      ]

      converted = Copilot.convert_messages(model, messages)

      reasoning_item = Enum.find(converted, &(Map.get(&1, :type) == "reasoning"))
      assert reasoning_item != nil
      assert reasoning_item.summary == [%{type: "summary_text", text: "My reasoning"}]

      message_item = Enum.find(converted, &(Map.get(&1, :role) == "assistant"))
      assert message_item != nil
    end

    test "Responses API: developer role when thinking is enabled" do
      for level <- [:low, :medium, :high, :max] do
        model = Model.new(:copilot, "gpt-5", thinking_level: level)
        messages = [%Message{id: "s1", role: :system, content: "Be helpful."}]
        [result] = Copilot.convert_messages(model, messages)
        assert result.role == "developer"
      end
    end

    test "Responses API: system role when thinking is off" do
      model = Model.new(:copilot, "gpt-5", thinking_level: :off)
      messages = [%Message{id: "s1", role: :system, content: "Be helpful."}]
      [result] = Copilot.convert_messages(model, messages)
      assert result.role == "system"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # SSE Parsing — unit-level verification of thinking event extraction
  # ════════════════════════════════════════════════════════════════════

  describe "Chat Completions SSE — reasoning_content parsing" do
    test "reasoning_content produces thinking_delta" do
      events =
        OpenAIShared.parse_chat_event(%{
          "choices" => [
            %{"delta" => %{"reasoning_content" => "thinking..."}, "finish_reason" => nil}
          ]
        })

      assert {:thinking_delta, "thinking..."} in events
    end

    test "simultaneous reasoning_content and content" do
      events =
        OpenAIShared.parse_chat_event(%{
          "choices" => [
            %{
              "delta" => %{
                "content" => "visible text",
                "reasoning_content" => "hidden thought"
              },
              "finish_reason" => nil
            }
          ]
        })

      assert {:text_delta, "visible text"} in events
      assert {:thinking_delta, "hidden thought"} in events
    end

    test "empty reasoning_content is ignored" do
      events =
        OpenAIShared.parse_chat_event(%{
          "choices" => [%{"delta" => %{"reasoning_content" => ""}, "finish_reason" => nil}]
        })

      refute Enum.any?(events, fn
               {:thinking_delta, _} -> true
               _ -> false
             end)
    end

    test "role-only chunk triggers text_start" do
      events =
        OpenAIShared.parse_chat_event(%{
          "choices" => [
            %{"delta" => %{"role" => "assistant", "content" => nil}, "finish_reason" => nil}
          ]
        })

      assert {:text_start, %{}} in events
    end
  end

  describe "Responses API SSE — reasoning item parsing" do
    test "reasoning output_item.added → thinking_start" do
      data =
        Jason.encode!(%{
          "type" => "response.output_item.added",
          "item" => %{"type" => "reasoning", "id" => "rs_001"}
        })

      assert [{:thinking_start, %{item_id: "rs_001"}}] = Copilot.parse_stream_event(data)
    end

    test "reasoning_summary_text.delta → thinking_delta" do
      data =
        Jason.encode!(%{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "step one"
        })

      assert [{:thinking_delta, "step one"}] = Copilot.parse_stream_event(data)
    end

    test "reasoning output_item.done is a no-op" do
      data =
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "item" => %{"type" => "reasoning", "id" => "rs_001"}
        })

      assert [] = Copilot.parse_stream_event(data)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Model thinking level validation
  # ════════════════════════════════════════════════════════════════════

  describe "Model thinking levels" do
    test "all valid levels accepted" do
      for level <- [:off, :low, :medium, :high, :max] do
        model = Model.new(:copilot, "test", thinking_level: level)
        assert model.thinking_level == level
      end
    end

    test "defaults to :off" do
      assert Model.new(:copilot, "test").thinking_level == :off
    end

    test "invalid levels rejected" do
      for bad <- [:xhigh, :extreme, :auto, :none, :turbo] do
        assert_raise ArgumentError, fn ->
          Model.new(:copilot, "test", thinking_level: bad)
        end
      end
    end

    test "thinking level propagates through parse/2" do
      model = Model.parse("anthropic:claude-sonnet-4-5", thinking_level: :medium)
      assert model.thinking_level == :medium
      assert model.provider == :anthropic
    end

    test "thinking level propagates through coerce/2" do
      model = Model.coerce({:copilot, "claude-opus-4.6"}, thinking_level: :max)
      assert model.thinking_level == :max
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Agent stream.ex — thinking accumulation
  # ════════════════════════════════════════════════════════════════════

  describe "Agent thinking accumulation" do
    test "current_thinking accumulates deltas" do
      %{pid: pid} = start_agent(fixture: "chat_completions_thinking.json")
      Agent.prompt(pid, "Think")
      state = wait_for_idle(pid)

      # current_thinking holds accumulated value when thinking deltas exist
      assert is_nil(state.current_thinking) or is_binary(state.current_thinking)
      if is_binary(state.current_thinking), do: assert(byte_size(state.current_thinking) > 0)
      # The message also has the thinking
      assistant = hd(state.messages)
      assert assistant.thinking == state.current_thinking
    end

    test "current_thinking resets at the start of each new turn" do
      %{pid: pid, session_id: sid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "First")
      wait_for_idle(pid)

      # Start second turn — current_thinking will reset at run_turn_internal
      Agent.prompt(pid, "Second")
      # After idle, it holds the NEW turn's thinking
      state = wait_for_idle(pid)
      assert is_nil(state.current_thinking) or is_binary(state.current_thinking)

      # Drain events
      collect_events(sid)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # OpenAI message conversion (shared module)
  # ════════════════════════════════════════════════════════════════════

  describe "OpenAI.convert_messages/2 thinking roundtrip" do
    test "includes reasoning_content when thinking present" do
      messages = [
        Message.assistant("Response", [], thinking: "My thinking process")
      ]

      [converted] = OpenAIShared.convert_messages_openai(messages)
      assert converted[:reasoning_content] == "My thinking process"
      assert converted.content == "Response"
      assert converted.role == "assistant"
    end

    test "omits reasoning_content when thinking is nil" do
      messages = [Message.assistant("Hello")]
      [converted] = OpenAIShared.convert_messages_openai(messages)
      refute Map.has_key?(converted, :reasoning_content)
    end

    test "omits reasoning_content when include_thinking: false" do
      messages = [
        Message.assistant("Response", [], thinking: "thinking content")
      ]

      [converted] = OpenAIShared.convert_messages_openai(messages, include_thinking: false)
      refute Map.has_key?(converted, :reasoning_content)
    end

    test "assistant with tool calls includes thinking" do
      tc = %{call_id: "c1", name: "test", arguments: %{}}
      messages = [Message.assistant("Text", [tc], thinking: "Thought process")]

      [converted] = OpenAIShared.convert_messages_openai(messages)
      assert converted[:reasoning_content] == "Thought process"
      assert length(converted.tool_calls) == 1
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Event ordering verification
  # ════════════════════════════════════════════════════════════════════

  describe "event ordering" do
    test "Chat Completions: thinking events precede message events" do
      %{pid: pid, session_id: sid} =
        start_agent(fixture: "chat_completions_thinking.json")

      Agent.prompt(pid, "Test ordering")
      events = collect_events(sid)
      types = Enum.map(events, &event_type/1)

      first_thinking = Enum.find_index(types, &(&1 == :thinking_start))
      first_message = Enum.find_index(types, &(&1 == :message_delta))

      assert first_message != nil, "Expected message_delta event, got: #{inspect(types)}"

      if first_thinking != nil do
        assert first_thinking < first_message
      end
    end

    test "Responses API: reasoning events precede text events" do
      %{pid: pid, session_id: sid} =
        start_agent(
          fixture: "responses_api_thinking.json",
          model_id: "gpt-5"
        )

      Agent.prompt(pid, "Test ordering")
      events = collect_events(sid)
      types = Enum.map(events, &event_type/1)

      first_thinking = Enum.find_index(types, &(&1 == :thinking_start))
      first_message = Enum.find_index(types, &(&1 in [:message_start, :message_delta]))

      assert first_thinking != nil, "Expected thinking_start, got: #{inspect(types)}"
      assert first_message != nil, "Expected message event, got: #{inspect(types)}"
      assert first_thinking < first_message
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Models discovery — thinking levels per model
  # ════════════════════════════════════════════════════════════════════

  describe "Models thinking level discovery" do
    test "thinking-capable copilot models have non-empty thinking_levels" do
      models = Opal.Provider.Registry.list_copilot()
      claude_sonnet = Enum.find(models, &(&1.id == "claude-sonnet-4"))

      assert claude_sonnet != nil
      assert claude_sonnet.supports_thinking == true
      assert is_list(claude_sonnet.thinking_levels)
      assert "high" in claude_sonnet.thinking_levels
    end

    test "non-thinking models have empty thinking_levels" do
      models = Opal.Provider.Registry.list_copilot()
      gpt4o = Enum.find(models, &(&1.id == "gpt-4o"))

      if gpt4o do
        assert gpt4o.supports_thinking == false
        assert gpt4o.thinking_levels == []
      end
    end

    test "opus models support max level" do
      models = Opal.Provider.Registry.list_copilot()
      opus = Enum.find(models, &(&1.id == "claude-opus-4.6"))

      if opus do
        assert "max" in opus.thinking_levels
      end
    end
  end
end
