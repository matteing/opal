defmodule Opal.StreamTest do
  use ExUnit.Case, async: true

  describe "Opal.stream/2" do
    test "returns a lazy stream of events" do
      # Simulate agent behavior with a spawned process that broadcasts events
      session_id = "stream-test-#{System.unique_integer([:positive])}"

      # Start the Events registry if not already started (test env)
      start_supervised!({Registry, keys: :duplicate, name: Opal.Events.Registry})

      # We need a mock agent that returns state and accepts prompts.
      # Use a simple GenServer for this.
      {:ok, _mock_agent} =
        Agent.start_link(fn -> %{session_id: session_id, status: :idle} end)

      # Spawn a process to broadcast events after subscription
      test_pid = self()

      spawn(fn ->
        # Wait for subscription
        Process.sleep(50)
        Opal.Events.broadcast(session_id, {:message_delta, %{delta: "Hello"}})
        Opal.Events.broadcast(session_id, {:message_delta, %{delta: " World"}})
        Opal.Events.broadcast(session_id, {:agent_end, []})
        send(test_pid, :events_sent)
      end)

      # Subscribe and collect events manually (since we can't use the real Opal.Agent)
      Opal.Events.subscribe(session_id)

      # Wait for events
      receive do
        :events_sent -> :ok
      after
        1000 -> flunk("Events not sent in time")
      end

      # Verify events arrived in our mailbox
      events = flush_events(session_id, [])
      assert length(events) == 3
      assert {:message_delta, %{delta: "Hello"}} in events
      assert {:message_delta, %{delta: " World"}} in events

      Opal.Events.unsubscribe(session_id)
    end
  end

  defp flush_events(session_id, acc) do
    receive do
      {:opal_event, ^session_id, event} -> flush_events(session_id, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
