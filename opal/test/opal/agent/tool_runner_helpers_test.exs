defmodule Opal.Agent.ToolRunnerHelpersTest do
  @moduledoc """
  Tests for pure helper functions in Opal.Agent.ToolRunner.
  """
  use ExUnit.Case, async: true

  alias Opal.Agent.ToolRunner

  defmodule EchoTool do
    @behaviour Opal.Tool
    def name, do: "echo"
    def description, do: "Echoes input"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(%{"text" => text}, _ctx), do: {:ok, text}
  end

  describe "find_tool/2" do
    test "returns matching module" do
      assert ToolRunner.find_tool("echo", [EchoTool]) == EchoTool
    end

    test "returns nil when empty list" do
      assert ToolRunner.find_tool("echo", []) == nil
    end
  end

  describe "execute_tool/3" do
    test "returns :error tuple for nil module" do
      assert {:error, "Tool not found"} = ToolRunner.execute_tool(nil, %{}, %{})
    end

    test "delegates to tool module" do
      assert {:ok, "hello"} = ToolRunner.execute_tool(EchoTool, %{"text" => "hello"}, %{})
    end
  end
end
