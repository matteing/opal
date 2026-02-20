defmodule Opal.AuthTest do
  use ExUnit.Case, async: true

  alias Opal.Auth

  describe "probe/0" do
    test "returns a map with status and provider" do
      result = Auth.probe()

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :provider)
      assert result.status in ["ready", "setup_required"]
    end

    test "provider is copilot when ready, nil otherwise" do
      result = Auth.probe()

      case result.status do
        "ready" -> assert result.provider == "copilot"
        "setup_required" -> assert result.provider == nil
      end
    end
  end

  describe "ready?/0" do
    test "returns a boolean" do
      assert is_boolean(Auth.ready?())
    end
  end
end
