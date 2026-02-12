defmodule Opal.RPC.HandlerTest do
  use ExUnit.Case, async: true

  alias Opal.RPC.Handler

  describe "handle/2 unknown method" do
    test "returns method_not_found error" do
      assert {:error, -32601, "Method not found: foo/bar", nil} =
               Handler.handle("foo/bar", %{})
    end
  end

  describe "handle/2 models/list" do
    test "returns a list of models" do
      assert {:ok, %{models: models}} = Handler.handle("models/list", %{})
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, fn m -> is_map(m) and Map.has_key?(m, :id) end)
    end
  end

  describe "handle/2 auth/status" do
    test "returns an authenticated boolean" do
      assert {:ok, %{authenticated: auth}} = Handler.handle("auth/status", %{})
      assert is_boolean(auth)
    end
  end

  describe "handle/2 session/list" do
    test "returns a sessions list (possibly empty)" do
      assert {:ok, %{sessions: sessions}} = Handler.handle("session/list", %{})
      assert is_list(sessions)
    end
  end

  describe "handle/2 agent/prompt missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("agent/prompt", %{})
    end
  end

  describe "handle/2 agent/steer missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("agent/steer", %{})
    end
  end

  describe "handle/2 agent/abort missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("agent/abort", %{})
    end
  end

  describe "handle/2 agent/state missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("agent/state", %{})
    end
  end

  describe "handle/2 session/branch missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("session/branch", %{})
    end
  end

  describe "handle/2 session/compact missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("session/compact", %{})
    end
  end

  describe "handle/2 agent/prompt with nonexistent session" do
    test "returns session not found error" do
      assert {:error, -32602, "Session not found", _} =
               Handler.handle("agent/prompt", %{"session_id" => "nonexistent", "text" => "hi"})
    end
  end

  describe "handle/2 session/compact with session_id" do
    test "returns session not found for unknown session" do
      assert {:error, -32602, "Session not found", _} =
               Handler.handle("session/compact", %{"session_id" => "abc"})
    end
  end
end
