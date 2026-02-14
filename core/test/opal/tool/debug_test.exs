defmodule Opal.Tool.DebugTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.{EventLog, State}
  alias Opal.Tool.Debug

  describe "execute/2" do
    test "returns error without agent_state" do
      assert {:error, "Missing agent_state in context"} = Debug.execute(%{}, %{})
    end

    test "returns snapshot with recent events and messages when debug is enabled" do
      session_id = "debug_test_#{System.unique_integer([:positive])}"

      state =
        %State{
          session_id: session_id,
          model: Opal.Model.coerce({:copilot, "claude-sonnet-4"}),
          working_dir: File.cwd!(),
          config: Opal.Config.new(%{features: %{debug: %{enabled: true}}}),
          tools: [Opal.Tool.Read, Opal.Tool.Debug],
          messages: [Opal.Message.user("hello from debug test")]
        }

      EventLog.clear(session_id)
      EventLog.broadcast(state, {:status_update, "inspecting"})

      assert {:ok, output} =
               Debug.execute(
                 %{"event_limit" => 10, "include_messages" => true, "message_limit" => 5},
                 %{agent_state: state}
               )

      payload = Jason.decode!(output)

      assert payload["session_id"] == session_id
      assert payload["messages"]["count"] == 1
      assert Enum.any?(payload["recent_events"], &(&1["type"] == "status_update"))

      EventLog.clear(session_id)
    end
  end

  describe "event logging" do
    test "does not retain events when debug is disabled" do
      session_id = "debug_test_#{System.unique_integer([:positive])}"

      state =
        %State{
          session_id: session_id,
          model: Opal.Model.coerce({:copilot, "claude-sonnet-4"}),
          working_dir: File.cwd!(),
          config: Opal.Config.new(%{features: %{debug: %{enabled: false}}})
        }

      EventLog.clear(session_id)
      EventLog.broadcast(state, {:status_update, "not logged"})

      assert EventLog.recent(session_id, 10) == []
    end
  end
end
