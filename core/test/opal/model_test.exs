defmodule Opal.ModelTest do
  use ExUnit.Case, async: true

  alias Opal.Model

  # Validates basic model construction
  describe "new/2" do
    test "creates model with provider and id" do
      model = Model.new(:copilot, "claude-sonnet-4-5")
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4-5"
    end

    test "defaults thinking_level to :off" do
      model = Model.new(:copilot, "gpt-4o")
      assert model.thinking_level == :off
    end
  end

  # Validates thinking_level option overrides
  describe "new/3 with thinking_level" do
    test "accepts :low" do
      model = Model.new(:copilot, "model-1", thinking_level: :low)
      assert model.thinking_level == :low
    end

    test "accepts :medium" do
      model = Model.new(:copilot, "model-1", thinking_level: :medium)
      assert model.thinking_level == :medium
    end

    test "accepts :high" do
      model = Model.new(:copilot, "model-1", thinking_level: :high)
      assert model.thinking_level == :high
    end

    test "accepts :off explicitly" do
      model = Model.new(:copilot, "model-1", thinking_level: :off)
      assert model.thinking_level == :off
    end

    test "raises on invalid thinking_level" do
      assert_raise ArgumentError, ~r/invalid thinking_level/, fn ->
        Model.new(:copilot, "model-1", thinking_level: :extreme)
      end
    end
  end

  # Validates struct fields
  describe "struct" do
    test "has all expected fields" do
      model = Model.new(:openai, "gpt-4o")
      assert Map.has_key?(model, :provider)
      assert Map.has_key?(model, :id)
      assert Map.has_key?(model, :thinking_level)
    end

    test "is an Opal.Model struct" do
      model = Model.new(:openai, "gpt-4o")
      assert %Model{} = model
    end
  end
end
