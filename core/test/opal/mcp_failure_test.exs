defmodule Opal.MCPFailureTest do
  @moduledoc """
  Tests MCP tool discovery and execution failures: discovery crash,
  partial failure, tool not found.
  """
  use ExUnit.Case, async: true

  alias Opal.MCP.Bridge

  describe "discover_tools with unavailable client" do
    test "returns empty list when client doesn't exist" do
      result = Bridge.discover_tools(:nonexistent_mcp_client)
      assert result == []
    end
  end

  describe "discover_tool_modules with unavailable servers" do
    test "returns empty list for servers that can't be reached" do
      servers = [%{name: :nonexistent_client}]
      result = Bridge.discover_tool_modules(servers, MapSet.new())
      assert result == []
    end

    test "returns empty list with native name collisions for unavailable servers" do
      servers = [%{name: :nonexistent_client}]
      native_names = MapSet.new(["read_file", "write_file"])
      result = Bridge.discover_tool_modules(servers, native_names)
      assert result == []
    end
  end

  describe "MCP tool discovery in agent init" do
    test "agent starts successfully even with invalid MCP servers" do
      session_id = "mcp-fail-#{System.unique_integer([:positive])}"
      {:ok, tool_sup} = Task.Supervisor.start_link()

      {:ok, pid} =
        Opal.Agent.start_link(
          session_id: session_id,
          model: Opal.Model.new(:test, "test"),
          working_dir: System.tmp_dir!(),
          system_prompt: "Test",
          tools: [],
          provider: Opal.Provider.Copilot,
          config: Opal.Config.new(),
          tool_supervisor: tool_sup,
          mcp_servers: [%{name: :fake_mcp, command: "nonexistent_binary"}]
        )

      # Agent should start even though MCP discovery failed
      assert Process.alive?(pid)
      state = Opal.Agent.get_state(pid)
      assert state.status == :idle
    end
  end
end
