defmodule Opal.EventsTest do
  use ExUnit.Case, async: true

  alias Opal.Events

  # Generate a unique session ID per test to allow async isolation
  setup do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    %{session_id: session_id}
  end

  # Validates subscribe registers the calling process
  describe "subscribe/1" do
    test "registers the calling process for events", %{session_id: sid} do
      assert {:ok, _pid} = Events.subscribe(sid)
    end

    test "allows duplicate subscriptions (registry uses :duplicate keys)", %{session_id: sid} do
      {:ok, _} = Events.subscribe(sid)
      assert {:ok, _} = Events.subscribe(sid)
    end
  end

  # Validates broadcast delivers events to subscribers
  describe "broadcast/2" do
    test "sends events to subscribed process", %{session_id: sid} do
      Events.subscribe(sid)
      Events.broadcast(sid, {:token, "hello"})
      assert_receive {:opal_event, ^sid, {:token, "hello"}}
    end

    test "events arrive as {:opal_event, session_id, event} tuples", %{session_id: sid} do
      Events.subscribe(sid)
      Events.broadcast(sid, :some_event)
      assert_receive {:opal_event, ^sid, :some_event}
    end

    test "multiple subscribers receive the same event", %{session_id: sid} do
      parent = self()

      # Spawn two subscriber processes
      pids =
        for i <- 1..2 do
          spawn(fn ->
            Events.subscribe(sid)
            send(parent, {:subscribed, i})

            receive do
              {:opal_event, _, event} -> send(parent, {:received, i, event})
            end
          end)
        end

      # Wait for both to subscribe
      for i <- 1..2, do: assert_receive({:subscribed, ^i})

      # Broadcast and verify both received
      Events.broadcast(sid, :test_event)

      for i <- 1..2, do: assert_receive({:received, ^i, :test_event})

      # Clean up
      for pid <- pids, Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  # Validates session isolation
  describe "session isolation" do
    test "subscribing to different session_ids isolates events", %{session_id: sid} do
      other_sid = "other-#{sid}"
      Events.subscribe(sid)
      Events.broadcast(other_sid, :wrong_event)
      refute_receive {:opal_event, _, :wrong_event}, 50
    end
  end

  # Validates unsubscribe stops delivery
  describe "unsubscribe/1" do
    test "stops event delivery after unsubscribe", %{session_id: sid} do
      Events.subscribe(sid)
      Events.broadcast(sid, :before)
      assert_receive {:opal_event, ^sid, :before}

      Events.unsubscribe(sid)
      Events.broadcast(sid, :after)
      refute_receive {:opal_event, ^sid, :after}, 50
    end
  end

  # Validates wildcard subscription
  describe "subscribe_all/0" do
    test "receives events from any session" do
      Events.subscribe_all()
      sid1 = "all-test-1-#{System.unique_integer([:positive])}"
      sid2 = "all-test-2-#{System.unique_integer([:positive])}"

      Events.broadcast(sid1, :event_a)
      Events.broadcast(sid2, :event_b)

      assert_receive {:opal_event, ^sid1, :event_a}
      assert_receive {:opal_event, ^sid2, :event_b}

      Events.unsubscribe_all()
    end

    test "both targeted and wildcard subscribers receive the event", %{session_id: sid} do
      Events.subscribe(sid)
      Events.subscribe_all()

      Events.broadcast(sid, :dual)
      assert_receive {:opal_event, ^sid, :dual}
      assert_receive {:opal_event, ^sid, :dual}

      Events.unsubscribe(sid)
      Events.unsubscribe_all()
    end

    test "unsubscribe_all stops wildcard delivery" do
      Events.subscribe_all()
      sid = "all-unsub-#{System.unique_integer([:positive])}"

      Events.broadcast(sid, :before)
      assert_receive {:opal_event, ^sid, :before}

      Events.unsubscribe_all()
      Events.broadcast(sid, :after)
      refute_receive {:opal_event, _, :after}, 50
    end
  end

  # Validates automatic cleanup on process crash
  describe "process crash cleanup" do
    test "process crash automatically unsubscribes", %{session_id: sid} do
      parent = self()

      pid =
        spawn(fn ->
          Events.subscribe(sid)
          send(parent, :subscribed)

          receive do
            :block -> :ok
          end
        end)

      assert_receive :subscribed

      # Kill the subscriber process
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Give Registry time to clean up
      Process.sleep(50)

      # Broadcast should not crash and no one should receive
      Events.broadcast(sid, :after_crash)
      refute_receive {:opal_event, _, :after_crash}, 50
    end
  end
end
