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

  describe "handle/2 models/list with reasoning metadata" do
    test "models include supports_thinking and thinking_levels" do
      assert {:ok, %{models: models}} = Handler.handle("models/list", %{})

      for model <- models do
        assert Map.has_key?(model, :supports_thinking),
               "model #{model.id} missing supports_thinking"

        assert Map.has_key?(model, :thinking_levels),
               "model #{model.id} missing thinking_levels"
      end
    end

    test "reasoning models have non-empty thinking_levels" do
      assert {:ok, %{models: models}} = Handler.handle("models/list", %{})
      reasoning = Enum.filter(models, & &1.supports_thinking)
      assert length(reasoning) > 0

      for model <- reasoning do
        assert model.thinking_levels != [],
               "reasoning model #{model.id} should have thinking_levels"
      end
    end

    test "non-reasoning models have empty thinking_levels" do
      assert {:ok, %{models: models}} = Handler.handle("models/list", %{})
      non_reasoning = Enum.filter(models, &(not &1.supports_thinking))

      for model <- non_reasoning do
        assert model.thinking_levels == [],
               "non-reasoning model #{model.id} should have empty thinking_levels"
      end
    end

    test "models from direct providers include thinking metadata" do
      assert {:ok, %{models: models}} =
               Handler.handle("models/list", %{"providers" => ["anthropic"]})

      anthropic = Enum.filter(models, &(&1.provider == "anthropic"))
      assert length(anthropic) > 0

      for model <- anthropic do
        assert Map.has_key?(model, :supports_thinking)
        assert Map.has_key?(model, :thinking_levels)
      end
    end

    test "returns invalid_params for unknown providers in list" do
      assert {:error, -32602, "Unknown provider in providers list", _} =
               Handler.handle("models/list", %{"providers" => ["definitely_not_a_provider"]})
    end
  end

  describe "handle/2 model/set missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("model/set", %{})
    end
  end

  describe "handle/2 thinking/set missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Handler.handle("thinking/set", %{})
    end
  end

  describe "handle/2 thinking/set with nonexistent session" do
    test "returns session not found error" do
      assert {:error, "No session with id: nonexistent"} =
               Handler.handle("thinking/set", %{"session_id" => "nonexistent", "level" => "high"})
    end
  end

  describe "handle/2 model/set with nonexistent session" do
    test "returns session not found error" do
      assert {:error, "No session with id: nonexistent"} =
               Handler.handle("model/set", %{
                 "session_id" => "nonexistent",
                 "model_id" => "gpt-5",
                 "thinking_level" => "high"
               })
    end
  end

  describe "handle/2 opal/config/get" do
    test "returns runtime feature and tool config for an active session" do
      {:ok, agent} = Opal.start_session(%{working_dir: File.cwd!()})
      on_exit(fn -> Opal.stop_session(agent) end)
      sid = Opal.get_info(agent).session_id

      assert {:ok, %{features: features, tools: tools}} =
               Handler.handle("opal/config/get", %{"session_id" => sid})

      assert is_boolean(features.sub_agents)
      assert is_boolean(features.skills)
      assert is_boolean(features.mcp)
      assert is_boolean(features.debug)
      assert is_list(tools.all)
      assert is_list(tools.enabled)
      assert is_list(tools.disabled)
    end
  end

  describe "handle/2 opal/config/set" do
    test "updates runtime features and tool allowlist" do
      {:ok, agent} = Opal.start_session(%{working_dir: File.cwd!()})
      on_exit(fn -> Opal.stop_session(agent) end)
      sid = Opal.get_info(agent).session_id

      assert {:ok, %{tools: %{all: [first_tool | _]}}} =
               Handler.handle("opal/config/get", %{"session_id" => sid})

      enabled_tools = Enum.uniq([first_tool, "debug_state"])

      assert {:ok, %{features: features, tools: tools}} =
               Handler.handle("opal/config/set", %{
                 "session_id" => sid,
                 "features" => %{"sub_agents" => false, "debug" => true},
                 "tools" => enabled_tools
               })

      refute features.sub_agents
      assert features.debug
      assert first_tool in tools.enabled
      assert "debug_state" in tools.enabled
      assert first_tool in tools.all
    end

    test "returns invalid_params for unknown tool names" do
      {:ok, agent} = Opal.start_session(%{working_dir: File.cwd!()})
      on_exit(fn -> Opal.stop_session(agent) end)
      sid = Opal.get_info(agent).session_id

      assert {:error, -32602, "Unknown tools in tools list", _} =
               Handler.handle("opal/config/set", %{
                 "session_id" => sid,
                 "tools" => ["definitely_not_a_tool"]
               })
    end
  end

  describe "handle/2 session/start with feature toggles" do
    test "accepts boot-time feature and tool configuration" do
      assert {:ok, %{session_id: sid}} =
               Handler.handle("session/start", %{
                 "working_dir" => File.cwd!(),
                 "features" => %{"sub_agents" => false},
                 "tools" => ["read_file"]
               })

      on_exit(fn ->
        case Registry.lookup(Opal.Registry, {:agent, sid}) do
          [{agent, _}] -> Opal.stop_session(agent)
          [] -> :ok
        end
      end)

      assert {:ok, %{features: features, tools: tools}} =
               Handler.handle("opal/config/get", %{"session_id" => sid})

      refute features.sub_agents
      assert tools.enabled == ["read_file"]
    end
  end
end
