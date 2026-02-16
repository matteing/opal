defmodule Opal.AuthTest do
  use ExUnit.Case, async: true

  alias Opal.Auth

  describe "probe/0" do
    test "returns a map with status, provider, and providers" do
      result = Auth.probe()

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :provider)
      assert Map.has_key?(result, :providers)
      assert result.status in ["ready", "setup_required"]
      assert is_list(result.providers)
      assert length(result.providers) == 4
    end

    test "all providers include id, name, method, and ready" do
      result = Auth.probe()

      for provider <- result.providers do
        assert Map.has_key?(provider, :id)
        assert Map.has_key?(provider, :name)
        assert Map.has_key?(provider, :method)
        assert Map.has_key?(provider, :ready)
        assert is_boolean(provider.ready)
      end
    end

    test "providers include copilot, anthropic, openai, google" do
      result = Auth.probe()
      ids = Enum.map(result.providers, & &1.id)
      assert "copilot" in ids
      assert "anthropic" in ids
      assert "openai" in ids
      assert "google" in ids
    end
  end

  describe "ready?/1" do
    test "returns boolean for copilot" do
      assert is_boolean(Auth.ready?("copilot"))
    end

    test "returns boolean for anthropic" do
      assert is_boolean(Auth.ready?("anthropic"))
    end

    test "returns false for unknown provider" do
      refute Auth.ready?("unknown_provider")
    end
  end
end
