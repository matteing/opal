# Opal — An OTP-Native Coding Agent Harness

> _Inspired by [Pi](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent), reimagined for the BEAM._

## What This Is

Opal is an Elixir SDK for building coding agents that takes full advantage of OTP
primitives — supervision trees, GenServers, process isolation, message passing,
and the observer. Rather than port Pi to Elixir, we steal the ideas that matter
and throw away the ones OTP already solves better.

**Core thesis:** A coding agent is a tree of actors with a conversation loop at
the heart. The BEAM gives us fault-tolerance, introspection, and massive
parallelism for free — things Pi has to bolt on through extensions, tmux hacks,
or external process spawning.

**Cross-platform by default.** Elixir and the BEAM run on Linux, macOS, and
Windows. Opal must work on all three from day one — no POSIX assumptions, no
bash-only tooling, no hardcoded `/` paths.

---

## What We Take from Pi

| Pi Concept                                          | What We Keep                    | What We Change                                                         |
| --------------------------------------------------- | ------------------------------- | ---------------------------------------------------------------------- |
| **Agent loop** (prompt → LLM → tool calls → repeat) | The core loop shape             | It's a GenServer, not an async function                                |
| **Tools** (read, write, edit, shell)                | Tool interface and built-in set | Tools are module callbacks, not JS objects                             |
| **Sessions** (JSONL tree with branching)            | Tree-structured message history | ETS/DETS-backed, not file-append                                       |
| **Events** (agent_start, tool_execution_end, etc.)  | Event lifecycle model           | `Registry`-based pubsub, not callback lists                            |
| **SDK embedding**                                   | Embeddable in apps              | Native OTP — just add to your supervision tree                         |
| **Extensibility** (extensions, skills, prompts)     | Plugin system concept           | Behaviours, not runtime JS loading                                     |
| **Steering/follow-up queues**                       | Mid-run message injection       | Process mailbox _is_ the queue                                         |
| **Provider abstraction**                            | Multi-provider from day one     | Single provider (GitHub Copilot) to start — behaviour ready for others |

## What We Don't Take

- **No npm/git package system.** Hex packages and Mix deps.
- **Single binary with built-in TUI.** The `opal` binary includes both the
  interactive terminal UI (TermUI/Elm Architecture) and the agent engine in a
  single BEAM process tree. No separate frontend process or serialization layer.
  A `--daemon` flag provides headless JSON-RPC mode for external consumers.
- **RPC for external consumers only.** Opal ships as both a library
  (`{:opal, ...}`) and a binary (`opal`). In interactive mode, the TUI calls
  the agent directly via Elixir function calls — no RPC overhead. In daemon
  mode (`opal --daemon`), it communicates via JSON-RPC 2.0 over stdio for
  external clients.
- **MCP client, not MCP-hostile.** Pi says "no MCP" — we disagree. Opal acts
  as an MCP _host_: it connects to external MCP servers and surfaces their
  tools/resources to the agent alongside native `Opal.Tool` modules. We use
  [Anubis MCP](https://hexdocs.pm/anubis_mcp) (`~> 0.17`) as the protocol
  foundation — it handles transports, lifecycle, and JSON-RPC so we don't
  reinvent any of it. Native tools and MCP tools coexist; MCP servers are just
  another tool source, managed by supervised Anubis client processes.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    opal binary (Elixir)                  │
│                                                          │
│  Interactive mode (default):                             │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              Opal.CLI.App (TermUI)                   │ │
│  │  init/update/view — Elm Architecture                 │ │
│  │                                                      │ │
│  │  Header │ MessageList │ Thinking │ TaskList           │ │
│  │  Input  │ StatusBar   │ ConfirmDialog                │ │
│  └────────────────────────┬────────────────────────────┘ │
│                           │ direct Elixir calls          │
│                           │ (no serialization)           │
│  ┌────────────────────────▼────────────────────────────┐ │
│  │              Opal (core library)                     │ │
│  │  Agent | Session | Tools | MCP | Provider | Events  │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                          │
│  Daemon mode (--daemon):                                 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Opal.RPC.Stdio (JSON-RPC 2.0 on stdin/stdout)      │ │
│  │  For external clients — no TUI, headless operation   │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                          │
│  As a library ({:opal, "~> 0.x"}):                       │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Opal.start_session/1, Opal.prompt/2, etc.          │ │
│  │  Embed in your own Elixir application                │ │
│  └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### Internal Process Tree

```
┌─────────────────────────────────────────────────────────┐
│                  Opal.SessionSupervisor                 │
│              (DynamicSupervisor per session)             │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │ Opal.Agent   │  │ Opal.Session │  │ Opal.ToolSup  │ │
│  │ (GenServer)  │  │ (GenServer)  │  │ (TaskSupervisor│ │
│  │              │  │              │  │  for tools)    │ │
│  │ • LLM loop   │  │ • Message    │  │               │ │
│  │ • Streaming   │  │   history   │  │ • Concurrent   │ │
│  │ • Turn mgmt   │  │ • Branching │  │   tool exec   │ │
│  │ • Steering    │  │ • Persist   │  │ • Timeouts    │ │
│  └──────┬───────┘  └──────────────┘  └───────────────┘ │
│         │                                               │
│         │ events via Registry                           │
│         ▼                                               │
│  ┌──────────────┐                                       │
│  │ Opal.Events  │ ← Any process can subscribe          │
│  │ (Registry)   │                                       │
│  └──────────────┘                                       │
└─────────────────────────────────────────────────────────┘
```

---

## Staged Build Plan

When in doubt, you can check [Pi](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent) for specific algorithms or implementation inspiration. You must stick to the overall architecture in this document, however.

### Stage 1 — The Loop (MVP)

> Goal: Send a prompt, get a streamed response, execute tools, repeat.
> Dependencies: [`req`](https://hexdocs.pm/req) (~> 0.5), [`jason`](https://hexdocs.pm/jason) (~> 1.4)

This is the beating heart. Everything else is scaffolding around it.

#### Modules

**`Opal.Agent`** — GenServer

The agent loop as a stateful process. Holds the system prompt, message history,
tools, model config, and streaming state.

```elixir
# Public API
Opal.Agent.prompt(agent, "What files are in src/?")
Opal.Agent.steer(agent, "Actually, focus on lib/ instead")
Opal.Agent.follow_up(agent, "Now write tests for those")
Opal.Agent.abort(agent)
Opal.Agent.get_state(agent)
Opal.Agent.platform(agent)  # :linux | :macos | :windows
```

Internal state:

```elixir
%Opal.Agent.State{
  system_prompt: String.t(),
  messages: [Opal.Message.t()],
  model: Opal.Model.t(),   # e.g. %{provider: :copilot, id: "claude-sonnet-4-5"}
  tools: [Opal.Tool.t()],
  thinking_level: :off | :low | :medium | :high,
  streaming?: boolean(),
  pending_tool_calls: MapSet.t()
}
```

The loop:

1. Receive `prompt` cast → append user message → call LLM
2. Stream response tokens → broadcast `:message_update` events
3. If response contains tool calls → execute each tool (via TaskSupervisor)
4. Append tool results → call LLM again (next turn)
5. If no tool calls → broadcast `:agent_end` → return to idle
6. Between tool executions, check mailbox for steering messages

Steering is natural: `steer/2` sends a message to the GenServer's mailbox.
Between tool executions, the loop does a selective `receive` to check for
steering — no polling, no callbacks, just the mailbox.

**`Opal.Provider`** — Behaviour

```elixir
defmodule Opal.Provider do
  @callback stream(model, context, opts) :: {:ok, stream_ref} | {:error, term}
  @callback parse_event(raw_event) :: Opal.Provider.Event.t()
  @callback models() :: [Opal.Model.t()]
end
```

Stage 1 ships with `Opal.Provider.Copilot` — GitHub Copilot via the OpenAI
Responses API. This is the only provider we build initially; the behaviour is
ready for others later.

**Why Copilot first?**

- Free for anyone with a GitHub account (Copilot Free tier)
- Uses the OpenAI Responses API wire format, so the same code path covers
  direct OpenAI usage later with minimal changes
- Device-code OAuth flow — no manual API key management needed
- Access to Claude, GPT-4o, o3, and other models through one endpoint

**`Opal.Provider.Copilot`** — the GitHub Copilot provider

The provider implements the OpenAI Responses API streaming protocol, with
Copilot-specific headers and OAuth token management. All HTTP is done via
[Req](https://hexdocs.pm/req) (`~> 0.5`). Reference implementation:
[Pi's openai-responses.ts](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/providers/openai-responses.ts)
and [github-copilot.ts](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/utils/oauth/github-copilot.ts).

Key implementation details from the reference:

**Authentication — Device Code OAuth Flow:**

1. POST `https://github.com/login/device/code` with client ID → get
   `device_code`, `user_code`, `verification_uri`
2. User visits URL, enters code
3. Poll `https://github.com/login/oauth/access_token` until granted
4. Exchange GitHub access token → Copilot API token via
   `https://api.github.com/copilot_internal/v2/token`
5. Parse `proxy-ep` from Copilot token to derive the API base URL
   (e.g. `https://api.individual.githubcopilot.com`)
6. Token expires → refresh using the stored GitHub access token

The token is stored on disk in `Opal.Config.data_dir()/auth.json`.
Re-login only when refresh fails. All HTTP calls in the auth flow use `Req`.

```elixir
defmodule Opal.Auth do
  @moduledoc "Manages Copilot OAuth credentials."

  @copilot_headers %{
    "user-agent" => "GitHubCopilotChat/0.35.0",
    "editor-version" => "vscode/1.107.0",
    "editor-plugin-version" => "copilot-chat/0.35.0",
    "copilot-integration-id" => "vscode-chat"
  }

  defp client_id, do: Opal.Config.copilot(:client_id) || "Iv1.b507a08c87ecfe98"
  defp domain,    do: Opal.Config.copilot(:domain) || "github.com"

  def start_device_flow(dom \\ domain()) do
    Req.post!("https://#{dom}/login/device/code",
      json: %{client_id: client_id(), scope: "read:user"},
      headers: %{"accept" => "application/json"})
    |> Map.get(:body)
    # => %{"device_code" => ..., "user_code" => ..., "verification_uri" => ...}
  end

  def poll_for_token(domain, device_code, interval_ms) do
    # Poll with Req, handle "authorization_pending" / "slow_down"
    Req.post!("https://#{domain}/login/oauth/access_token",
      json: %{client_id: client_id(), device_code: device_code,
              grant_type: "urn:ietf:params:oauth:grant-type:device_code"},
      headers: %{"accept" => "application/json"})
  end

  def exchange_copilot_token(github_token, domain \\ "github.com") do
    Req.get!("https://api.#{domain}/copilot_internal/v2/token",
      auth: {:bearer, github_token},
      headers: @copilot_headers)
    |> Map.get(:body)
    # => %{"token" => ..., "expires_at" => ...}
  end

  def get_token do
    # Load from disk, refresh if expired via exchange_copilot_token/2
  end
end
```

**Request Format — OpenAI Responses API (streaming via Req):**

The key insight: `Req.post!/2` with `into: :self` streams SSE chunks directly
into the calling process's mailbox — perfect for a GenServer. The provider
process receives raw SSE data as messages, parses them with
`Req.parse_message/2`, and dispatches events.

```elixir
defmodule Opal.Provider.Copilot do
  @behaviour Opal.Provider

  @impl true
  def stream(model, context, opts) do
    token = Opal.Auth.get_token()
    base_url = Opal.Auth.base_url(token)
    messages = convert_messages(model, context)

    req = Req.new(
      base_url: base_url,
      auth: {:bearer, token},
      headers: copilot_headers(context)
    )

    # into: :self streams SSE into the GenServer mailbox
    resp = Req.post!(req,
      url: "/v1/responses",
      json: %{
        model: model.id,
        input: messages,
        stream: true,
        store: false,
        tools: convert_tools(context.tools)
      },
      into: :self
    )

    {:ok, resp}  # caller iterates via Req.parse_message/2 or Enum
  end
end
```

In the `Opal.Agent` GenServer, incoming stream chunks arrive as regular
messages handled in `handle_info/2`:

```elixir
# In Opal.Agent
def handle_info(message, %{streaming_resp: resp} = state) do
  case Req.parse_message(resp, message) do
    {:ok, [{:data, data}]} ->
      data
      |> parse_sse_line()
      |> dispatch_event(state)

    {:ok, [:done]} ->
      finalize_response(state)

    {:error, reason} ->
      handle_stream_error(reason, state)

    :unknown ->
      {:noreply, state}
  end
end
```

**Copilot-specific headers** (set via `Req.new/1` `:headers`):

```elixir
defp copilot_headers(context) do
  last_role = context.messages |> List.last() |> Map.get(:role, "user")
  %{
    "user-agent" => "GitHubCopilotChat/0.35.0",
    "editor-version" => "vscode/1.107.0",
    "editor-plugin-version" => "copilot-chat/0.35.0",
    "copilot-integration-id" => "vscode-chat",
    "openai-intent" => "conversation-edits",
    "x-initiator" => if(last_role != "user", do: "agent", else: "user")
  }
end
```

**Streaming SSE events** to handle (from `processResponsesStream`):

| Event                                                | What to do                                              |
| ---------------------------------------------------- | ------------------------------------------------------- |
| `response.output_item.added` (type: `reasoning`)     | Push `{:thinking_start, ...}`                           |
| `response.reasoning_summary_text.delta`              | Accumulate thinking text, push `{:thinking_delta, ...}` |
| `response.output_item.added` (type: `message`)       | Push `{:text_start, ...}`                               |
| `response.output_text.delta`                         | Accumulate text, push `{:message_delta, ...}`           |
| `response.output_item.added` (type: `function_call`) | Push `{:tool_call_start, ...}`                          |
| `response.function_call_arguments.delta`             | Accumulate JSON args, push `{:tool_call_delta, ...}`    |
| `response.function_call_arguments.done`              | Parse final JSON args                                   |
| `response.output_item.done` (type: `function_call`)  | Emit complete `ToolCall` struct                         |
| `response.completed`                                 | Extract usage stats, determine stop reason              |
| `error` / `response.failed`                          | Emit error event                                        |

**Message conversion** (internal → Responses API input):

- User messages → `%{role: "user", content: [%{type: "input_text", text: ...}]}`
- Assistant text → `%{type: "message", role: "assistant", content: [%{type: "output_text", text: ...}], ...}`
- Tool calls → `%{type: "function_call", call_id: ..., name: ..., arguments: ...}`
- Tool results → `%{type: "function_call_output", call_id: ..., output: ...}`
- System prompt → `%{role: "developer", content: ...}` (for reasoning models)
  or `%{role: "system", content: ...}` (otherwise)

**Tool conversion:**

```elixir
def convert_tools(tools) do
  Enum.map(tools, fn tool ->
    %{type: "function", name: tool.name(),
      description: tool.description(),
      parameters: tool.parameters(), strict: false}
  end)
end
```

**`Opal.Tool`** — Behaviour

```elixir
defmodule Opal.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: Opal.Schema.t()   # JSON Schema-ish
  @callback execute(args :: map(), context :: map()) ::
    {:ok, result :: String.t()} | {:error, reason :: String.t()}
end
```

Stage 1 tools:

- `Opal.Tool.Read` — read files
- `Opal.Tool.Write` — write files
- `Opal.Tool.Edit` — search-and-replace edits
- `Opal.Tool.Shell` — run shell commands (cross-platform)

**`Opal.Tool.Shell`** — Cross-platform shell execution

Pi's `bash` tool assumes POSIX. Opal's `Shell` tool detects the platform and
acts accordingly:

```elixir
# Internal dispatch:
case :os.type() do
  {:unix, _}  -> System.cmd("sh", ["-c", command], opts)
  {:win32, _} -> System.cmd("cmd", ["/C", command], opts)
end
```

The tool name exposed to the LLM matches the configured shell (`"shell"`,
`"bash"`, `"cmd"`, `"powershell"`, etc.) so the model generates appropriate
syntax. On Windows, commands run via `cmd.exe` by default, with an option to
use PowerShell:

```elixir
# In session config:
Opal.start_session(%{
  shell: :powershell,  # :cmd (default on Windows) | :powershell | :sh (default on Unix)
  ...
})
```

**`Opal.Path`** — Path normalization

All internal path handling uses `Path` module functions (`Path.join/2`,
`Path.expand/1`, `Path.relative_to/2`) which are already cross-platform in
Elixir. The working directory and any tool arguments go through normalization:

```elixir
defmodule Opal.Path do
  def normalize(path) do
    path
    |> String.replace("\\", "/")   # normalize separators for internal use
    |> Path.expand()
  end

  def to_native(path) do
    case :os.type() do
      {:win32, _} -> String.replace(path, "/", "\\")
      _ -> path
    end
  end
end
```

**`Opal.Events`** — Registry-based pubsub

```elixir
# Subscribe to all events from a session
Opal.Events.subscribe(session_id)

# In your process
receive do
  {:opal_event, ^session_id, {:agent_start}} -> ...
  {:opal_event, ^session_id, {:message_update, delta}} -> ...
  {:opal_event, ^session_id, {:tool_execution_start, tool, args}} -> ...
  {:opal_event, ^session_id, {:tool_execution_end, tool, result}} -> ...
  {:opal_event, ^session_id, {:turn_end, message, tool_results}} -> ...
  {:opal_event, ^session_id, {:agent_end, messages}} -> ...
end
```

Any process in the VM can subscribe. Your LiveView, your CLI, your monitoring
dashboard, another agent — they all get the same event stream with zero
serialization overhead.

**`Opal.Config`** — Configuration

Opal uses Elixir's native application configuration as the foundation. Defaults
are sensible, the host app overrides via `config :opal`, and individual sessions
can override further at startup.

**Priority (highest wins):**

1. Session config — `Opal.start_session(%{data_dir: ..., shell: ..., ...})`
2. Application config — `config :opal, data_dir: "~/.opal"`
3. Environment variables — `OPAL_DATA_DIR`, `OPAL_SHELL`
4. Built-in defaults

**`config/config.exs`** (in the host app):

```elixir
config :opal,
  data_dir: "~/.opal",
  shell: :zsh,
  default_model: {"copilot", "claude-sonnet-4-5"},
  default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell],
  copilot: [
    client_id: "Iv1.b507a08c87ecfe98",
    domain: "github.com"
  ]
```

**`config/runtime.exs`** (for env-var-driven deploys/CI):

```elixir
config :opal,
  data_dir: System.get_env("OPAL_DATA_DIR", "~/.opal"),
  shell: System.get_env("OPAL_SHELL", "sh") |> String.to_existing_atom()
```

**Module:**

```elixir
defmodule Opal.Config do
  @moduledoc """
  Reads Opal configuration from Application env with per-session overrides.
  """

  @defaults %{
    data_dir: "~/.opal",
    shell: nil,              # nil = auto-detect per platform
    default_model: {"copilot", "claude-sonnet-4-5"},
    default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell]
  }

  @doc "Get a config value. Session overrides > Application env > defaults."
  def get(key, session_opts \\ %{}) do
    case Map.get(session_opts, key) do
      nil -> Application.get_env(:opal, key, Map.get(@defaults, key))
      val -> val
    end
  end

  @doc "Resolved data directory (expanded to absolute path)."
  def data_dir(session_opts \\ %{}),  do: get(:data_dir, session_opts) |> Path.expand()
  def sessions_dir(opts \\ %{}),      do: Path.join(data_dir(opts), "sessions")
  def auth_file(opts \\ %{}),         do: Path.join(data_dir(opts), "auth.json")
  def logs_dir(opts \\ %{}),          do: Path.join(data_dir(opts), "logs")

  @doc "Resolved shell — session override, app config, or platform default."
  def shell(session_opts \\ %{}) do
    case get(:shell, session_opts) do
      nil -> Opal.Tool.Shell.default_shell()
      shell -> shell
    end
  end

  @doc "Ensures the data directory tree exists."
  def ensure_dirs!(opts \\ %{}) do
    for dir <- [data_dir(opts), sessions_dir(opts), logs_dir(opts)] do
      File.mkdir_p!(dir)
    end
  end

  @doc "All copilot-specific config."
  def copilot(key) do
    :opal |> Application.get_env(:copilot, []) |> Keyword.get(key)
  end
end
```

Directory layout:

```
~/.opal/
├── auth.json          # Copilot OAuth tokens
├── sessions/          # Saved conversation trees
│   ├── <session-id>.etf
│   └── ...
├── logs/              # Agent logs (optional)
└── skills/            # User-defined skill files (optional)
```

**`Opal`** — Public API / Entry point

```elixir
# Start a session (returns pid of the session supervisor)
# Uses defaults from `config :opal` — override per-session as needed.
{:ok, session} = Opal.start_session(%{
  model: {"copilot", "claude-sonnet-4-5"},
  system_prompt: "You are a helpful coding assistant.",
  working_dir: "/path/to/project"
  # tools:    defaults from config :opal, :default_tools
  # shell:    defaults from config :opal, :shell (or platform auto-detect)
  # data_dir: defaults from config :opal, :data_dir (~/.opal)
})

# Send a prompt (async — subscribe to events for output)
:ok = Opal.prompt(session, "List all Elixir files")

# Or synchronous convenience
{:ok, response} = Opal.prompt_sync(session, "What is 2 + 2?")
```

#### What You Can Do After Stage 1

- Embed Opal in any Elixir app and have a working coding agent
- Stream LLM output to any subscriber
- Execute tools (file ops + shell)
- Steer the agent mid-run
- Inspect agent state via `:observer` or `:sys.get_state/1`

#### Testing the Provider

`Req.Test` lets you plug in a fake adapter so tests never hit the network:

```elixir
# In test setup:
Req.Test.stub(Opal.Provider.Copilot, fn conn ->
  conn
  |> Plug.Conn.put_resp_content_type("text/event-stream")
  |> Plug.Conn.send_resp(200, sse_fixture("simple_response"))
end)
```

This gives us deterministic, fast tests for the entire SSE parsing and event
dispatch pipeline — no mocking libraries, no network.

- Crash-recover individual sessions without taking down the app

---

### Stage 2 — Sessions & Persistence

> Goal: Save and restore conversations. Branch and navigate history.

**`Opal.Session`** — GenServer

Manages the conversation tree. Each message gets an ID and a parent ID, exactly
like Pi's JSONL tree — but backed by ETS for fast in-memory access and optionally
DETS or a file for persistence.

```elixir
Opal.Session.save(session)           # persist current state
Opal.Session.branch(session, entry_id) # rewind to a point
Opal.Session.get_tree(session)       # full tree structure
Opal.Session.get_path(session)       # root → current leaf
Opal.Session.list_sessions(dir)      # enumerate saved sessions
```

Session format: Erlang term storage (`.etf`) or JSONL for interop. We don't need
to match Pi's format — we need something that's fast to read/write from the BEAM.

**`Opal.Session.Compaction`**

When context gets long, summarize older messages. Same idea as Pi but
implemented as a separate pass that the Agent can trigger:

```elixir
Opal.Session.compact(session, keep_recent: 10)
```

---

### Stage 3 — Sub-Agents & Parallelism

> Goal: Spawn child agents that work in parallel.

This is where OTP shines and Pi explicitly punts. Pi says "spawn tmux sessions"
or "build it with extensions." We say: `DynamicSupervisor.start_child/2`.

**`Opal.SubAgent`**

A sub-agent is just another `Opal.Agent` started under the parent session's
supervisor. It gets its own process, its own message history, its own tool set.

```elixir
# From within a tool or the parent agent:
{:ok, sub} = Opal.SubAgent.spawn(parent_session, %{
  system_prompt: "You are a test-writing specialist.",
  tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Shell],
  model: {"copilot", "claude-haiku-3-5"}
})

{:ok, result} = Opal.SubAgent.run(sub, "Write tests for lib/opal/agent.ex")
```

The parent can spawn N sub-agents in parallel, each working on different files or
tasks. The supervision tree ensures cleanup:

```
SessionSupervisor
├── Opal.Agent (parent)
├── Opal.Session
├── Opal.ToolSup
└── Opal.SubAgentSup (DynamicSupervisor)
    ├── SubAgent session 1
    │   ├── Opal.Agent
    │   └── Opal.ToolSup
    ├── SubAgent session 2
    │   ├── Opal.Agent
    │   └── Opal.ToolSup
    └── ... N agents
```

If a sub-agent crashes, only that sub-agent restarts. The parent and siblings
are unaffected. If the parent session is torn down, all sub-agents are cleaned
up automatically. This is free from the supervision tree.

**Parallel tool execution**

Even within a single agent turn, Pi executes tool calls sequentially. We can
optionally run independent tool calls concurrently via `Task.async_stream`:

```elixir
# When the LLM returns multiple tool calls in one response:
tool_calls
|> Task.async_stream(fn call -> execute_tool(call) end, max_concurrency: 4)
|> Enum.map(fn {:ok, result} -> result end)
```

---

### Stage 4 — Context Files & Skills

> Goal: Load project context and reusable instruction sets.

**`Opal.Context`**

Walk up from `cwd`, collect `AGENTS.md` / `OPAL.md` files, concatenate into the
system prompt. Simple file-system walk, no magic.

```elixir
context_files = Opal.Context.discover(working_dir)
# Returns list of %{path: ..., content: ...}
```

**`Opal.Skill`** — Behaviour (optional)

```elixir
defmodule Opal.Skill do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback instructions() :: String.t()  # Markdown content
end
```

Skills are just modules that provide markdown instructions to append to the
system prompt on demand. No file-system discovery needed — they're Hex packages
or modules in your app.

---

### Stage 5 — MCP Client Integration

> Goal: Connect to external MCP servers and expose their tools to the agent.
> Dependency: [`anubis_mcp`](https://hexdocs.pm/anubis_mcp) (~> 0.17)

Opal acts as an MCP _host_ (in MCP terminology). Rather than hand-rolling
JSON-RPC 2.0 framing, transport management, and protocol lifecycle, we lean on
**Anubis MCP** — a mature Elixir SDK that already provides all of this as
supervised processes with a `use Anubis.Client` DSL.

Our job is thin: define one Anubis client module per MCP server, start them
under the session supervisor, discover their tools, and bridge those tools into
the `Opal.Tool` interface so the agent can't tell the difference.

#### What Anubis Gives Us (for free)

| Concern             | Anubis handles it                                                   |
| ------------------- | ------------------------------------------------------------------- |
| **Transports**      | `:stdio`, `:streamable_http`, `:websocket`, `:sse` — all built-in   |
| **Lifecycle**       | `initialize` → capability negotiation → `notifications/initialized` |
| **Tool ops**        | `list_tools/0`, `call_tool/2,3`, progress callbacks, timeouts       |
| **Resource ops**    | `list_resources/0`, `read_resource/1`                               |
| **Supervision**     | Each client is a child spec, drops into any supervisor tree         |
| **Named instances** | `Supervisor.child_spec/2` with `id:` for multiple servers           |
| **Protocol**        | JSON-RPC 2.0 framing, message validation via Peri schemas           |

This means we write _zero_ transport code and _zero_ protocol code.

#### Architecture

```
SessionSupervisor
├── Opal.Agent
├── Opal.Session
├── Opal.ToolSup
└── Opal.MCP.Supervisor          (plain Supervisor, one_for_one)
    ├── Opal.MCP.Client :fs       (Anubis.Client — stdio)
    ├── Opal.MCP.Client :sentry   (Anubis.Client — streamable_http)
    └── ...
```

**`Opal.MCP.Client`** — dynamic Anubis client module

We generate one `use Anubis.Client` module per configured MCP server at
runtime. Each module is a supervised GenServer that Anubis manages internally.

```elixir
defmodule Opal.MCP.Client do
  @moduledoc """
  Dynamically defines and starts an Anubis MCP client for each
  configured MCP server.
  """

  use Anubis.Client,
    name: "Opal",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: [:roots]

  @doc """
  Build a child spec for a named MCP server connection.
  """
  def child_spec(%{name: server_name, transport: transport_config}) do
    Supervisor.child_spec(
      {__MODULE__, transport: transport_config, name: server_name},
      id: {:mcp, server_name}
    )
  end
end
```

**`Opal.MCP.Supervisor`** — plain Supervisor

Starts one `Opal.MCP.Client` child per configured server.

```elixir
defmodule Opal.MCP.Supervisor do
  use Supervisor

  def start_link(mcp_servers) do
    Supervisor.start_link(__MODULE__, mcp_servers, name: __MODULE__)
  end

  @impl true
  def init(mcp_servers) do
    children = Enum.map(mcp_servers, &Opal.MCP.Client.child_spec/1)
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

**`Opal.MCP.Bridge`** — tool bridge

After each Anubis client connects, `Bridge` calls `list_tools/0` on the
client and wraps each discovered MCP tool into the `Opal.Tool` format that
the agent already understands. No new behaviour needed — just a data
transformation.

```elixir
defmodule Opal.MCP.Bridge do
  @moduledoc """
  Discovers tools from connected Anubis clients and presents them
  as Opal-compatible tool definitions for the agent's tool list.
  """

  @doc """
  Given a named MCP client, return a list of Opal tool maps.
  """
  def discover_tools(client_name) do
    {:ok, %{result: %{"tools" => tools}}} =
      Opal.MCP.Client.list_tools(client_name)

    Enum.map(tools, fn tool ->
      %{
        name: "mcp__#{client_name}__#{tool["name"]}",
        description: tool["description"],
        parameters: tool["inputSchema"],
        execute: fn args ->
          case Opal.MCP.Client.call_tool(client_name, tool["name"], args) do
            {:ok, %{is_error: false, result: result}} -> {:ok, result}
            {:ok, %{is_error: true, result: err}}     -> {:error, err}
            {:error, reason}                          -> {:error, reason}
          end
        end
      }
    end)
  end

  @doc """
  Discover tools from all running MCP clients.
  """
  def discover_all_tools(mcp_servers) do
    mcp_servers
    |> Enum.flat_map(fn %{name: name} -> discover_tools(name) end)
  end
end
```

Tool names are namespaced as `mcp__<server>__<tool>` to avoid collisions with
native `Opal.Tool` modules (e.g. `mcp__sentry__search_issues`).

**`Opal.MCP.Resources`** — resource injection

Same pattern for resources — discover them via `list_resources/0` and
`read_resource/1`, then inject their contents into the agent's context.

```elixir
defmodule Opal.MCP.Resources do
  def list(client_name) do
    {:ok, %{result: %{"resources" => resources}}} =
      Opal.MCP.Client.list_resources(client_name)
    resources
  end

  def read(client_name, uri) do
    {:ok, %{result: %{"contents" => contents}}} =
      Opal.MCP.Client.read_resource(client_name, uri)
    contents
  end
end
```

#### Session configuration

```elixir
{:ok, session} = Opal.start_session(%{
  model: {"copilot", "claude-sonnet-4-5"},
  tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell],
  mcp_servers: [
    %{name: :filesystem,
      transport: {:stdio, command: "npx",
                  args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]}},
    %{name: :sentry,
      transport: {:streamable_http,
                  base_url: "https://mcp.sentry.dev",
                  headers: [{"Authorization", "Bearer ..."}]}},
    %{name: :db,
      transport: {:stdio, command: "python", args: ["db_server.py"]}}
  ],
  system_prompt: "You are a helpful coding assistant.",
  working_dir: File.cwd!()
})
```

On session start, `Opal.MCP.Supervisor` launches one Anubis client per entry.
Each client connects, negotiates, and is ready. Then `Opal.MCP.Bridge` walks
all clients, discovers their tools, and merges them into the agent's flat tool
list. The agent loop calls MCP tools the same way it calls native tools — the
bridge closure routes the call through Anubis.

#### Why Anubis + OTP supervision?

| Concern            | How it works                                                                                                   |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| MCP server crashes | Anubis client process dies, supervisor restarts it, Anubis re-negotiates automatically                         |
| Slow MCP server    | `call_tool/3` supports `:timeout` option; doesn't block other tools                                            |
| Multiple servers   | Each is an independent child — parallel startup, independent failure domains                                   |
| Cleanup            | Session supervisor shutdown cascades through `Opal.MCP.Supervisor` to all Anubis clients, each calls `close/0` |
| Transport choice   | Config-driven — swap `:stdio` for `:streamable_http` without code changes                                      |
| Progress tracking  | Anubis built-in `progress:` option with token + callback                                                       |

#### What MCP Gets You

- Access to the entire MCP server ecosystem (filesystem, databases, Sentry,
  GitHub, Slack, etc.) without writing Elixir wrappers for each
- Remote tool execution via HTTP transport — tools on another machine
- Resource injection — MCP servers can provide context (file contents, DB
  schemas) that gets appended to the system prompt
- Dynamic tool updates — servers can add/remove tools at runtime via
  notifications, and the agent picks them up immediately

#### What We Don't Build

Because Anubis handles it:

- ❌ JSON-RPC 2.0 framing / message parsing
- ❌ Transport implementations (stdio, HTTP, WebSocket, SSE)
- ❌ Protocol lifecycle (`initialize` / capability negotiation)
- ❌ Progress token management
- ❌ Message validation schemas

---

### Stage 5.5 — RPC Server (Headless Mode)

> Goal: Ship Opal as both a library and a standalone binary that any language
> can drive over JSON-RPC 2.0. The `opal --daemon` flag activates headless mode
> for external clients.

**The TUI is now built-in.** The `opal` binary defaults to interactive mode
using TermUI (Elm Architecture). Headless JSON-RPC mode is available via
`opal --daemon` for external consumers that want to build their own frontends.
The Elixir `mix opal.chat` task remains as a debugging utility.

#### Design Decision: JSON-RPC 2.0 over stdio

We evaluated gRPC, WebSocket, HTTP+SSE, and custom binary protocols. **JSON-RPC
2.0 over stdio** wins on every axis that matters for the daemon mode:

| Concern            | JSON-RPC stdio                                                |
| ------------------ | ------------------------------------------------------------- |
| **Proven pattern** | Same protocol as LSP and MCP — well-understood, battle-tested |
| **Distribution**   | `opal --daemon` — no ports, firewall, TLS              |
| **Bidirectional**  | Both sides send requests + responses (like LSP)               |
| **Streaming**      | Notifications — no SSE, no WebSocket, no special mechanism    |
| **Cross-platform** | stdin/stdout identical on macOS, Linux, Windows               |
| **Self-contained** | ~200 lines of Elixir — `Opal.RPC` owns the codec, no deps     |
| **Future SDKs**    | Protocol spec is a markdown doc — any language implements     |
| **TS ecosystem**   | `vscode-jsonrpc` (6M+ downloads/week)                         |

The one constraint — single client per process — is the _correct_ constraint
for a CLI. One terminal = one agent. If we ever need multi-client (web UI,
IDE extension), we add a WebSocket or HTTP transport behind the same protocol
layer; only the transport changes, the methods stay identical.

#### Protocol Specification

The wire format is **newline-delimited JSON** on stdin/stdout. Each message is a
single JSON object followed by `\n`. Stderr is reserved for unstructured logs.
This matches the MCP stdio transport convention.

##### Requests (Client → Server)

Standard JSON-RPC 2.0 requests with `id`, `method`, `params`:

```jsonc
// Start or resume a session
{"jsonrpc": "2.0", "id": 1, "method": "session/start", "params": {
  "model": {"provider": "copilot", "id": "claude-sonnet-4-5"},
  "system_prompt": "You are a helpful coding assistant.",
  "working_dir": "/Users/me/project",
  "tools": ["read", "write", "edit", "shell"],
  "mcp_servers": [
    {"name": "filesystem", "transport": {"type": "stdio",
      "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"]}}
  ]
}}
// => {"jsonrpc": "2.0", "id": 1, "result": {"session_id": "abc123"}}

// Send a prompt (async — results stream as notifications)
{"jsonrpc": "2.0", "id": 2, "method": "agent/prompt", "params": {
  "session_id": "abc123",
  "text": "List all Elixir files in lib/"
}}
// => {"jsonrpc": "2.0", "id": 2, "result": {"ok": true}}

// Steer the agent mid-run
{"jsonrpc": "2.0", "id": 3, "method": "agent/steer", "params": {
  "session_id": "abc123",
  "text": "Actually, focus on test/ instead"
}}

// Abort the current run
{"jsonrpc": "2.0", "id": 4, "method": "agent/abort", "params": {
  "session_id": "abc123"
}}

// Get agent state
{"jsonrpc": "2.0", "id": 5, "method": "agent/state", "params": {
  "session_id": "abc123"
}}
// => {"jsonrpc": "2.0", "id": 5, "result": {"status": "idle", "model": ...}}

// Session management
{"jsonrpc": "2.0", "id": 6, "method": "session/branch", "params": {
  "session_id": "abc123", "entry_id": "msg-42"
}}
{"jsonrpc": "2.0", "id": 7, "method": "session/compact", "params": {
  "session_id": "abc123", "keep_recent": 10
}}
{"jsonrpc": "2.0", "id": 8, "method": "session/list", "params": {}}

// Auth
{"jsonrpc": "2.0", "id": 9, "method": "auth/status", "params": {}}
{"jsonrpc": "2.0", "id": 10, "method": "auth/login", "params": {}}

// Model listing
{"jsonrpc": "2.0", "id": 11, "method": "models/list", "params": {}}
```

##### Notifications (Server → Client)

Streaming events are JSON-RPC 2.0 **notifications** (no `id` — fire and forget).
These map 1:1 to `Opal.Events`:

```jsonc
// Agent lifecycle
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "agent_start"
}}

// LLM text streaming (one per token delta)
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "message_delta",
  "delta": "Here are the "
}}

// Thinking/reasoning
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "thinking_delta",
  "delta": "I should list the files..."
}}

// Tool execution
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "tool_execution_start",
  "tool": "shell", "call_id": "call_1",
  "args": {"command": "find lib/ -name '*.ex'"}
}}
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "tool_execution_end",
  "tool": "shell", "call_id": "call_1",
  "result": {"ok": true, "output": "lib/opal.ex\nlib/opal/agent.ex\n..."}
}}

// Turn and agent end
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "turn_end",
  "message": "Found 12 Elixir files..."
}}
{"jsonrpc": "2.0", "method": "agent/event", "params": {
  "session_id": "abc123", "type": "agent_end"
}}

// Auth flow (device code)
{"jsonrpc": "2.0", "method": "auth/device_code", "params": {
  "user_code": "ABCD-1234",
  "verification_uri": "https://github.com/login/device"
}}
```

##### Server → Client Requests (Bidirectional)

The server can send requests _to_ the client that require a response. This
is the LSP `window/showMessageRequest` pattern — essential for user
confirmation prompts, permission gates, etc.

```jsonc
// Server asks: "Should I execute this command?"
{"jsonrpc": "2.0", "id": "s2c-1", "method": "client/confirm", "params": {
  "session_id": "abc123",
  "title": "Execute shell command?",
  "message": "rm -rf node_modules/",
  "actions": ["allow", "deny", "allow_session"]
}}
// Client responds:
{"jsonrpc": "2.0", "id": "s2c-1", "result": {"action": "allow"}}

// Server asks for user input
{"jsonrpc": "2.0", "id": "s2c-2", "method": "client/input", "params": {
  "session_id": "abc123",
  "prompt": "Enter your API key:",
  "sensitive": true
}}
// Client responds:
{"jsonrpc": "2.0", "id": "s2c-2", "result": {"text": "sk-..."}}
```

#### Architecture

```
┌────────────────────────────────────────────────────────────┐
│            Daemon mode (opal --daemon)                      │
│   • Reads JSON-RPC requests from stdin                      │
│   • Writes JSON-RPC responses/notifications to stdout       │
│   • No TUI — designed for external clients/SDKs             │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Opal.RPC.Stdio (GenServer)                           │  │
│  │  • Reads newline-delimited JSON from :stdio           │  │
│  │  • Dispatches to Opal.RPC.Handler                     │  │
│  │  • Writes responses + notifications to :stdio         │  │
│  │  • Subscribes to Opal.Events, forwards as notifs      │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                      │
│  ┌──────────────────▼───────────────────────────────────┐  │
│  │ Opal.RPC.Handler                                     │  │
│  │  • "session/start"  → Opal.start_session/1            │  │
│  │  • "agent/prompt"   → Opal.prompt/2                   │  │
│  │  • "agent/abort"    → Opal.abort/1                    │  │
│  │  • "agent/state"    → Opal.Agent.get_state/1          │  │
│  │  • "session/list"   → Opal.Session.list_sessions/0    │  │
│  │  • "models/list"    → Opal.Provider.models/1          │  │
│  │  • "auth/*"         → Opal.Auth.*                     │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                      │
│          (calls into the normal Opal library API)          │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Opal (library — Stages 1-5)              │  │
│  │  Agent, Session, Tools, MCP, Events, etc.             │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

#### Modules

**`Opal.RPC`** — Protocol layer (transport-agnostic)

Encode/decode JSON-RPC 2.0 messages. Stateless functions.

```elixir
defmodule Opal.RPC do
  @moduledoc """
  JSON-RPC 2.0 encoding/decoding. Transport-agnostic — used by
  Opal.RPC.Stdio today, could be used by a WebSocket transport later.
  """

  @type message :: request() | response() | notification()
  @type request :: %{jsonrpc: String.t(), id: id(), method: String.t(), params: map()}
  @type response :: %{jsonrpc: String.t(), id: id(), result: term()} |
                    %{jsonrpc: String.t(), id: id(), error: error()}
  @type notification :: %{jsonrpc: String.t(), method: String.t(), params: map()}
  @type id :: integer() | String.t()
  @type error :: %{code: integer(), message: String.t(), data: term()}

  # Standard JSON-RPC error codes
  @parse_error      -32700
  @invalid_request  -32600
  @method_not_found -32601
  @invalid_params   -32602
  @internal_error   -32603

  def encode_request(id, method, params) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  def encode_response(id, result) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})
  end

  def encode_error(id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error
    Jason.encode!(%{jsonrpc: "2.0", id: id, error: error})
  end

  def encode_notification(method, params) do
    Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
  end

  def decode(json) do
    case Jason.decode(json) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg} ->
        {:request, id, method, Map.get(msg, "params", %{})}

      {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result}} ->
        {:response, id, result}

      {:ok, %{"jsonrpc" => "2.0", "id" => id, "error" => error}} ->
        {:error_response, id, error}

      {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} ->
        {:notification, method, Map.get(msg, "params", %{})}

      {:ok, _} -> {:error, :invalid_request}
      {:error, _} -> {:error, :parse_error}
    end
  end
end
```

**`Opal.RPC.Handler`** — Method dispatch

Maps JSON-RPC methods to Opal library calls. Pure functions — receives method +
params, returns result or error. No transport awareness.

```elixir
defmodule Opal.RPC.Handler do
  @moduledoc """
  Dispatches JSON-RPC methods to Opal library functions.
  Returns {:ok, result} | {:error, code, message, data}.
  """

  def handle("session/start", params) do
    opts = decode_session_opts(params)
    case Opal.start_session(opts) do
      {:ok, session_id} -> {:ok, %{session_id: session_id}}
      {:error, reason}  -> {:error, -32603, "Failed to start session", reason}
    end
  end

  def handle("agent/prompt", %{"session_id" => sid, "text" => text}) do
    case Opal.prompt(sid, text) do
      :ok          -> {:ok, %{ok: true}}
      {:error, r}  -> {:error, -32603, "Prompt failed", r}
    end
  end

  def handle("agent/steer", %{"session_id" => sid, "text" => text}) do
    :ok = Opal.steer(sid, text)
    {:ok, %{ok: true}}
  end

  def handle("agent/abort", %{"session_id" => sid}) do
    :ok = Opal.abort(sid)
    {:ok, %{ok: true}}
  end

  def handle("agent/state", %{"session_id" => sid}) do
    state = Opal.Agent.get_state(sid)
    {:ok, serialize_state(state)}
  end

  def handle("session/list", _params) do
    sessions = Opal.Session.list_sessions()
    {:ok, %{sessions: sessions}}
  end

  def handle("session/branch", %{"session_id" => sid, "entry_id" => eid}) do
    :ok = Opal.Session.branch(sid, eid)
    {:ok, %{ok: true}}
  end

  def handle("session/compact", %{"session_id" => sid} = params) do
    keep = Map.get(params, "keep_recent", 10)
    :ok = Opal.Session.compact(sid, keep_recent: keep)
    {:ok, %{ok: true}}
  end

  def handle("models/list", _params) do
    models = Opal.Provider.Copilot.models()
    {:ok, %{models: Enum.map(models, &serialize_model/1)}}
  end

  def handle("auth/status", _params) do
    {:ok, %{authenticated: Opal.Auth.authenticated?()}}
  end

  def handle("auth/login", _params) do
    # Triggers device flow — progress sent as notifications
    case Opal.Auth.login() do
      {:ok, _} -> {:ok, %{ok: true}}
      {:error, r} -> {:error, -32603, "Login failed", r}
    end
  end

  def handle(method, _params) do
    {:error, -32601, "Method not found: #{method}", nil}
  end

  # ... serialization helpers
end
```

**`Opal.RPC.Stdio`** — Stdio transport GenServer

The glue. Reads lines from stdin, dispatches, writes to stdout. Subscribes to
`Opal.Events` and forwards as notifications. Handles server→client requests
for user confirmations.

```elixir
defmodule Opal.RPC.Stdio do
  @moduledoc """
  JSON-RPC 2.0 transport over stdin/stdout.

  Reads newline-delimited JSON from stdin, dispatches via
  Opal.RPC.Handler, writes responses to stdout. Subscribes
  to Opal.Events and emits notifications for streaming events.
  """

  use GenServer

  defstruct [:port, :buffer, pending_requests: %{}, next_server_id: 1]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Open stdin as a port for line-based reading
    port = Port.open({:fd, 0, 1}, [:binary, :stream, {:line, 1_048_576}])
    {:ok, %__MODULE__{port: port, buffer: ""}}
  end

  # --- Incoming data from stdin ---

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = process_line(line, state)
    {:noreply, state}
  end

  # --- Opal events → JSON-RPC notifications ---

  def handle_info({:opal_event, session_id, event}, state) do
    notification = event_to_notification(session_id, event)
    write_stdout(notification)
    {:noreply, state}
  end

  # --- Server→Client request responses ---

  def handle_info({:client_response, id, result}, state) do
    case Map.pop(state.pending_requests, id) do
      {from, pending} when from != nil ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_requests: pending}}
      _ ->
        {:noreply, state}
    end
  end

  # --- Internal ---

  defp process_line(line, state) do
    case Opal.RPC.decode(line) do
      {:request, id, method, params} ->
        handle_request(id, method, params, state)

      {:response, id, result} ->
        # Client responding to a server→client request
        send(self(), {:client_response, id, result})
        state

      {:error, _reason} ->
        write_stdout(Opal.RPC.encode_error(nil, -32700, "Parse error"))
        state
    end
  end

  defp handle_request(id, method, params, state) do
    case Opal.RPC.Handler.handle(method, params) do
      {:ok, result} ->
        write_stdout(Opal.RPC.encode_response(id, result))

        # Auto-subscribe to events for new sessions
        if method == "session/start" do
          Opal.Events.subscribe(result.session_id)
        end

      {:error, code, message, data} ->
        write_stdout(Opal.RPC.encode_error(id, code, message, data))
    end
    state
  end

  @doc """
  Send a request to the client and wait for a response.
  Used for user confirmations, input prompts, etc.
  """
  def request_client(method, params, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:request_client, method, params}, timeout)
  end

  @impl true
  def handle_call({:request_client, method, params}, from, state) do
    id = "s2c-#{state.next_server_id}"
    write_stdout(Opal.RPC.encode_request(id, method, params))
    pending = Map.put(state.pending_requests, id, from)
    {:noreply, %{state | pending_requests: pending,
                         next_server_id: state.next_server_id + 1}}
  end

  defp event_to_notification(session_id, event) do
    {type, data} = serialize_event(event)
    params = Map.merge(%{session_id: session_id, type: type}, data)
    Opal.RPC.encode_notification("agent/event", params)
  end

  defp serialize_event({:agent_start}),
    do: {"agent_start", %{}}
  defp serialize_event({:message_delta, %{delta: delta}}),
    do: {"message_delta", %{delta: delta}}
  defp serialize_event({:thinking_delta, %{delta: delta}}),
    do: {"thinking_delta", %{delta: delta}}
  defp serialize_event({:tool_execution_start, tool, args}),
    do: {"tool_execution_start", %{tool: tool, args: args}}
  defp serialize_event({:tool_execution_end, tool, result}),
    do: {"tool_execution_end", %{tool: tool, result: result}}
  defp serialize_event({:turn_end, message, _results}),
    do: {"turn_end", %{message: message}}
  defp serialize_event({:agent_end, _messages}),
    do: {"agent_end", %{}}

  defp write_stdout(json) do
    IO.write(:stdio, json <> "\n")
  end
end
```

**`Opal.CLI.Server`** — Headless daemon entry point

The headless daemon mode (`opal --daemon`). Starts the OTP application,
launches the stdio transport, and blocks until stdin closes.

```elixir
defmodule Opal.CLI.Server do
  @moduledoc """
  Entry point for headless daemon mode (opal --daemon).

  Usage: opal --daemon [--log-level debug]

  The server communicates exclusively via JSON-RPC 2.0 on stdin/stdout.
  Logs go to stderr (configurable level).
  """

  def main(args \\ []) do
    configure_logging(args)
    Logger.configure_backend(:console, device: :standard_error)
    {:ok, _} = Application.ensure_all_started(:opal)
    {:ok, _} = Opal.RPC.Stdio.start_link()

    receive do
      {:EXIT, _, _} -> :ok
    end
  end
end
```

**`Opal.CLI.Main`** — Binary entry point

The `opal` binary entry point. Dispatches between interactive TUI (default)
and headless daemon mode (`--daemon`).

```elixir
defmodule Opal.CLI.Main do
  def main(args \\ []) do
    {opts, _, _} = OptionParser.parse(args, ...)

    cond do
      opts[:daemon] || opts[:headless] -> Opal.CLI.Server.main(args)
      true -> TermUI.Runtime.run(root: Opal.CLI.App, render_interval: 16)
    end
  end
end
```

#### Distribution

The `opal` binary is built as either:

- **Escript** — `mix escript.build` (requires Erlang/OTP on the target machine)
- **Mix release** — `mix release` (self-contained, bundles ERTS)
- **Burrito** — single-file binary, no runtime dependencies (future)

```
cd core
mix escript.build
./opal               # Interactive TUI
./opal --daemon      # Headless JSON-RPC
```

#### Deployment Modes

| Concern              | Opal library (Hex)                  | opal binary                     |
| -------------------- | ----------------------------------- | ------------------------------- |
| **Audience**         | Elixir developers embedding agents  | End users & external clients    |
| **Distribution**     | `{:opal, "~> 0.1"}` in `mix.exs`    | escript, mix release, or Burrito |
| **Interface**        | Elixir function calls, OTP messages | TUI (default) or JSON-RPC (--daemon) |
| **State management** | Your supervision tree               | Self-contained OTP app          |
| **Streaming**        | `Opal.Events.subscribe/1` + mailbox | Direct in TUI / notifications in daemon |

#### Future Transports (Not in This Stage)

The protocol layer (`Opal.RPC` + `Opal.RPC.Handler`) is transport-agnostic.
Adding new transports later is a small module each:

- **`Opal.RPC.WebSocket`** — for web UIs, IDE extensions, multi-client
- **`Opal.RPC.HTTP`** — REST + SSE for browser-based clients
- **`Opal.RPC.TCP`** — for daemon mode (long-running server, multiple CLIs)

Each transport module only handles framing and connection management. The
handler dispatch is shared.

---

### Stage 6 — CLI Frontend (Native Elixir / TermUI)

> Goal: A production-quality `opal` terminal application built into the binary.

The CLI is built in Elixir using [TermUI](https://github.com/pcharbon70/term_ui),
a BubbleTea-inspired Elm Architecture framework for terminal UIs. The TUI runs
in the same BEAM process tree as the agent engine — no child process spawning,
no JSON-RPC serialization for interactive mode.

**Why native Elixir instead of TypeScript/Ink?**

- **Zero serialization overhead.** The TUI calls `Opal.prompt/2` directly —
  no JSON encoding, no stdio parsing, no process spawning.
- **Single binary.** One `opal` executable, no Node.js runtime dependency.
- **Event bridge is trivial.** `Opal.Events.subscribe/1` delivers events as
  Erlang messages directly to the TermUI runtime process.
- **TermUI maturity.** 24+ widgets, 60fps differential rendering, markdown
  support via `mdex`, full RGB color, Elm Architecture state management.

**`mix opal.chat`** remains as a debugging utility for library developers.

#### Module Structure

```
core/lib/opal/cli/
├── app.ex              # Main TUI application (use TermUI.Elm)
├── commands.ex         # Slash command handling (/clear, /help, etc.)
├── config.ex           # Persistent CLI config (~/.config/opal/config.json)
├── main.ex             # Binary entry point (arg parsing, mode dispatch)
├── server.ex           # Headless JSON-RPC server entry point (--daemon)
├── theme.ex            # Color theme (pink accents, dark/light)
└── views/
    ├── confirm_dialog.ex  # Tool confirmation overlay
    ├── header.ex          # Header bar (title, cwd, model name)
    ├── input.ex           # User input prompt (cursor, submit)
    ├── message_list.ex    # Scrollable chat with role badges
    ├── status_bar.ex      # Bottom bar (tokens, shortcuts)
    ├── task_list.ex       # Tool execution status icons
    └── thinking.ex        # Animated kaomoji indicator
```

#### Usage

```
$ opal                           # Interactive TUI (default)
$ opal --daemon                  # Headless JSON-RPC on stdio
$ opal --version                 # Print version
$ opal --help                    # Show help
```

#### Platform Distribution

The `opal` binary is built as either:

1. **`mix escript.build`** — portable escript (requires Erlang/OTP on host)
2. **`mix release`** — self-contained release (bundles BEAM + deps)

| Platform        | Install method                          |
| --------------- | --------------------------------------- |
| **macOS arm64** | `brew install opal` / GitHub release    |
| **macOS x64**   | `brew install opal` / GitHub release    |
| **Linux x64**   | GitHub release / curl one-liner         |
| **Linux arm64** | GitHub release / curl one-liner         |
| **Windows x64** | GitHub release / scoop / winget         |

---

## OTP Advantages Over Pi's Architecture

| Concern             | Pi (TypeScript)                                 | Opal (Elixir/OTP)                                                                                             |
| ------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Agent isolation** | Single process, careful state management        | Each agent is a process — crash one, others survive                                                           |
| **Sub-agents**      | "Build it yourself" or tmux                     | `DynamicSupervisor.start_child/2`                                                                             |
| **Concurrency**     | Sequential tool execution                       | `Task.async_stream` for parallel tools                                                                        |
| **Event system**    | Callback arrays, manual cleanup                 | `Registry` pubsub — subscribe/unsubscribe is process lifecycle                                                |
| **Steering**        | Explicit queue arrays + polling                 | Process mailbox — selective receive                                                                           |
| **Inspection**      | Console logging                                 | `:observer`, `:sys.get_state`, tracing                                                                        |
| **Fault tolerance** | try/catch, process exit                         | Supervision trees, automatic restart strategies                                                               |
| **Embedding**       | SDK import + async/await                        | Add to your supervision tree — it's just processes                                                            |
| **Multi-session**   | Multiple AgentSession instances in one thread   | Each session is an isolated process tree                                                                      |
| **Hot code reload** | Restart the process                             | Hot code upgrade via releases                                                                                 |
| **Backpressure**    | Manual (message queue modes)                    | Process mailbox + GenServer handle_continue                                                                   |
| **Distributed**     | Not built-in                                    | `Node.connect` — agents across machines for free                                                              |
| **Cross-platform**  | Works but bash tool assumes POSIX               | BEAM runs natively on Windows, macOS, Linux — `Opal.Tool.Shell` dispatches per OS                             |
| **MCP integration** | Explicitly rejected; "build it with extensions" | Anubis MCP clients under OTP supervision — zero transport/protocol code, fault-tolerant, parallel negotiation |

---

## Module Summary

| Module                              | Type              | Stage | Purpose                                         |
| ----------------------------------- | ----------------- | ----- | ----------------------------------------------- |
| `Opal`                              | API               | 1     | Public interface, session lifecycle             |
| `Opal.Agent`                        | GenServer         | 1     | Core agent loop                                 |
| `Opal.Provider`                     | Behaviour         | 1     | LLM provider abstraction                        |
| `Opal.Provider.Copilot`             | Module            | 1     | GitHub Copilot (OpenAI Responses API)           |
| `Opal.Auth`                         | Module            | 1     | Copilot OAuth device-code flow + token storage  |
| `Opal.Tool`                         | Behaviour         | 1     | Tool interface                                  |
| `Opal.Tool.{Read,Write,Edit,Shell}` | Modules           | 1     | Built-in tools                                  |
| `Opal.Config`                       | Module            | 1     | Application config + per-session overrides      |
| `Opal.Path`                         | Module            | 1     | Cross-platform path normalization               |
| `Opal.Events`                       | Registry          | 1     | Event pubsub                                    |
| `Opal.Message`                      | Struct            | 1     | Message types                                   |
| `Opal.SessionSupervisor`            | DynamicSupervisor | 1     | Per-session process tree                        |
| `Opal.Session`                      | GenServer         | 2     | Message history + persistence                   |
| `Opal.Session.Compaction`           | Module            | 2     | Context window management                       |
| `Opal.SubAgent`                     | Module            | 3     | Sub-agent spawning                              |
| `Opal.SubAgentSup`                  | DynamicSupervisor | 3     | Sub-agent supervision                           |
| `Opal.Context`                      | Module            | 4     | Context file discovery                          |
| `Opal.Skill`                        | Behaviour         | 4     | Reusable instructions                           |
| `Opal.MCP.Supervisor`               | Supervisor        | 5     | Manages Anubis client processes                 |
| `Opal.MCP.Client`                   | Anubis.Client     | 5     | MCP server connection (via Anubis)              |
| `Opal.MCP.Bridge`                   | Module            | 5     | Discovers MCP tools → Opal tool format          |
| `Opal.MCP.Resources`                | Module            | 5     | MCP resource discovery + reading                |
| `Opal.RPC`                          | Module            | 5.5   | JSON-RPC 2.0 encode/decode (transport-agnostic) |
| `Opal.RPC.Handler`                  | Module            | 5.5   | Method dispatch → Opal API                      |
| `Opal.RPC.Stdio`                    | GenServer         | 5.5   | Stdio transport for headless daemon mode        |
| `Opal.CLI.Server`                   | Module            | 5.5   | Headless daemon entry point (`--daemon`)        |
| `Opal.CLI.Main`                     | Module            | 6     | Binary entry point (mode dispatch)              |
| `Opal.CLI.App`                      | TermUI.Elm        | 6     | Main TUI application (Elm Architecture)         |
| `Opal.CLI.Theme`                    | Module            | 6     | Color themes (dark/light, pink accents)         |
| `Opal.CLI.Config`                   | Module            | 6     | Persistent CLI config (~/.config/opal)          |
| `Opal.CLI.Commands`                 | Module            | 6     | Slash command handling                          |
| `Opal.CLI.Views.*`                  | Modules           | 6     | View components (Header, Input, MessageList, etc.) |
| `opal.chat`                         | Mix task          | 6     | Elixir debugging TUI (direct library usage)     |

---

## Usage: SDK in Your App

```elixir
# In your application.ex
children = [
  Opal.Supervisor  # starts the registry, session supervisor, etc.
]

# Anywhere in your app — tools, shell, data_dir come from config :opal
{:ok, session} = Opal.start_session(%{
  system_prompt: "You are a helpful assistant.",
  working_dir: File.cwd!()
})

# Subscribe from a LiveView, GenServer, or any process
Opal.Events.subscribe(session)

# Non-blocking
Opal.prompt(session, "Refactor the user module")

# Events arrive in your process mailbox
receive do
  {:opal_event, _, {:message_update, %{delta: text}}} ->
    IO.write(text)
  {:opal_event, _, {:agent_end, _messages}} ->
    IO.puts("\n--- Done ---")
end
```

## Usage: Headless / Script

```elixir
# In a Mix task or escript
Opal.Supervisor.start_link([])

{:ok, response} = Opal.prompt_sync(session, "What's in this repo?")
IO.puts(response)
```

---

## Cross-Platform Design Principles

1. **No POSIX assumptions.** Never shell out with hardcoded `sh -c`. Use
   `Opal.Tool.Shell` which dispatches to the right shell per OS.
2. **Use `Path` everywhere.** Never concatenate paths with `"/"`. Use
   `Path.join/2`, `Path.expand/1`, `Path.relative_to/2`.
3. **Normalize paths at boundaries.** Input from users, LLMs, and tool results
   goes through `Opal.Path.normalize/1` before storage or comparison.
4. **Data directory.** All persistent state lives under `~/.opal/` by default
   — one predictable location on every platform (like `~/.ssh`, `~/.docker`).
   Override via `config :opal, data_dir: ...` in your app, per-session
   with `data_dir:`, or `OPAL_DATA_DIR` env var. See `Opal.Config` for the
   full precedence chain.
5. **Session storage.** Saved under `Opal.Config.sessions_dir/0` which defaults
   to `~/.opal/sessions/`. Embedded apps can redirect to their own data dir.
6. **Environment variables.** `System.get_env/1` is cross-platform. API keys
   and config via env vars work everywhere.
7. **Line endings.** File reads/writes preserve platform line endings. Diffs
   and edits normalize to `\n` internally.
8. **Test on CI.** GitHub Actions matrix: `ubuntu-latest`, `macos-latest`,
   `windows-latest`. No platform is a second-class citizen.

---

## What's Not Here (Yet)

- **Multiple providers** — Ship GitHub Copilot first. Direct OpenAI, Anthropic,
  Google, etc. follow the same `Opal.Provider` behaviour. The Copilot provider
  already speaks the OpenAI Responses API, so direct OpenAI support is a
  near-trivial second provider.
- **Web UI** — Could be a Phoenix LiveView app that subscribes to events.
  That's a separate project.
- **Distributed agents** — The architecture supports it (processes + message
  passing), but we don't build for it in early stages.
- **Image/multimodal support** — Messages can carry image content, but tooling
  for it comes later.

---

## Naming

**Opal** — it's a gemstone, short, easy to type, and the `O` is for OTP.
Open to alternatives.
