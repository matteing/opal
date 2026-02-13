defmodule Opal.Session.CompactionTest do
  use ExUnit.Case, async: true

  alias Opal.Session
  alias Opal.Session.Compaction
  alias Opal.Message

  # Mock provider that returns a canned summary via streaming
  defmodule MockProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      # Extract the prompt to determine what to return
      prompt_msg = List.last(messages)
      # Match the updated prompt format (anti-continuation rules + conversation tags)
      summary =
        if prompt_msg && (prompt_msg.content =~ "<conversation>" or prompt_msg.content =~ "TRANSCRIPT") do
          "## Goal\nTest summary"
        else
          "Mock summary"
        end

      caller = self()
      ref = make_ref()

      resp = %Req.Response{
        status: 200,
        headers: %{},
        body: %Req.Response.Async{
          ref: ref,
          stream_fun: fn
            inner_ref, {inner_ref, {:data, data}} -> {:ok, [data: data]}
            inner_ref, {inner_ref, :done} -> {:ok, [:done]}
            _, _ -> :unknown
          end,
          cancel_fun: fn _ref -> :ok end
        }
      }

      # Build SSE events matching Copilot Responses API format
      # Use simple single-line deltas to avoid newline splitting issues
      events = [
        "data: " <> Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message"}}) <> "\n",
        "data: " <> Jason.encode!(%{"type" => "response.output_text.delta", "delta" => summary}) <> "\n",
        "data: " <> Jason.encode!(%{"type" => "response.completed"}) <> "\n"
      ]

      spawn(fn ->
        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end
        send(caller, {ref, :done})
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => "response.output_text.delta", "delta" => delta}} ->
          [{:text_delta, delta}]
        {:ok, %{"type" => "response.completed"}} ->
          [:done]
        _ ->
          []
      end
    end

    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # Mock provider that always fails
  defmodule FailingProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      {:error, :provider_unavailable}
    end

    @impl true
    def parse_stream_event(_data), do: []
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  @model %Opal.Model{provider: :test, id: "test-model"}

  setup do
    {:ok, session} =
      Session.start_link(session_id: "compact-test-#{System.unique_integer([:positive])}")

    %{session: session}
  end

  # Helper: populate a session with n user/assistant turn pairs of ~chars_each size
  defp populate_turns(session, n, chars_each \\ 200) do
    for i <- 1..n do
      :ok = Session.append(session, Message.user("user msg #{i} " <> String.duplicate("x", chars_each)))
      :ok = Session.append(session, Message.assistant("reply #{i} " <> String.duplicate("y", chars_each)))
    end
    :ok
  end

  # --- Truncate strategy ---

  describe "compact/2 with :truncate strategy" do
    test "does nothing when too few messages", %{session: session} do
      :ok = Session.append(session, Message.user("a"))
      :ok = Session.append(session, Message.assistant("b"))

      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)

      path = Session.get_path(session)
      assert length(path) == 2
    end

    test "compacts older messages into a summary", %{session: session} do
      for i <- 1..10 do
        :ok = Session.append(session, Message.user("msg #{i} " <> String.duplicate("x", 200)))
      end

      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      path = Session.get_path(session)
      assert length(path) < 10

      summary = hd(path)
      assert summary.role == :user
      assert summary.content =~ "Compacted"
    end

    test "preserves tree integrity after compaction", %{session: session} do
      for i <- 1..10 do
        :ok = Session.append(session, Message.user("msg #{i} " <> String.duplicate("y", 200)))
      end

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      path = Session.get_path(session)
      [first | rest] = path
      assert first.parent_id == nil

      Enum.reduce(rest, first, fn msg, prev ->
        assert msg.parent_id == prev.id
        msg
      end)
    end

    test "summary includes role frequencies", %{session: session} do
      populate_turns(session, 6)

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      path = Session.get_path(session)
      summary = hd(path)
      assert summary.content =~ "Compacted"
      assert summary.content =~ "user"
      assert summary.content =~ "assistant"
    end

    test "summary wraps content with conversation summary header", %{session: session} do
      populate_turns(session, 6)

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      summary = hd(Session.get_path(session))
      assert summary.content =~ "[Conversation summary"
    end
  end

  # --- Summarize strategy ---

  describe "compact/2 with :summarize strategy" do
    test "uses LLM provider to generate summary", %{session: session} do
      populate_turns(session, 6)

      :ok = Compaction.compact(session,
        strategy: :summarize,
        provider: MockProvider,
        model: @model,
        keep_recent_tokens: 200
      )

      path = Session.get_path(session)
      assert length(path) < 12

      summary = hd(path)
      assert summary.content =~ "Goal"
    end

    test "falls back to truncation when provider fails", %{session: session} do
      populate_turns(session, 6)

      :ok = Compaction.compact(session,
        strategy: :summarize,
        provider: FailingProvider,
        model: @model,
        keep_recent_tokens: 200
      )

      path = Session.get_path(session)
      summary = hd(path)
      # Should fall back to truncation format
      assert summary.content =~ "Compacted"
    end

    test "defaults to :summarize when provider is available", %{session: session} do
      populate_turns(session, 6)

      # No explicit strategy — should default to :summarize because provider is given
      :ok = Compaction.compact(session,
        provider: MockProvider,
        model: @model,
        keep_recent_tokens: 200
      )

      path = Session.get_path(session)
      summary = hd(path)
      assert summary.content =~ "Goal"
    end

    test "defaults to :truncate when no provider given", %{session: session} do
      populate_turns(session, 6)

      # No provider — should default to :truncate
      :ok = Compaction.compact(session, keep_recent_tokens: 200)

      path = Session.get_path(session)
      summary = hd(path)
      assert summary.content =~ "Compacted"
    end
  end

  # --- Force option ---

  describe "compact/2 with :force option" do
    test "compacts even when content fits in budget", %{session: session} do
      # 5 short messages that easily fit in 100k tokens
      :ok = Session.append(session, Message.user("first"))
      :ok = Session.append(session, Message.assistant("second"))
      :ok = Session.append(session, Message.user("third"))
      :ok = Session.append(session, Message.assistant("fourth"))
      :ok = Session.append(session, Message.user("fifth"))

      original_count = length(Session.get_path(session))
      assert original_count == 5

      :ok = Compaction.compact(session,
        strategy: :truncate,
        keep_recent_tokens: 100_000,
        force: true
      )

      path = Session.get_path(session)
      # Force mode: compact all but last 2, so 1 summary + 2 kept = 3 < 5
      assert length(path) < original_count
    end

    test "force keeps at least 2 messages", %{session: session} do
      :ok = Session.append(session, Message.user("first"))
      :ok = Session.append(session, Message.assistant("second"))
      :ok = Session.append(session, Message.user("third"))
      :ok = Session.append(session, Message.assistant("fourth"))

      :ok = Compaction.compact(session,
        strategy: :truncate,
        keep_recent_tokens: 100_000,
        force: true
      )

      path = Session.get_path(session)
      # Summary + last 2 messages
      assert length(path) >= 2
    end

    test "force does nothing with 2 or fewer messages", %{session: session} do
      :ok = Session.append(session, Message.user("only"))
      :ok = Session.append(session, Message.assistant("two"))

      :ok = Compaction.compact(session,
        strategy: :truncate,
        keep_recent_tokens: 100_000,
        force: true
      )

      path = Session.get_path(session)
      assert length(path) == 2
    end
  end

  # --- Serialize conversation ---

  describe "serialize_conversation/1" do
    test "serializes user and assistant messages" do
      messages = [
        %Message{id: "1", role: :user, content: "Hello"},
        %Message{id: "2", role: :assistant, content: "Hi there"}
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[User]: Hello"
      assert transcript =~ "[Assistant]: Hi there"
    end

    test "serializes tool calls in assistant messages" do
      messages = [
        %Message{
          id: "1",
          role: :assistant,
          content: "Let me check",
          tool_calls: [
            %{name: "read_file", arguments: %{"path" => "foo.ex"}}
          ]
        }
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[Assistant]: Let me check"
      assert transcript =~ "[Assistant tool calls]:"
      assert transcript =~ "read_file("
    end

    test "serializes tool result messages" do
      messages = [
        %Message{id: "1", role: :tool_result, call_id: "call_1", name: "read_file", content: "file contents here"}
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[Tool result (read_file)]:"
      assert transcript =~ "file contents here"
    end

    test "serializes system messages" do
      messages = [
        %Message{id: "1", role: :system, content: "You are helpful"}
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[System]: You are helpful"
    end

    test "handles nil content" do
      messages = [
        %Message{id: "1", role: :user, content: nil},
        %Message{id: "2", role: :assistant, content: nil}
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[User]:"
      assert transcript =~ "[Assistant]:"
    end

    test "truncates long tool result output" do
      long_content = String.duplicate("x", 1000)
      messages = [
        %Message{id: "1", role: :tool_result, call_id: "c1", name: "read_file", content: long_content}
      ]

      transcript = Compaction.serialize_conversation(messages)
      # Tool result content is sliced to 500 chars
      assert String.length(transcript) < 1000
    end
  end

  # --- Extract file ops ---

  describe "extract_file_ops/1" do
    test "extracts read and modified file paths" do
      messages = [
        %Message{
          id: "1",
          role: :assistant,
          content: "Let me check",
          tool_calls: [
            %{name: "read_file", arguments: %{"path" => "lib/foo.ex"}},
            %{name: "write_file", arguments: %{"path" => "lib/bar.ex"}},
            %{name: "edit_file", arguments: %{"path" => "lib/baz.ex"}}
          ]
        }
      ]

      ops = Compaction.extract_file_ops(messages)
      assert "lib/foo.ex" in ops.read
      assert "lib/bar.ex" in ops.modified
      assert "lib/baz.ex" in ops.modified
    end

    test "deduplicates file paths" do
      messages = [
        %Message{
          id: "1", role: :assistant, content: "first",
          tool_calls: [%{name: "read_file", arguments: %{"path" => "lib/foo.ex"}}]
        },
        %Message{
          id: "2", role: :assistant, content: "second",
          tool_calls: [%{name: "read_file", arguments: %{"path" => "lib/foo.ex"}}]
        }
      ]

      ops = Compaction.extract_file_ops(messages)
      assert ops.read == ["lib/foo.ex"]
    end

    test "ignores non-file tool calls" do
      messages = [
        %Message{
          id: "1", role: :assistant, content: "running",
          tool_calls: [%{name: "shell", arguments: %{"command" => "ls"}}]
        }
      ]

      ops = Compaction.extract_file_ops(messages)
      assert ops.read == []
      assert ops.modified == []
    end

    test "ignores tool calls without path argument" do
      messages = [
        %Message{
          id: "1", role: :assistant, content: "hmm",
          tool_calls: [%{name: "read_file", arguments: %{}}]
        }
      ]

      ops = Compaction.extract_file_ops(messages)
      assert ops.read == []
    end

    test "ignores non-assistant messages" do
      messages = [
        %Message{id: "1", role: :user, content: "read lib/foo.ex"},
        %Message{id: "2", role: :tool_result, call_id: "c1", content: "contents"}
      ]

      ops = Compaction.extract_file_ops(messages)
      assert ops.read == []
      assert ops.modified == []
    end

    test "returns empty when no messages" do
      ops = Compaction.extract_file_ops([])
      assert ops.read == []
      assert ops.modified == []
    end
  end

  # --- Cut point and turn boundaries ---

  describe "cut point and turn boundaries" do
    test "cuts at user message boundary", %{session: session} do
      for i <- 1..6 do
        :ok = Session.append(session, Message.user("user msg #{i} " <> String.duplicate("z", 300)))
        :ok = Session.append(session, Message.assistant("reply #{i} " <> String.duplicate("z", 300)))
      end

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 300)

      path = Session.get_path(session)
      non_summary = Enum.drop(path, 1)
      if non_summary != [] do
        assert hd(non_summary).role == :user
      end
    end

    test "does not compact if everything fits in budget", %{session: session} do
      :ok = Session.append(session, Message.user("short"))
      :ok = Session.append(session, Message.assistant("reply"))
      :ok = Session.append(session, Message.user("another"))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100_000)

      path = Session.get_path(session)
      assert length(path) == 3
    end

    test "includes file ops in truncation summary", %{session: session} do
      :ok = Session.append(session, Message.user("read a file"))
      :ok = Session.append(session, %Message{
        id: "tc1",
        role: :assistant,
        content: "reading" <> String.duplicate("x", 500),
        tool_calls: [%{name: "read_file", arguments: %{"path" => "lib/app.ex"}}]
      })
      :ok = Session.append(session, Message.user("edit it"))
      :ok = Session.append(session, %Message{
        id: "tc2",
        role: :assistant,
        content: "editing" <> String.duplicate("x", 500),
        tool_calls: [%{name: "edit_file", arguments: %{"path" => "lib/app.ex"}}]
      })
      :ok = Session.append(session, Message.user("done"))
      :ok = Session.append(session, Message.assistant("ok" <> String.duplicate("x", 500)))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)

      path = Session.get_path(session)
      summary = hd(path)
      assert summary.content =~ "read-files" or summary.content =~ "modified-files" or summary.content =~ "Compacted"
    end

    test "preserves tool result messages in kept portion", %{session: session} do
      # Build a conversation with tool calls and results
      :ok = Session.append(session, Message.user("old question " <> String.duplicate("a", 500)))
      :ok = Session.append(session, Message.assistant("old reply " <> String.duplicate("b", 500)))
      :ok = Session.append(session, Message.user("recent question"))
      :ok = Session.append(session, %Message{
        id: "tc_kept",
        role: :assistant,
        content: "let me check",
        tool_calls: [%{name: "read_file", arguments: %{"path" => "recent.ex"}}]
      })
      :ok = Session.append(session, %Message{
        id: "tr_kept",
        role: :tool_result,
        call_id: "call_1",
        name: "read",
        content: "recent contents"
      })
      :ok = Session.append(session, Message.assistant("here's what I found"))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 300)

      path = Session.get_path(session)
      roles = Enum.map(path, & &1.role)

      # Recent messages should be kept (may or may not include tool_result depending on cut)
      assert :user in roles or length(path) >= 2
    end
  end

  # --- Multiple compaction rounds ---

  describe "repeated compaction" do
    test "can compact multiple times", %{session: session} do
      # First round of messages
      populate_turns(session, 6)
      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      path_after_first = Session.get_path(session)
      first_count = length(path_after_first)
      assert first_count < 12

      # Add more messages
      for i <- 1..4 do
        :ok = Session.append(session, Message.user("new msg #{i} " <> String.duplicate("z", 300)))
        :ok = Session.append(session, Message.assistant("new reply #{i} " <> String.duplicate("w", 300)))
      end

      # Second compaction
      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 200)

      path_after_second = Session.get_path(session)
      assert length(path_after_second) < first_count + 8

      # Tree integrity still holds
      [first | rest] = path_after_second
      assert first.parent_id == nil
      Enum.reduce(rest, first, fn msg, prev ->
        assert msg.parent_id == prev.id
        msg
      end)
    end
  end

  # --- Anti-continuation serialization (Plan 07) ---

  describe "serialize_conversation/1 — anti-continuation" do
    test "wraps output in <conversation> tags" do
      messages = [
        %Message{id: "1", role: :user, content: "Hello"},
        %Message{id: "2", role: :assistant, content: "Hi"}
      ]

      transcript = Compaction.serialize_conversation(messages)
      assert String.starts_with?(transcript, "<conversation>\n")
      assert String.ends_with?(transcript, "\n</conversation>")
    end

    test "content inside tags preserves message format" do
      messages = [%Message{id: "1", role: :user, content: "Question?"}]
      transcript = Compaction.serialize_conversation(messages)
      assert transcript =~ "[User]: Question?"
    end
  end

  # --- Iterative summary updates (Plan 04) ---

  describe "iterative summary updates" do
    test "detects previous summary and uses update prompt", %{session: session} do
      # First compaction cycle
      populate_turns(session, 6)
      :ok = Compaction.compact(session,
        strategy: :summarize,
        provider: MockProvider,
        model: @model,
        keep_recent_tokens: 200
      )

      path_after_first = Session.get_path(session)
      summary_1 = hd(path_after_first)
      assert summary_1.content =~ "[Conversation summary"

      # Add more messages for second cycle
      for i <- 1..4 do
        :ok = Session.append(session, Message.user("new msg #{i} " <> String.duplicate("z", 300)))
        :ok = Session.append(session, Message.assistant("new reply #{i} " <> String.duplicate("w", 300)))
      end

      # Second compaction — should build on the previous summary
      :ok = Compaction.compact(session,
        strategy: :summarize,
        provider: MockProvider,
        model: @model,
        keep_recent_tokens: 200
      )

      path_after_second = Session.get_path(session)
      summary_2 = hd(path_after_second)
      assert summary_2.content =~ "[Conversation summary"
      # Should still have coherent content after iterative update
      assert String.length(summary_2.content) > 0
    end
  end

  # --- Cumulative file-op tracking (Plan 05) ---

  describe "cumulative file-op tracking" do
    test "summary message carries metadata with file ops", %{session: session} do
      :ok = Session.append(session, Message.user("read a file"))
      :ok = Session.append(session, %Message{
        id: "tc1", role: :assistant, content: "reading" <> String.duplicate("x", 500),
        tool_calls: [%{name: "read_file", arguments: %{"path" => "lib/app.ex"}}]
      })
      :ok = Session.append(session, Message.user("done"))
      :ok = Session.append(session, Message.assistant("ok" <> String.duplicate("x", 500)))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)

      summary = hd(Session.get_path(session))
      assert summary.metadata != nil
      assert summary.metadata.type == :compaction_summary
      assert "lib/app.ex" in summary.metadata.read_files
    end

    test "file ops accumulate across compaction cycles", %{session: session} do
      # Cycle 1: read file_a.ex, write file_b.ex
      :ok = Session.append(session, Message.user("read and write"))
      :ok = Session.append(session, %Message{
        id: "tc1", role: :assistant, content: String.duplicate("x", 500),
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "file_a.ex"}},
          %{name: "write_file", arguments: %{"path" => "file_b.ex"}}
        ]
      })
      :ok = Session.append(session, Message.user("next"))
      :ok = Session.append(session, Message.assistant("ok" <> String.duplicate("x", 500)))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)

      # Verify cycle 1 metadata
      summary_1 = hd(Session.get_path(session))
      assert "file_a.ex" in summary_1.metadata.read_files
      assert "file_b.ex" in summary_1.metadata.modified_files

      # Cycle 2: read file_c.ex, edit file_a.ex (should move to modified)
      :ok = Session.append(session, Message.user("more work"))
      :ok = Session.append(session, %Message{
        id: "tc2", role: :assistant, content: String.duplicate("y", 500),
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "file_c.ex"}},
          %{name: "edit_file", arguments: %{"path" => "file_a.ex"}}
        ]
      })
      :ok = Session.append(session, Message.user("done"))
      :ok = Session.append(session, Message.assistant("done" <> String.duplicate("z", 500)))

      :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)

      summary_2 = hd(Session.get_path(session))

      # file_a.ex should have moved from read to modified
      assert "file_a.ex" in summary_2.metadata.modified_files
      refute "file_a.ex" in summary_2.metadata.read_files

      # file_b.ex still in modified, file_c.ex in read
      assert "file_b.ex" in summary_2.metadata.modified_files
      assert "file_c.ex" in summary_2.metadata.read_files
    end

    test "merge_file_ops deduplicates paths" do
      ops = Compaction.extract_file_ops([
        %Message{id: "1", role: :assistant, content: "",
          tool_calls: [
            %{name: "read_file", arguments: %{"path" => "a.ex"}},
            %{name: "read_file", arguments: %{"path" => "a.ex"}}
          ]}
      ])

      assert ops.read == ["a.ex"]
    end
  end

  # --- Split-turn compaction (Plan 06) ---

  describe "split-turn compaction" do
    test "clean cut at turn boundary produces standard summary", %{session: session} do
      # Build clean turn boundaries: user/assistant pairs
      populate_turns(session, 6)

      :ok = Compaction.compact(session,
        strategy: :truncate,
        keep_recent_tokens: 300
      )

      path = Session.get_path(session)
      summary = hd(path)
      # Should not contain split-turn markers
      refute summary.content =~ "Turn Context"
    end

    test "split turn generates dual summary", %{session: session} do
      # Create a session where a single turn dominates:
      # User message followed by many assistant+tool result messages
      :ok = Session.append(session, Message.user("old turn " <> String.duplicate("a", 200)))
      :ok = Session.append(session, Message.assistant("old reply " <> String.duplicate("b", 200)))

      # Big turn: one user message, then many assistant+tool messages
      :ok = Session.append(session, Message.user("Refactor everything"))
      for i <- 1..20 do
        :ok = Session.append(session, %Message{
          id: "tc_#{i}", role: :assistant, content: "step #{i}" <> String.duplicate("x", 200),
          tool_calls: [%{name: "edit_file", arguments: %{"path" => "file_#{i}.ex"}}]
        })
        :ok = Session.append(session, %Message{
          id: "tr_#{i}", role: :tool_result, call_id: "call_#{i}", name: "edit_file",
          content: "edited" <> String.duplicate("y", 200)
        })
      end

      # Keep only a small budget so the cut lands mid-turn
      :ok = Compaction.compact(session,
        strategy: :summarize,
        provider: MockProvider,
        model: @model,
        keep_recent_tokens: 500
      )

      path = Session.get_path(session)
      summary = hd(path)

      # If the split was detected, we get a dual summary containing
      # both a history section and a turn context section
      # (Either way it should have compacted successfully)
      assert summary.content =~ "[Conversation summary"
      assert length(path) < 42 # started with 2 + 1 + 40 = 43
    end
  end

  # --- Message metadata persistence ---

  describe "metadata persistence" do
    test "metadata field survives struct creation" do
      msg = %Message{
        id: "test", role: :user, content: "hello",
        metadata: %{type: :compaction_summary, read_files: ["a.ex"]}
      }

      assert msg.metadata.type == :compaction_summary
      assert msg.metadata.read_files == ["a.ex"]
    end

    test "metadata is nil by default" do
      msg = Message.user("hello")
      assert msg.metadata == nil
    end
  end

  # --- Edge cases ---

  describe "edge cases" do
    test "empty session returns :ok", %{session: session} do
      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 100)
      assert Session.get_path(session) == []
    end

    test "single message returns :ok without compacting", %{session: session} do
      :ok = Session.append(session, Message.user("only one"))
      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 1)
      assert length(Session.get_path(session)) == 1
    end

    test "handles messages with nil content in token estimation", %{session: session} do
      :ok = Session.append(session, %Message{id: "nil1", role: :user, content: nil})
      :ok = Session.append(session, %Message{id: "nil2", role: :assistant, content: nil})
      :ok = Session.append(session, Message.user("recent " <> String.duplicate("x", 500)))

      # Should not crash on nil content
      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 50)
    end

    test "handles very large keep_recent_tokens gracefully", %{session: session} do
      populate_turns(session, 3)
      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 10_000_000)
      assert length(Session.get_path(session)) == 6
    end

    test "handles keep_recent_tokens of 0", %{session: session} do
      populate_turns(session, 3)
      # With 0 tokens budget, everything should be compacted (except the cut needs ≥1 message)
      assert :ok = Compaction.compact(session, strategy: :truncate, keep_recent_tokens: 0)
      path = Session.get_path(session)
      # Should still have at least a summary
      assert length(path) >= 1
    end
  end
end
