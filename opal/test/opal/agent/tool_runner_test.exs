defmodule Opal.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.ToolRunner
  alias Opal.Agent.State
  alias Opal.Provider.Model

  defmodule SuccessTool do
    @behaviour Opal.Tool
    def name, do: "success"
    def description, do: "Always succeeds"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: {:ok, "ok"}
  end

  defmodule CrashTool do
    @behaviour Opal.Tool
    def name, do: "crash"
    def description, do: "Always raises"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: raise("boom")
  end

  defp base_state do
    %State{
      session_id: "tr-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: Opal.Config.new(),
      tools: [SuccessTool, CrashTool]
    }
  end

  describe "find_tool/2" do
    test "finds tool by name" do
      assert ToolRunner.find_tool("success", [SuccessTool, CrashTool]) == SuccessTool
    end

    test "returns nil for unknown tool" do
      assert ToolRunner.find_tool("nonexistent", [SuccessTool]) == nil
    end
  end

  describe "execute_tool/3" do
    test "returns error when tool module is nil" do
      assert {:error, "Tool not found"} = ToolRunner.execute_tool(nil, %{}, %{})
    end

    test "executes tool successfully" do
      assert {:ok, "ok"} = ToolRunner.execute_tool(SuccessTool, %{}, %{})
    end

    test "catches exceptions and returns error" do
      assert {:error, msg} = ToolRunner.execute_tool(CrashTool, %{}, %{})
      assert msg =~ "boom"
    end
  end

  describe "active_tools/1" do
    test "returns all tools when nothing disabled" do
      state = base_state()
      tools = ToolRunner.active_tools(state)
      assert SuccessTool in tools
      assert CrashTool in tools
    end

    test "respects disabled_tools" do
      state = %{base_state() | disabled_tools: ["success"]}
      tools = ToolRunner.active_tools(state)
      refute SuccessTool in tools
      assert CrashTool in tools
    end
  end

  describe "drain_pending/1" do
    test "returns state unchanged when no pending messages" do
      state = base_state()
      assert ToolRunner.drain_pending(state) == state
    end

    test "injects pending messages as user turns" do
      state = %{base_state() | pending_messages: ["Do something else"]}
      new_state = ToolRunner.drain_pending(state)
      assert new_state.pending_messages == []
      [msg | _] = new_state.messages
      assert msg.role == :user
      assert msg.content == "Do something else"
    end
  end

  describe "cancel_all/1" do
    test "no-op when no pending tasks" do
      state = base_state()
      assert ToolRunner.cancel_all(state) == state
    end
  end
end
