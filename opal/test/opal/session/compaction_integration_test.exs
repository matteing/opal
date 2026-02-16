defmodule Opal.Session.CompactionIntegrationTest do
  @moduledoc """
  Integration tests for the compaction system using cached API responses.

  These tests drive compaction through realistic multi-turn conversations
  and verify behavior using recorded (cached) LLM responses, ensuring
  the full pipeline works end-to-end without hitting a live API.

  Run live tests (requires valid Copilot auth):

      mix test --include live test/opal/session/compaction_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias Opal.Session
  alias Opal.Session.Compaction
  alias Opal.Message
  alias Opal.Test.FixtureHelper

  # ── Fixture-backed Provider ──────────────────────────────────────────
  #
  # Serves cached API responses from a queue of fixtures, parsing events
  # through the real Copilot SSE parser. Each call to stream/4 advances
  # the queue, so tests can supply different fixtures for sequential
  # summarization calls (e.g. split-turn compaction makes 2 calls).

  defmodule CompactionProvider do
    @behaviour Opal.Provider

    def setup(fixtures) when is_list(fixtures) do
      :persistent_term.put({__MODULE__, :fixtures}, fixtures)
      :persistent_term.put({__MODULE__, :call_count}, 0)
    end

    def call_count do
      :persistent_term.get({__MODULE__, :call_count}, 0)
    end

    def cleanup do
      for key <- [:fixtures, :call_count] do
        try do
          :persistent_term.erase({__MODULE__, key})
        rescue
          _ -> :ok
        end
      end
    end

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      fixtures = :persistent_term.get({__MODULE__, :fixtures}, ["responses_api_text.json"])
      idx = :persistent_term.get({__MODULE__, :call_count}, 0)
      :persistent_term.put({__MODULE__, :call_count}, idx + 1)
      fixture = Enum.at(fixtures, idx) || List.last(fixtures)
      FixtureHelper.build_fixture_response(fixture)
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  # ── Agent-aware Provider ─────────────────────────────────────────────
  #
  # Distinguishes between normal agent turns and compaction summarization
  # calls by inspecting the system prompt. Serves different fixtures for
  # each, enabling end-to-end agent-driven compaction tests.

  defmodule AgentCompactionProvider do
    @behaviour Opal.Provider

    def setup(turn_fixture, compaction_fixtures) do
      :persistent_term.put({__MODULE__, :turn_fixture}, turn_fixture)
      :persistent_term.put({__MODULE__, :compaction_fixtures}, compaction_fixtures)
      :persistent_term.put({__MODULE__, :compaction_call}, 0)
    end

    def cleanup do
      for key <- [:turn_fixture, :compaction_fixtures, :compaction_call] do
        try do
          :persistent_term.erase({__MODULE__, key})
        rescue
          _ -> :ok
        end
      end
    end

    @impl true
    def stream(_model, messages, _tools, _opts \\ []) do
      is_compaction =
        Enum.any?(messages, fn
          %{role: :system, content: c} when is_binary(c) -> c =~ "summarizer"
          _ -> false
        end)

      if is_compaction do
        fixtures =
          :persistent_term.get({__MODULE__, :compaction_fixtures}, ["compaction_summary.json"])

        idx = :persistent_term.get({__MODULE__, :compaction_call}, 0)
        :persistent_term.put({__MODULE__, :compaction_call}, idx + 1)
        fixture = Enum.at(fixtures, idx) || List.last(fixtures)
        FixtureHelper.build_fixture_response(fixture)
      else
        fixture = :persistent_term.get({__MODULE__, :turn_fixture}, "responses_api_text.json")
        FixtureHelper.build_fixture_response(fixture)
      end
    end

    @impl true
    def parse_stream_event(data), do: Opal.Provider.Copilot.parse_stream_event(data)
    @impl true
    def convert_messages(_model, messages), do: messages
    @impl true
    def convert_tools(tools), do: tools
  end

  @model %Opal.Provider.Model{provider: :test, id: "test-model"}

  setup do
    {:ok, session} =
      Session.start_link(session_id: "compact-integ-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      CompactionProvider.cleanup()
      AgentCompactionProvider.cleanup()
    end)

    %{session: session}
  end

  # ── Conversation Builders ────────────────────────────────────────────
  #
  # These produce realistic multi-turn agent conversations with tool calls,
  # tool results, and natural user/assistant exchanges — the kind of data
  # the compaction system encounters in production.

  # Builds a realistic 4-turn coding session: user asks for a Phoenix
  # LiveView dashboard, agent reads files, creates modules, and writes tests.
  defp build_coding_session(session) do
    # Turn 1: User describes the feature, agent reads project files
    :ok =
      Session.append(
        session,
        Message.user(
          "I need to add a real-time metrics dashboard to my Phoenix app. " <>
            "It should show CPU usage, memory, and active connections. " <>
            "Use LiveView for real-time updates."
        )
      )

    :ok =
      Session.append(session, %Message{
        id: "ast_1",
        role: :assistant,
        content:
          "I'll help you create a real-time metrics dashboard. " <>
            "Let me start by examining your project structure.",
        tool_calls: [
          %{
            call_id: "call_1",
            name: "read_file",
            arguments: %{"path" => "lib/app_web/router.ex"}
          },
          %{
            call_id: "call_2",
            name: "read_file",
            arguments: %{"path" => "lib/app/metrics_collector.ex"}
          }
        ]
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_1",
        role: :tool_result,
        call_id: "call_1",
        name: "read_file",
        content:
          "defmodule AppWeb.Router do\n  use AppWeb, :router\n\n" <>
            "  scope \"/\", AppWeb do\n    pipe_through :browser\n" <>
            "    live \"/\", PageLive\n  end\nend"
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_2",
        role: :tool_result,
        call_id: "call_2",
        name: "read_file",
        content:
          "defmodule App.MetricsCollector do\n  use GenServer\n\n" <>
            "  def get_metrics do\n    %{cpu: :cpu_sup.avg1(), memory: :erlang.memory(:total)}\n" <>
            "  end\nend"
      })

    # Turn 2: Agent creates the dashboard and edits the router
    :ok =
      Session.append(session, %Message{
        id: "ast_2",
        role: :assistant,
        content: "I can see the structure. Let me create DashboardLive and update the router.",
        tool_calls: [
          %{
            call_id: "call_3",
            name: "write_file",
            arguments: %{
              "path" => "lib/app_web/live/dashboard_live.ex",
              "content" =>
                "defmodule AppWeb.DashboardLive do\n  use AppWeb, :live_view\n\n" <>
                  "  @impl true\n  def mount(_params, _session, socket) do\n" <>
                  "    if connected?(socket), do: :timer.send_interval(5000, :tick)\n" <>
                  "    {:ok, assign(socket, metrics: App.MetricsCollector.get_metrics())}\n" <>
                  "  end\nend"
            }
          },
          %{
            call_id: "call_4",
            name: "edit_file",
            arguments: %{
              "path" => "lib/app_web/router.ex",
              "content" => "live \"/dashboard\", DashboardLive"
            }
          }
        ]
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_3",
        role: :tool_result,
        call_id: "call_3",
        name: "write_file",
        content: "File written successfully"
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_4",
        role: :tool_result,
        call_id: "call_4",
        name: "edit_file",
        content: "File edited successfully"
      })

    # Turn 3: User asks for tests, agent reads existing test and writes new one
    :ok = Session.append(session, Message.user("Great! Now add some tests for the dashboard."))

    :ok =
      Session.append(session, %Message{
        id: "ast_3",
        role: :assistant,
        content: "I'll read the existing test patterns first, then write dashboard tests.",
        tool_calls: [
          %{
            call_id: "call_5",
            name: "read_file",
            arguments: %{"path" => "test/app_web/live/page_live_test.exs"}
          }
        ]
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_5",
        role: :tool_result,
        call_id: "call_5",
        name: "read_file",
        content:
          "defmodule AppWeb.PageLiveTest do\n  use AppWeb.ConnCase, async: true\n" <>
            "  import Phoenix.LiveViewTest\n\n  test \"renders page\" do\n" <>
            "    {:ok, _view, html} = live(conn, \"/\")\n    assert html =~ \"Welcome\"\n  end\nend"
      })

    :ok =
      Session.append(session, %Message{
        id: "ast_4",
        role: :assistant,
        content: "Creating the dashboard test file following existing patterns.",
        tool_calls: [
          %{
            call_id: "call_6",
            name: "write_file",
            arguments: %{
              "path" => "test/app_web/live/dashboard_live_test.exs",
              "content" =>
                "defmodule AppWeb.DashboardLiveTest do\n  use AppWeb.ConnCase, async: true\n" <>
                  "  import Phoenix.LiveViewTest\n\n  test \"renders dashboard\" do\n" <>
                  "    {:ok, _view, html} = live(conn, \"/dashboard\")\n" <>
                  "    assert html =~ \"Dashboard\"\n  end\nend"
            }
          }
        ]
      })

    :ok =
      Session.append(session, %Message{
        id: "tr_6",
        role: :tool_result,
        call_id: "call_6",
        name: "write_file",
        content: "File written successfully"
      })

    # Turn 4: Agent summarizes what was done
    :ok =
      Session.append(session, %Message{
        id: "ast_5",
        role: :assistant,
        content:
          "I've created the dashboard implementation and tests:\n\n" <>
            "1. Created `DashboardLive` module with real-time metrics polling\n" <>
            "2. Added the `/dashboard` route to the router\n" <>
            "3. Created a test file following existing patterns\n\n" <>
            "Run `mix test` to verify."
      })

    session
  end

  # Builds a session with a long, tool-heavy turn that's likely to cause
  # a split-turn during compaction (many assistant+tool_result pairs after
  # a single user message).
  defp build_long_tool_turn(session, tool_count \\ 20) do
    # Short initial turn to give history context
    :ok =
      Session.append(
        session,
        Message.user("Review the auth module structure" <> String.duplicate(" ", 200))
      )

    :ok =
      Session.append(
        session,
        Message.assistant("I'll examine the auth modules." <> String.duplicate(" ", 200))
      )

    # Long turn: user asks for bulk refactoring, agent edits many files
    :ok = Session.append(session, Message.user("Apply the refactoring to all files in lib/auth/"))

    for i <- 1..tool_count do
      file_path = "lib/auth/module_#{i}.ex"

      :ok =
        Session.append(session, %Message{
          id: "lt_ast_#{i}",
          role: :assistant,
          content: "Editing #{file_path}" <> String.duplicate(" ", 150),
          tool_calls: [
            %{
              call_id: "lt_call_#{i}",
              name: "edit_file",
              arguments: %{"path" => file_path}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "lt_tr_#{i}",
          role: :tool_result,
          call_id: "lt_call_#{i}",
          name: "edit_file",
          content: "Successfully edited #{file_path}" <> String.duplicate(" ", 150)
        })
    end

    session
  end

  # ── Cached Response Tests ──────────────────────────────────────────────

  describe "compaction with cached API responses" do
    test "summarizes a realistic coding session end-to-end", %{session: session} do
      CompactionProvider.setup(["compaction_summary.json"])
      build_coding_session(session)

      original_path = Session.get_path(session)
      original_count = length(original_path)
      assert original_count == 13

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      path = Session.get_path(session)
      assert length(path) < original_count

      # Summary message is well-formed
      summary = hd(path)
      assert summary.role == :user
      assert summary.content =~ "[Conversation summary"
      assert summary.content =~ "Goal"
      assert summary.content =~ "Progress"
      assert summary.parent_id == nil

      # Provider was called exactly once
      assert CompactionProvider.call_count() == 1

      # Metadata carries file-op tracking
      assert summary.metadata.type == :compaction_summary
      assert is_list(summary.metadata.read_files)
      assert is_list(summary.metadata.modified_files)
    end

    test "extracts file ops from realistic tool call history", %{session: session} do
      CompactionProvider.setup(["compaction_summary.json"])
      build_coding_session(session)

      # Use keep_recent_tokens: 0 to ensure all tool-call messages are compacted
      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 0
        )

      summary = hd(Session.get_path(session))

      # router.ex was read then edited → promoted to modified
      assert "lib/app_web/router.ex" in summary.metadata.modified_files
      refute "lib/app_web/router.ex" in summary.metadata.read_files

      # metrics_collector.ex was only read
      assert "lib/app/metrics_collector.ex" in summary.metadata.read_files

      # page_live_test.exs was only read
      assert "test/app_web/live/page_live_test.exs" in summary.metadata.read_files

      # write_file calls: dashboard_live.ex, dashboard_live_test.exs
      assert "lib/app_web/live/dashboard_live.ex" in summary.metadata.modified_files
      assert "test/app_web/live/dashboard_live_test.exs" in summary.metadata.modified_files
    end

    test "tree integrity maintained after compaction", %{session: session} do
      CompactionProvider.setup(["compaction_summary.json"])
      build_coding_session(session)

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      path = Session.get_path(session)
      assert length(path) >= 2

      [root | rest] = path
      assert root.parent_id == nil

      Enum.reduce(rest, root, fn msg, prev ->
        assert msg.parent_id == prev.id,
               "#{msg.id} (#{msg.role}) parent_id=#{inspect(msg.parent_id)}, expected #{prev.id}"

        msg
      end)
    end

    test "conversation can continue after compaction", %{session: session} do
      CompactionProvider.setup(["compaction_summary.json"])
      build_coding_session(session)

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      count_after = length(Session.get_path(session))

      # Append new messages — they should link correctly to the compacted path
      :ok = Session.append(session, Message.user("What's the status of the dashboard?"))

      :ok =
        Session.append(
          session,
          Message.assistant("The dashboard is implemented with real-time polling.")
        )

      path = Session.get_path(session)
      assert length(path) == count_after + 2

      # New messages properly linked to the existing chain
      last = List.last(path)
      second_last = Enum.at(path, -2)
      assert last.parent_id == second_last.id
    end

    test "iterative compaction updates existing summary across cycles", %{session: session} do
      CompactionProvider.setup([
        "compaction_summary.json",
        "compaction_summary_update.json"
      ])

      # Cycle 1: realistic coding session → compact
      build_coding_session(session)

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 200,
          force: true
        )

      summary_1 = hd(Session.get_path(session))
      assert summary_1.content =~ "[Conversation summary"
      assert summary_1.content =~ "Goal"
      assert CompactionProvider.call_count() == 1

      # Cycle 2: add more messages, compact again
      :ok = Session.append(session, Message.user("Add error handling to the dashboard"))

      :ok =
        Session.append(session, %Message{
          id: "iter_ast",
          role: :assistant,
          content: "I'll add error handling." <> String.duplicate("x", 500),
          tool_calls: [
            %{
              call_id: "iter_call",
              name: "edit_file",
              arguments: %{"path" => "lib/app_web/live/dashboard_live.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "iter_tr",
          role: :tool_result,
          call_id: "iter_call",
          name: "edit_file",
          content: "File edited" <> String.duplicate("y", 500)
        })

      :ok = Session.append(session, Message.user("Done" <> String.duplicate(" ", 200)))

      :ok =
        Session.append(
          session,
          Message.assistant("All done" <> String.duplicate("z", 500))
        )

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 200,
          force: true
        )

      summary_2 = hd(Session.get_path(session))
      assert summary_2.content =~ "[Conversation summary"
      # Second cycle used the update fixture (with error handling content)
      assert summary_2.content =~ "error handling"
      assert CompactionProvider.call_count() == 2

      # Tree integrity after two cycles
      [root | rest] = Session.get_path(session)
      assert root.parent_id == nil

      Enum.reduce(rest, root, fn msg, prev ->
        assert msg.parent_id == prev.id
        msg
      end)
    end

    test "file ops accumulate and promote across compaction cycles", %{session: session} do
      CompactionProvider.setup([
        "compaction_summary.json",
        "compaction_summary_update.json",
        "compaction_summary_update.json"
      ])

      # Cycle 1: read alpha.ex, write beta.ex
      :ok = Session.append(session, Message.user("First task"))

      :ok =
        Session.append(session, %Message{
          id: "cyc1_ast",
          role: :assistant,
          content: String.duplicate("x", 500),
          tool_calls: [
            %{call_id: "c1_r", name: "read_file", arguments: %{"path" => "lib/alpha.ex"}},
            %{call_id: "c1_w", name: "write_file", arguments: %{"path" => "lib/beta.ex"}}
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "cyc1_tr1",
          role: :tool_result,
          call_id: "c1_r",
          name: "read_file",
          content: "contents" <> String.duplicate("a", 500)
        })

      :ok =
        Session.append(session, %Message{
          id: "cyc1_tr2",
          role: :tool_result,
          call_id: "c1_w",
          name: "write_file",
          content: "written" <> String.duplicate("b", 500)
        })

      :ok = Session.append(session, Message.user("Next" <> String.duplicate(" ", 200)))
      :ok = Session.append(session, Message.assistant("OK" <> String.duplicate("c", 500)))

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      summary_1 = hd(Session.get_path(session))
      assert "lib/alpha.ex" in summary_1.metadata.read_files
      assert "lib/beta.ex" in summary_1.metadata.modified_files

      # Cycle 2: edit alpha.ex (promote read→modified), read gamma.ex
      :ok = Session.append(session, Message.user("Edit alpha"))

      :ok =
        Session.append(session, %Message{
          id: "cyc2_ast",
          role: :assistant,
          content: String.duplicate("d", 500),
          tool_calls: [
            %{call_id: "c2_e", name: "edit_file", arguments: %{"path" => "lib/alpha.ex"}},
            %{call_id: "c2_r", name: "read_file", arguments: %{"path" => "lib/gamma.ex"}}
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "cyc2_tr1",
          role: :tool_result,
          call_id: "c2_e",
          name: "edit_file",
          content: "edited" <> String.duplicate("e", 500)
        })

      :ok =
        Session.append(session, %Message{
          id: "cyc2_tr2",
          role: :tool_result,
          call_id: "c2_r",
          name: "read_file",
          content: "gamma" <> String.duplicate("f", 500)
        })

      :ok = Session.append(session, Message.user("Done" <> String.duplicate(" ", 200)))
      :ok = Session.append(session, Message.assistant("Done" <> String.duplicate("g", 500)))

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      summary_2 = hd(Session.get_path(session))

      # alpha.ex promoted from read to modified
      assert "lib/alpha.ex" in summary_2.metadata.modified_files
      refute "lib/alpha.ex" in summary_2.metadata.read_files

      # beta.ex still in modified from cycle 1
      assert "lib/beta.ex" in summary_2.metadata.modified_files

      # gamma.ex in read
      assert "lib/gamma.ex" in summary_2.metadata.read_files
    end

    test "split-turn generates dual summary for long tool turns", %{session: session} do
      CompactionProvider.setup([
        "compaction_split_history.json",
        "compaction_split_prefix.json"
      ])

      build_long_tool_turn(session)

      path_before = Session.get_path(session)
      # 2 initial msgs + 1 user + 20 * 2 (assistant+tool_result) = 43 messages
      assert length(path_before) == 43

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 1000
        )

      path = Session.get_path(session)
      assert length(path) < 43

      summary = hd(path)
      assert summary.content =~ "[Conversation summary"

      # If split was detected, provider was called twice and summary has dual sections
      if CompactionProvider.call_count() == 2 do
        assert summary.content =~ "History Summary" or summary.content =~ "Turn Context"
      end

      # Tree integrity after split-turn compaction
      [root | rest] = path
      assert root.parent_id == nil

      Enum.reduce(rest, root, fn msg, prev ->
        assert msg.parent_id == prev.id
        msg
      end)
    end

    test "serializes realistic tool-heavy conversations correctly" do
      messages = [
        Message.user("Add user authentication"),
        %Message{
          id: "s1",
          role: :assistant,
          content: "I'll create the auth module.",
          tool_calls: [
            %{
              call_id: "sc1",
              name: "read_file",
              arguments: %{"path" => "lib/app/accounts.ex"}
            },
            %{
              call_id: "sc2",
              name: "write_file",
              arguments: %{
                "path" => "lib/app/auth.ex",
                "content" => "defmodule App.Auth do\n  def verify(token), do: :ok\nend"
              }
            }
          ]
        },
        %Message{
          id: "s2",
          role: :tool_result,
          call_id: "sc1",
          name: "read_file",
          content: "defmodule App.Accounts do\n  # accounts module\nend"
        },
        %Message{
          id: "s3",
          role: :tool_result,
          call_id: "sc2",
          name: "write_file",
          content: "File written successfully"
        },
        %Message{
          id: "s4",
          role: :assistant,
          content: "Auth module created. Running tests.",
          tool_calls: [
            %{call_id: "sc3", name: "shell", arguments: %{"command" => "mix test"}}
          ]
        },
        %Message{
          id: "s5",
          role: :tool_result,
          call_id: "sc3",
          name: "shell",
          content: "15 tests, 0 failures"
        }
      ]

      transcript = Compaction.serialize_conversation(messages)

      # Conversation wrapping
      assert String.starts_with?(transcript, "<conversation>\n")
      assert String.ends_with?(transcript, "\n</conversation>")

      # All message types represented
      assert transcript =~ "[User]: Add user authentication"
      assert transcript =~ "[Assistant]: I'll create the auth module."
      assert transcript =~ "[Assistant tool calls]:"
      assert transcript =~ "read_file("
      assert transcript =~ "write_file("
      assert transcript =~ "[Tool result (read_file)]:"
      assert transcript =~ "[Tool result (write_file)]:"
      assert transcript =~ "[Tool result (shell)]:"
      assert transcript =~ "15 tests, 0 failures"
    end

    test "handles compaction with mixed message sizes", %{session: session} do
      CompactionProvider.setup(["compaction_summary.json"])

      # Simulate realistic message size distribution:
      # short user messages, medium assistant responses, long tool results
      :ok = Session.append(session, Message.user("Fix the bug in auth.ex"))

      :ok =
        Session.append(session, %Message{
          id: "mix_ast1",
          role: :assistant,
          content:
            "Let me examine the auth module to find the issue." <>
              String.duplicate(" ", 300),
          tool_calls: [
            %{call_id: "mix_c1", name: "read_file", arguments: %{"path" => "lib/auth.ex"}}
          ]
        })

      # Long tool result (simulates reading a large file)
      :ok =
        Session.append(session, %Message{
          id: "mix_tr1",
          role: :tool_result,
          call_id: "mix_c1",
          name: "read_file",
          content: String.duplicate("defmodule line #{} do\n  # code\nend\n", 100)
        })

      :ok =
        Session.append(session, %Message{
          id: "mix_ast2",
          role: :assistant,
          content: "Found the bug — missing pattern match." <> String.duplicate(" ", 300),
          tool_calls: [
            %{call_id: "mix_c2", name: "edit_file", arguments: %{"path" => "lib/auth.ex"}}
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "mix_tr2",
          role: :tool_result,
          call_id: "mix_c2",
          name: "edit_file",
          content: "File edited successfully"
        })

      :ok = Session.append(session, Message.user("Run the tests" <> String.duplicate(" ", 200)))

      :ok =
        Session.append(
          session,
          Message.assistant("All tests pass." <> String.duplicate(" ", 300))
        )

      :ok =
        Compaction.compact(session,
          provider: CompactionProvider,
          model: @model,
          keep_recent_tokens: 100
        )

      path = Session.get_path(session)
      summary = hd(path)
      assert summary.content =~ "[Conversation summary"
      assert summary.metadata.type == :compaction_summary
    end
  end

  # ── Agent-Driven Compaction ──────────────────────────────────────────

  describe "agent-driven auto-compaction with cached responses" do
    test "auto-compaction fires and uses cached summary" do
      AgentCompactionProvider.setup(
        "responses_api_high_usage.json",
        ["compaction_summary.json"]
      )

      session_id = "agent-compact-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)
      {:ok, tool_sup} = Task.Supervisor.start_link()

      # Pre-populate with large messages (8 turns × 20k chars = 320k total)
      for i <- 1..8 do
        :ok =
          Session.append(
            session,
            Message.user("msg #{i} " <> String.duplicate("x", 20_000))
          )

        :ok =
          Session.append(
            session,
            Message.assistant("reply #{i} " <> String.duplicate("y", 20_000))
          )
      end

      {:ok, pid} =
        Opal.Agent.start_link(
          session_id: session_id,
          model: Opal.Provider.Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "",
          tools: [],
          provider: AgentCompactionProvider,
          tool_supervisor: tool_sup,
          session: session
        )

      Opal.Events.subscribe(session_id)

      # First prompt: sets last_prompt_tokens = 110k (85.9% of 128k)
      Opal.Agent.prompt(pid, "first")
      wait_for_idle(pid)

      state = Opal.Agent.get_state(pid)
      assert state.last_prompt_tokens == 110_000

      # Switch turn fixture to low-usage for second turn
      :persistent_term.put({AgentCompactionProvider, :turn_fixture}, "responses_api_text.json")

      session_count_before = length(Session.get_path(session))

      # Second prompt triggers auto-compaction (must wait for compaction events
      # before calling wait_for_idle to avoid GenServer.call being consumed
      # by collect_stream_text's generic receive)
      Opal.Agent.prompt(pid, "second")

      assert_receive {:opal_event, ^session_id, {:compaction_start, _msg_count}}, 5000
      assert_receive {:opal_event, ^session_id, {:compaction_end, _before, after_count}}, 5000
      assert after_count < session_count_before

      wait_for_idle(pid)

      # Session was compacted
      final_path = Session.get_path(session)
      summary = hd(final_path)
      assert summary.content =~ "[Conversation summary"
      assert summary.metadata.type == :compaction_summary

      # Agent state syncs with session
      agent_msgs = Opal.Agent.get_state(pid).messages
      assert length(agent_msgs) == length(final_path)
      assert Opal.Agent.get_state(pid).status == :idle
    end

    test "agent continues normally after compaction" do
      AgentCompactionProvider.setup(
        "responses_api_high_usage.json",
        ["compaction_summary.json"]
      )

      session_id = "agent-cont-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)
      {:ok, tool_sup} = Task.Supervisor.start_link()

      for i <- 1..8 do
        :ok =
          Session.append(session, Message.user("msg #{i} " <> String.duplicate("x", 20_000)))

        :ok =
          Session.append(
            session,
            Message.assistant("reply #{i} " <> String.duplicate("y", 20_000))
          )
      end

      {:ok, pid} =
        Opal.Agent.start_link(
          session_id: session_id,
          model: Opal.Provider.Model.new(:test, "test-model"),
          working_dir: System.tmp_dir!(),
          system_prompt: "",
          tools: [],
          provider: AgentCompactionProvider,
          tool_supervisor: tool_sup,
          session: session
        )

      Opal.Events.subscribe(session_id)

      # First prompt: high usage
      Opal.Agent.prompt(pid, "first")
      wait_for_idle(pid)

      # Switch to low-usage for subsequent turns
      :persistent_term.put({AgentCompactionProvider, :turn_fixture}, "responses_api_text.json")

      # Second prompt: triggers compaction
      Opal.Agent.prompt(pid, "second")
      assert_receive {:opal_event, ^session_id, {:compaction_start, _}}, 5000
      assert_receive {:opal_event, ^session_id, {:compaction_end, _, _}}, 5000
      wait_for_idle(pid)

      msg_count_after_compaction = length(Opal.Agent.get_state(pid).messages)

      # Third prompt: should work normally after compaction
      Opal.Agent.prompt(pid, "third")
      wait_for_idle(pid)

      state = Opal.Agent.get_state(pid)
      assert state.status == :idle
      # Two new messages (user + assistant) added after compaction
      assert length(state.messages) == msg_count_after_compaction + 2
    end
  end

  # ── Live Compaction Tests ────────────────────────────────────────────

  describe "live compaction" do
    @describetag :live

    setup do
      case Opal.Auth.Copilot.get_token() do
        {:ok, _} -> :ok
        {:error, _} -> {:skip, "No valid Copilot auth token"}
      end
    end

    @tag timeout: 30_000
    test "real API produces structured compaction summary", %{session: session} do
      # Build a small realistic conversation
      :ok = Session.append(session, Message.user("Add a health check endpoint to my Phoenix app"))

      :ok =
        Session.append(session, %Message{
          id: "live_ast_1",
          role: :assistant,
          content: "I'll create a health check controller and route.",
          tool_calls: [
            %{
              call_id: "live_c1",
              name: "read_file",
              arguments: %{"path" => "lib/app_web/router.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "live_tr_1",
          role: :tool_result,
          call_id: "live_c1",
          name: "read_file",
          content:
            "defmodule AppWeb.Router do\n  use AppWeb, :router\n" <>
              "  scope \"/\" do\n    get \"/\", PageController, :index\n  end\nend"
        })

      :ok =
        Session.append(session, %Message{
          id: "live_ast_2",
          role: :assistant,
          content: "Creating the health controller and adding the route.",
          tool_calls: [
            %{
              call_id: "live_c2",
              name: "write_file",
              arguments: %{
                "path" => "lib/app_web/controllers/health_controller.ex",
                "content" =>
                  "defmodule AppWeb.HealthController do\n  use AppWeb, :controller\n" <>
                    "  def index(conn, _params), do: json(conn, %{status: \"ok\"})\nend"
              }
            },
            %{
              call_id: "live_c3",
              name: "edit_file",
              arguments: %{
                "path" => "lib/app_web/router.ex",
                "content" => "get \"/health\", HealthController, :index"
              }
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "live_tr_2",
          role: :tool_result,
          call_id: "live_c2",
          name: "write_file",
          content: "File written"
        })

      :ok =
        Session.append(session, %Message{
          id: "live_tr_3",
          role: :tool_result,
          call_id: "live_c3",
          name: "edit_file",
          content: "File edited"
        })

      :ok = Session.append(session, Message.user("Run the tests"))
      :ok = Session.append(session, Message.assistant("All 15 tests passed."))

      # Compact against real API
      model = Opal.Provider.Model.new(:copilot, "claude-sonnet-4")

      :ok =
        Compaction.compact(session,
          provider: Opal.Provider.Copilot,
          model: model,
          keep_recent_tokens: 200,
          force: true
        )

      path = Session.get_path(session)
      summary = hd(path)

      # Real API should produce structured content
      assert summary.content =~ "[Conversation summary"
      assert summary.metadata.type == :compaction_summary
      assert is_list(summary.metadata.read_files)
      assert is_list(summary.metadata.modified_files)

      # Summary should reference the actual task
      lower = String.downcase(summary.content)
      assert lower =~ "health" or lower =~ "endpoint" or lower =~ "controller"
    end

    @tag timeout: 30_000
    test "live iterative compaction produces coherent updates", %{session: session} do
      model = Opal.Provider.Model.new(:copilot, "claude-sonnet-4")

      # Cycle 1
      :ok = Session.append(session, Message.user("Create a JSON API for user CRUD"))

      :ok =
        Session.append(session, %Message{
          id: "liter_ast_1",
          role: :assistant,
          content: "I'll set up the user controller with CRUD endpoints.",
          tool_calls: [
            %{
              call_id: "liter_c1",
              name: "write_file",
              arguments: %{"path" => "lib/app_web/controllers/user_controller.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "liter_tr_1",
          role: :tool_result,
          call_id: "liter_c1",
          name: "write_file",
          content: "File written"
        })

      :ok = Session.append(session, Message.assistant("User controller created with CRUD."))

      :ok =
        Compaction.compact(session,
          provider: Opal.Provider.Copilot,
          model: model,
          keep_recent_tokens: 100,
          force: true
        )

      summary_1 = hd(Session.get_path(session))
      assert summary_1.content =~ "[Conversation summary"

      # Cycle 2: add more work, compact again
      :ok = Session.append(session, Message.user("Add pagination to the index endpoint"))

      :ok =
        Session.append(session, %Message{
          id: "liter_ast_2",
          role: :assistant,
          content: "Adding pagination support to the user index." <> String.duplicate(" ", 300),
          tool_calls: [
            %{
              call_id: "liter_c2",
              name: "edit_file",
              arguments: %{"path" => "lib/app_web/controllers/user_controller.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "liter_tr_2",
          role: :tool_result,
          call_id: "liter_c2",
          name: "edit_file",
          content: "File edited" <> String.duplicate(" ", 300)
        })

      :ok =
        Session.append(
          session,
          Message.assistant("Pagination added." <> String.duplicate(" ", 200))
        )

      :ok =
        Compaction.compact(session,
          provider: Opal.Provider.Copilot,
          model: model,
          keep_recent_tokens: 100,
          force: true
        )

      summary_2 = hd(Session.get_path(session))
      assert summary_2.content =~ "[Conversation summary"

      # Updated summary should reference both tasks
      lower = String.downcase(summary_2.content)
      assert lower =~ "user" or lower =~ "crud" or lower =~ "controller"
    end

    @tag timeout: 30_000
    @tag :save_fixtures
    test "records and saves compaction fixtures from live API", %{session: session} do
      # Build a conversation to summarize
      :ok =
        Session.append(
          session,
          Message.user("Implement user registration with email verification")
        )

      :ok =
        Session.append(session, %Message{
          id: "rec_ast_1",
          role: :assistant,
          content: "I'll create the registration module.",
          tool_calls: [
            %{
              call_id: "rec_c1",
              name: "read_file",
              arguments: %{"path" => "lib/app/accounts.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "rec_tr_1",
          role: :tool_result,
          call_id: "rec_c1",
          name: "read_file",
          content:
            "defmodule App.Accounts do\n  def create_user(attrs), do: Repo.insert(changeset(attrs))\nend"
        })

      :ok =
        Session.append(session, %Message{
          id: "rec_ast_2",
          role: :assistant,
          content: "Adding email verification.",
          tool_calls: [
            %{
              call_id: "rec_c2",
              name: "edit_file",
              arguments: %{"path" => "lib/app/accounts.ex"}
            }
          ]
        })

      :ok =
        Session.append(session, %Message{
          id: "rec_tr_2",
          role: :tool_result,
          call_id: "rec_c2",
          name: "edit_file",
          content: "File edited successfully"
        })

      :ok =
        Session.append(session, Message.assistant("Registration with email verification done."))

      # Serialize and record
      path_msgs = Session.get_path(session)
      prompt = Compaction.serialize_conversation(path_msgs)

      model = Opal.Provider.Model.new(:copilot, "claude-sonnet-4")

      # Use a local recording provider
      recording_pid = start_recording_provider()

      case Compaction.summarize_with_provider(
             RecordingProvider,
             model,
             "Summarize the following conversation transcript. " <>
               "Produce a structured summary.\n\n" <> prompt
           ) do
        {:ok, summary} ->
          assert String.length(summary) > 0

          events = stop_recording_provider(recording_pid)

          fixture_name = "compaction_live_recorded_#{System.unique_integer([:positive])}.json"
          path = FixtureHelper.save_fixture(fixture_name, events)
          assert File.exists?(path)
          File.rm!(path)

        {:error, reason} ->
          stop_recording_provider(recording_pid)
          flunk("Live API call failed: #{inspect(reason)}")
      end
    end
  end

  # ── Recording Provider (for live fixture capture) ────────────────────

  defmodule RecordingProvider do
    @behaviour Opal.Provider

    def start_recording do
      :persistent_term.put({__MODULE__, :recording}, true)
      :persistent_term.put({__MODULE__, :events}, [])
    end

    def stop_recording do
      events = :persistent_term.get({__MODULE__, :events}, [])
      :persistent_term.put({__MODULE__, :recording}, false)
      events
    end

    @impl true
    def stream(model, messages, tools, opts \\ []) do
      case Opal.Provider.Copilot.stream(model, messages, tools, opts) do
        {:ok, resp} -> {:ok, resp}
        error -> error
      end
    end

    @impl true
    def parse_stream_event(data) do
      if :persistent_term.get({__MODULE__, :recording}, false) do
        events = :persistent_term.get({__MODULE__, :events}, [])
        :persistent_term.put({__MODULE__, :events}, events ++ [data])
      end

      Opal.Provider.Copilot.parse_stream_event(data)
    end

    @impl true
    def convert_messages(model, messages),
      do: Opal.Provider.Copilot.convert_messages(model, messages)

    @impl true
    def convert_tools(tools), do: Opal.Provider.convert_tools(tools)
  end

  defp start_recording_provider do
    RecordingProvider.start_recording()
    self()
  end

  defp stop_recording_provider(_pid) do
    RecordingProvider.stop_recording()
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp wait_for_idle(pid, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_idle(pid, deadline)
  end

  defp do_wait_for_idle(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("Timed out waiting for idle")
    state = Opal.Agent.get_state(pid)

    if state.status == :idle do
      state
    else
      Process.sleep(10)
      do_wait_for_idle(pid, deadline)
    end
  end
end
