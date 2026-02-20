defmodule Opal.Provider.RegistryTest do
  use ExUnit.Case, async: true

  describe "list_copilot/0" do
    test "returns a non-empty list of models" do
      models = Opal.Provider.Registry.list_copilot()
      assert is_list(models)
      assert length(models) > 0
    end

    test "each model has id, name, and supports_thinking" do
      for model <- Opal.Provider.Registry.list_copilot() do
        assert is_binary(model.id), "expected id to be a string, got: #{inspect(model.id)}"
        assert is_binary(model.name), "expected name to be a string, got: #{inspect(model.name)}"
        assert is_boolean(model.supports_thinking)
      end
    end

    test "includes known Copilot models" do
      ids = Enum.map(Opal.Provider.Registry.list_copilot(), & &1.id)
      assert "claude-opus-4.6" in ids
      assert "claude-sonnet-4" in ids
      assert "gpt-5" in ids
    end

    test "claude models support thinking" do
      models = Opal.Provider.Registry.list_copilot()
      claude = Enum.find(models, &(&1.id == "claude-opus-4.6"))
      assert claude.supports_thinking == true
    end

    test "results are sorted by id" do
      models = Opal.Provider.Registry.list_copilot()
      ids = Enum.map(models, & &1.id)
      assert ids == Enum.sort(ids)
    end
  end

  describe "context_window/1" do
    test "returns context window for a known Copilot model" do
      model = %Opal.Provider.Model{id: "claude-opus-4.6"}
      ctx = Opal.Provider.Registry.context_window(model)
      assert is_integer(ctx)
      assert ctx > 0
    end

    test "falls back to default for unknown model" do
      model = %Opal.Provider.Model{id: "nonexistent-model-xyz"}
      assert Opal.Provider.Registry.context_window(model) == 128_000
    end
  end

  describe "resolve/1" do
    test "resolves a known Copilot model" do
      model = %Opal.Provider.Model{id: "claude-opus-4.6"}
      assert {:ok, resolved} = Opal.Provider.Registry.resolve(model)
      assert resolved.name == "Claude Opus 4.6"
      assert resolved.limits.context > 0
    end

    test "returns error for unknown model" do
      model = %Opal.Provider.Model{id: "nonexistent-xyz"}
      assert {:error, :not_found} = Opal.Provider.Registry.resolve(model)
    end
  end
end
