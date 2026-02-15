# App Directories

Opal uses two directory hierarchies: a **global data directory** for runtime state and credentials, and **per-project `.opal/` directories** for project configuration (analogous to `.claude/`).

## Directory Layout

```
~/.opal/                          # Global data directory (Opal.Config.data_dir)
├── auth.json                     # GitHub Copilot OAuth tokens
├── settings.json                 # Persistent user preferences
├── node                          # Erlang distribution discovery file
├── sessions/                     # Saved conversation history
│   └── {session_id}.jsonl        # One session per file (JSON Lines)
├── tasks/                        # Per-project task databases (created on first use by tasks tool)
│   └── {project_hash}.dets       # DETS file keyed by working directory
├── skills/                       # Global skill directories (user-created, not auto-created)
└── logs/                         # Reserved for structured logging

{project}/.opal/                  # Per-project configuration (committed to repo)
├── mcp.json                      # MCP server configuration
├── skills/                       # Project-specific skills
│   └── {name}/SKILL.md           # One skill per subdirectory
└── ...                           # Future project-level config

/tmp/opal-shell-{id}.log          # Truncated shell output (ephemeral)
```

## Per-Project Configuration (`{project}/.opal/`)

The `.opal/` directory inside a project is a first-class configuration path — similar to `.claude/`, `.vscode/`, or `.github/`. It's meant to be committed to the repository.

Opal discovers these directories during context and skill walk-up:

| Path | Purpose |
|------|---------|
| `.opal/mcp.json` | MCP server definitions (also checks `.vscode/mcp.json`, `.github/mcp.json`) |
| `.opal/skills/{name}/SKILL.md` | Project-scoped skills with progressive disclosure |
| `.agents/skills/` | Claude-compatible skill path (also discovered) |

Context file discovery (`AGENTS.md`, `OPAL.md`) walks up from the working directory, checking standard locations including `.opal/` and `.agents/` variants. See `Opal.Config.Features` for the full list of discoverable filenames and directories.

## Global Data (`~/.opal/`)

### `auth.json`

GitHub Copilot OAuth credentials. Managed by `Opal.Auth.Copilot`.

```json
{
  "github_token": "ghu_...",
  "copilot_token": "aHR0cHM6Ly9...",
  "expires_at": 1700000000,
  "base_url": "https://api.individual.githubcopilot.com"
}
```

- Written by `Opal.Auth.Copilot.save_token/1` after device-code OAuth or token refresh
- Read by `Opal.Auth.Copilot.get_token/0` on every Copilot API call
- Auto-refreshed 5 minutes before `expires_at`
- Only used by the Copilot provider — the LLM provider uses environment-variable API keys

### `settings.json`

Persistent user preferences. Managed by `Opal.Settings`.

```json
{
  "default_model": "anthropic:claude-sonnet-4-5"
}
```

- Read by `Opal.start_session/1` when no explicit model is passed
- Written by the CLI when the user changes models via `/model` or `/models`
- Merged on write (existing keys are preserved)
- RPC: `settings/get`, `settings/save`

### `node`

Erlang distribution discovery file for remote debugging. Managed by `Opal.Application`.

```
opal_12345
opal
```

- Line 1: Node name
- Line 2: Cookie atom
- Used by `opal --connect <node>` to attach a remote IEx session

### `sessions/`

Conversation history in JSON Lines format. Managed by `Opal.Session`.

Each file is `{session_id}.jsonl`:
- Line 1: Session metadata (`session_id`, `current_id`, `metadata`)
- Lines 2+: One message per line (`role`, `content`, `tool_calls`, `metadata`)

Sessions are written when `auto_save: true` or explicitly via `Opal.Session.save/2`.

### `logs/`

Reserved directory for structured logging output. Created by `Opal.Config.ensure_dirs!/1` but not currently populated.

## Runtime Data (`~/.opal/tasks/`)

### `{project_hash}.dets`

Erlang DETS (Disk Erlang Term Storage) file for the task tracker tool. Managed by `Opal.Tool.Tasks`.

Each working directory gets a unique DETS file named by a SHA-256 hash of the directory path (first 12 chars, URL-safe base64). This keeps runtime data in the global data directory rather than mixing it with project configuration in `{project}/.opal/`.

Each record contains: `id`, `label`, `status`, `priority`, `group_name`, `tags`, `due`, `notes`, `blocked_by`, `created_at`, `updated_at`.

## Temporary Files

### `/tmp/opal-shell-{id}.log`

Full output from shell commands that were truncated (>2000 lines or >50KB). Created by `Opal.Tool.Shell.save_full_output/1`. These are ephemeral and referenced by the LLM for context when output is large.

## Configuration

The root data directory can be overridden at multiple levels:

```elixir
# Application config
config :opal, data_dir: "/custom/path"

# Session override
Opal.start_session(%{data_dir: "/custom/path"})

# Environment variable (via runtime.exs)
config :opal, data_dir: System.get_env("OPAL_DATA_DIR", "~/.opal")
```

`Opal.Config.ensure_dirs!/1` auto-creates `data_dir`, `sessions/`, and `logs/` on session start. The `tasks/` directory is created lazily by `Opal.Tool.Tasks` on first use; `skills/` is scanned if present but must be created manually.

## Source

- `packages/core/lib/opal/config.ex` — Data directory paths and `ensure_dirs!/1`
- `packages/core/lib/opal/auth/copilot.ex` — Copilot token persistence (`save_token/1`, `load_token/0`)
- `packages/core/lib/opal/settings.ex` — User preferences persistence
- `packages/core/lib/opal/session.ex` — Session save/load in JSONL format
- `packages/core/lib/opal/tool/tasks.ex` — DETS-backed task storage
- `packages/core/lib/opal/tool/shell.ex` — Temporary output files
- `packages/core/lib/opal/application.ex` — Node discovery file
