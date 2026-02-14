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

    ctx_a = %{working_dir: tmp_dir, session_id: session_a}

    assert {:ok, _} = Tasks.execute(%{"action" => "insert", "label" => "Scoped task"}, ctx_a)

    assert {:ok, tasks_a} = Tasks.query_raw(%{session_id: session_a}, nil)
    assert {:ok, tasks_b} = Tasks.query_raw(%{session_id: session_b}, nil)

    assert length(tasks_a) == 1
    assert tasks_b == []
    assert Enum.at(tasks_a, 0)["label"] == "Scoped task"
  end
end
