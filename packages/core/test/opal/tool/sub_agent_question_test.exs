defmodule Opal.Tool.SubAgent.QuestionHandlerTest do
  @moduledoc """
  Tests the question-handler closure and the collect_and_forward
  receive clause that together enable sub-agents to ask questions
  back to the user via the parent's tool task process.

  These tests exercise the OTP message-passing pattern in isolation,
  without starting a full Agent or LLM provider.
  """

  use ExUnit.Case, async: true

  describe "question_handler closure" do
    test "sends :sub_agent_question and blocks until :sub_agent_answer" do
      # Simulate the parent task: capture self(), build handler, run it in a child.
      parent = self()

      handler = fn %{question: question, choices: choices} ->
        ref = make_ref()
        send(parent, {:sub_agent_question, self(), ref, %{question: question, choices: choices}})

        receive do
          {:sub_agent_answer, ^ref, answer} -> {:ok, answer}
        end
      end

      # Spawn a "sub-agent tool task" that calls the handler
      task =
        Task.async(fn ->
          handler.(%{question: "Which env?", choices: ["dev", "prod"]})
        end)

      # Parent receives the question
      assert_receive {:sub_agent_question, from, ref,
                      %{question: "Which env?", choices: ["dev", "prod"]}}

      # Parent replies
      send(from, {:sub_agent_answer, ref, "prod"})

      # Sub-agent task gets the answer
      assert {:ok, "prod"} = Task.await(task)
    end

    test "ref ensures only the matching answer is received" do
      parent = self()

      handler = fn %{question: question, choices: _} ->
        ref = make_ref()
        send(parent, {:sub_agent_question, self(), ref, %{question: question, choices: []}})

        receive do
          {:sub_agent_answer, ^ref, answer} -> {:ok, answer}
        after
          500 -> {:error, :timeout}
        end
      end

      task = Task.async(fn -> handler.(%{question: "Q1", choices: []}) end)

      assert_receive {:sub_agent_question, from, ref, _}

      # Send a bogus answer with a wrong ref — should NOT match
      send(from, {:sub_agent_answer, make_ref(), "wrong"})

      # Send the real answer
      send(from, {:sub_agent_answer, ref, "right"})

      assert {:ok, "right"} = Task.await(task)
    end

    test "propagates explicit question errors back to AskParent" do
      parent = self()

      handler = fn %{question: question, choices: choices} ->
        ref = make_ref()
        monitor = Process.monitor(parent)
        send(parent, {:sub_agent_question, self(), ref, %{question: question, choices: choices}})

        receive do
          {:sub_agent_answer, ^ref, answer} ->
            Process.demonitor(monitor, [:flush])
            {:ok, answer}

          {:sub_agent_answer_error, ^ref, reason} ->
            Process.demonitor(monitor, [:flush])
            {:error, reason}

          {:DOWN, ^monitor, :process, _pid, reason} ->
            {:error, {:parent_task_down, reason}}
        end
      end

      task = Task.async(fn -> handler.(%{question: "Deploy?", choices: []}) end)

      assert_receive {:sub_agent_question, from, ref, %{question: "Deploy?", choices: []}}
      send(from, {:sub_agent_answer_error, ref, :rpc_unavailable})

      assert {:error, :rpc_unavailable} = Task.await(task)
    end
  end

  describe "AskParent integration with handler" do
    test "AskParent.execute uses question_handler when present" do
      parent = self()

      handler = fn %{question: q, choices: c} ->
        send(parent, {:asked, q, c})
        {:ok, "handler answer"}
      end

      context = %{session_id: "test-sub", question_handler: handler}
      args = %{"question" => "Deploy?", "choices" => ["yes", "no"]}

      assert {:ok, "handler answer"} = Opal.Tool.AskParent.execute(args, context)
      assert_receive {:asked, "Deploy?", ["yes", "no"]}
    end

    test "AskParent.execute defaults choices to empty list" do
      handler = fn %{choices: choices} -> {:ok, "got #{length(choices)}"} end
      context = %{session_id: "test-sub", question_handler: handler}

      assert {:ok, "got 0"} = Opal.Tool.AskParent.execute(%{"question" => "Q"}, context)
    end
  end
end
