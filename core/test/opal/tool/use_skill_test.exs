defmodule Opal.Tool.UseSkillTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.UseSkill

  describe "tool metadata" do
    test "name/0 returns use_skill" do
      assert UseSkill.name() == "use_skill"
    end

    test "description/0 returns a non-empty string" do
      desc = UseSkill.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 requires skill_name" do
      params = UseSkill.parameters()
      assert params["type"] == "object"
      assert params["required"] == ["skill_name"]
      assert Map.has_key?(params["properties"], "skill_name")
    end
  end

  describe "meta/1" do
    test "includes skill name" do
      assert UseSkill.meta(%{"skill_name" => "git"}) == "Loading skill: git"
    end

    test "returns fallback for missing skill_name" do
      assert UseSkill.meta(%{}) == "Loading skill"
    end
  end

  describe "execute/2" do
    test "returns error when agent_pid missing" do
      assert {:error, "Missing agent_pid in context."} =
               UseSkill.execute(%{"skill_name" => "git"}, %{})
    end

    test "returns error when skill_name missing" do
      assert {:error, "Missing required parameter: skill_name"} =
               UseSkill.execute(%{}, %{agent_pid: self()})
    end
  end
end
