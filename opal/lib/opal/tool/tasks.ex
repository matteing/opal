defmodule Opal.Tool.Tasks do
  @moduledoc """
  Session-scoped task tracker backed by DETS (built into Erlang).

  Uses structured JSON parameters — no SQL parsing needed. The LLM
  passes action + fields directly. Database stored at `~/.opal/tasks/<hash>.dets`,
  keyed by session ID when available (with working-dir fallback for compatibility).

  Supports DAG dependencies via `blocked_by` — completing a task
  auto-unblocks its dependents.  Hierarchical breakdown is expressed
  with `parent_id`.  The `ready` view surfaces dispatchable work.

  ## Actions

      insert  — create a task (requires label)
      list    — list tasks with optional filters or a named view
      update  — update a task by id
      delete  — delete a task by id
      batch   — execute multiple ops atomically (validates DAG)

  ## Fields

      id, label, status (open|done|blocked|in_progress),
      parent_id, prompt, result, notes, blocked_by
  """

  @behaviour Opal.Tool

  @settable_fields ~w(label status notes blocked_by parent_id prompt result)a

  @impl true
  def name, do: "tasks"

  @impl true
  def description do
    """
    Manages a task list for planning and tracking work. Actions: insert, list, update, delete, batch.

    For complex tasks, break work into subtasks with parent_id for hierarchy and
    blocked_by for dependencies. Independent tasks can be dispatched to sub_agents
    in parallel.

    insert:  {action: "insert", label: "Fix parser", parent_id: 1, prompt: "...", blocked_by: "2"}
    list:    {action: "list", view: "ready"}  — tasks with all blockers done
    update:  {action: "update", id: 3, status: "done", result: "..."}
    delete:  {action: "delete", id: 1}
    batch:   {action: "batch", ops: [...]}  — validated atomically (rejects cycles)

    Fields: label, status (open|done|blocked|in_progress), parent_id, prompt,
    result, blocked_by (comma-separated IDs), notes.
    Completing a task auto-unblocks dependents.
    Returns structured JSON snapshots (`tasks`, `counts`, `changes`, and `operations` for batch).

    id accepts an integer or array for bulk operations:
      update:  {action: "update", id: [1,2,3], status: "done"}
      delete:  {action: "delete", id: [4,5]}
    """
  end

  @impl true
  def meta(%{"action" => "update", "id" => ids}) when is_list(ids),
    do: "Update #{length(ids)} tasks"

  def meta(%{"action" => "delete", "id" => ids}) when is_list(ids),
    do: "Delete #{length(ids)} tasks"

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
          "oneOf" => [
            %{"type" => "integer"},
            %{"type" => "array", "items" => %{"type" => "integer"}}
          ],
          "description" =>
            "Task ID (required for update/delete). Pass an array for bulk operations."
        },
        "view" => %{
          "type" => "string",
          "enum" => ["open", "done", "blocked", "in_progress", "ready"],
          "description" => "Named filter preset for list action."
        },
        "tree" => %{
          "type" => "boolean",
          "description" => "When true, order tasks by parent_id hierarchy with depth."
        },
        "label" => %{"type" => "string", "description" => "Task label (required for insert)."},
        "status" => %{
          "type" => "string",
          "enum" => ["open", "done", "blocked", "in_progress"],
          "description" => "Task status."
        },
        "parent_id" => %{
          "type" => "integer",
          "description" => "Parent task ID for hierarchical breakdown."
        },
        "prompt" => %{
          "type" => "string",
          "description" => "Full sub-agent instructions for executing the task."
        },
        "result" => %{
          "type" => "string",
          "description" => "Sub-agent output (written on completion)."
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
  @spec query_raw(map() | String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def query_raw(scope, _query) do
    with_dets(scope_key(scope), fn table ->
      tasks =
        all_tasks(table)
        |> Enum.filter(&(&1.status in ["open", "in_progress", "blocked"]))
        |> Enum.sort_by(& &1.id)

      {:ok, Enum.map(tasks, &task_to_string_map/1)}
    end)
  end

  # -- BATCH --

  defp run_batch(wd, ops) do
    with_dets(wd, fn table ->
      case validate_batch_dag(table, ops) do
        :ok ->
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

          tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)
          {:ok, tasks_payload("batch", tasks, %{operations: operation_results})}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp run_single(table, %{"action" => "insert"} = params), do: do_insert(table, params)
  defp run_single(table, %{"action" => "update"} = params), do: do_update(table, params)
  defp run_single(table, %{"action" => "delete"} = params), do: do_delete(table, params)
  defp run_single(table, %{"action" => "list"} = params), do: do_list(table, params)
  defp run_single(_, %{"action" => a}), do: {:error, "Unknown action in batch: #{a}"}
  defp run_single(_, _), do: {:error, "Each batch op requires an 'action' field."}

  # -- DAG Validation --

  @spec validate_batch_dag(:dets.tab_name(), [map()]) :: :ok | {:error, String.t()}
  defp validate_batch_dag(table, ops) do
    existing = all_tasks(table)
    existing_ids = MapSet.new(existing, & &1.id)
    base = peek_counter(table)

    # Predict IDs for inserts in order
    {inserts, _} =
      ops
      |> Enum.filter(&(&1["action"] == "insert"))
      |> Enum.map_reduce(base, fn op, counter ->
        id = counter + 1
        {{id, op}, id}
      end)

    new_ids = MapSet.new(inserts, fn {id, _} -> id end)
    all_ids = MapSet.union(existing_ids, new_ids)

    # Validate blocked_by and parent_id refs
    with :ok <- validate_batch_refs(inserts, all_ids),
         :ok <- validate_batch_parents(inserts, all_ids) do
      # Build full dependency graph and check for cycles
      graph =
        Enum.reduce(existing, %{}, fn task, acc ->
          deps = parse_blocked_by(Map.get(task, :blocked_by))
          if deps == [], do: acc, else: Map.put(acc, task.id, deps)
        end)

      graph =
        Enum.reduce(inserts, graph, fn {id, op}, acc ->
          deps = parse_blocked_by(op["blocked_by"])
          if deps == [], do: acc, else: Map.put(acc, id, deps)
        end)

      detect_cycle(graph)
    end
  end

  @spec validate_batch_refs([{integer(), map()}], MapSet.t(integer())) ::
          :ok | {:error, String.t()}
  defp validate_batch_refs(inserts, all_ids) do
    errors =
      for {id, op} <- inserts,
          dep <- parse_blocked_by(op["blocked_by"]),
          not MapSet.member?(all_ids, dep),
          do: "Task ##{id}: blocked_by references unknown task ##{dep}"

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  @spec validate_batch_parents([{integer(), map()}], MapSet.t(integer())) ::
          :ok | {:error, String.t()}
  defp validate_batch_parents(inserts, all_ids) do
    errors =
      for {id, op} <- inserts,
          pid = parse_int(op["parent_id"]),
          pid != nil,
          not MapSet.member?(all_ids, pid),
          do: "Task ##{id}: parent_id references unknown task ##{pid}"

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  # DFS cycle detection with three-color marking (white → gray → black).
  @spec detect_cycle(%{integer() => [integer()]}) :: :ok | {:error, String.t()}
  defp detect_cycle(graph) do
    all_nodes =
      graph
      |> Enum.flat_map(fn {k, vs} -> [k | vs] end)
      |> MapSet.new()

    result =
      Enum.reduce_while(all_nodes, %{}, fn node, colors ->
        case dfs_visit(node, graph, colors) do
          {:ok, colors} -> {:cont, colors}
          {:cycle, trail} -> {:halt, {:cycle, trail}}
        end
      end)

    case result do
      {:cycle, trail} -> {:error, "Cycle detected: #{Enum.join(trail, " \u2192 ")}"}
      _ -> :ok
    end
  end

  @spec dfs_visit(integer(), %{integer() => [integer()]}, %{integer() => :gray | :black}) ::
          {:ok, %{integer() => :gray | :black}} | {:cycle, [integer()]}
  defp dfs_visit(node, graph, colors) do
    case Map.get(colors, node) do
      :black ->
        {:ok, colors}

      :gray ->
        {:cycle, [node]}

      nil ->
        colors = Map.put(colors, node, :gray)
        deps = Map.get(graph, node, [])

        case Enum.reduce_while(deps, {:ok, colors}, fn dep, {:ok, colors} ->
               case dfs_visit(dep, graph, colors) do
                 {:ok, colors} -> {:cont, {:ok, colors}}
                 {:cycle, trail} -> {:halt, {:cycle, [node | trail]}}
               end
             end) do
          {:ok, colors} -> {:ok, Map.put(colors, node, :black)}
          {:cycle, trail} -> {:cycle, trail}
        end
    end
  end

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
    :dets.foldl(
      fn
        {:__counter__, _}, acc -> acc
        {_id, task}, acc -> [task | acc]
      end,
      [],
      table
    )
  end

  @spec all_task_ids(:dets.tab_name()) :: MapSet.t(integer())
  defp all_task_ids(table) do
    :dets.foldl(
      fn
        {:__counter__, _}, acc -> acc
        {id, _task}, acc -> MapSet.put(acc, id)
      end,
      MapSet.new(),
      table
    )
  end

  # Atomic counter — avoids duplicate IDs when concurrent with_dets calls overlap.
  # Uses :dets.update_counter/3 which is atomic within a single DETS table.
  defp next_id(table) do
    :dets.update_counter(table, :__counter__, 1)
  end

  defp peek_counter(table) do
    case :dets.lookup(table, :__counter__) do
      [{:__counter__, c}] -> c
      _ -> 0
    end
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
    with_dets(wd, fn table ->
      with :ok <- validate_refs(table, params) do
        do_insert(table, params)
      end
    end)
  end

  defp do_insert(table, params) do
    case params do
      %{"label" => label} when is_binary(label) and label != "" ->
        id = next_id(table)
        now = now_iso()
        blocked_by = params["blocked_by"]
        has_blockers? = blocked_by != nil and blocked_by != ""

        status =
          case params["status"] do
            nil -> if has_blockers?, do: "blocked", else: "open"
            explicit -> explicit
          end

        task = %{
          id: id,
          label: label,
          status: status,
          notes: params["notes"] || "",
          blocked_by: blocked_by,
          parent_id: parse_int(params["parent_id"]),
          prompt: params["prompt"],
          result: params["result"],
          created_at: now,
          updated_at: now
        }

        :dets.insert(table, {id, task})
        tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)

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
    "ready" => :ready
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

    ordered =
      if params["tree"] == true do
        tree_order(filtered)
      else
        Enum.sort_by(filtered, & &1.id)
      end

    {:ok, tasks_payload("list", ordered, %{tree: params["tree"] == true})}
  end

  defp apply_view(tasks, view) do
    case Map.get(@views, view) do
      nil ->
        tasks

      :ready ->
        Enum.filter(tasks, fn t ->
          t.status == "open" and parse_blocked_by(Map.get(t, :blocked_by)) == []
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

  # Orders tasks depth-first by parent_id, adding a :depth key.
  @spec tree_order([map()]) :: [map()]
  defp tree_order(tasks) do
    by_parent = Enum.group_by(tasks, &Map.get(&1, :parent_id))
    roots = Map.get(by_parent, nil, []) |> Enum.sort_by(& &1.id)
    build_tree(roots, by_parent, 0)
  end

  @spec build_tree([map()], %{optional(integer() | nil) => [map()]}, non_neg_integer()) :: [map()]
  defp build_tree(nodes, by_parent, depth) do
    Enum.flat_map(nodes, fn node ->
      children = Map.get(by_parent, node.id, []) |> Enum.sort_by(& &1.id)
      [Map.put(node, :depth, depth) | build_tree(children, by_parent, depth + 1)]
    end)
  end

  # -- UPDATE --

  defp run_update(wd, params) do
    with_dets(wd, fn table ->
      with :ok <- validate_refs(table, params) do
        do_update(table, params)
      end
    end)
  end

  defp do_update(table, %{"id" => ids} = params) when is_list(ids) do
    ids = Enum.map(ids, &coerce_int/1)

    {changes, unblock_changes} =
      Enum.reduce(ids, {[], []}, fn id, {ch_acc, ub_acc} ->
        case update_one(table, id, params) do
          {:ok, ch, ub} -> {ch_acc ++ ch, ub_acc ++ ub}
          {:error, _} -> {ch_acc, ub_acc}
        end
      end)

    tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)
    {:ok, tasks_payload("update", tasks, %{changes: changes ++ unblock_changes})}
  end

  defp do_update(table, %{"id" => id} = params) when not is_nil(id) do
    id = coerce_int(id)

    case update_one(table, id, params) do
      {:ok, changes, unblock_changes} ->
        tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)
        {:ok, tasks_payload("update", tasks, %{changes: changes ++ unblock_changes})}

      {:error, _} = err ->
        err
    end
  end

  defp do_update(_table, _params), do: {:error, "Update requires an 'id' field."}

  @spec update_one(:dets.tab_name(), integer(), map()) ::
          {:ok, [map()], [map()]} | {:error, String.t()}
  defp update_one(table, id, params) do
    case :dets.lookup(table, id) do
      [{^id, task}] ->
        updated =
          Enum.reduce(@settable_fields, task, fn field, acc ->
            key = to_string(field)

            case Map.get(params, key) do
              nil ->
                acc

              val when field == :parent_id ->
                Map.put(acc, field, parse_int(val))

              val ->
                Map.put(acc, field, val)
            end
          end)
          |> Map.put(:updated_at, now_iso())

        :dets.insert(table, {id, updated})

        # Auto-unblock dependents when marking done
        unblocked = if updated.status == "done", do: auto_unblock(table, id), else: []

        changed_fields =
          @settable_fields
          |> Enum.map(&to_string/1)
          |> Enum.filter(&Map.has_key?(params, &1))

        changes = [%{op: "update", id: id, changed_fields: changed_fields}]

        unblock_changes =
          Enum.map(unblocked, fn uid ->
            %{op: "auto_unblock", id: uid, changed_fields: ["blocked_by", "status"]}
          end)

        {:ok, changes, unblock_changes}

      [] ->
        {:error, "Task ##{id} not found."}
    end
  end

  # Removes `completed_id` from every task's `blocked_by`.  When a task's
  # blocker list becomes empty and its status is `"blocked"`, it transitions
  # to `"open"`.  Returns the list of unblocked task IDs.
  @spec auto_unblock(:dets.tab_name(), integer()) :: [integer()]
  defp auto_unblock(table, completed_id) do
    completed_str = to_string(completed_id)

    all_tasks(table)
    |> Enum.filter(fn t ->
      completed_str in parse_blocked_by_strings(Map.get(t, :blocked_by))
    end)
    |> Enum.flat_map(fn task ->
      remaining =
        task.blocked_by
        |> parse_blocked_by_strings()
        |> Enum.reject(&(&1 == completed_str))
        |> Enum.join(",")

      remaining = if remaining == "", do: nil, else: remaining
      new_status = if remaining == nil and task.status == "blocked", do: "open", else: task.status

      updated =
        task
        |> Map.put(:blocked_by, remaining)
        |> Map.put(:status, new_status)
        |> Map.put(:updated_at, now_iso())

      :dets.insert(table, {task.id, updated})

      if new_status != task.status, do: [task.id], else: []
    end)
  end

  # -- Reference Validation --

  # Validates that blocked_by and parent_id reference existing tasks.
  @spec validate_refs(:dets.tab_name(), map()) :: :ok | {:error, String.t()}
  defp validate_refs(table, params) do
    existing_ids = all_task_ids(table)

    blocked_errors =
      for dep <- parse_blocked_by(params["blocked_by"]),
          not MapSet.member?(existing_ids, dep),
          do: "blocked_by references unknown task ##{dep}"

    parent_errors =
      case parse_int(params["parent_id"]) do
        nil ->
          []

        pid ->
          if MapSet.member?(existing_ids, pid),
            do: [],
            else: ["parent_id references unknown task ##{pid}"]
      end

    errors = blocked_errors ++ parent_errors
    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  # -- DELETE --

  defp run_delete(wd, params) do
    with_dets(wd, fn table -> do_delete(table, params) end)
  end

  defp do_delete(table, %{"id" => ids} = _params) when is_list(ids) do
    ids = Enum.map(ids, &coerce_int/1)

    changes =
      Enum.flat_map(ids, fn id ->
        case :dets.lookup(table, id) do
          [{^id, task}] ->
            :dets.delete(table, id)
            [%{op: "delete", id: id, label: task.label}]

          [] ->
            []
        end
      end)

    tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)
    {:ok, tasks_payload("delete", tasks, %{changes: changes})}
  end

  defp do_delete(table, %{"id" => id} = _params) when not is_nil(id) do
    id = coerce_int(id)

    case :dets.lookup(table, id) do
      [{^id, task}] ->
        :dets.delete(table, id)
        tasks = table |> all_tasks() |> Enum.sort_by(& &1.id)

        {:ok,
         tasks_payload("delete", tasks, %{
           changes: [%{op: "delete", id: id, label: task.label}]
         })}

      [] ->
        {:error, "Task ##{id} not found."}
    end
  end

  defp do_delete(_table, _params), do: {:error, "Delete requires an 'id' field."}

  # -- Payload helpers --

  defp tasks_payload(action, tasks, extras) do
    counts =
      Enum.reduce(tasks, %{"open" => 0, "in_progress" => 0, "done" => 0, "blocked" => 0}, fn t,
                                                                                             acc ->
        Map.update(acc, t.status, 1, &(&1 + 1))
      end)

    tree? = Map.get(extras, :tree, false)

    payload = %{
      kind: "tasks",
      action: action,
      tasks: Enum.map(tasks, &task_to_wire_map(&1, tree?)),
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

  @spec task_to_wire_map(map(), boolean()) :: map()
  defp task_to_wire_map(task, tree?) do
    base = %{
      id: task.id,
      label: task.label,
      status: task.status,
      done: task.status == "done",
      parent_id: Map.get(task, :parent_id),
      prompt: Map.get(task, :prompt),
      result: Map.get(task, :result),
      notes: Map.get(task, :notes, ""),
      blocked_by: parse_blocked_by_strings(Map.get(task, :blocked_by)),
      created_at: task.created_at,
      updated_at: task.updated_at
    }

    if tree?, do: Map.put(base, :depth, Map.get(task, :depth, 0)), else: base
  end

  # -- Parsing helpers --

  @spec parse_blocked_by(String.t() | nil) :: [integer()]
  defp parse_blocked_by(nil), do: []
  defp parse_blocked_by(""), do: []

  defp parse_blocked_by(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_blocked_by(_), do: []

  @spec parse_blocked_by_strings(String.t() | nil) :: [String.t()]
  defp parse_blocked_by_strings(nil), do: []
  defp parse_blocked_by_strings(""), do: []

  defp parse_blocked_by_strings(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_blocked_by_strings(_), do: []

  @spec parse_int(term()) :: integer() | nil
  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)
  defp parse_int(_), do: nil

  @spec coerce_int(integer() | String.t()) :: integer()
  defp coerce_int(val) when is_integer(val), do: val
  defp coerce_int(val) when is_binary(val), do: String.to_integer(val)

  defp task_to_string_map(task) do
    Map.new(task, fn {k, v} -> {to_string(k), to_s(v)} end)
  end

  defp to_s(nil), do: ""
  defp to_s(val), do: to_string(val)
end
