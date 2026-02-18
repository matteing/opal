defmodule Opal.InspectTest do
  use ExUnit.Case, async: true

  # Test the pure format_event/1 and to_preview/1 helpers via the module.
  # Since format_event/1 and to_preview/1 are private, we test them
  # indirectly through the public watch/0 flow, or we can use a wrapper
  # approach. Since the functions are private, we'll test through the
  # event subscription mechanism.

  # Instead: test format_event indirectly by spawning the watcher and
  # sending events. The IO output isn't easily capturable in tests,
  # so we exercise the code paths by calling watch() and sending events.

  describe "watch/0 processes events without crashing" do
    setup do
      # Subscribe so we can broadcast events
      session_id = "inspect-test-#{System.unique_integer([:positive])}"
      {:ok, pid} = Opal.Inspect.watch()
      # Give it a moment to subscribe
      Process.sleep(10)
      on_exit(fn -> Process.exit(pid, :normal) end)
      %{session_id: session_id, watcher: pid}
    end

    test "handles agent_start", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:agent_start}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles agent_abort", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:agent_abort}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles agent_end with messages", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:agent_end, []}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles agent_end with usage", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:agent_end, [], %{tokens: 100}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles usage_update", %{session_id: sid, watcher: pid} do
      usage = %{prompt_tokens: 100, total_tokens: 200, context_window: 128_000}

      send(pid, {:opal_event, sid, {:usage_update, usage}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles status_update", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:status_update, "thinking..."}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles message_start", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:message_start}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles message_delta", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:message_delta, %{delta: "Hello world"}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles thinking_start", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:thinking_start}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles thinking_delta", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:thinking_delta, %{delta: "reasoning..."}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_start with 3 args", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_start, "read_file", %{}, "meta"}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_start with 4 args", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_start, "shell", "call1", %{}, "meta"}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_start with 2 args", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_start, "shell", %{}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end ok with call_id", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_end, "read_file", "call1", {:ok, "content"}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end error with call_id", %{session_id: sid, watcher: pid} do
      send(
        pid,
        {:opal_event, sid, {:tool_execution_end, "shell", "call1", {:error, "failed"}}}
      )

      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end ok without call_id", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_end, "read_file", {:ok, "data"}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end error without call_id", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_end, "shell", {:error, "timeout"}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end with map output (the original crash case)", %{
      session_id: sid,
      watcher: pid
    } do
      # This was the original crash — tool output is a map, not a string
      map_output = %{kind: "tasks", action: "batch", total: 5, tasks: []}

      send(
        pid,
        {:opal_event, sid, {:tool_execution_end, "tasks", "call1", {:ok, map_output}}}
      )

      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles tool_execution_end with nil output", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:tool_execution_end, "tasks", "call1", {:ok, nil}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles sub_agent_event", %{session_id: sid, watcher: pid} do
      inner = {:message_delta, %{delta: "sub-agent output"}}

      send(
        pid,
        {:opal_event, sid, {:sub_agent_event, "call1", "sub-session-id-12345", inner}}
      )

      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles skill_loaded", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:skill_loaded, "git", "Git helper"}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles turn_end", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:turn_end, %{}, []}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles error", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:error, :some_reason}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles request_start", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:request_start, %{url: "https://api.example.com"}}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles request_end", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:request_end}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles agent_recovered", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:agent_recovered}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "handles unknown event types", %{session_id: sid, watcher: pid} do
      send(pid, {:opal_event, sid, {:something_new, "data"}})
      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "ignores non-event messages", %{watcher: pid} do
      send(pid, :random_message)
      Process.sleep(10)
      assert Process.alive?(pid)
    end
  end
end
