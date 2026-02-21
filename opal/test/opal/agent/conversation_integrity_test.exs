defmodule Opal.Agent.ConversationIntegrityTest do
  @moduledoc """
  Tests for conversation integrity — ensuring tool_use/tool_result pairing
  is always valid before messages are sent to the provider.

  Covers:
  - Deep orphan repair (orphans not in the most recent assistant message)
  - Stream error recovery (agent stays responsive after stream errors)
  - ensure_tool_results defense-in-depth validation
  - Multiple orphan batches across the conversation
  """
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Agent.Repair
  alias Opal.Events
  alias Opal.Message
  alias Opal.Provider.Model

  # ── Unit tests for ensure_tool_results ─────────────────────────────

  describe "ensure_tool_results/1" do
    test "no-ops on clean conversation" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "c1", name: "t", arguments: %{}}]
        },
        %Message{id: "3", role: :tool_result, call_id: "c1", content: "ok"},
        %Message{id: "4", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)
      assert length(result) == 4
      assert Enum.map(result, & &1.role) == [:user, :assistant, :tool_result, :assistant]
    end

    test "injects synthetic result for orphaned tool_call" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "orphan1", name: "t", arguments: %{}}]
        },
        # No tool_result for orphan1!
        %Message{id: "3", role: :user, content: "continue"}
      ]

      result = Repair.ensure_tool_results(messages)
      assert length(result) == 4

      # Synthetic result should be right after the assistant message
      assert Enum.at(result, 0).role == :user
      assert Enum.at(result, 1).role == :assistant
      assert Enum.at(result, 2).role == :tool_result
      assert Enum.at(result, 2).call_id == "orphan1"
      assert Enum.at(result, 2).is_error == true
      assert Enum.at(result, 3).role == :user
    end

    test "handles deep orphan not in most recent assistant" do
      messages = [
        %Message{id: "1", role: :user, content: "start"},
        # First assistant with tool_calls — orphan1 has NO result
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{call_id: "orphan1", name: "t1", arguments: %{}},
            %{call_id: "ok1", name: "t2", arguments: %{}}
          ]
        },
        # Only ok1 has a result
        %Message{id: "3", role: :tool_result, call_id: "ok1", content: "fine"},
        %Message{id: "4", role: :user, content: "next"},
        # Second assistant — fully paired
        %Message{
          id: "5",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "ok2", name: "t3", arguments: %{}}]
        },
        %Message{id: "6", role: :tool_result, call_id: "ok2", content: "good"},
        %Message{id: "7", role: :assistant, content: "final answer"}
      ]

      result = Repair.ensure_tool_results(messages)

      # orphan1 should have a synthetic result injected right after the first assistant
      roles = Enum.map(result, & &1.role)

      assert roles == [
               :user,
               :assistant,
               :tool_result,
               :tool_result,
               :user,
               :assistant,
               :tool_result,
               :assistant
             ]

      # Find the synthetic result
      orphan_result = Enum.find(result, &(&1.call_id == "orphan1"))
      assert orphan_result != nil
      assert orphan_result.is_error == true

      # It should be at position 2 or 3 (right after the first assistant)
      orphan_idx = Enum.find_index(result, &(&1.call_id == "orphan1"))
      assistant_idx = Enum.find_index(result, &(&1.id == "2"))
      assert orphan_idx > assistant_idx
      assert orphan_idx <= assistant_idx + 2
    end

    test "handles multiple orphans in same assistant message" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{call_id: "a", name: "t1", arguments: %{}},
            %{call_id: "b", name: "t2", arguments: %{}},
            %{call_id: "c", name: "t3", arguments: %{}}
          ]
        },
        # Only "b" has a result
        %Message{id: "3", role: :tool_result, call_id: "b", content: "ok"}
      ]

      result = Repair.ensure_tool_results(messages)

      result_ids = result |> Enum.filter(&(&1.role == :tool_result)) |> Enum.map(& &1.call_id)
      assert "a" in result_ids
      assert "b" in result_ids
      assert "c" in result_ids

      # All results should be right after the assistant
      assert Enum.at(result, 0).role == :user
      assert Enum.at(result, 1).role == :assistant
      # Positions 2-4 should all be tool_results
      tool_results = Enum.slice(result, 2, 3)
      assert Enum.all?(tool_results, &(&1.role == :tool_result))
    end

    test "handles assistant with empty tool_calls" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{id: "2", role: :assistant, content: "hello", tool_calls: []},
        %Message{id: "3", role: :user, content: "thanks"}
      ]

      result = Repair.ensure_tool_results(messages)
      assert length(result) == 3
    end

    test "handles assistant with nil tool_calls" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{id: "2", role: :assistant, content: "hello", tool_calls: nil},
        %Message{id: "3", role: :user, content: "thanks"}
      ]

      result = Repair.ensure_tool_results(messages)
      assert length(result) == 3
    end

    test "handles multiple orphan batches across conversation" do
      messages = [
        %Message{id: "1", role: :user, content: "s1"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "orphan_a", name: "t", arguments: %{}}]
        },
        # No result for orphan_a
        %Message{id: "3", role: :user, content: "s2"},
        %Message{
          id: "4",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "orphan_b", name: "t", arguments: %{}}]
        },
        # No result for orphan_b
        %Message{id: "5", role: :user, content: "s3"},
        %Message{id: "6", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)

      result_ids = result |> Enum.filter(&(&1.role == :tool_result)) |> Enum.map(& &1.call_id)
      assert "orphan_a" in result_ids
      assert "orphan_b" in result_ids

      # Each synthetic result should be positioned right after its assistant
      orphan_a_idx = Enum.find_index(result, &(&1.call_id == "orphan_a"))
      assistant_a_idx = Enum.find_index(result, &(&1.id == "2"))
      assert orphan_a_idx == assistant_a_idx + 1

      orphan_b_idx = Enum.find_index(result, &(&1.call_id == "orphan_b"))
      assistant_b_idx = Enum.find_index(result, &(&1.id == "4"))
      assert orphan_b_idx == assistant_b_idx + 1
    end

    test "strips orphaned tool_results with no matching tool_call" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        # This tool_result has no matching assistant with tool_calls
        %Message{id: "2", role: :tool_result, call_id: "ghost", content: "from nowhere"},
        %Message{id: "3", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)
      assert length(result) == 2

      # The orphaned tool_result should be stripped
      roles = Enum.map(result, & &1.role)
      assert roles == [:user, :assistant]
      refute Enum.any?(result, &(&1.call_id == "ghost"))
    end

    test "keeps tool_results that match and strips ones that don't" do
      messages = [
        %Message{id: "1", role: :user, content: "hi"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "valid", name: "t", arguments: %{}}]
        },
        %Message{id: "3", role: :tool_result, call_id: "valid", content: "ok"},
        # This one has no matching assistant
        %Message{id: "4", role: :tool_result, call_id: "stale", content: "leftover"},
        %Message{id: "5", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)

      result_ids = result |> Enum.filter(&(&1.role == :tool_result)) |> Enum.map(& &1.call_id)
      assert "valid" in result_ids
      refute "stale" in result_ids
    end

    test "relocates existing tool_results directly after assistant tool_calls" do
      messages = [
        %Message{id: "1", role: :user, content: "load skills"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{call_id: "toolu_1", name: "use_skill", arguments: %{"skill_name" => "git"}},
            %{call_id: "toolu_2", name: "use_skill", arguments: %{"skill_name" => "docs"}}
          ]
        },
        # Skill context injection can interleave before tool results land
        %Message{id: "3", role: :user, content: "[System] Skill 'git' activated"},
        %Message{id: "4", role: :user, content: "[System] Skill 'docs' activated"},
        %Message{id: "5", role: :tool_result, call_id: "toolu_1", content: "Skill git loaded"},
        %Message{id: "6", role: :tool_result, call_id: "toolu_2", content: "Skill docs loaded"},
        %Message{id: "7", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)

      assert Enum.map(result, & &1.role) == [
               :user,
               :assistant,
               :tool_result,
               :tool_result,
               :user,
               :user,
               :assistant
             ]

      assert Enum.at(result, 2).call_id == "toolu_1"
      assert Enum.at(result, 3).call_id == "toolu_2"
    end

    test "orders relocated tool_results by tool_call order and preserves payload" do
      messages = [
        %Message{id: "1", role: :user, content: "run tools"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{call_id: "a", name: "t1", arguments: %{}},
            %{call_id: "b", name: "t2", arguments: %{}}
          ]
        },
        %Message{id: "3", role: :tool_result, call_id: "b", content: "second ok"},
        %Message{
          id: "4",
          role: :tool_result,
          call_id: "a",
          content: "first failed",
          is_error: true
        },
        %Message{id: "5", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)
      [result_a, result_b] = Enum.slice(result, 2, 2)

      assert Enum.map(result, & &1.role) == [
               :user,
               :assistant,
               :tool_result,
               :tool_result,
               :assistant
             ]

      assert result_a.call_id == "a"
      assert result_a.content == "first failed"
      assert result_a.is_error == true
      assert result_b.call_id == "b"
      assert result_b.content == "second ok"
      assert result_b.is_error == false
    end

    test "handles string-key tool_call maps without injecting synthetic results" do
      messages = [
        %Message{id: "1", role: :user, content: "continue"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{
              "call_id" => "str_1",
              "name" => "use_skill",
              "arguments" => %{"skill_name" => "git"}
            },
            %{
              "call_id" => "str_2",
              "name" => "use_skill",
              "arguments" => %{"skill_name" => "docs"}
            }
          ]
        },
        %Message{id: "3", role: :user, content: "[System] skill load"},
        %Message{id: "4", role: :tool_result, call_id: "str_1", content: "git loaded"},
        %Message{id: "5", role: :tool_result, call_id: "str_2", content: "docs loaded"}
      ]

      result = Repair.ensure_tool_results(messages)

      tool_results =
        result
        |> Enum.filter(&(&1.role == :tool_result))

      assert Enum.map(tool_results, & &1.call_id) == ["str_1", "str_2"]

      refute Enum.any?(
               tool_results,
               &String.contains?(&1.content, "[Error: tool result missing]")
             )
    end

    test "drops duplicate tool_results after relocating the first match" do
      messages = [
        %Message{id: "1", role: :user, content: "run once"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "dup", name: "tool", arguments: %{}}]
        },
        %Message{id: "3", role: :tool_result, call_id: "dup", content: "first"},
        %Message{id: "4", role: :user, content: "interleaved"},
        %Message{id: "5", role: :tool_result, call_id: "dup", content: "second"},
        %Message{id: "6", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)

      assert Enum.map(result, & &1.role) == [:user, :assistant, :tool_result, :user, :assistant]

      dup_results = Enum.filter(result, &(&1.role == :tool_result and &1.call_id == "dup"))
      assert length(dup_results) == 1
      assert hd(dup_results).content == "first"
    end

    test "relocates each assistant's results independently across turns" do
      messages = [
        %Message{id: "1", role: :user, content: "start"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "a", name: "t1", arguments: %{}}]
        },
        %Message{id: "3", role: :user, content: "[System] interleaved note"},
        %Message{
          id: "4",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "b", name: "t2", arguments: %{}}]
        },
        %Message{id: "5", role: :tool_result, call_id: "b", content: "b result"},
        %Message{id: "6", role: :tool_result, call_id: "a", content: "a result"},
        %Message{id: "7", role: :assistant, content: "done"}
      ]

      result = Repair.ensure_tool_results(messages)

      assert Enum.map(result, & &1.role) == [
               :user,
               :assistant,
               :tool_result,
               :user,
               :assistant,
               :tool_result,
               :assistant
             ]

      assert Enum.at(result, 2).call_id == "a"
      assert Enum.at(result, 5).call_id == "b"
    end
  end

  # ── Integration tests with the agent ───────────────────────────────

  defmodule StreamErrorProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
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

      spawn(fn ->
        Process.sleep(5)

        error_json =
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "code" => "invalid_request_body",
              "message" => "tool_use without tool_result"
            }
          })

        send(caller, {ref, {:data, "data: #{error_json}\n"}})
        Process.sleep(5)
        send(caller, {ref, :done})
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => "error"} = event} ->
          [{:error, Map.get(event, "error", event)}]

        {:ok, %{"error" => error}} ->
          [{:error, error}]

        {:ok, %{"choices" => _} = event} ->
          Opal.Provider.parse_chat_event(event)

        _ ->
          []
      end
    end

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools
  end

  # Provider that succeeds on second call (after orphan repair)
  defmodule RecoveryProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      caller = self()
      ref = make_ref()
      call_count = :persistent_term.get({__MODULE__, :call_count}, 0) + 1
      :persistent_term.put({__MODULE__, :call_count}, call_count)

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

      spawn(fn ->
        Process.sleep(5)

        if call_count == 1 do
          # First call: send error
          error_json =
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "code" => "invalid_request_body",
                "message" => "broken"
              }
            })

          send(caller, {ref, {:data, "data: #{error_json}\n"}})
        else
          # Subsequent calls: succeed with text
          events = [
            "data: #{Jason.encode!(%{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "item_ok"}})}\n",
            "data: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "Recovered!"})}\n",
            "data: #{Jason.encode!(%{"type" => "response.output_text.done", "text" => "Recovered!"})}\n",
            "data: #{Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "r2", "status" => "completed", "usage" => %{}}})}\n"
          ]

          for event <- events do
            send(caller, {ref, {:data, event}})
            Process.sleep(1)
          end
        end

        send(caller, {ref, :done})
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => "error"} = event} ->
          [{:error, Map.get(event, "error", event)}]

        {:ok, %{"choices" => _} = event} ->
          Opal.Provider.parse_chat_event(event)

        {:ok, %{"type" => "response.output_item.added", "item" => item}} ->
          case item["type"] do
            "message" -> [{:text_start, %{item_id: item["id"]}}]
            _ -> []
          end

        {:ok, %{"type" => "response.output_text.delta", "delta" => delta}} ->
          [{:text_delta, delta}]

        {:ok, %{"type" => "response.output_text.done", "text" => text}} ->
          [{:text_done, text}]

        {:ok, %{"type" => "response.completed", "response" => resp}} ->
          [{:response_done, %{usage: Map.get(resp, "usage", %{})}}]

        _ ->
          []
      end
    end

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp start_agent(opts) do
    session_id = "integrity-test-#{System.unique_integer([:positive])}"
    {:ok, tool_sup} = Task.Supervisor.start_link()

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: Keyword.get(opts, :system_prompt, "Test assistant."),
      tools: Keyword.get(opts, :tools, []),
      provider: Keyword.get(opts, :provider, StreamErrorProvider),
      tool_supervisor: tool_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    Events.subscribe(session_id)
    %{pid: pid, session_id: session_id}
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({RecoveryProvider, :call_count})
    end)

    :ok
  end

  # ── Stream error tests ──────────────────────────────────────────────

  describe "stream error recovery" do
    test "agent goes idle and broadcasts error on stream error event" do
      %{pid: pid, session_id: sid} = start_agent(provider: StreamErrorProvider)

      Agent.prompt(pid, "Will fail")

      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000

      assert_receive {:opal_event, ^sid,
                      {:error,
                       %{
                         "code" => "invalid_request_body",
                         "message" => "tool_use without tool_result"
                       }}},
                     2000

      # Wait for done processing
      Process.sleep(100)

      state = Agent.get_state(pid)
      assert state.status == :idle
    end

    test "agent does not create broken assistant message after stream error" do
      %{pid: pid, session_id: sid} = start_agent(provider: StreamErrorProvider)

      Agent.prompt(pid, "Will fail")
      assert_receive {:opal_event, ^sid, {:error, _}}, 2000

      Process.sleep(100)
      state = Agent.get_state(pid)

      # Should only have the user message — no broken assistant message
      assert length(state.messages) == 1
      assert List.first(state.messages).role == :user
    end

    test "agent accepts new prompts after stream error" do
      %{pid: pid, session_id: sid} = start_agent(provider: RecoveryProvider)

      # First prompt fails
      Agent.prompt(pid, "First attempt")
      assert_receive {:opal_event, ^sid, {:error, _}}, 2000

      Process.sleep(100)
      assert Agent.get_state(pid).status == :idle

      # Second prompt should succeed
      Agent.prompt(pid, "Second attempt")
      assert_receive {:opal_event, ^sid, {:agent_start}}, 1000
      assert_receive {:opal_event, ^sid, {:agent_end, messages, _}}, 3000

      # Messages should include both prompts
      user_msgs = Enum.filter(messages, &(&1.role == :user))
      assert length(user_msgs) == 2
    end
  end

  # ── find_orphaned_calls tests (via repair) ──────────────────────────

  describe "deep orphan repair" do
    test "repairs orphans in older assistant messages" do
      # Simulate a state with a deep orphan
      messages = [
        # newest first
        %Message{id: "7", role: :assistant, content: "final"},
        %Message{id: "6", role: :tool_result, call_id: "ok2", content: "good"},
        %Message{
          id: "5",
          role: :assistant,
          content: "",
          tool_calls: [%{call_id: "ok2", name: "t", arguments: %{}}]
        },
        %Message{id: "4", role: :user, content: "next"},
        # ok1 has a result, but orphan1 does NOT
        %Message{id: "3", role: :tool_result, call_id: "ok1", content: "fine"},
        %Message{
          id: "2",
          role: :assistant,
          content: "",
          tool_calls: [
            %{call_id: "orphan1", name: "t1", arguments: %{}},
            %{call_id: "ok1", name: "t2", arguments: %{}}
          ]
        },
        %Message{id: "1", role: :user, content: "start"}
      ]

      # Test through the public ensure_tool_results
      chronological = Enum.reverse(messages)
      result = Repair.ensure_tool_results(chronological)

      # orphan1 should now have a synthetic result
      orphan_result = Enum.find(result, &(&1.call_id == "orphan1"))
      assert orphan_result != nil
      assert orphan_result.is_error == true
      assert String.contains?(orphan_result.content, "missing")
    end
  end
end
