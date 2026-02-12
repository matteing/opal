# `Opal.Tool.Tasks`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/tool/tasks.ex#L1)

Project-scoped task tracker backed by DETS (built into Erlang).

Uses structured JSON parameters — no SQL parsing needed. The LLM
passes action + fields directly. Database stored at `.opal/tasks.dets`.

## Actions

    insert  — create a task (requires label)
    list    — list tasks with optional filters or a named view
    update  — update a task by id
    delete  — delete a task by id

## Fields

    id, label, status (open|done|blocked|in_progress),
    priority (low|medium|high|critical), group_name, tags,
    due (ISO date), notes, blocked_by

# `clear`

```elixir
@spec clear(String.t()) :: :ok
```

Clear all tasks. Called at session start to reset the scratchpad.

# `query_raw`

```elixir
@spec query_raw(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
```

Return active tasks as a list of maps. Used by the RPC layer.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
