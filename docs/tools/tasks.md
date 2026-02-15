# tasks

Persistent task tracker backed by DETS. The LLM uses this to maintain a structured work plan across turns and sessions.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | string | yes | `insert`, `list`, `update`, `delete`, or `batch` |
| `id` | string | no | Task ID (auto-generated for insert) |
| `label` | string | no | Task description |
| `status` | string | no | `open`, `in_progress`, `done`, `blocked` |
| `priority` | string | no | `low`, `medium`, `high`, `critical` |
| `group_name` | string | no | Group/category label |
| `tags` | string | no | Comma-separated tags for filtering |
| `due` | string | no | Due date |
| `notes` | string | no | Additional notes |
| `blocked_by` | string | no | Comma-separated IDs of blocking tasks |

## Actions

- **insert** — Create a task. Auto-generates ID, defaults to `status: "open"`, `priority: "medium"`.
- **list** — Query tasks. Supports named views (`open`, `done`, `blocked`, `overdue`, `high_priority`) or custom filters. Results are sorted by priority.
- **update** — Modify a task by ID. Any settable field can be changed.
- **delete** — Remove a task by ID.
- **batch** — Process an array of operations atomically.

All actions return a structured JSON payload (not ASCII tables) with:

- `kind: "tasks"`
- `action` — action that produced the payload
- `tasks` — full task list snapshot
- `total` and `counts` (`open`, `in_progress`, `done`, `blocked`)
- `changes` — operation-specific changes (insert/update/delete)
- `operations` — per-op batch results (batch only)

## Storage

Tasks are stored in a DETS file at `~/.opal/tasks/<hash>.dets`, where `<hash>` is derived from the working directory so each project gets its own task database. DETS is Erlang's disk-based term storage — tasks survive agent restarts. Each task has `created_at` and `updated_at` timestamps.

## Source

`packages/core/lib/opal/tool/tasks.ex`
