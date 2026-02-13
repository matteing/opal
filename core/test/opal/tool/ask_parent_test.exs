defmodule Opal.Tool.AskParentTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.AskParent

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      Code.ensure_loaded!(AskParent)
      assert function_exported?(AskParent, :name, 0)
      assert function_exported?(AskParent, :description, 0)
      assert function_exported?(AskParent, :parameters, 0)
      assert function_exported?(AskParent, :execute, 2)
      assert function_exported?(AskParent, :meta, 1)
    end

    test "delegates spec to Opal.Tool.Ask" do
      assert AskParent.name() == Opal.Tool.Ask.name()
      assert AskParent.description() == Opal.Tool.Ask.description()
      assert AskParent.parameters() == Opal.Tool.Ask.parameters()
      assert AskParent.meta(%{"question" => "hi"}) == Opal.Tool.Ask.meta(%{"question" => "hi"})
    end
  end

  describe "execute/2 with question_handler" do
    test "calls handler and returns answer" do
      handler = fn %{question: q, choices: _c} -> {:ok, "Answer to: #{q}"} end
      context = %{session_id: "test", question_handler: handler}

      assert {:ok, "Answer to: What color?"} =
               AskParent.execute(%{"question" => "What color?"}, context)
    end

    test "passes choices to handler" do
      handler = fn %{question: _q, choices: choices} -> {:ok, hd(choices)} end
      context = %{session_id: "test", question_handler: handler}

      assert {:ok, "red"} =
               AskParent.execute(
                 %{"question" => "Pick one", "choices" => ["red", "blue"]},
                 context
               )
    end

    test "defaults choices to empty list" do
      handler = fn %{choices: choices} -> {:ok, "choices=#{length(choices)}"} end
      context = %{session_id: "test", question_handler: handler}

      assert {:ok, "choices=0"} =
               AskParent.execute(%{"question" => "Anything?"}, context)
    end

    test "returns error when handler fails" do
      handler = fn _req -> {:error, :timeout} end
      context = %{session_id: "test", question_handler: handler}

      assert {:error, "Question failed: :timeout"} =
               AskParent.execute(%{"question" => "Hello?"}, context)
    end
  end

  describe "execute/2 errors" do
    test "returns error when question is missing" do
      assert {:error, "Missing required parameter: question"} =
               AskParent.execute(%{}, %{session_id: "test"})
    end
  end
end
