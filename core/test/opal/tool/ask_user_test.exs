defmodule Opal.Tool.AskUserTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.AskUser

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      Code.ensure_loaded!(AskUser)
      assert function_exported?(AskUser, :name, 0)
      assert function_exported?(AskUser, :description, 0)
      assert function_exported?(AskUser, :parameters, 0)
      assert function_exported?(AskUser, :execute, 2)
      assert function_exported?(AskUser, :meta, 1)
    end

    test "delegates spec to Opal.Tool.Ask" do
      assert AskUser.name() == Opal.Tool.Ask.name()
      assert AskUser.description() == Opal.Tool.Ask.description()
      assert AskUser.parameters() == Opal.Tool.Ask.parameters()
      assert AskUser.meta(%{"question" => "hi"}) == Opal.Tool.Ask.meta(%{"question" => "hi"})
    end
  end

  describe "execute/2 errors" do
    test "returns error when question is missing" do
      assert {:error, "Missing required parameter: question"} =
               AskUser.execute(%{}, %{session_id: "test"})
    end

    test "returns error when args are empty" do
      assert {:error, "Missing required parameter: question"} =
               AskUser.execute(%{"choices" => ["a"]}, %{session_id: "test"})
    end
  end
end
