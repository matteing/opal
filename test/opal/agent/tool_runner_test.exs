defmodule Opal.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.ToolRunner
  alias Opal.Agent.State
  alias Opal.Model

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

  describe "find_tool_module/2" do
    test "finds tool by name" do
      assert ToolRunner.find_tool_module("success", [SuccessTool, CrashTool]) == SuccessTool
    end

    test "returns nil for unknown tool" do
      assert ToolRunner.find_tool_module("nonexistent", [SuccessTool]) == nil
    end
  end

  describe "execute_single_tool/3" do
    test "returns error when tool module is nil" do
      assert {:error, "Tool not found"} = ToolRunner.execute_single_tool(nil, %{}, %{})
    end

    test "executes tool successfully" do
      assert {:ok, "ok"} = ToolRunner.execute_single_tool(SuccessTool, %{}, %{})
    end

    test "catches exceptions and returns error" do
      assert {:error, msg} = ToolRunner.execute_single_tool(CrashTool, %{}, %{})
      assert msg =~ "boom"
    end
  end

  describe "make_relative/2" do
    test "converts absolute path within working dir to relative" do
      assert ToolRunner.make_relative("/home/user/project/src/main.ex", "/home/user/project") ==
               "src/main.ex"
    end

    test "returns path unchanged when outside working dir" do
      assert ToolRunner.make_relative("/other/path/file.ex", "/home/user/project") ==
               "/other/path/file.ex"
    end

    test "handles already relative path" do
      assert ToolRunner.make_relative("src/main.ex", "/home/user/project") == "src/main.ex"
    end
  end

  describe "build_tool_context/1" do
    test "includes working_dir, session_id, config" do
      state = base_state()
      ctx = ToolRunner.build_tool_context(state)
      assert ctx.working_dir == state.working_dir
      assert ctx.session_id == state.session_id
      assert ctx.config == state.config
    end

    test "includes question_handler when present" do
      handler = fn _q -> {:ok, "answer"} end
      state = %{base_state() | question_handler: handler}
      ctx = ToolRunner.build_tool_context(state)
      assert ctx.question_handler == handler
    end

    test "omits question_handler when nil" do
      ctx = ToolRunner.build_tool_context(base_state())
      refute Map.has_key?(ctx, :question_handler)
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

  describe "check_for_steering/1" do
    test "returns state unchanged when no pending steers" do
      state = base_state()
      assert ToolRunner.check_for_steering(state) == state
    end

    test "injects pending steers as user messages" do
      state = %{base_state() | pending_steers: ["Do something else"]}
      new_state = ToolRunner.check_for_steering(state)
      assert new_state.pending_steers == []
      [msg | _] = new_state.messages
      assert msg.role == :user
      assert msg.content == "Do something else"
    end
  end

  describe "cancel_all_tasks/1" do
    test "no-op when no pending tasks" do
      state = base_state()
      assert ToolRunner.cancel_all_tasks(state) == state
    end
  end

  describe "maybe_auto_load_skills/2" do
    test "no-op when no available skills" do
      state = base_state()
      assert ToolRunner.maybe_auto_load_skills([], state) == state
    end

    test "no-op when skills feature is disabled" do
      config = Opal.Config.new()
      features = %{config.features | skills: %{config.features.skills | enabled: false}}
      state = %{base_state() | config: %{config | features: features}}
      assert ToolRunner.maybe_auto_load_skills([], state) == state
    end
  end
end
