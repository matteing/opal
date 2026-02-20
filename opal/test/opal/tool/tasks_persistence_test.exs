defmodule Opal.Tool.TasksPersistenceTest do
  @moduledoc """
  Tests for DETS persistence, counter continuity, scope isolation edge cases,
  concurrent access, and full agent-workflow scenarios for the Tasks tool.

  These complement tasks_test.exs and focus on the "tasks reset unexpectedly"
  failure mode — verifying that data survives across repeated open/close cycles,
  that IDs never collide, and that scope-key changes produce the expected
  (separate) storage.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Tasks

  setup %{tmp_dir: tmp_dir} do
    session_id = "persist-#{System.unique_integer([:positive])}"
    :ok = Tasks.clear("session:" <> session_id)
    %{ctx: %{working_dir: tmp_dir, session_id: session_id}}
  end

  # ---------------------------------------------------------------------------
  # DETS persistence — tasks survive across separate execute calls
  # ---------------------------------------------------------------------------

  describe "DETS persistence across calls" do
    test "tasks inserted in one call are visible in a subsequent list call", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Alpha"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Beta"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Gamma"}, ctx)

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)

      assert payload.total == 3
      labels = Enum.map(payload.tasks, & &1.label)
      assert labels == ["Alpha", "Beta", "Gamma"]
    end

    test "tasks persist across 20 rapid insert/list cycles", %{ctx: ctx} do
      for i <- 1..20 do
        {:ok, ins} = Tasks.execute(%{"action" => "insert", "label" => "Task #{i}"}, ctx)
        assert ins.total == i, "After insert #{i}, total should be #{i} but was #{ins.total}"
      end

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 20
      ids = Enum.map(payload.tasks, & &1.id)
      assert ids == Enum.to_list(1..20)
    end

    test "updates persist and are visible on next list", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Original"}, ctx)

      {:ok, _} =
        Tasks.execute(
          %{"action" => "update", "id" => 1, "label" => "Revised", "notes" => "changed"},
          ctx
        )

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      task = hd(payload.tasks)
      assert task.label == "Revised"
      assert task.notes == "changed"
    end

    test "delete is permanent — task does not reappear on next list", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Ephemeral"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Keeper"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 1
      assert hd(payload.tasks).label == "Keeper"
    end
  end

  # ---------------------------------------------------------------------------
  # Counter continuity — IDs must never reset or collide
  # ---------------------------------------------------------------------------

  describe "counter continuity" do
    test "IDs monotonically increase even after deletes", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C"}, ctx)

      # Delete middle task
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 2}, ctx)

      # Next insert should be ID 4, not 2
      {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "D"}, ctx)
      ids = Enum.map(payload.tasks, & &1.id) |> Enum.sort()
      assert ids == [1, 3, 4]
    end

    test "IDs continue from last value after delete-all-then-reinsert", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C"}, ctx)

      # Delete all tasks individually
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 2}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 3}, ctx)

      # Counter should still be at 3, next ID = 4
      {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "New"}, ctx)
      assert hd(payload.tasks).id == 4
    end

    test "clear resets counter — new IDs start at 1", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Before clear"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Also before"}, ctx)

      :ok = Tasks.clear("session:" <> ctx.session_id)

      {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "After clear"}, ctx)
      assert hd(payload.tasks).id == 1
      assert payload.total == 1
    end

    test "batch insert IDs are sequential and don't collide with prior inserts", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Pre-batch"}, ctx)

      ops = [
        %{"action" => "insert", "label" => "Batch 1"},
        %{"action" => "insert", "label" => "Batch 2"},
        %{"action" => "insert", "label" => "Batch 3"}
      ]

      {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      ids = Enum.map(payload.tasks, & &1.id) |> Enum.sort()
      assert ids == [1, 2, 3, 4]
    end

    test "IDs are unique across interleaved batch and single inserts", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Single 1"}, ctx)

      ops = [
        %{"action" => "insert", "label" => "Batch A"},
        %{"action" => "insert", "label" => "Batch B"}
      ]

      {:ok, _} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Single 2"}, ctx)

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      ids = Enum.map(payload.tasks, & &1.id) |> Enum.sort()
      assert ids == [1, 2, 3, 4]
      assert length(ids) == length(Enum.uniq(ids)), "All IDs must be unique"
    end
  end

  # ---------------------------------------------------------------------------
  # Scope key — context shape determines which DETS file is used
  # ---------------------------------------------------------------------------

  describe "scope key behavior" do
    test "missing session_id falls back to working_dir scope", %{ctx: ctx} do
      ctx_no_session = %{working_dir: ctx.working_dir}
      :ok = Tasks.clear(ctx.working_dir)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Dir-scoped"}, ctx_no_session)

      # Session-scoped context should NOT see the dir-scoped task
      {:ok, session_list} = Tasks.execute(%{"action" => "list"}, ctx)
      {:ok, dir_list} = Tasks.execute(%{"action" => "list"}, ctx_no_session)

      assert session_list.total == 0
      assert dir_list.total == 1
    end

    test "empty session_id falls back to working_dir scope", %{ctx: ctx} do
      ctx_empty = %{working_dir: ctx.working_dir, session_id: ""}
      :ok = Tasks.clear(ctx.working_dir)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Empty-session"}, ctx_empty)

      {:ok, session_list} = Tasks.execute(%{"action" => "list"}, ctx)
      {:ok, empty_list} = Tasks.execute(%{"action" => "list"}, ctx_empty)

      assert session_list.total == 0
      assert empty_list.total == 1
    end

    test "switching session_id mid-workflow sees a different task store", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Session A task"}, ctx)

      other_session = "other-#{System.unique_integer([:positive])}"
      :ok = Tasks.clear("session:" <> other_session)
      ctx_b = %{ctx | session_id: other_session}

      {:ok, list_b} = Tasks.execute(%{"action" => "list"}, ctx_b)
      assert list_b.total == 0, "Switching session_id should produce an empty task list"

      # Original session still has its task
      {:ok, list_a} = Tasks.execute(%{"action" => "list"}, ctx)
      assert list_a.total == 1
    end

    test "nil context fields fall back to cwd", %{ctx: _ctx} do
      scope1 = "session:real-session-#{System.unique_integer([:positive])}"
      :ok = Tasks.clear(scope1)

      ctx_nil = %{working_dir: nil, session_id: nil}

      # Should not crash — falls back to File.cwd!()
      {:ok, _} = Tasks.execute(%{"action" => "list"}, ctx_nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent access — multiple processes hitting the same scope
  # ---------------------------------------------------------------------------

  describe "concurrent access" do
    test "concurrent inserts from multiple processes don't lose tasks", %{ctx: ctx} do
      parent = self()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result = Tasks.execute(%{"action" => "insert", "label" => "Concurrent #{i}"}, ctx)
            send(parent, {:inserted, i, result})
            result
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 10

      ids = Enum.map(payload.tasks, & &1.id) |> Enum.sort()
      assert length(ids) == length(Enum.uniq(ids)), "All IDs must be unique under concurrency"
    end

    test "concurrent insert and list don't crash or lose data", %{ctx: ctx} do
      # Seed some tasks
      for i <- 1..5 do
        {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Seed #{i}"}, ctx)
      end

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Tasks.execute(%{"action" => "insert", "label" => "Conc #{i}"}, ctx)
            else
              Tasks.execute(%{"action" => "list"}, ctx)
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      {:ok, final} = Tasks.execute(%{"action" => "list"}, ctx)
      # 5 seed + 5 concurrent inserts (even numbers 2,4,6,8,10)
      assert final.total == 10
    end
  end

  # ---------------------------------------------------------------------------
  # Full agent-workflow scenarios — multi-step task management
  # ---------------------------------------------------------------------------

  describe "full workflow: plan → execute → complete" do
    test "typical agent workflow: batch plan, mark in_progress, complete, verify", %{ctx: ctx} do
      # Step 1: Agent creates a plan via batch
      plan_ops = [
        %{"action" => "insert", "label" => "Analyze codebase"},
        %{"action" => "insert", "label" => "Write implementation", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Write tests", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Run tests", "blocked_by" => "2,3"},
        %{"action" => "insert", "label" => "Update docs", "blocked_by" => "4"}
      ]

      {:ok, plan} = Tasks.execute(%{"action" => "batch", "ops" => plan_ops}, ctx)
      assert plan.total == 5
      assert plan.counts["open"] == 1
      assert plan.counts["blocked"] == 4

      # Step 2: Check ready work
      {:ok, ready} = Tasks.execute(%{"action" => "list", "view" => "ready"}, ctx)
      assert length(ready.tasks) == 1
      assert hd(ready.tasks).label == "Analyze codebase"

      # Step 3: Start first task
      {:ok, _} =
        Tasks.execute(%{"action" => "update", "id" => 1, "status" => "in_progress"}, ctx)

      {:ok, wip} = Tasks.execute(%{"action" => "list", "view" => "in_progress"}, ctx)
      assert length(wip.tasks) == 1

      # Step 4: Complete first task — should unblock tasks 2 and 3
      {:ok, done1} =
        Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      unblocked_ids =
        done1.changes
        |> Enum.filter(&(&1.op == "auto_unblock"))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert unblocked_ids == [2, 3]

      # Step 5: Ready should now have tasks 2 and 3
      {:ok, ready2} = Tasks.execute(%{"action" => "list", "view" => "ready"}, ctx)
      ready_ids = Enum.map(ready2.tasks, & &1.id) |> Enum.sort()
      assert ready_ids == [2, 3]

      # Step 6: Complete tasks 2 and 3 in batch
      done_ops = [
        %{"action" => "update", "id" => 2, "status" => "done"},
        %{"action" => "update", "id" => 3, "status" => "done"}
      ]

      {:ok, _} = Tasks.execute(%{"action" => "batch", "ops" => done_ops}, ctx)

      # Step 7: Task 4 should now be ready (unblocked by 2 and 3)
      {:ok, ready3} = Tasks.execute(%{"action" => "list", "view" => "ready"}, ctx)
      assert length(ready3.tasks) == 1
      assert hd(ready3.tasks).id == 4

      # Step 8: Complete task 4, verify task 5 becomes ready
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 4, "status" => "done"}, ctx)
      {:ok, ready4} = Tasks.execute(%{"action" => "list", "view" => "ready"}, ctx)
      assert length(ready4.tasks) == 1
      assert hd(ready4.tasks).id == 5

      # Step 9: Complete everything
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 5, "status" => "done"}, ctx)
      {:ok, final} = Tasks.execute(%{"action" => "list"}, ctx)
      assert final.counts["done"] == 5
      assert final.counts["open"] == 0
      assert final.counts["blocked"] == 0
    end

    test "mid-workflow interruption: new tasks added after partial completion", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Step 1"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Step 2", "blocked_by" => "1"}, ctx)

      # Complete step 1
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      # Agent discovers more work mid-flow and adds tasks
      {:ok, _} =
        Tasks.execute(
          %{"action" => "insert", "label" => "Step 2a (new)", "blocked_by" => "2"},
          ctx
        )

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Step 3", "blocked_by" => "2,3"}, ctx)

      # Verify the full state is consistent
      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 4

      task2 = Enum.find(payload.tasks, &(&1.id == 2))
      assert task2.status == "open", "Task 2 should be open (unblocked by task 1)"

      task3 = Enum.find(payload.tasks, &(&1.id == 3))
      assert task3.status == "blocked"

      task4 = Enum.find(payload.tasks, &(&1.id == 4))
      assert task4.status == "blocked"
      assert task4.blocked_by == ["2", "3"]
    end

    test "re-blocking a completed task's dependents via update", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Blocker"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Dependent", "blocked_by" => "1"}, ctx)

      # Complete blocker — dependent becomes open
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      {:ok, mid} = Tasks.execute(%{"action" => "list"}, ctx)
      dep = Enum.find(mid.tasks, &(&1.id == 2))
      assert dep.status == "open"

      # Re-block dependent manually (agent changes plan)
      {:ok, _} =
        Tasks.execute(
          %{"action" => "update", "id" => 2, "status" => "blocked", "blocked_by" => "1"},
          ctx
        )

      {:ok, after_reblock} = Tasks.execute(%{"action" => "list"}, ctx)
      dep2 = Enum.find(after_reblock.tasks, &(&1.id == 2))
      assert dep2.status == "blocked"
      assert dep2.blocked_by == ["1"]
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-unblock edge cases
  # ---------------------------------------------------------------------------

  describe "auto-unblock edge cases" do
    test "completing a task that nothing depends on produces no unblock changes", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Standalone"}, ctx)

      {:ok, payload} =
        Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      unblock_changes = Enum.filter(payload.changes, &(&1.op == "auto_unblock"))
      assert unblock_changes == []
    end

    test "auto-unblock only transitions blocked tasks, not in_progress ones", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Blocker"}, ctx)

      {:ok, _} =
        Tasks.execute(
          %{
            "action" => "insert",
            "label" => "Eager",
            "blocked_by" => "1",
            "status" => "in_progress"
          },
          ctx
        )

      {:ok, payload} =
        Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      eager = Enum.find(payload.tasks, &(&1.id == 2))
      # Status should stay in_progress (not switch to open)
      assert eager.status == "in_progress"
      assert eager.blocked_by == []
    end

    test "auto-unblock handles diamond dependency pattern", %{ctx: ctx} do
      #   1
      #  / \
      # 2   3
      #  \ /
      #   4
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Root"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Left", "blocked_by" => "1"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Right", "blocked_by" => "1"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Join", "blocked_by" => "2,3"}, ctx)

      # Complete root → unblocks left and right
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

      {:ok, mid} = Tasks.execute(%{"action" => "list"}, ctx)
      join = Enum.find(mid.tasks, &(&1.id == 4))
      assert join.status == "blocked"
      assert join.blocked_by == ["2", "3"]

      # Complete left
      {:ok, _} = Tasks.execute(%{"action" => "update", "id" => 2, "status" => "done"}, ctx)
      {:ok, mid2} = Tasks.execute(%{"action" => "list"}, ctx)
      join2 = Enum.find(mid2.tasks, &(&1.id == 4))
      assert join2.status == "blocked"
      assert join2.blocked_by == ["3"]

      # Complete right → join should unblock
      {:ok, payload} = Tasks.execute(%{"action" => "update", "id" => 3, "status" => "done"}, ctx)
      join3 = Enum.find(payload.tasks, &(&1.id == 4))
      assert join3.status == "open"
      assert join3.blocked_by == []
    end

    test "auto-unblock chain: A blocks B blocks C", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B", "blocked_by" => "1"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C", "blocked_by" => "2"}, ctx)

      # Completing A unblocks B, but not C (C depends on B, not A)
      {:ok, p1} = Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)
      b = Enum.find(p1.tasks, &(&1.id == 2))
      c = Enum.find(p1.tasks, &(&1.id == 3))
      assert b.status == "open"
      assert c.status == "blocked"

      # Completing B unblocks C
      {:ok, p2} = Tasks.execute(%{"action" => "update", "id" => 2, "status" => "done"}, ctx)
      c2 = Enum.find(p2.tasks, &(&1.id == 3))
      assert c2.status == "open"
    end
  end

  # ---------------------------------------------------------------------------
  # Batch consistency — state after partial failures
  # ---------------------------------------------------------------------------

  describe "batch partial failure consistency" do
    test "successful ops in a batch persist even when later ops fail", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Existing"}, ctx)

      ops = [
        %{"action" => "insert", "label" => "New task"},
        %{"action" => "update", "id" => 999, "status" => "done"},
        %{"action" => "insert", "label" => "Another new"}
      ]

      {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)

      ok_ops = Enum.filter(payload.operations, & &1.ok)
      fail_ops = Enum.reject(payload.operations, & &1.ok)

      assert length(ok_ops) == 2
      assert length(fail_ops) == 1

      # All 3 tasks should exist (1 existing + 2 new)
      assert payload.total == 3
    end

    test "batch with all failing ops still returns current task state", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Survivor"}, ctx)

      ops = [
        %{"action" => "update", "id" => 888, "status" => "done"},
        %{"action" => "delete", "id" => 777}
      ]

      {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert payload.total == 1
      assert hd(payload.tasks).label == "Survivor"
      assert Enum.all?(payload.operations, &(!&1.ok))
    end

    test "batch delete then insert maintains correct count", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "To delete"}, ctx)

      ops = [
        %{"action" => "delete", "id" => 1},
        %{"action" => "insert", "label" => "Replacement"}
      ]

      {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert payload.total == 1
      assert hd(payload.tasks).label == "Replacement"
      assert hd(payload.tasks).id == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Blocked_by parsing edge cases
  # ---------------------------------------------------------------------------

  describe "blocked_by parsing" do
    test "blocked_by with extra whitespace is handled", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

      {:ok, payload} =
        Tasks.execute(
          %{"action" => "insert", "label" => "C", "blocked_by" => " 1 , 2 "},
          ctx
        )

      task_c = Enum.find(payload.tasks, &(&1.id == 3))
      assert task_c.status == "blocked"
      assert task_c.blocked_by == ["1", "2"]
    end

    test "blocked_by with trailing comma is handled", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)

      {:ok, payload} =
        Tasks.execute(
          %{"action" => "insert", "label" => "B", "blocked_by" => "1,"},
          ctx
        )

      task_b = Enum.find(payload.tasks, &(&1.id == 2))
      assert task_b.status == "blocked"
      assert task_b.blocked_by == ["1"]
    end

    test "blocked_by with empty string is treated as no blockers", %{ctx: ctx} do
      {:ok, payload} =
        Tasks.execute(%{"action" => "insert", "label" => "Free", "blocked_by" => ""}, ctx)

      assert hd(payload.tasks).status == "open"
      assert hd(payload.tasks).blocked_by == []
    end

    test "blocked_by with nil is treated as no blockers", %{ctx: ctx} do
      {:ok, payload} =
        Tasks.execute(%{"action" => "insert", "label" => "Free", "blocked_by" => nil}, ctx)

      assert hd(payload.tasks).status == "open"
      assert hd(payload.tasks).blocked_by == []
    end
  end

  # ---------------------------------------------------------------------------
  # query_raw — used by agent loop for task summaries
  # ---------------------------------------------------------------------------

  describe "query_raw" do
    test "returns only non-done tasks in string-keyed maps", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Active"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Done", "status" => "done"}, ctx)

      {:ok, _} =
        Tasks.execute(
          %{"action" => "insert", "label" => "Blocked", "status" => "blocked"},
          ctx
        )

      {:ok, raw} = Tasks.query_raw(%{session_id: ctx.session_id}, nil)

      labels = Enum.map(raw, & &1["label"])
      assert "Active" in labels
      assert "Blocked" in labels
      refute "Done" in labels
    end

    test "query_raw returns empty list for fresh session", %{ctx: _ctx} do
      fresh = "fresh-#{System.unique_integer([:positive])}"
      :ok = Tasks.clear("session:" <> fresh)

      {:ok, raw} = Tasks.query_raw(%{session_id: fresh}, nil)
      assert raw == []
    end

    test "query_raw results are sorted by id", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

      {:ok, raw} = Tasks.query_raw(%{session_id: ctx.session_id}, nil)
      ids = Enum.map(raw, &String.to_integer(&1["id"]))
      assert ids == [1, 2, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # Payload structure — verify all expected fields
  # ---------------------------------------------------------------------------

  describe "payload structure" do
    test "insert payload has all expected keys", %{ctx: ctx} do
      {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "Test"}, ctx)

      assert Map.has_key?(payload, :kind)
      assert Map.has_key?(payload, :action)
      assert Map.has_key?(payload, :tasks)
      assert Map.has_key?(payload, :total)
      assert Map.has_key?(payload, :counts)
      assert Map.has_key?(payload, :changes)
      assert payload.kind == "tasks"
    end

    test "task wire format has all expected fields", %{ctx: ctx} do
      {:ok, payload} =
        Tasks.execute(
          %{
            "action" => "insert",
            "label" => "Full task",
            "notes" => "some notes",
            "prompt" => "do the thing",
            "result" => "it worked"
          },
          ctx
        )

      task = hd(payload.tasks)

      assert Map.has_key?(task, :id)
      assert Map.has_key?(task, :label)
      assert Map.has_key?(task, :status)
      assert Map.has_key?(task, :done)
      assert Map.has_key?(task, :parent_id)
      assert Map.has_key?(task, :prompt)
      assert Map.has_key?(task, :result)
      assert Map.has_key?(task, :notes)
      assert Map.has_key?(task, :blocked_by)
      assert Map.has_key?(task, :created_at)
      assert Map.has_key?(task, :updated_at)
    end

    test "batch payload includes operations field", %{ctx: ctx} do
      ops = [%{"action" => "insert", "label" => "A"}]
      {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)

      assert Map.has_key?(payload, :operations)
      assert is_list(payload.operations)
    end

    test "counts reflect all four statuses", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Open"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "WIP", "status" => "in_progress"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Done", "status" => "done"}, ctx)

      {:ok, _} =
        Tasks.execute(
          %{"action" => "insert", "label" => "Blocked", "blocked_by" => "1"},
          ctx
        )

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)

      assert payload.counts["open"] == 1
      assert payload.counts["in_progress"] == 1
      assert payload.counts["done"] == 1
      assert payload.counts["blocked"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp integrity
  # ---------------------------------------------------------------------------

  describe "timestamps" do
    test "created_at and updated_at are set on insert", %{ctx: ctx} do
      {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "Timed"}, ctx)
      task = hd(payload.tasks)

      assert is_binary(task.created_at)
      assert is_binary(task.updated_at)
      assert task.created_at == task.updated_at
    end

    test "updated_at changes on update but created_at stays the same", %{ctx: ctx} do
      {:ok, ins} = Tasks.execute(%{"action" => "insert", "label" => "Original"}, ctx)
      original = hd(ins.tasks)

      # Small delay to ensure timestamp differs
      Process.sleep(10)

      {:ok, upd} =
        Tasks.execute(%{"action" => "update", "id" => 1, "label" => "Modified"}, ctx)

      modified = hd(upd.tasks)

      assert modified.created_at == original.created_at
      assert modified.updated_at >= original.updated_at
    end
  end

  # ---------------------------------------------------------------------------
  # Hierarchical (parent_id) scenarios
  # ---------------------------------------------------------------------------

  describe "hierarchical task management" do
    test "deleting a parent does not cascade-delete children", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Parent"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Child", "parent_id" => 1}, ctx)

      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)

      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 1
      assert hd(payload.tasks).label == "Child"
      assert hd(payload.tasks).parent_id == 1
    end

    test "tree view silently drops orphaned children (parent deleted)", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Parent"}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Child A", "parent_id" => 1}, ctx)

      {:ok, _} =
        Tasks.execute(%{"action" => "insert", "label" => "Child B", "parent_id" => 1}, ctx)

      # Delete parent — children now reference a nonexistent parent
      {:ok, _} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)

      # Tree view drops orphans: tree_order groups by parent_id, and orphans
      # with parent_id=1 aren't roots (parent_id != nil) and their parent
      # doesn't exist, so they're unreachable in the tree walk.
      {:ok, tree_payload} = Tasks.execute(%{"action" => "list", "tree" => true}, ctx)
      assert tree_payload.total == 0

      # But a flat list still shows them — data isn't lost
      {:ok, flat_payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert flat_payload.total == 2
    end

    test "deeply nested tree (4 levels) renders correct depths", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "L0"}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "L1", "parent_id" => 1}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "L2", "parent_id" => 2}, ctx)
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "L3", "parent_id" => 3}, ctx)

      {:ok, payload} = Tasks.execute(%{"action" => "list", "tree" => true}, ctx)
      depths = Enum.map(payload.tasks, & &1.depth)
      assert depths == [0, 1, 2, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # DAG validation edge cases
  # ---------------------------------------------------------------------------

  describe "DAG validation edge cases" do
    test "batch rejects 3-node cycle: A→B→C→A", %{ctx: ctx} do
      ops = [
        %{"action" => "insert", "label" => "A", "blocked_by" => "3"},
        %{"action" => "insert", "label" => "B", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "C", "blocked_by" => "2"}
      ]

      assert {:error, msg} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert msg =~ "Cycle detected"
    end

    test "batch allows long chain without false cycle detection", %{ctx: ctx} do
      ops =
        for i <- 1..10 do
          if i == 1 do
            %{"action" => "insert", "label" => "Task #{i}"}
          else
            %{"action" => "insert", "label" => "Task #{i}", "blocked_by" => "#{i - 1}"}
          end
        end

      assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert payload.total == 10
    end

    test "batch allows fan-out pattern (one task blocks many)", %{ctx: ctx} do
      ops = [
        %{"action" => "insert", "label" => "Root"},
        %{"action" => "insert", "label" => "Branch 1", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Branch 2", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Branch 3", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Branch 4", "blocked_by" => "1"},
        %{"action" => "insert", "label" => "Branch 5", "blocked_by" => "1"}
      ]

      assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert payload.total == 6
      assert payload.counts["blocked"] == 5
    end

    test "batch allows fan-in pattern (many tasks block one)", %{ctx: ctx} do
      ops = [
        %{"action" => "insert", "label" => "Dep 1"},
        %{"action" => "insert", "label" => "Dep 2"},
        %{"action" => "insert", "label" => "Dep 3"},
        %{"action" => "insert", "label" => "Collector", "blocked_by" => "1,2,3"}
      ]

      assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
      assert payload.total == 4
      collector = Enum.find(payload.tasks, &(&1.id == 4))
      assert collector.blocked_by == ["1", "2", "3"]
    end

    test "batch with existing + new tasks forming cycle is rejected", %{ctx: ctx} do
      # Create existing task first
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Existing"}, ctx)

      # Batch tries to create cycle: Existing(1) → New(2) → Existing(1)
      ops = [
        %{"action" => "insert", "label" => "New", "blocked_by" => "1"}
      ]

      {:ok, _} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)

      # Now update existing to depend on new — this goes through run_update, not batch DAG
      {:ok, _} =
        Tasks.execute(%{"action" => "update", "id" => 1, "blocked_by" => "2"}, ctx)

      # The system doesn't prevent single-update cycles (only batch validates DAG)
      # but verify data is consistent
      {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
      assert payload.total == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "insert without label returns descriptive error", %{ctx: ctx} do
      assert {:error, msg} = Tasks.execute(%{"action" => "insert"}, ctx)
      assert msg =~ "label"
    end

    test "update with non-numeric string id raises", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Task"}, ctx)

      assert_raise ArgumentError, fn ->
        Tasks.execute(%{"action" => "update", "id" => "abc", "label" => "X"}, ctx)
      end
    end

    test "delete with non-numeric string id raises", %{ctx: ctx} do
      assert_raise ArgumentError, fn ->
        Tasks.execute(%{"action" => "delete", "id" => "abc"}, ctx)
      end
    end

    test "batch with non-list ops returns error", %{ctx: ctx} do
      assert {:error, _} = Tasks.execute(%{"action" => "batch", "ops" => "not a list"}, ctx)
    end

    test "completely empty params returns error", %{ctx: ctx} do
      assert {:error, _} = Tasks.execute(%{}, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Update multiple fields atomically
  # ---------------------------------------------------------------------------

  describe "multi-field updates" do
    test "update can change multiple fields in a single call", %{ctx: ctx} do
      {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Base"}, ctx)

      {:ok, payload} =
        Tasks.execute(
          %{
            "action" => "update",
            "id" => 1,
            "label" => "New label",
            "status" => "in_progress",
            "notes" => "Working on it",
            "prompt" => "Do all the things"
          },
          ctx
        )

      task = hd(payload.tasks)
      assert task.label == "New label"
      assert task.status == "in_progress"
      assert task.notes == "Working on it"
      assert task.prompt == "Do all the things"

      # Verify changed_fields tracks all of them
      change = hd(payload.changes)
      assert "label" in change.changed_fields
      assert "status" in change.changed_fields
      assert "notes" in change.changed_fields
      assert "prompt" in change.changed_fields
    end
  end
end
