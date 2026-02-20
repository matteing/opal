defmodule Opal.ModelTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.Model

  describe "new/1" do
    test "creates model with id" do
      model = Model.new("claude-sonnet-4-5")
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4-5"
    end

    test "defaults thinking_level to :off" do
      model = Model.new("gpt-4o")
      assert model.thinking_level == :off
    end
  end

  describe "new/2 with opts" do
    test "accepts :low" do
      model = Model.new("model-1", thinking_level: :low)
      assert model.thinking_level == :low
    end

    test "accepts :medium" do
      model = Model.new("model-1", thinking_level: :medium)
      assert model.thinking_level == :medium
    end

    test "accepts :high" do
      model = Model.new("model-1", thinking_level: :high)
      assert model.thinking_level == :high
    end

    test "accepts :off explicitly" do
      model = Model.new("model-1", thinking_level: :off)
      assert model.thinking_level == :off
    end

    test "raises on invalid thinking_level" do
      assert_raise ArgumentError, ~r/invalid thinking_level/, fn ->
        Model.new("model-1", thinking_level: :extreme)
      end
    end
  end

  describe "backwards-compat new/3 with provider" do
    test "ignores provider atom" do
      model = Model.new(:openai, "gpt-4o")
      assert model.provider == :copilot
      assert model.id == "gpt-4o"
    end

    test "ignores provider with opts" do
      model = Model.new(:anthropic, "claude-sonnet-4-5", thinking_level: :high)
      assert model.provider == :copilot
      assert model.thinking_level == :high
    end
  end

  describe "struct" do
    test "has all expected fields" do
      model = Model.new("gpt-4o")
      assert Map.has_key?(model, :provider)
      assert Map.has_key?(model, :id)
      assert Map.has_key?(model, :thinking_level)
    end

    test "is an Opal.Provider.Model struct" do
      model = Model.new("gpt-4o")
      assert %Model{} = model
    end
  end

  describe "parse/1" do
    test "parses model id" do
      model = Model.parse("claude-sonnet-4-5")
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4-5"
      assert model.thinking_level == :off
    end

    test "passes thinking_level option" do
      model = Model.parse("claude-sonnet-4-5", thinking_level: :high)
      assert model.thinking_level == :high
    end
  end

  describe "coerce/2" do
    test "passes through Model struct as-is" do
      model = Model.new("claude-sonnet-4-5")
      assert Model.coerce(model) == model
    end

    test "coerces string spec" do
      model = Model.coerce("claude-sonnet-4-5")
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4-5"
    end

    test "coerces atom tuple" do
      model = Model.coerce({:openai, "gpt-4o"})
      assert model.provider == :copilot
      assert model.id == "gpt-4o"
    end

    test "coerces string-key tuple" do
      model = Model.coerce({"copilot", "claude-sonnet-4"})
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4"
    end

    test "passes thinking_level option" do
      model = Model.coerce({:anthropic, "claude-sonnet-4-5"}, thinking_level: :high)
      assert model.thinking_level == :high
    end
  end
end
