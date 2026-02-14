defmodule Opal.Agent.CollectorTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Collector

  describe "collect_response/3" do
    test "accumulates message_delta events until agent_end" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"
      parent = self()

      spawn(fn ->
        Process.sleep(5)
        send(parent, {:opal_event, session_id, {:message_delta, %{delta: "Hello"}}})
        send(parent, {:opal_event, session_id, {:message_delta, %{delta: " world"}}})
        send(parent, {:opal_event, session_id, {:agent_end, []}})
      end)

      assert {:ok, "Hello world"} = Collector.collect_response(session_id)
    end

    test "handles agent_end with usage tuple" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"
      parent = self()

      spawn(fn ->
        Process.sleep(5)
        send(parent, {:opal_event, session_id, {:message_delta, %{delta: "result"}}})
        send(parent, {:opal_event, session_id, {:agent_end, [], %{tokens: 100}}})
      end)

      assert {:ok, "result"} = Collector.collect_response(session_id)
    end

    test "returns error on error event" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"
      parent = self()

      spawn(fn ->
        Process.sleep(5)
        send(parent, {:opal_event, session_id, {:error, :provider_failed}})
      end)

      assert {:error, :provider_failed} = Collector.collect_response(session_id)
    end

    test "returns timeout error when no events received" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"

      assert {:error, :timeout} = Collector.collect_response(session_id, "", 50)
    end

    test "skips non-delta events and continues collecting" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"
      parent = self()

      spawn(fn ->
        Process.sleep(5)
        send(parent, {:opal_event, session_id, {:status_update, "thinking"}})
        send(parent, {:opal_event, session_id, {:message_delta, %{delta: "answer"}}})
        send(parent, {:opal_event, session_id, {:tool_execution_start, "shell", %{}}})
        send(parent, {:opal_event, session_id, {:agent_end, []}})
      end)

      assert {:ok, "answer"} = Collector.collect_response(session_id)
    end

    test "returns empty string when agent_end before any deltas" do
      session_id = "collector-test-#{System.unique_integer([:positive])}"
      parent = self()

      spawn(fn ->
        Process.sleep(5)
        send(parent, {:opal_event, session_id, {:agent_end, []}})
      end)

      assert {:ok, ""} = Collector.collect_response(session_id)
    end
  end
end
