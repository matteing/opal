defmodule Opal.ModelTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.Model

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

    test "is an Opal.Provider.Model struct" do
      model = Model.new(:openai, "gpt-4o")
      assert %Model{} = model
    end
  end

  # Validates model spec parsing
  describe "parse/1" do
    test "parses provider:model format" do
      model = Model.parse("anthropic:claude-sonnet-4-5")
      assert model.provider == :anthropic
      assert model.id == "claude-sonnet-4-5"
      assert model.thinking_level == :off
    end

    test "parses bare model id as copilot" do
      model = Model.parse("claude-sonnet-4-5")
      assert model.provider == :copilot
      assert model.id == "claude-sonnet-4-5"
    end

    test "parses openai model" do
      model = Model.parse("openai:gpt-4o")
      assert model.provider == :openai
      assert model.id == "gpt-4o"
    end

    test "passes thinking_level option" do
      model = Model.parse("anthropic:claude-sonnet-4-5", thinking_level: :high)
      assert model.thinking_level == :high
    end

    test "handles provider with colon in model id" do
      # Only first colon splits
      model = Model.parse("openai:gpt-5:latest")
      assert model.provider == :openai
      assert model.id == "gpt-5:latest"
    end
  end

  # Validates ReqLLM spec conversion
  describe "to_req_llm_spec/1" do
    test "converts to provider:model string" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      assert Model.to_req_llm_spec(model) == "anthropic:claude-sonnet-4-5"
    end

    test "converts copilot model" do
      model = Model.new(:copilot, "gpt-5")
      assert Model.to_req_llm_spec(model) == "copilot:gpt-5"
    end
  end

  describe "coerce/2" do
    test "passes through Model struct as-is" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      assert Model.coerce(model) == model
    end

    test "coerces string spec" do
      model = Model.coerce("anthropic:claude-sonnet-4-5")
      assert model.provider == :anthropic
      assert model.id == "claude-sonnet-4-5"
    end

    test "coerces bare string as copilot" do
      model = Model.coerce("gpt-5")
      assert model.provider == :copilot
      assert model.id == "gpt-5"
    end

    test "coerces atom tuple" do
      model = Model.coerce({:openai, "gpt-4o"})
      assert model.provider == :openai
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

  describe "provider_module/1" do
    test "returns Copilot provider for copilot models" do
      model = Model.new(:copilot, "gpt-5")
      assert Model.provider_module(model) == Opal.Provider.Copilot
    end

    test "returns LLM provider for anthropic models" do
      model = Model.new(:anthropic, "claude-sonnet-4-5")
      assert Model.provider_module(model) == Opal.Provider.LLM
    end

    test "returns LLM provider for openai models" do
      model = Model.new(:openai, "gpt-4o")
      assert Model.provider_module(model) == Opal.Provider.LLM
    end
  end
end
