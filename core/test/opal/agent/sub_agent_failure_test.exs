defmodule Opal.Agent.SubAgentFailureTest do
  @moduledoc """
  Tests sub-agent lifecycle failures: spawn failure, process crash,
  disabled feature, missing context.
  """
  use ExUnit.Case, async: true

  alias Opal.Tool.SubAgent

  describe "missing agent_state in context" do
    test "returns error when agent_state is nil" do
      result = SubAgent.execute(%{"prompt" => "test"}, %{})
      assert result == {:error, "sub_agent tool requires agent_state in context"}
    end
  end

  describe "sub-agents disabled" do
    test "returns error when feature is disabled" do
      config = %Opal.Config{
        Opal.Config.new()
        | features: %Opal.Config.Features{
            Opal.Config.Features.new()
            | sub_agents: %{enabled: false}
          }
      }

      context = %{
        agent_state: %Opal.Agent.State{
          session_id: "test",
          model: Opal.Model.new(:test, "test"),
          working_dir: "/tmp",
          config: config
        },
        config: config
      }

      result = SubAgent.execute(%{"prompt" => "test"}, context)
      assert result == {:error, "Sub-agents are disabled in configuration"}
    end
  end

  describe "sub-agent metadata" do
    test "meta truncates long prompts" do
      long = String.duplicate("x", 100)
      meta = SubAgent.meta(%{"prompt" => long})
      assert String.length(meta) < 80
      assert meta =~ "..."
    end

    test "meta with missing prompt returns fallback" do
      assert SubAgent.meta(%{}) == "Sub-agent"
    end

    test "meta with short prompt shows full text" do
      meta = SubAgent.meta(%{"prompt" => "hello"})
      assert meta == "Sub-agent: hello"
    end
  end

  describe "sub-agent spawn failure" do
    test "execute raises when spawn fails (rescued by ToolRunner)" do
      config = Opal.Config.new()

      state = %Opal.Agent.State{
        session_id: "sub-fail-#{System.unique_integer([:positive])}",
        model: Opal.Model.new(:test, "test"),
        working_dir: System.tmp_dir!(),
        config: config,
        tools: [],
        provider: Opal.Provider.Copilot,
        tool_supervisor: nil,
        sub_agent_supervisor: nil
      }

      context = %{
        agent_state: state,
        config: config,
        working_dir: System.tmp_dir!(),
        session_id: state.session_id
      }

      # SubAgent.execute calls DynamicSupervisor.start_child(nil, ...) which
      # raises an EXIT. In the real agent loop, ToolRunner.execute_single_tool
      # would rescue this. Here we verify the exit propagates.
      assert catch_exit(SubAgent.execute(%{"prompt" => "test task"}, context)) != nil
    end
  end
end
