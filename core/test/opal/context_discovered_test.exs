defmodule Opal.ContextDiscoveredTest do
  use ExUnit.Case, async: true

  alias Opal.{Agent, Events}

  describe "context discovery events" do
    test "context_discovered event is emitted during agent startup" do
      # Create a temporary directory with context files
      test_dir = System.tmp_dir!()
      agents_file = Path.join(test_dir, "AGENTS.md")
      File.write!(agents_file, "# Test Context\nThis is test context.")

      session_id = "context-test-#{:rand.uniform(10000)}"
      
      # Subscribe to events before starting the agent
      Events.subscribe(session_id)

      # Start an agent in the test directory
      {:ok, _agent} = Agent.start_link([
        session_id: session_id,
        model: %Opal.Model{provider: :test, id: "test-model"},
        working_dir: test_dir,
        tools: [],
        tool_supervisor: nil,
        sub_agent_supervisor: nil,
        session: false
      ])

      # Wait for the context_discovered event
      assert_receive {:opal_event, ^session_id, {:context_discovered, files}}, 1000

      # Should contain the AGENTS.md file we created
      assert is_list(files)
      assert Enum.any?(files, &String.ends_with?(&1, "AGENTS.md"))

      # Clean up
      File.rm(agents_file)
    end

    test "no context_discovered event when no context files exist" do
      # Create a temporary directory without context files
      test_dir = System.tmp_dir!()

      session_id = "context-empty-test-#{:rand.uniform(10000)}"
      
      # Subscribe to events before starting the agent
      Events.subscribe(session_id)

      # Start an agent in the empty test directory
      {:ok, _agent} = Agent.start_link([
        session_id: session_id,
        model: %Opal.Model{provider: :test, id: "test-model"},
        working_dir: test_dir,
        tools: [],
        tool_supervisor: nil,
        sub_agent_supervisor: nil,
        session: false
      ])

      # Should not receive a context_discovered event (or it should be empty)
      receive do
        {:opal_event, ^session_id, {:context_discovered, []}} ->
          # Empty context is acceptable
          :ok
        {:opal_event, ^session_id, {:context_discovered, _files}} ->
          flunk("Should not have discovered context files in empty directory")
      after
        500 ->
          # No event is also acceptable
          :ok
      end
    end
  end
end