defmodule Opal.Tool.Tasks do
  @moduledoc """
  Session-scoped task tracker backed by DETS (built into Erlang).

  Uses structured JSON parameters — no SQL parsing needed. The LLM
  passes action + fields directly. Database stored at `~/.opal/tasks/<hash>.dets`,
  keyed by session ID when available (with working-dir fallback for compatibility).

  Results are returned as structured maps (task lists, counts, and operation
  metadata). Rendering is handled client-side.

  ## Actions

      insert  — create a task (requires label)
      list    — list tasks with optional filters or a named view
      update  — update a task by id
      delete  — delete a task by id

  ## Fields

      id, label, status (open|done|blocked|in_progress),
      priority (low|medium|high|critical), group_name, tags,
      due (ISO date), notes, blocked_by
  """

  @behaviour Opal.Tool

  @settable_fields ~w(label status priority group_name tags due notes blocked_by)a

  @impl true
  def name, do: "tasks"

  @impl true
  def description do
    """
    Manages a task list. Useful for planning complex, multi-step work. Actions: insert, list, update, delete, batch.

    insert: {action: "insert", label: "Fix bug", priority: "high", tags: "api"}
    list:   {action: "list"} or {action: "list", view: "open"} or {action: "list", status: "blocked", priority: "high"}
    update: {action: "update", id: 1, status: "done"}
    delete: {action: "delete", id: 1}
    batch:  {action: "batch", ops: [{action: "insert", label: "Task A"}, {action: "insert", label: "Task B"}, {action: "update", id: 1, status: "done"}]}

    Views: open, done, blocked, in_progress, overdue, high_priority.
    Fields: label, status (open|done|blocked|in_progress), priority (low|medium|high|critical),
    group_name, tags (comma-separated), due (ISO date), notes, blocked_by.
    Returns structured JSON snapshots (`tasks`, `counts`, `changes`, and `operations` for batch).
    """
  end

  @impl true
  def meta(%{"action" => "insert"}), do: "Add task"
  def meta(%{"action" => "list"}), do: "Query tasks"
  def meta(%{"action" => "update"}), do: "Update task"
  def meta(%{"action" => "delete"}), do: "Remove task"
  def meta(%{"action" => "batch", "ops" => ops}) when is_list(ops), do: "Batch #{length(ops)} ops"
  def meta(_), do: "Tasks"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["insert", "list", "update", "delete", "batch"],
          "description" => "The operation to perform."
        },
        "id" => %{
          "type" => "integer",
          "description" => "Task ID (required for update/delete)."
        },
        "view" => %{
          "type" => "string",
          "enum" => ["open", "done", "blocked", "in_progress", "overdue", "high_priority"],
          "description" => "Named filter preset for list action."
        },
        "label" => %{"type" => "string", "description" => "Task label (required for insert)."},
        "status" => %{
          "type" => "string",
          "enum" => ["open", "done", "blocked", "in_progress"],
          "description" => "Task status."
        },
        "priority" => %{
          "type" => "string",
          "enum" => ["low", "medium", "high", "critical"],
          "description" => "Task priority."
        },
        "group_name" => %{"type" => "string", "description" => "Group/category name."},
        "tags" => %{"type" => "string", "description" => "Comma-separated tags."},
        "due" => %{
          "type" => "string",
          "description" => "Due date in ISO 8601 format (YYYY-MM-DD)."
        },
        "notes" => %{"type" => "string", "description" => "Additional notes."},
        "blocked_by" => %{
          "type" => "string",
          "description" => "IDs of blocking tasks (comma-separated)."
        },
        "ops" => %{
          "type" => "array",
          "description" =>
            "Array of operations for batch action. Each element is an object with the same fields as a single action.",
          "items" => %{"type" => "object"}
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "insert"} = params, context) when is_map(context),
    do: run_insert(scope_key(context), params)

  def execute(%{"action" => "list"} = params, context) when is_map(context),
    do: run_list(scope_key(context), params)

  def execute(%{"action" => "update"} = params, context) when is_map(context),
    do: run_update(scope_key(context), params)

  def execute(%{"action" => "delete"} = params, context) when is_map(context),
    do: run_delete(scope_key(context), params)

  def execute(%{"action" => "batch", "ops" => ops}, context)
      when is_list(ops) and is_map(context),
      do: run_batch(scope_key(context), ops)

  def execute(%{"action" => "batch"}, _), do: {:error, "Batch requires an 'ops' array."}

  def execute(%{"action" => _}, _),
    do: {:error, "Unknown action. Use: insert, list, update, delete, batch."}

  def execute(_, _), do: {:error, "Missing required parameter: action"}

  @doc """
  Clear all tasks for a given scope key.
  """
  @spec clear(String.t()) :: :ok
  def clear(scope) do
    key = scope_key(scope)
    path = dets_path(key)
    table = table_name(key)

    case :dets.open_file(table, file: path, type: :set) do
      {:ok, ^table} ->
        :dets.delete_all_objects(table)
        :dets.close(table)
        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Return active tasks as a list of maps for a session or scope key.
  """
  @spec query_raw(map() | String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def query_raw(scope, _query) do
    with_dets(scope_key(scope), fn table ->
      tasks =
        all_tasks(table)
        |> Enum.filter(&(&1.status in ["open", "in_progress", "blocked"]))
        |> sort_by_priority()

      {:ok, Enum.map(tasks, &task_to_string_map/1)}
    end)
  end

  # -- BATCH --

  defp run_batch(wd, ops) do
    with_dets(wd, fn table ->
      operation_results =
        Enum.map(ops, fn op ->
          action = Map.get(op, "action", "unknown")

          case run_single(table, op) do
            {:ok, payload} ->
              %{
                action: action,
                ok: true,
                changes: Map.get(payload, :changes, []),
                total: Map.get(payload, :total, 0)
              }

            {:error, message} ->
              %{action: action, ok: false, error: message}
          end
        end)

      tasks =
        table
        |> all_tasks()
        |> sort_by_priority()

      {:ok, tasks_payload("batch", tasks, %{operations: operation_results})}
    end)
  end

  defp run_single(table, %{"action" => "insert"} = params), do: do_insert(table, params)
  defp run_single(table, %{"action" => "update"} = params), do: do_update(table, params)
  defp run_single(table, %{"action" => "delete"} = params), do: do_delete(table, params)
  defp run_single(table, %{"action" => "list"} = params), do: do_list(table, params)
  defp run_single(_, %{"action" => a}), do: {:error, "Unknown action in batch: #{a}"}
  defp run_single(_, _), do: {:error, "Each batch op requires an 'action' field."}

  # -- DETS Helpers --

  defp scope_key(%{session_id: sid}) when is_binary(sid) and sid != "", do: "session:" <> sid
  defp scope_key(%{working_dir: wd}) when is_binary(wd) and wd != "", do: wd
  defp scope_key(scope) when is_binary(scope) and scope != "", do: scope
  defp scope_key(_), do: File.cwd!()

  defp dets_path(working_dir) do
    cfg = Opal.Config.new()
    dir = Path.join(Opal.Config.data_dir(cfg), "tasks")
    File.mkdir_p!(dir)

    hash =
      :crypto.hash(:sha256, working_dir)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    Path.join(dir, "#{hash}.dets") |> String.to_charlist()
  end

  # Atom count is bounded — one per unique working_dir hash, not per user input.
  # Working dirs are a finite set within a session's lifetime.
  defp table_name(working_dir) do
    hash =
      :crypto.hash(:sha256, working_dir)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    String.to_atom("opal_tasks_#{hash}")
  end

  defp with_dets(working_dir, fun) do
    path = dets_path(working_dir)
    table = table_name(working_dir)

    case :dets.open_file(table, file: path, type: :set) do
      {:ok, ^table} ->
        try do
          ensure_counter(table)
          fun.(table)
        after
          :dets.close(table)
        end

      {:error, reason} ->
        {:error, "Failed to open tasks database: #{inspect(reason)}"}
    end
  end

  defp all_tasks(table) do
    :dets.foldl(fn
      {:__counter__, _}, acc -> acc
      {_id, task}, acc -> [task | acc]
    end, [], table)
  end

  # Atomic counter — avoids duplicate IDs when concurrent with_dets calls overlap.
  # Uses :dets.update_counter/3 which is atomic within a single DETS table.
  defp next_id(table) do
    :dets.update_counter(table, :__counter__, 1)
  end

  # Seeds the :__counter__ key on first access or when opening a legacy table.
  # insert_new/2 is atomic — only one process will succeed under concurrent access.
  defp ensure_counter(table) do
    unless :dets.member(table, :__counter__) do
      max_id =
        :dets.foldl(
          fn
            {id, _}, max when is_integer(id) -> max(id, max)
            _, max -> max
          end,
          0,
          table
        )

      :dets.insert_new(table, {:__counter__, max_id})
    end

    :ok
  end

  defp now_iso, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_string()

  # -- INSERT --

  defp run_insert(wd, params) do
    with_dets(wd, fn table -> do_insert(table, params) end)
  end

  defp do_insert(table, params) do
    case params do
      %{"label" => label} when is_binary(label) and label != "" ->
        id = next_id(table)
        now = now_iso()

        task =
          %{
            id: id,
            label: label,
            status: params["status"] || "open",
            priority: params["priority"] || "medium",
            group_name: params["group_name"] || "default",
            tags: params["tags"] || "",
            due: params["due"],
            notes: params["notes"] || "",
            blocked_by: params["blocked_by"],
            created_at: now,
            updated_at: now
          }

        :dets.insert(table, {id, task})
        tasks = table |> all_tasks() |> sort_by_priority()

        {:ok,
         tasks_payload("insert", tasks, %{
           changes: [%{op: "insert", id: id, label: label}]
         })}

      _ ->
        {:error, "Insert requires a non-empty 'label' field."}
    end
  end

  # -- LIST --

  @views %{
    "open" => %{"status" => "open"},
    "done" => %{"status" => "done"},
    "blocked" => %{"status" => "blocked"},
    "in_progress" => %{"status" => "in_progress"},
    "high_priority" => :high_priority,
    "overdue" => :overdue
  }

  defp run_list(wd, params) do
    with_dets(wd, fn table -> do_list(table, params) end)
  end

  defp do_list(table, params) do
    tasks = all_tasks(table)

    filtered =
      case params["view"] do
        nil -> apply_filters(tasks, params)
        view -> apply_view(tasks, view)
      end
      |> sort_by_priority()

    {:ok, tasks_payload("list", filtered)}
  end

  defp apply_view(tasks, view) do
    case Map.get(@views, view) do
      nil ->
        tasks

      :high_priority ->
        Enum.filter(
          tasks,
          &(&1.priority in ["high", "critical"] and &1.status in ["open", "in_progress"])
        )

      :overdue ->
        today = Date.utc_today() |> Date.to_iso8601()

        Enum.filter(tasks, fn t ->
          t.due != nil and t.due != "" and t.due < today and t.status in ["open", "in_progress"]
        end)

      filters when is_map(filters) ->
        apply_filters(tasks, filters)
    end
  end

  defp apply_filters(tasks, params) do
    Enum.filter(tasks, fn task ->
      Enum.all?(@settable_fields, fn field ->
        key = to_string(field)

        case Map.get(params, key) do
          nil -> true
          val -> to_string(Map.get(task, field, "")) == val
        end
      end)
    end)
  end

  # -- UPDATE --

  defp run_update(wd, params) do
    with_dets(wd, fn table -> do_update(table, params) end)
  end

  defp do_update(table, params) do
    case params["id"] do
      nil ->
        {:error, "Update requires an 'id' field."}

      id ->
        id = if is_binary(id), do: String.to_integer(id), else: id

        case :dets.lookup(table, id) do
          [{^id, task}] ->
            updated =
              Enum.reduce(@settable_fields, task, fn field, acc ->
                key = to_string(field)

                case Map.get(params, key) do
                  nil -> acc
                  val -> Map.put(acc, field, val)
                end
              end)
              |> Map.put(:updated_at, now_iso())

            :dets.insert(table, {id, updated})
            tasks = table |> all_tasks() |> sort_by_priority()

            changed_fields =
              @settable_fields
              |> Enum.map(&to_string/1)
              |> Enum.filter(&Map.has_key?(params, &1))

            {:ok,
             tasks_payload("update", tasks, %{
               changes: [
                 %{
                   op: "update",
                   id: id,
                   changed_fields: changed_fields
                 }
               ]
             })}

          [] ->
            {:error, "Task ##{id} not found."}
        end
    end
  end

  # -- DELETE --

  defp run_delete(wd, params) do
    with_dets(wd, fn table -> do_delete(table, params) end)
  end

  defp do_delete(table, params) do
    case params["id"] do
      nil ->
        {:error, "Delete requires an 'id' field."}

      id ->
        id = if is_binary(id), do: String.to_integer(id), else: id

        case :dets.lookup(table, id) do
          [{^id, task}] ->
            :dets.delete(table, id)
            tasks = table |> all_tasks() |> sort_by_priority()

            {:ok,
             tasks_payload("delete", tasks, %{
               changes: [%{op: "delete", id: id, label: task.label}]
             })}

          [] ->
            {:error, "Task ##{id} not found."}
        end
    end
  end

  # -- Payload helpers --

  defp sort_by_priority(tasks) do
    priority_order = %{"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}

    Enum.sort_by(tasks, fn t ->
      {Map.get(priority_order, t.priority, 9), t.id}
    end)
  end

  defp tasks_payload(action, tasks, extras \\ %{}) do
    counts =
      Enum.reduce(tasks, %{"open" => 0, "in_progress" => 0, "done" => 0, "blocked" => 0}, fn t,
                                                                                             acc ->
        Map.update(acc, t.status, 1, &(&1 + 1))
      end)

    payload = %{
      kind: "tasks",
      action: action,
      tasks: Enum.map(tasks, &task_to_wire_map/1),
      total: length(tasks),
      counts: counts,
      changes: Map.get(extras, :changes, []),
      notes: Map.get(extras, :notes, [])
    }

    case Map.get(extras, :operations) do
      nil -> payload
      operations -> Map.put(payload, :operations, operations)
    end
  end

  defp task_to_wire_map(task) do
    %{
      id: task.id,
      label: task.label,
      status: task.status,
      done: task.status == "done",
      priority: task.priority,
      group_name: task.group_name,
      tags: split_csv(task.tags),
      due: nil_if_blank(task.due),
      notes: task.notes,
      blocked_by: split_csv(task.blocked_by),
      created_at: task.created_at,
      updated_at: task.updated_at
    }
  end

  defp split_csv(nil), do: []
  defp split_csv(""), do: []

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_csv(value), do: [to_string(value)]

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(value), do: value

  defp task_to_string_map(task) do
    Map.new(task, fn {k, v} -> {to_string(k), to_s(v)} end)
  end

  defp to_s(nil), do: ""
  defp to_s(val), do: to_string(val)
end
