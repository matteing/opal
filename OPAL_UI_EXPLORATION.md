  "system_prompt" => "You are a tester"    # optional: override system prompt
}
```

**Result**:
```json
{
  "response": "final assistant message",
  "tool_calls": [
    {"tool": "read_file", "args": {...}, "result": {...}},
    ...
  ]
}
```

### Task/Planning System

**Tool**: `Opal.Tool.Tasks` (`/opal/lib/opal/tool/tasks.ex`)

**Persistence**: DETS file at `~/.opal/tasks/<hash>.dets` (keyed by session ID, with working-dir fallback)

**Actions** (structured JSON):
- `insert` — create task (requires label)
- `list` — query tasks with filters or named views
- `update` — modify task by ID (bulk update supported)
- `delete` — remove task (bulk delete supported)
- `batch` — execute multiple ops atomically (DAG validation)

**Fields**:
- `id`, `label`, `status` (open|done|blocked|in_progress)
- `parent_id` (for hierarchical breakdown)
- `prompt` (task description), `result` (completion result)
- `notes`, `blocked_by` (comma-separated IDs for DAG dependencies)

**Features**:
- DAG dependency tracking via `blocked_by`
- Auto-unblock dependents when blocker completed
- `view: "ready"` returns tasks with all blockers done
- Hierarchy support via `parent_id`

**System Prompt Integration**: Planning instructions injected into system prompt at session start:
```
For complex multi-step tasks, create a plan document at:
  ~/.opal/sessions/<session_id>/plan.md

Write your plan before starting implementation. Update it as you complete steps.
```

User opens plan with `ctrl+y` in CLI.

### Authentication

**Module**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/auth/auth.ex`

**Probe Function**:
```elixir
Opal.Auth.probe() → %{status: "ready" | "setup_required", provider: "copilot" | nil}
```

**Copilot Token Storage**: `~/.opal/auth.json`
```json
{
  "copilot_token": "...",
  "github_token": "...",
  "expires_at": 1234567890
}
```

**Auto-Refresh**: Token refreshed when < 5 minutes to expiry.

### Configuration/Settings

**Feature Toggles** (`lib/opal/config.ex`):
```elixir
features: %{
  sub_agents: %{enabled: true},
  context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
  skills: %{enabled: true, extra_dirs: []},
  debug: %{enabled: false}
}
```

**Persistent Settings** (`~/.opal/settings.json`):
```json
{
  "default_model": "copilot:claude-sonnet-4"
}
```

**Environment Variables**:
| Variable | Purpose | Default |
|----------|---------|---------|
| `OPAL_DATA_DIR` | User data directory | `~/.opal` |
| `OPAL_SHELL` | Shell for `shell` tool | Auto-detect |
| `OPAL_COPILOT_DOMAIN` | GitHub domain (enterprise) | `github.com` |
| `OPAL_CWD` | Working directory override | — |

---

## 3. Communication Protocol (JSON-RPC 2.0)

**Location**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/rpc/protocol.ex` (927 lines)

### Wire Format

**Newline-delimited JSON over stdin/stdout** (same pattern as LSP)

```json
→ {"jsonrpc":"2.0","method":"session/start","params":{...},"id":1}
← {"jsonrpc":"2.0","result":{...},"id":1}
← {"jsonrpc":"2.0","method":"agent/event","params":{"session_id":"abc123","type":"message_delta","delta":"Hello"}}
```

### Client → Server Methods (RPC Requests)

| Method | Purpose | Params | Result |
|--------|---------|--------|--------|
| `session/start` | Start new agent session | model, system_prompt, working_dir, features, session, session_id | session_id, session_dir, context_files, available_skills, node_name, auth |
| `agent/prompt` | Send user message | session_id, text | queued (bool) |
| `agent/abort` | Cancel current turn | session_id | — |
| `agent/state` | Get agent state | session_id | session_id, status, model, message_count, tools |
| `session/list` | List saved sessions | — | sessions (array) |
| `session/branch` | Branch conversation | session_id, entry_id | — |
| `session/compact` | Compress history | session_id, keep_recent? | — |
| `session/history` | Get message history | session_id, limit? | messages (array) |
| `session/delete` | Delete session | session_id | — |
| `models/list` | List available models | — | models (array of {id, name, provider, supports_thinking}) |
| `model/set` | Switch active model | session_id, model_id, thinking_level? | model |
| `thinking/set` | Change reasoning effort | session_id, level | — |
| `auth/status` | Probe auth readiness | — | authenticated (bool), provider |
| `auth/login` | Start device-code flow | — | user_code, verification_uri, device_code, interval |
| `auth/poll` | Poll for authorization | device_code, interval | token (optional) |
| `auth/set_key` | Save API key | provider_id, api_key | — |
| `tasks/list` | List tracked tasks | session_id, view? | tasks (array) |
| `settings/get` | Get user settings | — | settings (object) |
| `settings/save` | Save settings (merged) | settings (object) | — |
| `opal/config/get` | Get runtime config | session_id | config object |
| `opal/config/set` | Update runtime config | session_id, features?, enabled_tools? | — |
| `opal/ping` | Liveness check | — | — |
| `opal/version` | Get version info | — | version, protocol_version |

### Server → Client Methods (RPC Requests)

The server can issue requests to the client, blocking until response arrives:

| Method | Purpose | Params | Result |
|--------|---------|--------|--------|
| `client/confirm` | Approve tool action | session_id, tool, action_description | action ("allow" \| "deny") |
| `client/input` | Freeform text input | prompt, session_id | text |
| `client/ask_user` | Question w/ choices | question, choices? (array), session_id | answer |

### Server → Client Events (Notifications)

Server streams agent events as notifications on `agent/event`. CLI subscribes automatically when starting a session.

| Event | When | Payload |
|-------|------|---------|
| `agent_start` | Agent begins processing | — |
| `message_start` | New assistant message begins | — |
| `message_delta` | Streaming text token | delta (string) |
| `message_queued` | Prompt queued while busy | text (string) |
| `message_applied` | Queued prompt was applied | — |
| `thinking_start` | Reasoning/thinking begins | — |
| `thinking_delta` | Streaming thinking token | delta (string) |
| `tool_execution_start` | Tool begins running | tool (string), call_id, args (object), meta (string) |
| `tool_execution_end` | Tool finished | tool (string), call_id, result (string), error? (string) |
| `turn_end` | LLM turn complete | — |
| `usage_update` | Live token usage | prompt_tokens, completion_tokens, total_tokens, context_window, current_context_tokens |
| `status_update` | Interim status | message (string), level ("info" \| "success" \| "error") |
| `agent_end` | Agent done, idle | messages, usage |
| `agent_abort` | Agent cancelled | — |
| `agent_recovered` | Agent crashed + restarted | error_message |
| `error` | Something went wrong | message, code? |
| `context_discovered` | Context files found | files (array of paths) |
| `skill_loaded` | Agent skill activated | name, description |
| `sub_agent_event` | Nested event from child agent | inner (event), sub_session_id |

### Protocol Definition Format

Single source of truth in `Opal.RPC.Protocol` — declarative Elixir data structures:

```elixir
@methods [
  %{
    method: "session/start",
    direction: :client_to_server,
    description: "...",
    params: [
      %{name: "model", type: {...}, required: false, description: "..."},
      ...
    ],
    result: [
      %{name: "session_id", type: :string, description: "..."},
      ...
    ]
  },
  ...
]

@events [
  %{type: "message_delta", description: "...", fields: [...]},
  ...
]
```

**Codegen Pipeline**:
1. `opal/lib/opal/rpc/protocol.ex` — source of truth
2. `mix opal.gen.json_schema` → `priv/rpc_schema.json` (JSON Schema export)
3. `scripts/codegen_ts.exs` → `cli/src/sdk/protocol.ts` (TypeScript types)
4. Verify with `--check` flag in CI

---

## 4. Session Management in Depth

### Session Lifecycle

1. **Creation** (`session/start` RPC call)
   - Generate session ID (or resume existing)
   - Resolve model, working directory, config
   - Discover context files (walk-up AGENTS.md, OPAL.md)
   - Discover skills (.claude/skills/, .github/skills/, ~/.opal/skills/)
   - Start `SessionServer` (supervisor)
   - Return session_id, session_dir, context_files, available_skills to client

2. **Persistence** (optional, enabled via `session: true`)
   - `Opal.Session` GenServer maintains ETS tree + DETS file
   - Files in `~/.opal/sessions/<session_id>.dets`
   - Automatically loaded on resume (same session_id)

3. **Branching**
   - `session/branch` RPC moves current_id pointer in ETS tree
   - Subsequent messages grow from new branch point
   - Tree structure preserved for navigation

4. **Compaction** (planned)
   - `session/compact` RPC triggers message history compression
   - Auto-triggered when context window approaches limit

5. **Termination**
   - Session server supervision tree cleaned up
   - Session file persisted (if enabled)
   - Can be resumed via `--session <id>` flag or RPC

### Data Storage

```
~/.opal/
├── auth.json                    # Copilot tokens
├── settings.json                # Default model, preferences
├── sessions/
│   ├── <session_id_1>.dets      # Erlang term storage (messages tree)
│   ├── <session_id_2>.dets
│   └── ...
└── logs/
    └── opal.log
```

---

## 5. Tool System in Detail

### Tool Registration

**Default Tools** (built-in, always available):
```elixir
config :opal,
  default_tools: [
    Opal.Tool.ReadFile,
    Opal.Tool.EditFile,
    Opal.Tool.WriteFile,
    Opal.Tool.Grep,
    Opal.Tool.Shell,
    Opal.Tool.SubAgent,
    Opal.Tool.Tasks,
    Opal.Tool.UseSkill,
    Opal.Tool.AskUser,
    # Opal.Tool.DebugState   # disabled by default
  ]
```

**Custom Tools**: Passed at session start
```elixir
{:ok, agent} = Opal.start_session(%{
  tools: [Opal.Tool.ReadFile, MyApp.CustomSearchTool],
  working_dir: "."
})
```

**Runtime Tool Disabling**: Via RPC or config
```elixir
Opal.Agent.configure(agent, %{enabled_tools: ["read_file", "shell"]})
```

### Tool Execution Context

Each tool receives a context map:
```elixir
%{
  working_dir: String.t(),          # Base directory for file operations
  session_id: String.t(),           # Current session ID
  config: Opal.Config.t(),          # Session configuration
  agent_pid: pid(),                 # Handle to running agent
  agent_state: Opal.Agent.State.t(), # Snapshot of agent state
  call_id: String.t(),              # Unique call identifier
  emit: fun(String.t()),            # Callback for streaming output
}
```

### Tool Invocation Flow

```
1. Agent receives tool_call_done event from provider
2. ToolRunner extracts tool calls from response
3. For each tool call:
   a. Look up module by name in tools registry
   b. Extract call arguments
   c. Start Task via Task.Supervisor.async_nolink
   d. Task calls module.execute(args, context)
4. On task completion:
   a. Result received as :info message
   b. Converted to tool_result message
   c. Agent continues to next turn (streaming + next tool batch)
5. All tool results appended as single assistant turn
```

### Hashline System

**Purpose**: Enable safe, content-independent line editing via hash anchors

**Algorithm**:
1. Read file, compute SHA256 hash for each line
2. Output format: `#123456# content` (6-char hash prefix)
3. `edit_file` uses hash anchors to locate lines (content-independent)
4. Fixes references if surrounding context shifts

**Used by**: `read_file`, `grep` (output), `edit_file` (input), `write_file` (can produce hashline output)

---

## 6. Provider System in Detail

### Copilot Provider Implementation

**File**: `opal/lib/opal/provider/copilot.ex`

**Streaming via SSE**: Two API variants (auto-detected):

**Chat Completions** (most models):
```json
{"choices": [{"delta": {"content": "Hello"}}]}
{"choices": [{"delta": {"tool_calls": [{"function": {...}}]}}]}
{"usage": {"prompt_tokens": 1500, "completion_tokens": 200}}
```

**Responses API** (GPT-5 family):
```json
{"type": "response.output_text.delta", "delta": "Hello"}
{"type": "response.function_call_arguments.delta", "delta": "{\"path"}
{"type": "response.completed", "response": {"usage": {"input_tokens": 1500}}}
```

### Model Discovery (LLMDB)

**Registry** (`opal/lib/opal/provider/registry.ex`):
```elixir
Opal.Provider.Registry.list_copilot()
#=> [%{id: "claude-opus-4.6", name: "Claude Opus 4.6", supports_thinking: true}, ...]

Opal.Provider.Registry.context_window(model)
#=> 128_000

Opal.Provider.Registry.resolve(model)
#=> {:ok, %LLMDB.Model{limits: %{context: 128_000}, ...}}
```

### Provider Behaviour

```elixir
@callback stream(model, messages, tools, opts) :: {:ok, Req.Response.t()} | {:error, term()}
@callback parse_stream_event(String.t()) :: [stream_event()]
@callback convert_messages(model, [Opal.Message.t()]) :: [map()]
@callback convert_tools([module()]) :: [map()]
```

### Adding a Custom Provider

1. Create module with `use Opal.Provider, name: :my_provider`
2. Implement `stream/4` to return `{:ok, %Req.Response{}}` with SSE
3. Implement `parse_stream_event/1` to normalize API events
4. Implement `convert_messages/2` and `convert_tools/1` for wire format
5. Pass in config: `Opal.start_session(%{provider: MyProvider})`

**Helpers for OpenAI-compatible APIs**:
- `parse_chat_event/1` — SSE parsing
- `convert_messages_openai/2` — message conversion
- `reasoning_effort/1` — thinking level mapping

---

## 7. Sub-Agent System

### Spawning Sub-Agents

**Tool**: `sub_agent`

**Parameters**:
```json
{
  "prompt": "Refactor the auth module",
  "tools": ["read_file", "edit_file"],      # optional: subset
  "model": "claude-haiku-3-5",              # optional: override
  "system_prompt": "Focus on security"      # optional: override
}
```

**Result**:
```json
{
  "response": "I refactored the module to use stateless tokens...",
  "tool_calls": [
    {"tool": "read_file", "args": {...}, "result": {...}},
    {"tool": "edit_file", "args": {...}, "result": {...}}
  ]
}
```

### Supervision & Isolation

- Each sub-agent is an OTP process under a `DynamicSupervisor` (per-session)
- Depth-limited to 1 level (sub_agent tool excluded from sub-agent's tools)
- If sub-agent crashes, parent continues (supervision catches it)
- Sub-agent events forwarded to parent session for observability

### Event Forwarding

Sub-agent events wrapped in `subAgentEvent` envelope:
```json
{
  "type": "sub_agent_event",
  "subSessionId": "sub-abc123",
  "inner": {
    "type": "message_delta",
    "delta": "Refactoring..."
  }
}
```

CLI normalizes these, routes inner event to correct agent in `agents` map.

---

## 8. Task/Planning System

### Task Tracker (DETS-Backed)

**Tool**: `tasks`

**DETS File Location**: `~/.opal/tasks/<hash>.dets` (session_id keyed, working_dir fallback)

**Actions**:
```json
{
  "action": "insert",
  "label": "Fix parser",
  "parent_id": 1,
  "blocked_by": "2,3",
  "prompt": "The parser crashes on nested functions"
}
```

### Planning Integration

**System Prompt Injection** (session start):
```
For complex multi-step tasks, create a plan document at:
  ~/.opal/sessions/<session_id>/plan.md

Write your plan before starting implementation.
```

**User Access** (`ctrl+y`):
- CLI opens plan.md in `$VISUAL` / `$EDITOR` / platform default
- Agent reads updated plan via `read_file`
- Fully real-time, file-based (no schema)

---

## 9. Authentication

### Device-Code Flow (Copilot)

1. **Initiate**: `auth/login` RPC
   - POST to GitHub's device-code endpoint
   - Returns: `user_code`, `device_code`, `verification_uri`, `interval`

2. **User Authorizes**: Open `verification_uri`, enter `user_code`

3. **Poll**: `auth/poll` RPC (called every `interval` seconds)
   - Poll GitHub until token available or request expires

4. **Exchange**: GitHub token → Copilot API token via `exchange_copilot_token/1`

5. **Persist**: Token stored in `~/.opal/auth.json`

6. **Refresh**: Auto-refresh when < 5 minutes to expiry

### Token Storage

```json
{
  "copilot_token": "ghp_...",
  "github_token": "ghu_...",
  "expires_at": 1234567890
}
```

---

## 10. Configuration/Settings

### Feature Toggles

```elixir
config :opal,
  features: %{
    sub_agents: %{enabled: true},
    context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
    skills: %{enabled: true, extra_dirs: []},
    debug: %{enabled: false}
  }
```

### Runtime Configuration

Via RPC (`opal/config/set`):
```json
{
  "session_id": "abc123",
  "features": {"sub_agents": true, "skills": false},
  "enabled_tools": ["read_file", "grep", "shell"]
}
```

### Settings Persistence

**File**: `~/.opal/settings.json`

```json
{
  "default_model": "copilot:claude-sonnet-4"
}
```

**API**:
- `settings/get` — read all settings
- `settings/save` — merge settings

---

## Architecture Highlights

### 1. OTP-First Design

- **Supervision Trees**: Process lifecycle management, automatic restart, cleanup
- **Message Passing**: Erlang mailboxes for queuing, event pub/sub via `Registry`
- **State Machines**: `:gen_statem` for explicit agent loop lifecycle
- **Concurrency**: `Task.Supervisor` for parallel tool execution, no thread pools

### 2. Event System

**Registry-Based Pub/Sub** (`Opal.Events`):
- Multiple subscribers to single session ID
- Broadcast to all subscribers + wildcard `:all` subscribers
- Message format: `{:opal_event, session_id, event}`

**Event Types**:
- Agent lifecycle events (start, end, abort)
- Streaming deltas (text, thinking)
- Tool execution (start, end)
- Usage updates
- Sub-agent events (nested)

### 3. Resilience Patterns

- **Retry with Backoff** (`Opal.Agent.Retry`): Exponential backoff on transient errors
- **Context Overflow Recovery** (`Opal.Agent.Overflow`): Auto-compaction when approaching window limit
- **Stream Stall Detection**: 10-second timeout, broadcasts stall notification
- **Task Crash Isolation**: Tools run in separate supervised tasks; crash doesn't crash agent

### 4. Streaming Architecture

- Provider streams SSE via `Req.Response` (async body)
- Agent checks mailbox between chunks
- Chunks parsed to semantic events (provider-agnostic)
- Stream state accumulated (text, tool calls, thinking)
- Terminal event triggers response finalization

### 5. CLI-Server Communication

- **Transport**: stdin/stdout newline-delimited JSON-RPC 2.0
- **Bidirectional**: Client → Server (requests), Server → Client (notifications + requests)
- **Server→Client Requests**: Used for user confirmations, input solicitation
- **Streaming**: Events batched & coalesced (32ms window) to avoid excessive re-renders

---

## Key Files Reference

### Elixir Backend
| File | Lines | Purpose |
|------|-------|---------|
| `opal/lib/opal.ex` | 275 | Main public API |
| `opal/lib/opal/agent/agent.ex` | 631 | :gen_statem loop |
| `opal/lib/opal/rpc/protocol.ex` | 927 | Protocol definitions (source of truth) |
| `opal/lib/opal/rpc/server.ex` | 200+ | Stdio transport + dispatch |
| `opal/lib/opal/session/session.ex` | 100+ | Session tree + persistence |
| `opal/lib/opal/session/server.ex` | 150+ | Per-session supervision tree |
| `opal/lib/opal/tool/sub_agent.ex` | 200+ | Sub-agent spawning |
| `opal/lib/opal/tool/tasks.ex` | 300+ | Task tracker |
| `opal/lib/opal/provider/copilot.ex` | 400+ | Copilot implementation |
| `opal/lib/opal/auth/copilot.ex` | 150+ | Device-code OAuth |
| `opal/lib/opal/events.ex` | 84 | Pub/sub registry |

### TypeScript CLI
| File | Purpose |
|------|---------|
| `cli/src/bin.ts` | Entry point, CLI arg parsing (yargs) |
| `cli/src/app.tsx` | Main Ink layout (1 KB) |
| `cli/src/commands/tui.ts` | Terminal prep + render launch |
| `cli/src/state/store.ts` | Zustand store (80 lines) |
| `cli/src/state/timeline.ts` | Event reducer + agents map |
| `cli/src/state/session.ts` | SDK connection lifecycle |
| `cli/src/sdk/session.ts` | High-level Session API |
| `cli/src/sdk/client.ts` | Typed JSON-RPC client |
| `cli/src/sdk/protocol.ts` | Auto-generated types |
| `cli/src/sdk/transport/stdio.ts` | Stdio transport (spawn server) |

### Documentation
| File | Topic |
|------|-------|
| `docs/cli.md` | CLI architecture & components |
| `docs/sdk.md` | TypeScript SDK usage |
| `docs/rpc.md` | JSON-RPC protocol spec |
| `docs/agent-loop.md` | Agent state machine FSM |
| `docs/providers.md` | Provider behaviour & Copilot details |
| `docs/installing.md` | Installation & authentication setup |
| `docs/planning.md` | Plan documents & Ctrl+Y editor |
| `docs/state.md` | CLI state management (Zustand) |
| `docs/tools.md` | Built-in tools reference |

---

## Development Workflow

### Build & Run
```bash
cd /Users/sergio/Projects/2026/opal

# Install dependencies
mise run deps

# Run TUI in dev mode
mise run dev

# Run with debug feature/tools enabled
mise run dev -- --debug

# Run tests
mise run test

# Lint & format
mise run lint && mise run format

# Connect via iex to running dev instance
mise run inspect
```

### Protocol Codegen
```bash
cd opal
mix opal.gen.json_schema   # → priv/rpc_schema.json
mix run ../scripts/codegen_ts.exs  # → cli/src/sdk/protocol.ts
mix run ../scripts/codegen_ts.exs --check  # Verify in CI
```

---

## Conclusion

**Opal** is a production-ready agentic harness that leverages Erlang/OTP's process model, supervision trees, and message passing to build a reliable, observable agent system. The clean separation between the Elixir backend (agent loop, tools, providers), the JSON-RPC transport (decoupled server communication), and the TypeScript frontend (reactive CLI) makes it easy to extend and embed in other contexts.

The architecture shines in:
1. **Concurrency**: Cheap OTP processes for sub-agents and tools
2. **Observability**: Live event streaming, debugging via `iex`, JSON-RPC introspection
3. **Resilience**: Supervision strategies, retry policies, overflow recovery
4. **Extensibility**: Custom tools, providers, middleware via Elixir config
5. **User Experience**: Real-time streaming, multi-agent UI, keyboard shortcuts

For a UI app specification, the key integration points are:
- **RPC Protocol** (`opal/config/get`, `opal/config/set`) for runtime feature toggles
- **Event Stream** (`agent/event` notifications) for timeline rendering
- **Session API** (create, branch, compact, resume) for conversation management
- **Model & Auth APIs** for interactive LLM selection and provider setup

EOF
cat /tmp/opal_exploration.md

                EC=$?
                echo "___BEGIN___COMMAND_DONE_MARKER___$EC"
            }
___BEGIN___COMMAND_OUTPUT_MARKER___
# Opal Project - Comprehensive Exploration Report

## Executive Summary

**Opal** is a sophisticated, multi-layered agent harness built on Elixir/OTP with a TypeScript Ink/React CLI frontend. It's designed as both a **standalone CLI tool** for interactive coding tasks and a **library** that can be embedded in Elixir applications. The architecture emphasizes resilience, concurrency, and observability through OTP primitives.

### Key Characteristics
- **Elixir Backend**: Core agent loop runs as an OTP state machine with supervised processes
- **TypeScript CLI**: React/Ink terminal UI communicates via JSON-RPC over stdio
- **Multi-layered Communication**: High-level Elixir SDK → OTP message passing → JSON-RPC/stdio → TypeScript client
- **Provider-Agnostic**: Currently supports GitHub Copilot (which proxies Claude, GPT, Gemini, Grok)
- **Research-Driven**: Implements latest agent patterns (extended thinking, auto-compaction, sub-agent parallelization)

---

## 1. CLI Features (TypeScript/Ink React TUI)

**Location**: `/Users/sergio/Projects/2026/opal/cli/`

### Architecture Overview
```
bin.ts (CLI entry point, yargs arg parsing)
  ↓
commands/tui.ts (Terminal prep + Ink render)
  ↓
app.tsx (Main layout)
  ↓
views/ (StartingView, AuthView, OpalView)
  ↓
components/ (React/Ink UI widgets)
  ↓
state/ (Zustand store with 5 slices)
  ↓
sdk/ (TypeScript JSON-RPC client)
  ↓
opal-server (Elixir subprocess via stdio)
```

### User-Facing Features

#### 1. **Interactive Prompt Input**
- Bottom-bar text input with multi-line support (`ctrl+j` for newline)
- Keyboard navigation for confirmations and picker selections
- History stack (implied via session resumption)

#### 2. **Model Selection & Switching**
- `/models` command opens interactive picker
- `/model <id>` quick switch
- Model metadata from LLMDB (context windows, thinking support, deprecation)
- Per-session model persistence

#### 3. **Timeline Rendering**
- Streaming message deltas rendered in real-time
- Tool execution tracking with spinner + result display
- Thinking/reasoning block visualization (with kaomoji spinner)
- Context discovery & skill loading notifications
- Sub-agent events nested hierarchically

#### 4. **Authentication**
- Device-code OAuth flow for GitHub Copilot
- API key fallback for other providers
- Stored in `~/.opal/auth.json` with auto-refresh (5-minute buffer)

#### 5. **Session Management**
- Session persistence across restarts
- `opal session list` — list saved sessions
- `opal session show <id>` — view session data
- `opal session delete <id>` — remove session
- `--session, -s <id>` flag to resume a session
- Session files stored as DETS (Erlang term storage) in `~/.opal/sessions/`

#### 6. **Advanced Interactions**
- **Tool Approval Dialog** — confirm/deny tool execution with `y`/`n` shortcuts
- **Ask User Dialog** — agent questions with optional multiple-choice answers
- **Slash Commands**: 
  - `/help` — show available commands
  - `/model` — show current model
  - `/models` — open model picker
  - `/compact` — trigger conversation compaction
  - `/agents` — list active sub-agents
  - `/agents <n|main>` — switch to sub-agent view
  - `/opal` — open runtime config menu (toggle Sub-agents, Skills, Debug)
  - `/debug` — toggle JSON-RPC debug panel

#### 7. **Keyboard Shortcuts**
| Key | Context | Action |
|-----|---------|--------|
| `ctrl+c` | Running | Abort agent |
| `ctrl+c` | Idle | Exit CLI |
| `ctrl+o` | Any | Toggle tool output visibility |
| `ctrl+y` | Any | Open plan in external editor |
| `ctrl+j` | Input | Insert newline |
| `↑` `↓` | Picker | Navigate options |

#### 8. **Visibility & Debugging**
- Tool output visibility toggle (`ctrl+o`)
- RPC message debug panel (`/debug`)
- Stderr capture & display
- Status bar showing: model, token usage, session directory
- Welcome animation on startup

### UI Component Library

| Component | Path | Purpose |
|-----------|------|---------|
| `header.tsx` | Working directory and Erlang node name display |
| `timeline-*.tsx` | Entry rendering (messages, tools, thinking, status, context, skills) |
| `message-list.tsx` | Sliding window renderer (performance optimization for large histories) |
| `thinking.tsx` | Animated kaomoji spinner with status label |
| `bottom-bar.tsx` | Input field, help shortcuts, model/token display |
| `confirm-dialog.tsx` | Tool execution approval modal |
| `ask-user-dialog.tsx` | Agent question dialog with optional choices |
| `model-picker.tsx` | Interactive model/thinking selector |
| `device-auth.tsx` | Device-code OAuth + API key setup wizard |
| `shimmer-text.tsx` | Animated iridescent loading text |
| `help-menu.tsx` | Overlay with keyboard shortcuts and commands |
| `opal-menu.tsx` | Runtime feature/tool toggles |
| `rpc-panel.tsx` | JSON-RPC traffic debug viewer |
| `welcome.tsx` | Animated iridescent opal gem startup animation |

### CLI Arguments
```bash
opal [prompt] [options]
  --model <provider/id>      Model to use (e.g., copilot/claude-sonnet-4)
  --working-dir, -C          Working directory (default: $OPAL_CWD → $INIT_CWD → cwd)
  --session, -s <id>         Resume a session by ID
  --auto-confirm             Auto-confirm all tool executions (no approval dialogs)
  --debug                    Enable debug tools (debug_state tool, introspection)
  --expose <name[#cookie]>   Expose for remote debugging (Erlang distribution)
  --no-tui                   Headless mode: print response to stdout, exit
  --verbose, -v              Pipe server stderr to terminal
  --version                  Print version information
  --help, -h                 Show usage

opal auth <login|status>     Authentication commands
opal session <list|show|delete> [id]   Session management
opal doctor                  Diagnostic check
```

### State Management

**Technology**: Zustand store with 5 independent slices

| Slice | File | State | Actions |
|-------|------|-------|---------|
| **Session** | `session.ts` | SDK connection, session lifecycle, event batching | `connect()`, `disconnect()` |
| **Timeline** | `timeline.ts` | Agents map, focus stack, entry history | `applyEvents()`, `focusAgent()`, `focusBack()` |
| **Models** | `models.ts` | Available models, current selection | `selectModel()`, `setThinking()` |
| **Auth** | `auth.ts` | Copilot auth state machine | `startDeviceFlow()`, `pollForToken()` |
| **Debug** | `debug.ts` | RPC message log (200 entries), stderr (50 lines) | Ring buffers, selectors |

**Key Design**: All agents (root + sub-agents) normalized in single `agents: Record<string, AgentView>` map. Components use `useActiveAgent()` selector to read from focused agent.

---

## 2. Opal SDK/Engine (Elixir Backend)

**Location**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/`

### Core Module Structure

```
opal/lib/opal/
├── opal.ex                          # Main public API (start_session, stream, prompt, etc.)
├── application.ex                   # OTP application supervision tree
├── config.ex                        # Configuration management
├── events.ex                        # Registry-based pub/sub for events
├── id.ex                            # ID generation utilities
├── message.ex                       # Message struct (user/assistant/system/repair)
│
├── agent/
│   ├── agent.ex                     # :gen_statem loop (631 lines)
│   ├── state.ex                     # Runtime state struct
│   ├── stream.ex                    # Provider event parsing
│   ├── tool_runner.ex               # Concurrent tool execution orchestration
│   ├── emitter.ex                   # Event broadcasting
│   ├── collector.ex                 # Response collection helper
│   ├── spawner.ex                   # Sub-agent creation
│   ├── token.ex                     # Token utility functions
│   ├── usage_tracker.ex             # Token usage tracking
│   ├── overflow.ex                  # Context window overflow handling
│   ├── repair.ex                    # Message repair and formatting
│   ├── retry.ex                     # Retry policy & backoff classification
│   └── system_prompt.ex             # System prompt assembly
│
├── session/
│   ├── session.ex                   # Conversation tree with branching (ETS + DETS persistence)
│   ├── server.ex                    # Per-session supervisor (process tree)
│   └── compaction.ex                # Message history compression
│
├── tool/
│   ├── tool.ex                      # Tool behaviour definition
│   ├── read_file.ex                 # File reading with hashline output
│   ├── edit_file.ex                 # Hash-anchored line editing
│   ├── write_file.ex                # File creation/overwrite
│   ├── grep.ex                      # Cross-platform regex search
│   ├── shell.ex                     # Shell command execution with streaming
│   ├── sub_agent.ex                 # Sub-agent spawning tool
│   ├── tasks.ex                     # DAG-aware task tracker (DETS-backed)
│   ├── use_skill.ex                 # Progressive skill loading
│   ├── ask_user.ex                  # User input solicitation
│   ├── debug_state.ex               # Runtime introspection tool
│   └── args.ex                      # Argument validation helper
│
├── provider/
│   ├── provider.ex                  # Provider behaviour + shared helpers
│   ├── copilot.ex                   # GitHub Copilot implementation (SSE)
│   ├── model.ex                     # Model struct with parsing utilities
│   └── registry.ex                  # LLMDB-backed model discovery
│
├── auth/
│   ├── auth.ex                      # Copilot credential probing
│   └── copilot.ex                   # Device-code OAuth + token management
│
├── rpc/
│   ├── rpc.ex                       # JSON-RPC encode/decode helpers
│   ├── protocol.ex                  # Declarative method/event definitions (927 lines)
│   └── server.ex                    # Stdio transport + dispatch
│
├── util/
│   ├── file_io.ex                   # BOM/CRLF handling, path utilities
│   ├── hashline.ex                  # Hash computation for line anchoring
│   ├── gitignore.ex                 # .gitignore matching
│   ├── platform.ex                  # Cross-platform detection
│   ├── registry.ex                  # Utility registry wrapper
│   ├── settings.ex                  # User settings persistence
│   ├── json.ex                      # JSON utilities
│   ├── text.ex                      # Text processing
│   ├── path.ex                      # Path manipulation
│   ├── error.ex                     # Error formatting
│   ├── inspect.ex                   # Debug introspection
│   ├── map.ex                       # Map utilities
│   └── number.ex                    # Number formatting
└── shell/
    └── process.ex                   # Shell process management
```

### Agent Loop (`:gen_statem`)

**File**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/agent/agent.ex` (631 lines)

#### State Machine States

```
                ┌──────┐
           ┌───►│ idle │
           │    └──────┘
           │       ▲
     prompt│       │ agent_end / abort
           │       │
        ┌──┴──┐    │
        │   running ├─────────────┐
        └──┬──┘     │             │
        retry│      │ stream      │ tool calls
             │      ▼             ▼
           ┌──────────┐       ┌──────────────────┐
           │streaming │       │executing_tools   │
           └──┬───────┘       └──┬───────────────┘
              │                  │
              └──────────┬───────┘
                         │
                    finalize
                         │
                    next_turn ──┐
                                │
                         return to running
```

**Four Primary States:**

1. **`:idle`** — Waiting for user prompt
   - Accepts `prompt()` calls → transitions to `:running`
   - Queues prompts while not idle
   - Processes calls: `get_state`, `set_model`, `configure`

2. **`:running`** — Preparing context, about to call provider or retrying
   - `run_turn/1` builds messages, applies compaction
   - Resolves active tools (feature-gated + disabled list)
   - Initiates streaming through configured provider
   - Transition to `:streaming`

3. **`:streaming`** — Processing LLM response chunks (SSE)
   - Receives HTTP chunks via `Req.parse_message/2`
   - Passes each JSON line to `provider.parse_stream_event/1`
   - `Opal.Agent.Stream` normalizes events (`:text_delta`, `:tool_call_done`, `:usage`, `:response_done`)
   - Accumulates response text, tool calls, thinking
   - Stall detection (10s timeout) with broadcast
   - On `:done`, transitions to `:running` and finalizes response

4. **`:executing_tools`** — Running tool calls concurrently
   - Tool calls started via `Task.Supervisor.async_nolink` (concurrent, safe crash)
   - Results received as `:info` messages and correlated by ref
   - `Opal.Agent.ToolRunner` orchestrates execution, context building
   - On batch completion, transitions back to `:running` for next turn

#### Key Concepts

**Message Queuing**: When the agent is busy (not `:idle`), prompts from `prompt/2` calls are stored in `pending_messages` and applied between tool calls — this enables mid-flight steering without blocking.

**Tool Execution**: Concurrent, supervised via `Task.Supervisor` (per-session). Tools receive context map with `working_dir`, `session_id`, `config`, `agent_pid`, and can emit streaming output via `emit` callback.

**Streaming**: All providers return Server-Sent Events (SSE) via `Req.Response` with async body. Agent checks its mailbox between events for stall detection and new prompts.

**Resilience**: 
- `Opal.Agent.Retry` classifies errors and schedules exponential backoff
- `Opal.Agent.Overflow` handles context window overflow with auto-compaction
- `Opal.Agent.Repair` applies message repair and formatting

#### Provider Abstraction

All providers (currently only Copilot) implement:
- `stream/4` — initiates SSE request, returns `{:ok, %Req.Response{}}`
- `parse_stream_event/1` — normalizes SSE JSON lines to semantic events
- `convert_messages/2` — translates `Opal.Message` to provider wire format
- `convert_tools/1` — translates tool modules to provider's function-calling schema

**Semantic Event Vocabulary**:
```
{:text_start, %{}}
{:text_delta, "Hello"}
{:thinking_start, %{}}
{:thinking_delta, "..."}
{:tool_call_start, %{call_id, name}}
{:tool_call_delta, json_fragment}
{:tool_call_done, %{arguments: map}}
{:response_done, %{usage: ...}}
{:usage, %{...}}
{:error, reason}
```

### Session Management

**File**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/session/session.ex`

**Persistence Architecture**:
- Conversation tree stored in **ETS table** (in-memory) keyed by message ID
- Messages linked via `parent_id` into a tree structure
- `current_id` pointer tracks the active leaf
- **Branching** moves pointer; subsequent appends grow from new position
- **DETS persistence** writes Erlang terms directly to disk (zero serialization overhead)
- Files: `~/.opal/sessions/<session_id>.dets`

**API**:
```elixir
Opal.Session.append(session, message)           # Add message to current leaf
Opal.Session.append_many(session, messages)     # Chain multiple messages
Opal.Session.get_path(session)                  # Path from root to current leaf
Opal.Session.get_tree(session)                  # Full tree structure
Opal.Session.branch(session, message_id)        # Create branch point
Opal.Session.current_id(session)                # Current leaf ID
Opal.Session.all_messages(session)              # All messages (unordered)
```

**Supervision**: Per-session supervision tree in `SessionServer`:

```
SessionServer (Supervisor, :rest_for_one)
├── Task.Supervisor              — per-session tool execution
├── DynamicSupervisor            — per-session sub-agents
├── Opal.Session                 — conversation persistence (optional)
└── Opal.Agent                   — the agent loop
```

### Tool System

**Behaviour Definition** (`lib/opal/tool/tool.ex`):
```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()                   # JSON Schema
@callback execute(map(), context_map) :: {:ok, String.t()} | {:error, String.t()} | {:effect, term()}
@callback description(tool_context()) :: String.t()  # optional (context-aware)
@callback meta(map()) :: String.t()               # optional (call-specific label)
```

**Built-in Tools** (10 tools):

| Tool | Module | Description | Streaming? |
|------|--------|-------------|-----------|
| `read_file` | `Opal.Tool.ReadFile` | Read with hashline-tagged output (for edit anchoring) | No |
| `edit_file` | `Opal.Tool.EditFile` | Hash-anchored line editing (replace, insert, delete) | No |
| `write_file` | `Opal.Tool.WriteFile` | Create or overwrite files (with encoding preservation) | No |
| `grep` | `Opal.Tool.Grep` | Cross-platform regex search with context + glob filtering | No |
| `shell` | `Opal.Tool.Shell` | Execute shell commands with streaming output (tail-truncation) | **Yes** |
| `sub_agent` | `Opal.Tool.SubAgent` | Spawn parallel child agents (depth-limited to 1 level) | **Yes** (nested) |
| `tasks` | `Opal.Tool.Tasks` | DAG-aware task tracker (DETS-backed, supports dependencies) | No |
| `use_skill` | `Opal.Tool.UseSkill` | Progressive skill loading from `.claude/skills/` | No |
| `ask_user` | `Opal.Tool.AskUser` | User question solicitation (freeform or multiple-choice) | No |
| `debug_state` | `Opal.Tool.DebugState` | Runtime introspection (disabled by default) | No |

**Tool Encoding Layer**: `Opal.FileIO` handles:
- **UTF-8 BOM** detection/removal before processing, restoration after edits
- **CRLF line endings** normalization to LF for processing, restoration after edits

**Shared by**: `ReadFile`, `EditFile`, `WriteFile`, `Grep`

### Provider System

**Currently Supported**: GitHub Copilot (proxies Claude, GPT, Gemini, Grok)

**Location**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/provider/copilot.ex`

**Two API Variants** (auto-detected):
- **Chat Completions** — Claude, Gemini, GPT-4o, Grok → `/chat/completions`
- **Responses API** — GPT-5 family → `/responses`

**Model Discovery**: LLMDB integration for:
- Context window lookup
- Capability metadata (thinking support, deprecation status)
- Model naming (handles Copilot's dots-vs-dashes quirk)

**Authentication**: Device-code OAuth flow stored in `~/.opal/auth.json`
1. `start_device_flow()` → user code + verification URL
2. User authorizes → GitHub token
3. `poll_for_token()` → wait for authorization
4. `exchange_copilot_token()` → GitHub token → Copilot API token
5. Auto-refresh with 5-minute buffer before expiry

### Sub-Agent System

**Tool**: `Opal.Tool.SubAgent` (`/opal/lib/opal/tool/sub_agent.ex`)

**Features**:
- Spawns child agents as cheap OTP processes
- Each sub-agent has its own conversation loop, tool set, and model
- Depth-limited to 1 level (sub_agent tool not included in sub-agent's tools)
- Can override parent's tools or inherit all (minus sub_agent)
- Parent can override model, system prompt for child
- Child events forwarded to parent session for real-time observability
- Results include full response + structured log of tool calls made

**Invocation**:
```elixir
%{
  "prompt" => "task description",
  "tools" => ["read_file", "grep"],        # optional: subset of parent's tools
  "model" => "claude-haiku-3-5",           # optional: override model
  "system_prompt" => "You are a tester"    # optional: override system prompt
}
```

**Result**:
```json
{
  "response": "final assistant message",
  "tool_calls": [
    {"tool": "read_file", "args": {...}, "result": {...}},
    ...
  ]
}
```

### Task/Planning System

**Tool**: `Opal.Tool.Tasks` (`/opal/lib/opal/tool/tasks.ex`)

**Persistence**: DETS file at `~/.opal/tasks/<hash>.dets` (keyed by session ID, with working-dir fallback)

**Actions** (structured JSON):
- `insert` — create task (requires label)
- `list` — query tasks with filters or named views
- `update` — modify task by ID (bulk update supported)
- `delete` — remove task (bulk delete supported)
- `batch` — execute multiple ops atomically (DAG validation)

**Fields**:
- `id`, `label`, `status` (open|done|blocked|in_progress)
- `parent_id` (for hierarchical breakdown)
- `prompt` (task description), `result` (completion result)
- `notes`, `blocked_by` (comma-separated IDs for DAG dependencies)

**Features**:
- DAG dependency tracking via `blocked_by`
- Auto-unblock dependents when blocker completed
- `view: "ready"` returns tasks with all blockers done
- Hierarchy support via `parent_id`

**System Prompt Integration**: Planning instructions injected into system prompt at session start:
```
For complex multi-step tasks, create a plan document at:
  ~/.opal/sessions/<session_id>/plan.md

Write your plan before starting implementation. Update it as you complete steps.
```

User opens plan with `ctrl+y` in CLI.

### Authentication

**Module**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/auth/auth.ex`

**Probe Function**:
```elixir
Opal.Auth.probe() → %{status: "ready" | "setup_required", provider: "copilot" | nil}
```

**Copilot Token Storage**: `~/.opal/auth.json`
```json
{
  "copilot_token": "...",
  "github_token": "...",
  "expires_at": 1234567890
}
```

**Auto-Refresh**: Token refreshed when < 5 minutes to expiry.

### Configuration/Settings

**Feature Toggles** (`lib/opal/config.ex`):
```elixir
features: %{
  sub_agents: %{enabled: true},
  context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
  skills: %{enabled: true, extra_dirs: []},
  debug: %{enabled: false}
}
```

**Persistent Settings** (`~/.opal/settings.json`):
```json
{
  "default_model": "copilot:claude-sonnet-4"
}
```

**Environment Variables**:
| Variable | Purpose | Default |
|----------|---------|---------|
| `OPAL_DATA_DIR` | User data directory | `~/.opal` |
| `OPAL_SHELL` | Shell for `shell` tool | Auto-detect |
| `OPAL_COPILOT_DOMAIN` | GitHub domain (enterprise) | `github.com` |
| `OPAL_CWD` | Working directory override | — |

---

## 3. Communication Protocol (JSON-RPC 2.0)

**Location**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/rpc/protocol.ex` (927 lines)

### Wire Format

**Newline-delimited JSON over stdin/stdout** (same pattern as LSP)

```json
→ {"jsonrpc":"2.0","method":"session/start","params":{...},"id":1}
← {"jsonrpc":"2.0","result":{...},"id":1}
← {"jsonrpc":"2.0","method":"agent/event","params":{"session_id":"abc123","type":"message_delta","delta":"Hello"}}
```

### Client → Server Methods (RPC Requests)

| Method | Purpose | Params | Result |
|--------|---------|--------|--------|
| `session/start` | Start new agent session | model, system_prompt, working_dir, features, session, session_id | session_id, session_dir, context_files, available_skills, node_name, auth |
| `agent/prompt` | Send user message | session_id, text | queued (bool) |
| `agent/abort` | Cancel current turn | session_id | — |
| `agent/state` | Get agent state | session_id | session_id, status, model, message_count, tools |
| `session/list` | List saved sessions | — | sessions (array) |
| `session/branch` | Branch conversation | session_id, entry_id | — |
| `session/compact` | Compress history | session_id, keep_recent? | — |
| `session/history` | Get message history | session_id, limit? | messages (array) |
| `session/delete` | Delete session | session_id | — |
| `models/list` | List available models | — | models (array of {id, name, provider, supports_thinking}) |
| `model/set` | Switch active model | session_id, model_id, thinking_level? | model |
| `thinking/set` | Change reasoning effort | session_id, level | — |
| `auth/status` | Probe auth readiness | — | authenticated (bool), provider |
| `auth/login` | Start device-code flow | — | user_code, verification_uri, device_code, interval |
| `auth/poll` | Poll for authorization | device_code, interval | token (optional) |
| `auth/set_key` | Save API key | provider_id, api_key | — |
| `tasks/list` | List tracked tasks | session_id, view? | tasks (array) |
| `settings/get` | Get user settings | — | settings (object) |
| `settings/save` | Save settings (merged) | settings (object) | — |
| `opal/config/get` | Get runtime config | session_id | config object |
| `opal/config/set` | Update runtime config | session_id, features?, enabled_tools? | — |
| `opal/ping` | Liveness check | — | — |
| `opal/version` | Get version info | — | version, protocol_version |

### Server → Client Methods (RPC Requests)

The server can issue requests to the client, blocking until response arrives:

| Method | Purpose | Params | Result |
|--------|---------|--------|--------|
| `client/confirm` | Approve tool action | session_id, tool, action_description | action ("allow" \| "deny") |
| `client/input` | Freeform text input | prompt, session_id | text |
| `client/ask_user` | Question w/ choices | question, choices? (array), session_id | answer |

### Server → Client Events (Notifications)

Server streams agent events as notifications on `agent/event`. CLI subscribes automatically when starting a session.

| Event | When | Payload |
|-------|------|---------|
| `agent_start` | Agent begins processing | — |
| `message_start` | New assistant message begins | — |
| `message_delta` | Streaming text token | delta (string) |
| `message_queued` | Prompt queued while busy | text (string) |
| `message_applied` | Queued prompt was applied | — |
| `thinking_start` | Reasoning/thinking begins | — |
| `thinking_delta` | Streaming thinking token | delta (string) |
| `tool_execution_start` | Tool begins running | tool (string), call_id, args (object), meta (string) |
| `tool_execution_end` | Tool finished | tool (string), call_id, result (string), error? (string) |
| `turn_end` | LLM turn complete | — |
| `usage_update` | Live token usage | prompt_tokens, completion_tokens, total_tokens, context_window, current_context_tokens |
| `status_update` | Interim status | message (string), level ("info" \| "success" \| "error") |
| `agent_end` | Agent done, idle | messages, usage |
| `agent_abort` | Agent cancelled | — |
| `agent_recovered` | Agent crashed + restarted | error_message |
| `error` | Something went wrong | message, code? |
| `context_discovered` | Context files found | files (array of paths) |
| `skill_loaded` | Agent skill activated | name, description |
| `sub_agent_event` | Nested event from child agent | inner (event), sub_session_id |

### Protocol Definition Format

Single source of truth in `Opal.RPC.Protocol` — declarative Elixir data structures:

```elixir
@methods [
  %{
    method: "session/start",
    direction: :client_to_server,
    description: "...",
    params: [
      %{name: "model", type: {...}, required: false, description: "..."},
      ...
    ],
    result: [
      %{name: "session_id", type: :string, description: "..."},
      ...
    ]
  },
  ...
]

@events [
  %{type: "message_delta", description: "...", fields: [...]},
  ...
]
```

**Codegen Pipeline**:
1. `opal/lib/opal/rpc/protocol.ex` — source of truth
2. `mix opal.gen.json_schema` → `priv/rpc_schema.json` (JSON Schema export)
3. `scripts/codegen_ts.exs` → `cli/src/sdk/protocol.ts` (TypeScript types)
4. Verify with `--check` flag in CI

---

## 4. Session Management in Depth

### Session Lifecycle

1. **Creation** (`session/start` RPC call)
   - Generate session ID (or resume existing)
   - Resolve model, working directory, config
   - Discover context files (walk-up AGENTS.md, OPAL.md)
   - Discover skills (.claude/skills/, .github/skills/, ~/.opal/skills/)
   - Start `SessionServer` (supervisor)
   - Return session_id, session_dir, context_files, available_skills to client

2. **Persistence** (optional, enabled via `session: true`)
   - `Opal.Session` GenServer maintains ETS tree + DETS file
   - Files in `~/.opal/sessions/<session_id>.dets`
   - Automatically loaded on resume (same session_id)

3. **Branching**
   - `session/branch` RPC moves current_id pointer in ETS tree
   - Subsequent messages grow from new branch point
   - Tree structure preserved for navigation

4. **Compaction** (planned)
   - `session/compact` RPC triggers message history compression
   - Auto-triggered when context window approaches limit

5. **Termination**
   - Session server supervision tree cleaned up
   - Session file persisted (if enabled)
   - Can be resumed via `--session <id>` flag or RPC

### Data Storage

```
~/.opal/
├── auth.json                    # Copilot tokens
├── settings.json                # Default model, preferences
├── sessions/
│   ├── <session_id_1>.dets      # Erlang term storage (messages tree)
│   ├── <session_id_2>.dets
│   └── ...
└── logs/
    └── opal.log
```

---

## 5. Tool System in Detail

### Tool Registration

**Default Tools** (built-in, always available):
```elixir
config :opal,
  default_tools: [
    Opal.Tool.ReadFile,
    Opal.Tool.EditFile,
    Opal.Tool.WriteFile,
    Opal.Tool.Grep,
    Opal.Tool.Shell,
    Opal.Tool.SubAgent,
    Opal.Tool.Tasks,
    Opal.Tool.UseSkill,
    Opal.Tool.AskUser,
    # Opal.Tool.DebugState   # disabled by default
  ]
```

**Custom Tools**: Passed at session start
```elixir
{:ok, agent} = Opal.start_session(%{
  tools: [Opal.Tool.ReadFile, MyApp.CustomSearchTool],
  working_dir: "."
})
```

**Runtime Tool Disabling**: Via RPC or config
```elixir
Opal.Agent.configure(agent, %{enabled_tools: ["read_file", "shell"]})
```

### Tool Execution Context

Each tool receives a context map:
```elixir
%{
  working_dir: String.t(),          # Base directory for file operations
  session_id: String.t(),           # Current session ID
  config: Opal.Config.t(),          # Session configuration
  agent_pid: pid(),                 # Handle to running agent
  agent_state: Opal.Agent.State.t(), # Snapshot of agent state
  call_id: String.t(),              # Unique call identifier
  emit: fun(String.t()),            # Callback for streaming output
}
```

### Tool Invocation Flow

```
1. Agent receives tool_call_done event from provider
2. ToolRunner extracts tool calls from response
3. For each tool call:
   a. Look up module by name in tools registry
   b. Extract call arguments
   c. Start Task via Task.Supervisor.async_nolink
   d. Task calls module.execute(args, context)
4. On task completion:
   a. Result received as :info message
   b. Converted to tool_result message
   c. Agent continues to next turn (streaming + next tool batch)
5. All tool results appended as single assistant turn
```

### Hashline System

**Purpose**: Enable safe, content-independent line editing via hash anchors

**Algorithm**:
1. Read file, compute SHA256 hash for each line
2. Output format: `#123456# content` (6-char hash prefix)
3. `edit_file` uses hash anchors to locate lines (content-independent)
4. Fixes references if surrounding context shifts

**Used by**: `read_file`, `grep` (output), `edit_file` (input), `write_file` (can produce hashline output)

---

## 6. Provider System in Detail

### Copilot Provider Implementation

**File**: `opal/lib/opal/provider/copilot.ex`

**Streaming via SSE**: Two API variants (auto-detected):

**Chat Completions** (most models):
```json
{"choices": [{"delta": {"content": "Hello"}}]}
{"choices": [{"delta": {"tool_calls": [{"function": {...}}]}}]}
{"usage": {"prompt_tokens": 1500, "completion_tokens": 200}}
```

**Responses API** (GPT-5 family):
```json
{"type": "response.output_text.delta", "delta": "Hello"}
{"type": "response.function_call_arguments.delta", "delta": "{\"path"}
{"type": "response.completed", "response": {"usage": {"input_tokens": 1500}}}
```

### Model Discovery (LLMDB)

**Registry** (`opal/lib/opal/provider/registry.ex`):
```elixir
Opal.Provider.Registry.list_copilot()
#=> [%{id: "claude-opus-4.6", name: "Claude Opus 4.6", supports_thinking: true}, ...]

Opal.Provider.Registry.context_window(model)
#=> 128_000

Opal.Provider.Registry.resolve(model)
#=> {:ok, %LLMDB.Model{limits: %{context: 128_000}, ...}}
```

### Provider Behaviour

```elixir
@callback stream(model, messages, tools, opts) :: {:ok, Req.Response.t()} | {:error, term()}
@callback parse_stream_event(String.t()) :: [stream_event()]
@callback convert_messages(model, [Opal.Message.t()]) :: [map()]
@callback convert_tools([module()]) :: [map()]
```

### Adding a Custom Provider

1. Create module with `use Opal.Provider, name: :my_provider`
2. Implement `stream/4` to return `{:ok, %Req.Response{}}` with SSE
3. Implement `parse_stream_event/1` to normalize API events
4. Implement `convert_messages/2` and `convert_tools/1` for wire format
5. Pass in config: `Opal.start_session(%{provider: MyProvider})`

**Helpers for OpenAI-compatible APIs**:
- `parse_chat_event/1` — SSE parsing
- `convert_messages_openai/2` — message conversion
- `reasoning_effort/1` — thinking level mapping

---

## 7. Sub-Agent System

### Spawning Sub-Agents

**Tool**: `sub_agent`

**Parameters**:
```json
{
  "prompt": "Refactor the auth module",
  "tools": ["read_file", "edit_file"],      # optional: subset
  "model": "claude-haiku-3-5",              # optional: override
  "system_prompt": "Focus on security"      # optional: override
}
```

**Result**:
```json
{
  "response": "I refactored the module to use stateless tokens...",
  "tool_calls": [
    {"tool": "read_file", "args": {...}, "result": {...}},
    {"tool": "edit_file", "args": {...}, "result": {...}}
  ]
}
```

### Supervision & Isolation

- Each sub-agent is an OTP process under a `DynamicSupervisor` (per-session)
- Depth-limited to 1 level (sub_agent tool excluded from sub-agent's tools)
- If sub-agent crashes, parent continues (supervision catches it)
- Sub-agent events forwarded to parent session for observability

### Event Forwarding

Sub-agent events wrapped in `subAgentEvent` envelope:
```json
{
  "type": "sub_agent_event",
  "subSessionId": "sub-abc123",
  "inner": {
    "type": "message_delta",
    "delta": "Refactoring..."
  }
}
```

CLI normalizes these, routes inner event to correct agent in `agents` map.

---

## 8. Task/Planning System

### Task Tracker (DETS-Backed)

**Tool**: `tasks`

**DETS File Location**: `~/.opal/tasks/<hash>.dets` (session_id keyed, working_dir fallback)

**Actions**:
```json
{
  "action": "insert",
  "label": "Fix parser",
  "parent_id": 1,
  "blocked_by": "2,3",
  "prompt": "The parser crashes on nested functions"
}
```

### Planning Integration

**System Prompt Injection** (session start):
```
For complex multi-step tasks, create a plan document at:
  ~/.opal/sessions/<session_id>/plan.md

Write your plan before starting implementation.
```

**User Access** (`ctrl+y`):
- CLI opens plan.md in `$VISUAL` / `$EDITOR` / platform default
- Agent reads updated plan via `read_file`
- Fully real-time, file-based (no schema)

---

## 9. Authentication

### Device-Code Flow (Copilot)

1. **Initiate**: `auth/login` RPC
   - POST to GitHub's device-code endpoint
   - Returns: `user_code`, `device_code`, `verification_uri`, `interval`

2. **User Authorizes**: Open `verification_uri`, enter `user_code`

3. **Poll**: `auth/poll` RPC (called every `interval` seconds)
   - Poll GitHub until token available or request expires

4. **Exchange**: GitHub token → Copilot API token via `exchange_copilot_token/1`

5. **Persist**: Token stored in `~/.opal/auth.json`

6. **Refresh**: Auto-refresh when < 5 minutes to expiry

### Token Storage

```json
{
  "copilot_token": "ghp_...",
  "github_token": "ghu_...",
  "expires_at": 1234567890
}
```

---

## 10. Configuration/Settings

### Feature Toggles

```elixir
config :opal,
  features: %{
    sub_agents: %{enabled: true},
    context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
    skills: %{enabled: true, extra_dirs: []},
    debug: %{enabled: false}
  }
```

### Runtime Configuration

Via RPC (`opal/config/set`):
```json
{
  "session_id": "abc123",
  "features": {"sub_agents": true, "skills": false},
  "enabled_tools": ["read_file", "grep", "shell"]
}
```

### Settings Persistence

**File**: `~/.opal/settings.json`

```json
{
  "default_model": "copilot:claude-sonnet-4"
}
```

**API**:
- `settings/get` — read all settings
- `settings/save` — merge settings

---

## Architecture Highlights

### 1. OTP-First Design

- **Supervision Trees**: Process lifecycle management, automatic restart, cleanup
- **Message Passing**: Erlang mailboxes for queuing, event pub/sub via `Registry`
- **State Machines**: `:gen_statem` for explicit agent loop lifecycle
- **Concurrency**: `Task.Supervisor` for parallel tool execution, no thread pools

### 2. Event System

**Registry-Based Pub/Sub** (`Opal.Events`):
- Multiple subscribers to single session ID
- Broadcast to all subscribers + wildcard `:all` subscribers
- Message format: `{:opal_event, session_id, event}`

**Event Types**:
- Agent lifecycle events (start, end, abort)
- Streaming deltas (text, thinking)
- Tool execution (start, end)
- Usage updates
- Sub-agent events (nested)

### 3. Resilience Patterns

- **Retry with Backoff** (`Opal.Agent.Retry`): Exponential backoff on transient errors
- **Context Overflow Recovery** (`Opal.Agent.Overflow`): Auto-compaction when approaching window limit
- **Stream Stall Detection**: 10-second timeout, broadcasts stall notification
- **Task Crash Isolation**: Tools run in separate supervised tasks; crash doesn't crash agent

### 4. Streaming Architecture

- Provider streams SSE via `Req.Response` (async body)
- Agent checks mailbox between chunks
- Chunks parsed to semantic events (provider-agnostic)
- Stream state accumulated (text, tool calls, thinking)
- Terminal event triggers response finalization

### 5. CLI-Server Communication

- **Transport**: stdin/stdout newline-delimited JSON-RPC 2.0
- **Bidirectional**: Client → Server (requests), Server → Client (notifications + requests)
- **Server→Client Requests**: Used for user confirmations, input solicitation
- **Streaming**: Events batched & coalesced (32ms window) to avoid excessive re-renders

---

## Key Files Reference

### Elixir Backend
| File | Lines | Purpose |
|------|-------|---------|
| `opal/lib/opal.ex` | 275 | Main public API |
| `opal/lib/opal/agent/agent.ex` | 631 | :gen_statem loop |
| `opal/lib/opal/rpc/protocol.ex` | 927 | Protocol definitions (source of truth) |
| `opal/lib/opal/rpc/server.ex` | 200+ | Stdio transport + dispatch |
| `opal/lib/opal/session/session.ex` | 100+ | Session tree + persistence |
| `opal/lib/opal/session/server.ex` | 150+ | Per-session supervision tree |
| `opal/lib/opal/tool/sub_agent.ex` | 200+ | Sub-agent spawning |
| `opal/lib/opal/tool/tasks.ex` | 300+ | Task tracker |
| `opal/lib/opal/provider/copilot.ex` | 400+ | Copilot implementation |
| `opal/lib/opal/auth/copilot.ex` | 150+ | Device-code OAuth |
| `opal/lib/opal/events.ex` | 84 | Pub/sub registry |

### TypeScript CLI
| File | Purpose |
|------|---------|
| `cli/src/bin.ts` | Entry point, CLI arg parsing (yargs) |
| `cli/src/app.tsx` | Main Ink layout (1 KB) |
| `cli/src/commands/tui.ts` | Terminal prep + render launch |
| `cli/src/state/store.ts` | Zustand store (80 lines) |
| `cli/src/state/timeline.ts` | Event reducer + agents map |
| `cli/src/state/session.ts` | SDK connection lifecycle |
| `cli/src/sdk/session.ts` | High-level Session API |
| `cli/src/sdk/client.ts` | Typed JSON-RPC client |
| `cli/src/sdk/protocol.ts` | Auto-generated types |
| `cli/src/sdk/transport/stdio.ts` | Stdio transport (spawn server) |

### Documentation
| File | Topic |
|------|-------|
| `docs/cli.md` | CLI architecture & components |
| `docs/sdk.md` | TypeScript SDK usage |
| `docs/rpc.md` | JSON-RPC protocol spec |
| `docs/agent-loop.md` | Agent state machine FSM |
| `docs/providers.md` | Provider behaviour & Copilot details |
| `docs/installing.md` | Installation & authentication setup |
| `docs/planning.md` | Plan documents & Ctrl+Y editor |
| `docs/state.md` | CLI state management (Zustand) |
| `docs/tools.md` | Built-in tools reference |

---

## Development Workflow

### Build & Run
```bash
cd /Users/sergio/Projects/2026/opal

# Install dependencies
mise run deps

# Run TUI in dev mode
mise run dev

# Run with debug feature/tools enabled
mise run dev -- --debug

# Run tests
mise run test

# Lint & format
mise run lint && mise run format

# Connect via iex to running dev instance
mise run inspect
```

### Protocol Codegen
```bash
cd opal
mix opal.gen.json_schema   # → priv/rpc_schema.json
mix run ../scripts/codegen_ts.exs  # → cli/src/sdk/protocol.ts
mix run ../scripts/codegen_ts.exs --check  # Verify in CI
```

---

## Conclusion

**Opal** is a production-ready agentic harness that leverages Erlang/OTP's process model, supervision trees, and message passing to build a reliable, observable agent system. The clean separation between the Elixir backend (agent loop, tools, providers), the JSON-RPC transport (decoupled server communication), and the TypeScript frontend (reactive CLI) makes it easy to extend and embed in other contexts.

The architecture shines in:
1. **Concurrency**: Cheap OTP processes for sub-agents and tools
2. **Observability**: Live event streaming, debugging via `iex`, JSON-RPC introspection
3. **Resilience**: Supervision strategies, retry policies, overflow recovery
4. **Extensibility**: Custom tools, providers, middleware via Elixir config
5. **User Experience**: Real-time streaming, multi-agent UI, keyboard shortcuts

For a UI app specification, the key integration points are:
- **RPC Protocol** (`opal/config/get`, `opal/config/set`) for runtime feature toggles
- **Event Stream** (`agent/event` notifications) for timeline rendering
- **Session API** (create, branch, compact, resume) for conversation management
- **Model & Auth APIs** for interactive LLM selection and provider setup

___BEGIN___COMMAND_DONE_MARKER___0
