defmodule Opal.MCP.SupervisorTest do
  use ExUnit.Case, async: true

  alias Opal.MCP.Supervisor, as: MCPSupervisor

  @moduletag :mcp

  describe "start_link/1" do
    test "starts with empty server list" do
      {:ok, pid} = MCPSupervisor.start_link(servers: [])
      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      assert children == []

      Supervisor.stop(pid)
    end
  end

  describe "running_clients/1" do
    test "returns empty list for supervisor with no servers" do
      {:ok, pid} = MCPSupervisor.start_link(servers: [])
      assert MCPSupervisor.running_clients(pid) == []
      Supervisor.stop(pid)
    end
  end
end
