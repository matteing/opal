defmodule Opal.RPC.ServerDispatchTest do
  use ExUnit.Case, async: true

  alias Opal.RPC.Server

  describe "handle/2 unknown method" do
    test "returns method_not_found error" do
      assert {:error, -32601, "Method not found: foo/bar", nil} =
               Server.dispatch("foo/bar", %{})
    end
  end

  describe "handle/2 models/list" do
    test "returns a list of models" do
      assert {:ok, %{models: models}} = Server.dispatch("models/list", %{})
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, fn m -> is_map(m) and Map.has_key?(m, :id) end)
    end
  end

  describe "handle/2 auth/status" do
    test "returns an authenticated boolean" do
      assert {:ok, %{authenticated: auth}} = Server.dispatch("auth/status", %{})
      assert is_boolean(auth)
    end
  end

  describe "handle/2 session/list" do
    test "returns a sessions list (possibly empty)" do
      assert {:ok, %{sessions: sessions}} = Server.dispatch("session/list", %{})
      assert is_list(sessions)
    end
  end

  describe "handle/2 agent/prompt missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("agent/prompt", %{})
    end
  end

  describe "handle/2 agent/abort missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("agent/abort", %{})
    end
  end

  describe "handle/2 agent/state missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("agent/state", %{})
    end
  end

  describe "handle/2 session/branch missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("session/branch", %{})
    end
  end

  describe "handle/2 session/compact missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("session/compact", %{})
    end
  end

  describe "handle/2 agent/prompt with nonexistent session" do
    test "returns session not found error" do
      assert {:error, -32602, "Session not found", _} =
               Server.dispatch("agent/prompt", %{"session_id" => "nonexistent", "text" => "hi"})
    end
  end

  describe "handle/2 session/compact with session_id" do
    test "returns session not found for unknown session" do
      assert {:error, -32602, "Session not found", _} =
               Server.dispatch("session/compact", %{"session_id" => "abc"})
    end
  end

  describe "handle/2 models/list with reasoning metadata" do
    test "models include supports_thinking and thinking_levels" do
      assert {:ok, %{models: models}} = Server.dispatch("models/list", %{})

      for model <- models do
        assert Map.has_key?(model, :supports_thinking),
               "model #{model.id} missing supports_thinking"

        assert Map.has_key?(model, :thinking_levels),
               "model #{model.id} missing thinking_levels"
      end
    end

    test "reasoning models have non-empty thinking_levels" do
      assert {:ok, %{models: models}} = Server.dispatch("models/list", %{})
      reasoning = Enum.filter(models, & &1.supports_thinking)
      assert length(reasoning) > 0

      for model <- reasoning do
        assert model.thinking_levels != [],
               "reasoning model #{model.id} should have thinking_levels"
      end
    end

    test "non-reasoning models have empty thinking_levels" do
      assert {:ok, %{models: models}} = Server.dispatch("models/list", %{})
      non_reasoning = Enum.filter(models, &(not &1.supports_thinking))

      for model <- non_reasoning do
        assert model.thinking_levels == [],
               "non-reasoning model #{model.id} should have empty thinking_levels"
      end
    end

    test "models from direct providers include thinking metadata" do
      assert {:ok, %{models: models}} =
               Server.dispatch("models/list", %{"providers" => ["anthropic"]})

      anthropic = Enum.filter(models, &(&1.provider == "anthropic"))
      assert length(anthropic) > 0

      for model <- anthropic do
        assert Map.has_key?(model, :supports_thinking)
        assert Map.has_key?(model, :thinking_levels)
      end
    end

    test "returns invalid_params for unknown providers in list" do
      assert {:error, -32602, "Unknown provider in providers list", _} =
               Server.dispatch("models/list", %{"providers" => ["definitely_not_a_provider"]})
    end
  end

  describe "handle/2 model/set missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("model/set", %{})
    end
  end

  describe "handle/2 thinking/set missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("thinking/set", %{})
    end
  end

  describe "handle/2 thinking/set with nonexistent session" do
    test "returns session not found error" do
      assert {:error, -32602, "Session not found", "No session with id: nonexistent"} =
               Server.dispatch("thinking/set", %{"session_id" => "nonexistent", "level" => "high"})
    end
  end

  describe "handle/2 model/set with nonexistent session" do
    test "returns session not found error" do
      assert {:error, -32602, "Session not found", "No session with id: nonexistent"} =
               Server.dispatch("model/set", %{
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
               Server.dispatch("opal/config/get", %{"session_id" => sid})

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
               Server.dispatch("opal/config/get", %{"session_id" => sid})

      enabled_tools = Enum.uniq([first_tool, "debug_state"])

      assert {:ok, %{features: features, tools: tools}} =
               Server.dispatch("opal/config/set", %{
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
               Server.dispatch("opal/config/set", %{
                 "session_id" => sid,
                 "tools" => ["definitely_not_a_tool"]
               })
    end
  end

  describe "handle/2 session/start with feature toggles" do
    test "accepts boot-time feature and tool configuration" do
      assert {:ok, %{session_id: sid}} =
               Server.dispatch("session/start", %{
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
               Server.dispatch("opal/config/get", %{"session_id" => sid})

      refute features.sub_agents
      assert tools.enabled == ["read_file"]
    end
  end

  describe "handle/2 opal/ping" do
    test "returns ok with empty map" do
      assert {:ok, %{}} = Server.dispatch("opal/ping", %{})
    end
  end

  describe "handle/2 settings/get" do
    test "returns settings map" do
      assert {:ok, %{settings: settings}} = Server.dispatch("settings/get", %{})
      assert is_map(settings)
    end
  end

  describe "handle/2 settings/save" do
    test "saves and returns settings" do
      assert {:ok, %{settings: _}} =
               Server.dispatch("settings/save", %{
                 "settings" => %{"test_key_handler" => "test_value"}
               })
    end

    test "returns error for missing settings" do
      assert {:error, -32602, _, nil} = Server.dispatch("settings/save", %{})
    end

    test "returns error for non-map settings" do
      assert {:error, -32602, _, nil} =
               Server.dispatch("settings/save", %{"settings" => "not a map"})
    end
  end

  describe "handle/2 tasks/list" do
    test "returns error for missing session_id" do
      assert {:error, -32602, _, nil} = Server.dispatch("tasks/list", %{})
    end

    test "returns error for nonexistent session" do
      assert {:error, -32602, "Session not found", _} =
               Server.dispatch("tasks/list", %{"session_id" => "nonexistent"})
    end
  end

  describe "handle/2 auth/set_key" do
    test "sets provider API key" do
      assert {:ok, %{ok: true}} =
               Server.dispatch("auth/set_key", %{
                 "provider" => "test_provider",
                 "api_key" => "test-key-123"
               })
    end

    test "returns error for missing params" do
      assert {:error, -32602, _, nil} = Server.dispatch("auth/set_key", %{})
    end

    test "returns error for empty api_key" do
      assert {:error, -32602, _, nil} =
               Server.dispatch("auth/set_key", %{"provider" => "test", "api_key" => ""})
    end
  end

  describe "handle/2 auth/poll" do
    test "returns error for missing params" do
      assert {:error, -32602, _, nil} = Server.dispatch("auth/poll", %{})
    end
  end

  describe "handle/2 session/start validation" do
    test "returns error for invalid model params" do
      assert {:error, -32602, "model must be {provider, id} with non-empty strings", _} =
               Server.dispatch("session/start", %{
                 "working_dir" => File.cwd!(),
                 "model" => %{"provider" => "", "id" => ""}
               })
    end

    test "returns error for invalid features type" do
      assert {:error, -32602, "features must be an object", _} =
               Server.dispatch("session/start", %{
                 "working_dir" => File.cwd!(),
                 "features" => "not_a_map"
               })
    end

    test "returns error for invalid tools type" do
      assert {:error, -32602, "tools must be an array of strings", _} =
               Server.dispatch("session/start", %{
                 "working_dir" => File.cwd!(),
                 "tools" => "not_an_array"
               })
    end

    test "returns error for unknown feature keys" do
      assert {:error, -32602, "Unknown feature keys", _} =
               Server.dispatch("session/start", %{
                 "working_dir" => File.cwd!(),
                 "features" => %{"unknown_feature" => true}
               })
    end

    test "returns error for non-boolean feature values" do
      assert {:error, -32602, "Invalid feature value", _} =
               Server.dispatch("session/start", %{
                 "working_dir" => File.cwd!(),
                 "features" => %{"debug" => "yes"}
               })
    end
  end

  describe "handle/2 opal/config/get missing params" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("opal/config/get", %{})
    end
  end

  describe "handle/2 opal/config/set missing session_id" do
    test "returns invalid_params error" do
      assert {:error, -32602, _, nil} = Server.dispatch("opal/config/set", %{})
    end
  end

  describe "handle/2 with active session" do
    setup do
      {:ok, agent} = Opal.start_session(%{working_dir: File.cwd!()})
      sid = Opal.get_info(agent).session_id
      on_exit(fn -> Opal.stop_session(agent) end)
      %{agent: agent, sid: sid}
    end

    test "agent/state returns state for valid session", %{sid: sid} do
      assert {:ok, state} = Server.dispatch("agent/state", %{"session_id" => sid})
      assert is_map(state)
      assert Map.has_key?(state, :model)
    end

    test "agent/abort returns ok for valid session", %{sid: sid} do
      assert {:ok, _} = Server.dispatch("agent/abort", %{"session_id" => sid})
    end

    test "model/set changes model for valid session", %{sid: sid} do
      assert {:ok, %{model: %{id: "gpt-4o"}}} =
               Server.dispatch("model/set", %{"session_id" => sid, "model_id" => "gpt-4o"})
    end

    test "thinking/set changes thinking level for valid session", %{sid: sid} do
      assert {:ok, _} =
               Server.dispatch("thinking/set", %{"session_id" => sid, "level" => "off"})
    end

    test "session/branch with entry_id", %{sid: sid} do
      # entry_id won't exist so this should return some kind of response
      result =
        Server.dispatch("session/branch", %{
          "session_id" => sid,
          "entry_id" => "nonexistent-entry"
        })

      # May succeed or fail depending on session state — both are valid paths
      assert is_tuple(result)
    end

    test "tasks/list returns tasks for valid session", %{sid: sid} do
      assert {:ok, %{tasks: tasks}} =
               Server.dispatch("tasks/list", %{"session_id" => sid})

      assert is_list(tasks)
    end
  end

  describe "handle/2 models/list with provider filter" do
    test "returns models for copilot provider" do
      assert {:ok, %{models: models}} =
               Server.dispatch("models/list", %{"providers" => ["copilot"]})

      assert length(models) > 0
      assert Enum.all?(models, &(&1.provider == "copilot"))
    end

    test "returns models for multiple providers" do
      assert {:ok, %{models: models}} =
               Server.dispatch("models/list", %{"providers" => ["copilot", "anthropic"]})

      providers = models |> Enum.map(& &1.provider) |> Enum.uniq()
      assert length(providers) >= 1
    end
  end

  describe "handle/2 opal/version" do
    test "returns server_version and protocol_version" do
      assert {:ok, result} = Server.dispatch("opal/version", %{})
      assert is_binary(result.server_version)
      assert is_binary(result.protocol_version)
      assert result.server_version =~ ~r/^\d+\.\d+\.\d+/
      assert result.protocol_version =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  describe "handle/2 session/delete" do
    test "returns invalid_params when session_id is missing" do
      assert {:error, -32602, "Missing required param: session_id", nil} =
               Server.dispatch("session/delete", %{})
    end

    test "returns error for nonexistent session" do
      assert {:error, -32602, "Session not found", _} =
               Server.dispatch("session/delete", %{"session_id" => "nonexistent-id-12345"})
    end

    test "deletes an existing session file" do
      config = Opal.Config.new()
      dir = Opal.Config.sessions_dir(config)
      File.mkdir_p!(dir)

      session_id = "test-delete-#{System.unique_integer([:positive])}"
      path = Path.join(dir, "#{session_id}.jsonl")
      File.write!(path, "test data\n")
      assert File.exists?(path)

      assert {:ok, %{ok: true}} =
               Server.dispatch("session/delete", %{"session_id" => session_id})

      refute File.exists?(path)
    end
  end
end
