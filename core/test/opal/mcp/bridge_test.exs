defmodule Opal.MCP.BridgeTest do
  use ExUnit.Case, async: true

  alias Opal.MCP.Bridge

  @moduletag :mcp

  describe "create_tool_module/3" do
    test "uses the resolved name for the tool" do
      tool = %{
        "name" => "search_issues",
        "description" => "Search for issues",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"}
          }
        }
      }

      mod = Bridge.create_tool_module(:sentry, tool, "search_issues")

      assert mod.name() == "search_issues"
      assert mod.description() == "Search for issues"
      assert mod.parameters() == tool["inputSchema"]
    end

    test "handles tool with no description" do
      tool = %{
        "name" => "ping",
        "inputSchema" => %{}
      }

      mod = Bridge.create_tool_module(:test_server, tool, "ping")

      assert mod.name() == "ping"
      assert mod.description() == ""
    end

    test "handles tool with no inputSchema" do
      tool = %{
        "name" => "status"
      }

      mod = Bridge.create_tool_module(:test_server2, tool, "status")

      assert mod.name() == "status"
      assert mod.parameters() == %{}
    end

    test "creates modules implementing Opal.Tool behaviour" do
      tool = %{
        "name" => "echo",
        "description" => "Echoes input",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string"}
          }
        }
      }

      mod = Bridge.create_tool_module(:echo_server, tool, "echo")

      assert function_exported?(mod, :name, 0)
      assert function_exported?(mod, :description, 0)
      assert function_exported?(mod, :parameters, 0)
      assert function_exported?(mod, :execute, 2)
    end

    test "prefixed names when collision occurs" do
      tool = %{"name" => "list", "description" => "List items"}

      mod_a = Bridge.create_tool_module(:server_a, tool, "server_a_list")
      mod_b = Bridge.create_tool_module(:server_b, tool, "server_b_list")

      assert mod_a != mod_b
      assert mod_a.name() == "server_a_list"
      assert mod_b.name() == "server_b_list"
    end
  end

  describe "discover_all_tools/1" do
    test "returns empty list for empty servers" do
      assert Bridge.discover_all_tools([]) == []
    end
  end
end
