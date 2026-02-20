defmodule Opal.Tool.TasksTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Tasks

  setup %{tmp_dir: tmp_dir} do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    :ok = Tasks.clear("session:" <> session_id)
    %{ctx: %{working_dir: tmp_dir, session_id: session_id}}
  end

  # -- Insert ----------------------------------------------------------------

  test "insert returns structured payload with changes and done state", %{ctx: ctx} do
    assert {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "Draft plan"}, ctx)

    assert payload.kind == "tasks"
    assert payload.action == "insert"
    assert payload.total == 1
    assert payload.counts["open"] == 1
    assert payload.changes == [%{op: "insert", id: 1, label: "Draft plan"}]
    assert [%{id: 1, label: "Draft plan", status: "open", done: false}] = payload.tasks
  end

  test "insert with blocked_by auto-sets status to blocked", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "First"}, ctx)

    {:ok, payload} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Second", "blocked_by" => "1"},
        ctx
      )

    task = Enum.find(payload.tasks, &(&1.id == 2))
    assert task.status == "blocked"
  end

  test "insert respects explicit status even with blocked_by", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "First"}, ctx)

    {:ok, payload} =
      Tasks.execute(
        %{
          "action" => "insert",
          "label" => "Second",
          "blocked_by" => "1",
          "status" => "in_progress"
        },
        ctx
      )

    task = Enum.find(payload.tasks, &(&1.id == 2))
    assert task.status == "in_progress"
  end

  test "insert with parent_id, prompt, and result", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Parent"}, ctx)

    {:ok, payload} =
      Tasks.execute(
        %{
          "action" => "insert",
          "label" => "Child",
          "parent_id" => 1,
          "prompt" => "Do the thing",
          "result" => "Done"
        },
        ctx
      )

    task = Enum.find(payload.tasks, &(&1.id == 2))
    assert task.parent_id == 1
    assert task.prompt == "Do the thing"
    assert task.result == "Done"
  end

  test "insert with unknown parent_id returns error", %{ctx: ctx} do
    assert {:error, msg} =
             Tasks.execute(
               %{"action" => "insert", "label" => "Orphan", "parent_id" => 99},
               ctx
             )

    assert msg =~ "parent_id references unknown task #99"
  end

  test "insert with unknown blocked_by returns error", %{ctx: ctx} do
    assert {:error, msg} =
             Tasks.execute(
               %{"action" => "insert", "label" => "Bad ref", "blocked_by" => "42"},
               ctx
             )

    assert msg =~ "blocked_by references unknown task #42"
  end

  test "insert with empty label returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{"action" => "insert", "label" => ""}, ctx)
  end

  # -- Update ----------------------------------------------------------------

  test "update returns structured payload with changed fields", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Draft plan"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => 1, "label" => "Write tests"}, ctx)

    assert payload.action == "update"
    assert payload.total == 1
    assert [%{op: "update", id: 1, changed_fields: ["label"]}] = payload.changes
    assert [%{id: 1, label: "Write tests"}] = payload.tasks
  end

  test "update accepts string id", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "First"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => "1", "label" => "Updated"}, ctx)

    assert hd(payload.tasks).label == "Updated"
  end

  test "update nonexistent task returns error", %{ctx: ctx} do
    assert {:error, "Task #999 not found."} =
             Tasks.execute(%{"action" => "update", "id" => 999, "status" => "done"}, ctx)
  end

  test "update without id returns error", %{ctx: ctx} do
    assert {:error, "Update requires an 'id' field."} =
             Tasks.execute(%{"action" => "update", "status" => "done"}, ctx)
  end

  test "update with unknown blocked_by returns error", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Task"}, ctx)

    assert {:error, msg} =
             Tasks.execute(%{"action" => "update", "id" => 1, "blocked_by" => "99"}, ctx)

    assert msg =~ "blocked_by references unknown task #99"
  end

  # -- Auto-unblock ----------------------------------------------------------

  test "marking task done auto-unblocks dependents", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Blocker"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Blocked", "blocked_by" => "1"},
        ctx
      )

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

    blocked_task = Enum.find(payload.tasks, &(&1.id == 2))
    assert blocked_task.status == "open"
    assert blocked_task.blocked_by == []

    unblock_change = Enum.find(payload.changes, &(&1.op == "auto_unblock"))
    assert unblock_change.id == 2
  end

  test "auto-unblock removes only completed id from multi-blocker list", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "C", "blocked_by" => "1,2"},
        ctx
      )

    {:ok, payload} =
      Tasks.execute(%{"action" => "update", "id" => 1, "status" => "done"}, ctx)

    task_c = Enum.find(payload.tasks, &(&1.id == 3))
    assert task_c.status == "blocked"
    assert task_c.blocked_by == ["2"]
  end

  test "auto-unblock cascades through batch updates", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "C", "blocked_by" => "1,2"},
        ctx
      )

    ops = [
      %{"action" => "update", "id" => 1, "status" => "done"},
      %{"action" => "update", "id" => 2, "status" => "done"}
    ]

    {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)

    task_c = Enum.find(payload.tasks, &(&1.id == 3))
    assert task_c.status == "open"
    assert task_c.blocked_by == []
  end

  # -- Delete ----------------------------------------------------------------

  test "delete returns empty snapshot with delete change", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Old task"}, ctx)

    assert {:ok, payload} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)

    assert payload.action == "delete"
    assert payload.total == 0
    assert payload.tasks == []
    assert payload.changes == [%{op: "delete", id: 1, label: "Old task"}]
  end

  test "delete nonexistent task returns error", %{ctx: ctx} do
    assert {:error, "Task #999 not found."} =
             Tasks.execute(%{"action" => "delete", "id" => 999}, ctx)
  end

  test "delete without id returns error", %{ctx: ctx} do
    assert {:error, "Delete requires an 'id' field."} =
             Tasks.execute(%{"action" => "delete"}, ctx)
  end

  # -- List & Views ----------------------------------------------------------

  test "list includes done boolean for completed tasks", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Ship", "status" => "done"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)

    assert [%{label: "Ship", status: "done", done: true}] = payload.tasks
    assert payload.counts["done"] == 1
  end

  test "list with view=open only returns open tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Open task"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Done", "status" => "done"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "open"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "Open task"
  end

  test "list with view=done only returns done tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Open"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Done", "status" => "done"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "done"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "Done"
  end

  test "list with view=blocked returns blocked tasks", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Blocked", "status" => "blocked"}, ctx)

    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Open"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "blocked"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "Blocked"
  end

  test "list with view=in_progress returns in_progress tasks", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Working", "status" => "in_progress"},
        ctx
      )

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "in_progress"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "Working"
  end

  test "list with view=ready returns open tasks with no blockers", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Ready task"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Blocked task", "blocked_by" => "1"},
        ctx
      )

    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Also ready"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "ready"}, ctx)
    labels = Enum.map(payload.tasks, & &1.label)
    assert "Ready task" in labels
    assert "Also ready" in labels
    refute "Blocked task" in labels
  end

  test "list with unknown view returns all tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Task1"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "nonexistent"}, ctx)
    assert length(payload.tasks) == 1
  end

  test "list with status filter", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A", "status" => "open"}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "B", "status" => "in_progress"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "status" => "in_progress"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "B"
  end

  # -- Tree rendering --------------------------------------------------------

  test "list with tree=true orders by parent hierarchy with depth", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Root A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Root B"}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Child A1", "parent_id" => 1}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Child A2", "parent_id" => 1}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Grandchild", "parent_id" => 3}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "tree" => true}, ctx)

    labels = Enum.map(payload.tasks, & &1.label)
    depths = Enum.map(payload.tasks, & &1.depth)

    assert labels == ["Root A", "Child A1", "Grandchild", "Child A2", "Root B"]
    assert depths == [0, 1, 2, 1, 0]
  end

  test "list without tree=true does not include depth", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Task"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)
    refute Map.has_key?(hd(payload.tasks), :depth)
  end

  # -- Batch -----------------------------------------------------------------

  test "batch executes multiple operations and returns structured result", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Task A"},
      %{"action" => "insert", "label" => "Task B"},
      %{"action" => "insert", "label" => "Task C"}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert payload.action == "batch"
    assert payload.total == 3
    assert length(payload.tasks) == 3
    assert length(payload.operations) == 3
    assert Enum.all?(payload.operations, & &1.ok)
  end

  test "batch with update operations", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Existing"}, ctx)

    ops = [
      %{"action" => "update", "id" => 1, "status" => "done"},
      %{"action" => "insert", "label" => "New task"}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert payload.total == 2
    assert length(payload.operations) == 2
    done_task = Enum.find(payload.tasks, &(&1.id == 1))
    assert done_task.status == "done"
    assert done_task.done == true
  end

  test "batch returns error for missing ops", %{ctx: ctx} do
    assert {:error, "Batch requires an 'ops' array."} =
             Tasks.execute(%{"action" => "batch"}, ctx)
  end

  test "batch handles errors within individual ops", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Good task"},
      %{"action" => "update", "id" => 999, "status" => "done"}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert length(payload.operations) == 2
    assert Enum.at(payload.operations, 0).ok == true
    assert Enum.at(payload.operations, 1).ok == false
  end

  # -- DAG Validation -------------------------------------------------------

  test "batch validates blocked_by refs within batch", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "A"},
      %{"action" => "insert", "label" => "B", "blocked_by" => "1"}
    ]

    assert {:ok, _} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
  end

  test "batch rejects unknown blocked_by refs", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "A", "blocked_by" => "99"}
    ]

    assert {:error, msg} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert msg =~ "blocked_by references unknown task #99"
  end

  test "batch rejects cycles", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "A", "blocked_by" => "2"},
      %{"action" => "insert", "label" => "B", "blocked_by" => "1"}
    ]

    assert {:error, msg} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert msg =~ "Cycle detected"
  end

  test "batch rejects self-referential blocked_by", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Self-loop", "blocked_by" => "1"}
    ]

    assert {:error, msg} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert msg =~ "Cycle detected"
  end

  test "batch validates parent_id refs", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Child", "parent_id" => 99}
    ]

    assert {:error, msg} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert msg =~ "parent_id references unknown task #99"
  end

  test "batch allows parent_id referencing another batch insert", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Parent"},
      %{"action" => "insert", "label" => "Child", "parent_id" => 1}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    child = Enum.find(payload.tasks, &(&1.id == 2))
    assert child.parent_id == 1
  end

  test "batch accepts valid DAG with multiple layers", %{ctx: ctx} do
    ops = [
      %{"action" => "insert", "label" => "Root"},
      %{"action" => "insert", "label" => "Read", "parent_id" => 1},
      %{"action" => "insert", "label" => "Write tests", "parent_id" => 1, "blocked_by" => "2"},
      %{"action" => "insert", "label" => "Update docs", "parent_id" => 1, "blocked_by" => "2"},
      %{"action" => "insert", "label" => "Verify", "parent_id" => 1, "blocked_by" => "3,4"}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert payload.total == 5

    verify = Enum.find(payload.tasks, &(&1.id == 5))
    assert verify.blocked_by == ["3", "4"]
    assert verify.status == "blocked"
  end

  # -- Bulk id (array) --------------------------------------------------------

  test "update with id array updates multiple tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => [1, 2, 3], "status" => "done"}, ctx)

    assert Enum.all?(payload.tasks, &(&1.status == "done"))
    assert length(payload.changes) == 3
    assert Enum.all?(payload.changes, &(&1.op == "update"))
  end

  test "delete with id array deletes multiple tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "C"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "delete", "id" => [1, 3]}, ctx)

    assert payload.total == 1
    remaining_ids = Enum.map(payload.tasks, & &1.id)
    assert remaining_ids == [2]
    assert length(payload.changes) == 2
  end

  test "bulk update skips missing ids without error", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => [1, 999], "status" => "done"}, ctx)

    assert length(payload.changes) == 1
    task = Enum.find(payload.tasks, &(&1.id == 1))
    assert task.status == "done"
  end

  test "bulk delete skips missing ids without error", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "delete", "id" => [1, 999]}, ctx)

    assert payload.total == 0
    assert length(payload.changes) == 1
  end

  test "bulk update triggers auto-unblock for each completed task", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "C", "blocked_by" => "1,2"},
        ctx
      )

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => [1, 2], "status" => "done"}, ctx)

    task_c = Enum.find(payload.tasks, &(&1.id == 3))
    assert task_c.status == "open"
    assert task_c.blocked_by == []
  end

  test "bulk id works inside a batch op", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A"}, ctx)
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "B"}, ctx)

    ops = [
      %{"action" => "update", "id" => [1, 2], "status" => "done"},
      %{"action" => "insert", "label" => "C"}
    ]

    assert {:ok, payload} = Tasks.execute(%{"action" => "batch", "ops" => ops}, ctx)
    assert payload.total == 3
    assert Enum.at(payload.operations, 0).ok == true
    assert Enum.at(payload.operations, 1).ok == true
  end

  test "meta reflects bulk id count", %{ctx: _ctx} do
    assert Tasks.meta(%{"action" => "update", "id" => [1, 2, 3]}) == "Update 3 tasks"
    assert Tasks.meta(%{"action" => "delete", "id" => [4, 5]}) == "Delete 2 tasks"
    # Single id still works
    assert Tasks.meta(%{"action" => "update", "id" => 1}) == "Update task"
    assert Tasks.meta(%{"action" => "delete", "id" => 1}) == "Remove task"
  end

  # -- Session isolation -----------------------------------------------------

  test "session ids isolate task lists in the same working directory", %{tmp_dir: tmp_dir} do
    session_a = "test-session-a-#{System.unique_integer([:positive])}"
    session_b = "test-session-b-#{System.unique_integer([:positive])}"

    ctx_a = %{working_dir: tmp_dir, session_id: session_a}
    ctx_b = %{working_dir: tmp_dir, session_id: session_b}

    :ok = Tasks.clear("session:" <> session_a)
    :ok = Tasks.clear("session:" <> session_b)

    assert {:ok, inserted} =
             Tasks.execute(%{"action" => "insert", "label" => "Only for session A"}, ctx_a)

    assert inserted.total == 1

    assert {:ok, payload_a} = Tasks.execute(%{"action" => "list"}, ctx_a)
    assert {:ok, payload_b} = Tasks.execute(%{"action" => "list"}, ctx_b)

    assert payload_a.total == 1
    assert payload_b.total == 0
    assert [%{label: "Only for session A"}] = payload_a.tasks
    assert payload_b.tasks == []
  end

  test "query_raw respects session scope", %{tmp_dir: tmp_dir} do
    session_a = "test-session-a-#{System.unique_integer([:positive])}"
    session_b = "test-session-b-#{System.unique_integer([:positive])}"

    :ok = Tasks.clear("session:" <> session_a)
    :ok = Tasks.clear("session:" <> session_b)

    ctx_a = %{working_dir: tmp_dir, session_id: session_a}

    assert {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Scoped task"}, ctx_a)

    assert {:ok, tasks_a} = Tasks.query_raw(%{session_id: session_a}, nil)
    assert {:ok, tasks_b} = Tasks.query_raw(%{session_id: session_b}, nil)

    assert length(tasks_a) == 1
    assert tasks_b == []
    assert Enum.at(tasks_a, 0)["label"] == "Scoped task"
  end

  # -- Meta ------------------------------------------------------------------

  test "meta/1 returns appropriate strings" do
    assert Tasks.meta(%{"action" => "insert"}) == "Add task"
    assert Tasks.meta(%{"action" => "list"}) == "Query tasks"
    assert Tasks.meta(%{"action" => "update"}) == "Update task"
    assert Tasks.meta(%{"action" => "delete"}) == "Remove task"
    assert Tasks.meta(%{"action" => "batch", "ops" => [%{}, %{}, %{}]}) == "Batch 3 ops"
    assert Tasks.meta(%{}) == "Tasks"
  end

  # -- Error cases -----------------------------------------------------------

  test "unknown action returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{"action" => "unknown"}, ctx)
  end

  test "missing action returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{}, ctx)
  end
end
