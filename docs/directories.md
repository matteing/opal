# App Directories

Opal uses two directory hierarchies: a **global data directory** for runtime state and credentials, and **project-local config/skill directories** (like `.opal/`, `.agents/`, `.github/`, `.claude/`).

## Directory Layout

```
~/.opal/                          # Global data directory (Opal.Config.data_dir)
├── auth.json                     # GitHub Copilot OAuth tokens
├── settings.json                 # Persistent user preferences
├── node                          # Erlang distribution discovery file
├── sessions/                     # Saved conversation state
│   └── {session_id}.dets         # One session per file (DETS)
├── tasks/                        # Task databases (created on first use by tasks tool)
│   └── {scope_hash}.dets         # DETS file keyed by session_id (or working-dir fallback)
├── skills/                       # Global skill directories (user-created, not auto-created)
└── logs/                         # Reserved for structured logging

{project}/.opal/                  # Per-project configuration (committed to repo)
├── mcp.json                      # MCP server configuration
└── ...                           # Future project-level config

{project}/.{agents,github,claude}/skills/
└── {name}/SKILL.md               # Project-specific skills

{System.tmp_dir!()}/opal-shell/{id}.log  # Truncated shell output (ephemeral)
```

## Per-Project Configuration (`{project}/.opal/`)

The `.opal/` directory inside a project is a first-class configuration path — similar to `.claude/`, `.vscode/`, or `.github/`. It's meant to be committed to the repository.

Opal discovers these directories during context and skill walk-up:

| Path | Purpose |
|------|---------|
| `.opal/mcp.json` | MCP server definitions (also checks `.vscode/mcp.json`, `.github/mcp.json`, `.mcp.json`, `~/.opal/mcp.json`) |
| `.{agents,github,claude}/skills/{name}/SKILL.md` | Project-scoped skills with progressive disclosure |

Context file discovery (`AGENTS.md`, `OPAL.md`) walks up from the working directory, checking standard locations including `.opal/` and `.agents/` variants. See `Opal.Context` (and `Opal.Config.Features` overrides) for the full discovery behavior.

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
opal_12345@hostname
N3Q0N2JfY29va2ll
```

- Line 1: Node name
- Line 2: Cookie atom
- Used by `scripts/inspect.sh` / `mise run inspect` to attach a remote IEx session

### `sessions/`

Conversation state in DETS format. Managed by `Opal.Session`.

Each file is `{session_id}.dets`:
- `:__session_meta__` record with `session_id`, `current_id`, and `metadata`
- One record per message (`{message_id, %Opal.Message{...}}`)

Sessions are written when `auto_save: true` or explicitly via `Opal.Session.save/2`.

### `logs/`

Reserved directory for structured logging output. Created by `Opal.Config.ensure_dirs!/1` but not currently populated.

## Runtime Data (`~/.opal/tasks/`)

### `{scope_hash}.dets`

Erlang DETS (Disk Erlang Term Storage) file for the task tracker tool. Managed by `Opal.Tool.Tasks`.

Each scope key gets a unique DETS file named by a SHA-256 hash (first 12 chars, URL-safe base64). Scope is session ID when available, with working-directory fallback for compatibility. This keeps runtime data in the global data directory rather than mixing it with project configuration in `{project}/.opal/`.

Each record contains: `id`, `label`, `status`, `priority`, `group_name`, `tags`, `due`, `notes`, `blocked_by`, `created_at`, `updated_at`.

## Temporary Files

### `{System.tmp_dir!()}/opal-shell/{id}.log`

Full output from shell commands that were truncated (>2000 lines or >50KB). Created by `Opal.Tool.Shell.save_full_output/1`. These are ephemeral and referenced by the LLM for context when output is large.

## Configuration

The root data directory can be overridden at multiple levels:

```elixir
# Application config
config :opal, data_dir: "/custom/path"

# Session override
Opal.start_session(%{data_dir: "/custom/path"})

# Environment variable (via runtime.exs)
if data_dir = System.get_env("OPAL_DATA_DIR") do
  config :opal, data_dir: data_dir
end
```

`Opal.Config.ensure_dirs!/1` auto-creates `data_dir`, `sessions/`, and `logs/` on session start. The `tasks/` directory is created lazily by `Opal.Tool.Tasks` on first use; `skills/` is scanned if present but must be created manually.

## Source

- `opal/lib/opal/config.ex` — Data directory paths and `ensure_dirs!/1`
- `opal/lib/opal/auth/copilot.ex` — Copilot token persistence (`save_token/1`, `load_token/0`)
- `opal/lib/opal/util/settings.ex` — User preferences persistence
- `opal/lib/opal/session/session.ex` — DETS-backed session persistence
- `opal/lib/opal/tool/tasks.ex` — DETS-backed task storage
- `opal/lib/opal/tool/shell.ex` — Temporary output files
- `opal/lib/opal/application.ex` — Node discovery file
- `opal/lib/opal/context/context.ex` — Context/skills discovery paths
- `opal/lib/opal/mcp/config.ex` — MCP config discovery paths
