# tasks

Persistent task tracker backed by DETS. The LLM uses this to maintain a structured work plan across turns, scoped by `session_id` when available (with working-directory fallback).

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | string | yes | `insert`, `list`, `update`, `delete`, or `batch` |
| `id` | integer | no | Task ID (auto-generated for insert; required for update/delete) |
| `view` | string | no | Named list preset: `open`, `done`, `blocked`, `in_progress`, `overdue`, `high_priority` |
| `label` | string | no | Task description |
| `status` | string | no | `open`, `in_progress`, `done`, `blocked` |
| `priority` | string | no | `low`, `medium`, `high`, `critical` |
| `group_name` | string | no | Group/category label |
| `tags` | string | no | Comma-separated tags for filtering |
| `due` | string | no | Due date |
| `notes` | string | no | Additional notes |
| `blocked_by` | string | no | Comma-separated IDs of blocking tasks |
| `ops` | array | no | Array of operations for `batch` |

## Actions

- **insert** — Create a task. Auto-generates ID, defaults to `status: "open"`, `priority: "medium"`.
- **list** — Query tasks. Supports named views (`open`, `done`, `blocked`, `in_progress`, `overdue`, `high_priority`) or custom filters. Results are sorted by priority.
- **update** — Modify a task by ID. Any settable field can be changed.
- **delete** — Remove a task by ID.
- **batch** — Process an array of operations in one call, with per-operation success/error results.

All actions return a structured JSON payload (not ASCII tables) with:

- `kind: "tasks"`
- `action` — action that produced the payload
- `tasks` — task snapshot for the action (filtered for `list` when `view`/filters are used)
- `total` and `counts` (`open`, `in_progress`, `done`, `blocked`)
- `changes` — operation-specific changes (insert/update/delete)
- `operations` — per-op batch results (batch only)

## Storage

Tasks are stored in a DETS file at `~/.opal/tasks/<hash>.dets`, where `<hash>` is derived from the scope key (`session:<id>` when available, otherwise working directory). DETS is Erlang's disk-based term storage — tasks survive agent restarts. Each task has `created_at` and `updated_at` timestamps.

## Source

`lib/opal/tool/tasks.ex`
