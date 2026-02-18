defmodule Opal.Tool.TasksTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Tasks

  setup %{tmp_dir: tmp_dir} do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    :ok = Tasks.clear("session:" <> session_id)
    %{ctx: %{working_dir: tmp_dir, session_id: session_id}}
  end

  test "insert returns structured payload with changes and done state", %{ctx: ctx} do
    assert {:ok, payload} = Tasks.execute(%{"action" => "insert", "label" => "Draft plan"}, ctx)

    assert payload.kind == "tasks"
    assert payload.action == "insert"
    assert payload.total == 1
    assert payload.counts["open"] == 1
    assert payload.changes == [%{op: "insert", id: 1, label: "Draft plan"}]
    assert [%{id: 1, label: "Draft plan", status: "open", done: false}] = payload.tasks
  end

  test "update returns structured payload with changed fields", %{ctx: ctx} do
    assert {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Draft plan"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => 1, "label" => "Write tests"}, ctx)

    assert payload.action == "update"
    assert payload.total == 1
    assert payload.changes == [%{op: "update", id: 1, changed_fields: ["label"]}]
    assert [%{id: 1, label: "Write tests"}] = payload.tasks
  end

  test "delete returns empty structured snapshot with delete change", %{ctx: ctx} do
    assert {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Old task"}, ctx)

    assert {:ok, payload} = Tasks.execute(%{"action" => "delete", "id" => 1}, ctx)

    assert payload.action == "delete"
    assert payload.total == 0
    assert payload.tasks == []
    assert payload.changes == [%{op: "delete", id: 1, label: "Old task"}]
  end

  test "list includes done boolean for completed tasks", %{ctx: ctx} do
    assert {:ok, _} =
             Tasks.execute(%{"action" => "insert", "label" => "Ship", "status" => "done"}, ctx)

    assert {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)

    assert [%{label: "Ship", status: "done", done: true}] = payload.tasks
    assert payload.counts["done"] == 1
  end

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

  # -- Batch action -----------------------------------------------------------

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

  # -- Fields: group_name, tags, priority, notes, due, blocked_by -----------

  test "insert respects all optional fields", %{ctx: ctx} do
    assert {:ok, payload} =
             Tasks.execute(
               %{
                 "action" => "insert",
                 "label" => "Full task",
                 "priority" => "critical",
                 "group_name" => "backend",
                 "tags" => "api, auth",
                 "notes" => "Important note",
                 "due" => "2026-03-01",
                 "blocked_by" => "1,2"
               },
               ctx
             )

    task = hd(payload.tasks)
    assert task.priority == "critical"
    assert task.group_name == "backend"
    assert task.tags == ["api", "auth"]
    assert task.notes == "Important note"
    assert task.due == "2026-03-01"
    assert task.blocked_by == ["1", "2"]
  end

  test "sort_by_priority orders critical > high > medium > low", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Low", "priority" => "low"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Critical", "priority" => "critical"},
        ctx
      )

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "High", "priority" => "high"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list"}, ctx)

    labels = Enum.map(payload.tasks, & &1.label)
    assert labels == ["Critical", "High", "Low"]
  end

  # -- Views -----------------------------------------------------------------

  test "list with view=open only returns open tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Open task"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Done task", "status" => "done"},
        ctx
      )

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

  test "list with view=high_priority returns high/critical open tasks", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "Low prio", "priority" => "low"}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "High prio", "priority" => "high"}, ctx)

    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Critical prio", "priority" => "critical"},
        ctx
      )

    {:ok, _} =
      Tasks.execute(
        %{
          "action" => "insert",
          "label" => "Done critical",
          "priority" => "critical",
          "status" => "done"
        },
        ctx
      )

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "high_priority"}, ctx)
    labels = Enum.map(payload.tasks, & &1.label)
    assert "High prio" in labels
    assert "Critical prio" in labels
    refute "Low prio" in labels
    refute "Done critical" in labels
  end

  test "list with view=blocked returns blocked tasks", %{ctx: ctx} do
    {:ok, _} =
      Tasks.execute(
        %{"action" => "insert", "label" => "Blocked", "status" => "blocked"},
        ctx
      )

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

  test "list with unknown view returns all tasks", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Task1"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "view" => "nonexistent"}, ctx)
    assert length(payload.tasks) == 1
  end

  # -- Meta ------------------------------------------------------------------

  test "meta/1 returns appropriate strings" do
    assert Tasks.meta(%{"action" => "insert"}) == "Add task"
    assert Tasks.meta(%{"action" => "list"}) == "Query tasks"
    assert Tasks.meta(%{"action" => "update"}) == "Update task"
    assert Tasks.meta(%{"action" => "delete"}) == "Remove task"

    assert Tasks.meta(%{"action" => "batch", "ops" => [%{}, %{}, %{}]}) ==
             "Batch 3 ops"

    assert Tasks.meta(%{}) == "Tasks"
  end

  # -- Error cases -----------------------------------------------------------

  test "insert with empty label returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{"action" => "insert", "label" => ""}, ctx)
  end

  test "update nonexistent task returns error", %{ctx: ctx} do
    assert {:error, "Task #999 not found."} =
             Tasks.execute(%{"action" => "update", "id" => 999, "status" => "done"}, ctx)
  end

  test "delete nonexistent task returns error", %{ctx: ctx} do
    assert {:error, "Task #999 not found."} =
             Tasks.execute(%{"action" => "delete", "id" => 999}, ctx)
  end

  test "update without id returns error", %{ctx: ctx} do
    assert {:error, "Update requires an 'id' field."} =
             Tasks.execute(%{"action" => "update", "status" => "done"}, ctx)
  end

  test "delete without id returns error", %{ctx: ctx} do
    assert {:error, "Delete requires an 'id' field."} =
             Tasks.execute(%{"action" => "delete"}, ctx)
  end

  test "unknown action returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{"action" => "unknown"}, ctx)
  end

  test "missing action returns error", %{ctx: ctx} do
    assert {:error, _} = Tasks.execute(%{}, ctx)
  end

  # -- Filter by status field -------------------------------------------------

  test "list with status filter", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "A", "status" => "open"}, ctx)

    {:ok, _} =
      Tasks.execute(%{"action" => "insert", "label" => "B", "status" => "in_progress"}, ctx)

    {:ok, payload} = Tasks.execute(%{"action" => "list", "status" => "in_progress"}, ctx)
    assert length(payload.tasks) == 1
    assert hd(payload.tasks).label == "B"
  end

  # -- Update with string id --------------------------------------------------

  test "update accepts string id", %{ctx: ctx} do
    {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "First"}, ctx)

    assert {:ok, payload} =
             Tasks.execute(%{"action" => "update", "id" => "1", "label" => "Updated"}, ctx)

    assert hd(payload.tasks).label == "Updated"
  end
end
