defmodule Opal.ModelsTest do
  use ExUnit.Case, async: true

  describe "list_copilot/0" do
    test "returns a non-empty list of models" do
      models = Opal.Models.list_copilot()
      assert is_list(models)
      assert length(models) > 0
    end

    test "each model has id, name, and supports_thinking" do
      for model <- Opal.Models.list_copilot() do
        assert is_binary(model.id), "expected id to be a string, got: #{inspect(model.id)}"
        assert is_binary(model.name), "expected name to be a string, got: #{inspect(model.name)}"
        assert is_boolean(model.supports_thinking)
      end
    end

    test "includes known Copilot models" do
      ids = Enum.map(Opal.Models.list_copilot(), & &1.id)
      assert "claude-opus-4.6" in ids
      assert "claude-sonnet-4" in ids
      assert "gpt-5" in ids
    end

    test "claude models support thinking" do
      models = Opal.Models.list_copilot()
      claude = Enum.find(models, &(&1.id == "claude-opus-4.6"))
      assert claude.supports_thinking == true
    end

    test "results are sorted by id" do
      models = Opal.Models.list_copilot()
      ids = Enum.map(models, & &1.id)
      assert ids == Enum.sort(ids)
    end
  end

  describe "list_provider/1" do
    test "returns Anthropic models" do
      models = Opal.Models.list_provider(:anthropic)
      assert length(models) > 0
      ids = Enum.map(models, & &1.id)
      assert Enum.any?(ids, &String.contains?(&1, "claude"))
    end

    test "returns empty list for unknown provider" do
      assert Opal.Models.list_provider(:nonexistent_provider_xyz) == []
    end
  end

  describe "context_window/1" do
    test "returns context window for a known Copilot model" do
      model = %Opal.Model{provider: :copilot, id: "claude-opus-4.6"}
      ctx = Opal.Models.context_window(model)
      assert is_integer(ctx)
      assert ctx > 0
    end

    test "returns context window for a direct provider model" do
      model = %Opal.Model{provider: :anthropic, id: "claude-sonnet-4-5"}
      ctx = Opal.Models.context_window(model)
      assert ctx == 200_000
    end

    test "falls back to default for unknown model" do
      model = %Opal.Model{provider: :copilot, id: "nonexistent-model-xyz"}
      assert Opal.Models.context_window(model) == 128_000
    end
  end

  describe "resolve/1" do
    test "resolves a known Copilot model" do
      model = %Opal.Model{provider: :copilot, id: "claude-opus-4.6"}
      assert {:ok, resolved} = Opal.Models.resolve(model)
      assert resolved.name == "Claude Opus 4.6"
      assert resolved.limits.context > 0
    end

    test "resolves a direct provider model" do
      model = %Opal.Model{provider: :anthropic, id: "claude-sonnet-4-5"}
      assert {:ok, resolved} = Opal.Models.resolve(model)
      assert String.contains?(resolved.name, "Sonnet")
    end

    test "returns error for unknown model" do
      model = %Opal.Model{provider: :copilot, id: "nonexistent-xyz"}
      assert {:error, :not_found} = Opal.Models.resolve(model)
    end
  end
end
