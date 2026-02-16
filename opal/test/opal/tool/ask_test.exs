defmodule Opal.Tool.AskTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.Ask

  describe "shared spec" do
    test "name/0 returns ask_user" do
      assert Ask.name() == "ask_user"
    end

    test "description/0 returns a non-empty string" do
      desc = Ask.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns valid JSON Schema" do
      params = Ask.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"]["question"])
      assert is_map(params["properties"]["choices"])
      assert params["required"] == ["question"]
    end

    test "meta/1 truncates question to 60 chars" do
      long_q = String.duplicate("a", 100)
      assert String.length(Ask.meta(%{"question" => long_q})) == 60
    end

    test "meta/1 returns full question when short" do
      assert Ask.meta(%{"question" => "hello?"}) == "hello?"
    end

    test "meta/1 returns fallback for missing question" do
      assert Ask.meta(%{}) == "ask_user"
    end
  end
end
