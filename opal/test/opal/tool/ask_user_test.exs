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

    test "name/0 returns ask_user" do
      assert AskUser.name() == "ask_user"
    end

    test "description/0 returns a non-empty string" do
      desc = AskUser.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns valid JSON Schema" do
      params = AskUser.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"]["question"])
      assert is_map(params["properties"]["choices"])
      assert params["required"] == ["question"]
    end

    test "meta/1 truncates question to 60 chars" do
      long_q = String.duplicate("a", 100)
      assert String.length(AskUser.meta(%{"question" => long_q})) == 60
    end

    test "meta/1 returns full question when short" do
      assert AskUser.meta(%{"question" => "hello?"}) == "hello?"
    end

    test "meta/1 returns fallback for missing question" do
      assert AskUser.meta(%{}) == "ask_user"
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
