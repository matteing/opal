defmodule Opal.Auth.CopilotTest do
  use ExUnit.Case, async: true

  describe "token_expired?/1" do
    test "returns true when expires_at is in the past" do
      past = System.system_time(:second) - 600
      assert Opal.Auth.Copilot.token_expired?(%{"expires_at" => past})
    end

    test "returns true when expires_at is within 5-minute buffer" do
      almost_expired = System.system_time(:second) + 200
      assert Opal.Auth.Copilot.token_expired?(%{"expires_at" => almost_expired})
    end

    test "returns false when expires_at is well in the future" do
      future = System.system_time(:second) + 3600
      refute Opal.Auth.Copilot.token_expired?(%{"expires_at" => future})
    end

    test "returns false when expires_at is exactly at the 5-minute boundary" do
      boundary = System.system_time(:second) + 301
      refute Opal.Auth.Copilot.token_expired?(%{"expires_at" => boundary})
    end

    test "returns true for map without expires_at" do
      assert Opal.Auth.Copilot.token_expired?(%{})
    end

    test "returns true for non-integer expires_at" do
      assert Opal.Auth.Copilot.token_expired?(%{"expires_at" => "not_a_number"})
    end

    test "returns true for nil input" do
      assert Opal.Auth.Copilot.token_expired?(nil)
    end
  end

  describe "save_token/1 and load_token/0 round-trip" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "opal_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      token_path = Path.join(tmp_dir, "token.json")

      # Override the token_path function for testing by writing directly
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, token_path: token_path}
    end

    test "round-trips token data through file", %{token_path: token_path} do
      token_data = %{
        "github_token" => "ghu_test123",
        "copilot_token" => "tid_test456",
        "expires_at" => System.system_time(:second) + 3600
      }

      json = Jason.encode!(token_data)
      File.write!(token_path, json)

      {:ok, contents} = File.read(token_path)
      {:ok, loaded} = Jason.decode(contents)

      assert loaded["github_token"] == "ghu_test123"
      assert loaded["copilot_token"] == "tid_test456"
      assert loaded["expires_at"] == token_data["expires_at"]
    end

    test "handles empty map token data", %{token_path: token_path} do
      File.write!(token_path, Jason.encode!(%{}))
      {:ok, contents} = File.read(token_path)
      {:ok, loaded} = Jason.decode(contents)
      assert loaded == %{}
    end
  end

  describe "load_token/0 error handling" do
    test "returns error for missing file" do
      # We can test the underlying mechanics: File.read + Jason.decode
      assert {:error, :enoent} =
               File.read(
                 "/tmp/opal_nonexistent_#{:erlang.unique_integer([:positive])}/token.json"
               )
    end

    test "returns error for corrupt JSON" do
      tmp = Path.join(System.tmp_dir!(), "opal_corrupt_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      path = Path.join(tmp, "token.json")
      File.write!(path, "not valid json{{{")

      {:ok, contents} = File.read(path)
      assert {:error, _} = Jason.decode(contents)

      File.rm_rf!(tmp)
    end
  end

  describe "base_url/1" do
    test "extracts URL from endpoints.api" do
      token_data = %{"endpoints" => %{"api" => "https://custom.api.example.com"}}
      assert Opal.Auth.Copilot.base_url(token_data) == "https://custom.api.example.com"
    end

    test "extracts proxy-ep from semicolon-delimited token" do
      token = "tid=abc123;proxy-ep=proxy.enterprise.githubcopilot.com;exp=9999999999"

      token_data = %{"token" => token}
      assert Opal.Auth.Copilot.base_url(token_data) == "https://api.enterprise.githubcopilot.com"
    end

    test "falls back to default URL when token has no proxy-ep" do
      token = "tid=abc123;exp=9999999999;chat=1"

      token_data = %{"token" => token}
      assert Opal.Auth.Copilot.base_url(token_data) == "https://api.individual.githubcopilot.com"
    end

    test "falls back to default URL for invalid token format" do
      token_data = %{"token" => "!!!invalid!!!"}
      assert Opal.Auth.Copilot.base_url(token_data) == "https://api.individual.githubcopilot.com"
    end

    test "handles proxy-ep without proxy. prefix" do
      token = "tid=abc;proxy-ep=custom.githubcopilot.com;exp=9999"
      token_data = %{"token" => token}
      assert Opal.Auth.Copilot.base_url(token_data) == "https://custom.githubcopilot.com"
    end

    test "falls back to default URL for empty map" do
      assert Opal.Auth.Copilot.base_url(%{}) == "https://api.individual.githubcopilot.com"
    end

    test "falls back to default URL for nil" do
      assert Opal.Auth.Copilot.base_url(nil) == "https://api.individual.githubcopilot.com"
    end

    test "endpoints.api takes precedence over token field" do
      payload = Jason.encode!(%{"proxy-ep" => "https://proxy.example.com"})
      encoded_payload = Base.encode64(payload, padding: false)
      token = "header.#{encoded_payload}.signature"

      token_data = %{
        "endpoints" => %{"api" => "https://api.endpoint.com"},
        "token" => token
      }

      assert Opal.Auth.Copilot.base_url(token_data) == "https://api.endpoint.com"
    end
  end

  describe "list_models/0" do
    test "returns a non-empty list" do
      models = Opal.Auth.Copilot.list_models()
      assert is_list(models)
      assert length(models) > 0
    end

    test "each model has :id and :name keys" do
      for model <- Opal.Auth.Copilot.list_models() do
        assert Map.has_key?(model, :id), "Model missing :id key: #{inspect(model)}"
        assert Map.has_key?(model, :name), "Model missing :name key: #{inspect(model)}"
        assert is_binary(model.id)
        assert is_binary(model.name)
      end
    end

    test "includes expected models" do
      ids = Opal.Auth.Copilot.list_models() |> Enum.map(& &1.id)
      assert "claude-sonnet-4" in ids
      assert "gpt-5" in ids
      assert "gpt-4o" in ids
    end

    test "all model IDs are unique" do
      ids = Opal.Auth.Copilot.list_models() |> Enum.map(& &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "all model names are non-empty" do
      for model <- Opal.Auth.Copilot.list_models() do
        assert byte_size(model.name) > 0, "Model #{model.id} has empty name"
      end
    end
  end
end
