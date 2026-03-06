# Opal v2 — Architecture & Migration Plan

> Remotely access all your agents, everywhere, on any machine.

## Overview

```
┌─────────┐         ┌──────────┐         ┌──────────┐
│  UI/SPA │◄──wss──►│  Relay   │◄──wss──►│  Daemon  │──► Opal (library)
│ (Vite)  │         │ (Elixir) │         │ (Elixir) │
└─────────┘         └──────────┘         └──────────┘
```

**opal/** — Pure idiomatic Elixir agent library. No transport, no JSON-RPC.
**daemon/** — Connects Opal to the relay. Manages sessions, bridges events.
**relay/** — Thin WebSocket router. Routes by identity, touches no content.
**ui/** — Vite SPA. Connects through relay, controls daemons remotely.

## Code Principles

Every component follows these rules. No exceptions.

### General

- **No dead code.** If it's not called, delete it. No "might need later."
- **No premature abstraction.** Write the concrete thing first. Extract only
  when you see actual duplication (rule of three).
- **Small modules.** Each file does one thing. If a module exceeds ~200 LOC,
  split it. If a function exceeds ~20 lines, extract a helper.
- **Explicit over implicit.** No magic. No global state. Dependencies are
  passed, not imported from ambient context.

### Elixir (opal/, daemon/, relay/)

- **Let it crash.** Use supervisors, not defensive try/catch. Handle the
  happy path; let OTP restart failures.
- **Pattern match at the function head.** Don't `case` on args inside the
  body when you can match in the function clause.
- **Pipelines for data transformation.** Use `|>` for linear transforms.
  Don't pipe into side-effectful functions or into `case`/`if`.
- **Tagged tuples.** Return `{:ok, value}` / `{:error, reason}`. Never
  return raw values that might be nil.
- **Structs with `@enforce_keys`.** Required fields are enforced at compile
  time. No silent nil defaults for important data.
- **No `use` unless necessary.** Prefer `import` or explicit calls. `use`
  is reserved for behaviours (`use GenServer`) and macros that genuinely
  reduce boilerplate.
- **Typespec public functions.** Every public function gets `@spec`. Private
  functions only when the types aren't obvious.
- **`@moduledoc` on every module.** One sentence. What it does, not how.

### TypeScript (ui/)

- **Strict mode.** `"strict": true` in tsconfig. No `any` except at
  serialization boundaries (WebSocket messages).
- **Named exports only.** No default exports — they make refactoring harder.
- **Discriminated unions for message types.** Not string enums, not bare
  strings. `type Event = { type: "message_delta"; text: string } | ...`
- **Prefer `const` and `readonly`.** Mutability is opt-in, not default.
- **React: functional components only.** No class components. Hooks for
  state and effects. Custom hooks to encapsulate logic.
- **Zustand slices stay thin.** Store holds state + simple setters. Business
  logic lives in hooks or pure functions, not inside the store.
- **No barrel files.** Import from the actual module, not `index.ts`
  re-exports. Tree-shaking works better, imports are greppable.

---

## Security Model

Opal agents have `shell` and `write_file` tools. A compromised connection
is arbitrary code execution on every connected machine. Security is not
optional — it's the foundation.

### Threat Model

| Threat | Vector | Impact | Mitigation |
|--------|--------|--------|------------|
| **Stolen GitHub token** | Phishing, laptop theft, token leak | Attacker connects to relay as you | Pairing keys — token alone can't control daemons |
| **Relay compromise** | Server hack, fly.io breach | Read/inject all traffic | E2E encryption — relay sees only opaque blobs |
| **Replay attack** | Sniff valid command, replay later | Re-execute shell commands | Signed timestamps — commands expire after 30s |
| **MITM relay** | DNS hijack, rogue relay | Intercept everything | Mutual HMAC — daemon verifies relay identity |
| **Rogue client** | Unauthorized browser access | Control daemons remotely | Daemon-side allowlist — only paired keys accepted |
| **Direct daemon access** | SSH to machine, hit localhost | Bypass relay auth | Daemon binds to 127.0.0.1, relay-only access |

### Trust Boundaries

```
┌─────────────────────────────────────────────────────┐
│                    TRUST BOUNDARY 1                 │
│              GitHub OAuth → Relay Access             │
│  "You are who you say you are"                      │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │              TRUST BOUNDARY 2               │   │
│   │         Paired Key → Daemon Access          │   │
│   │  "You are allowed to control this machine"  │   │
│   │                                             │   │
│   │   ┌─────────────────────────────────────┐   │   │
│   │   │          TRUST BOUNDARY 3           │   │   │
│   │   │    Signed Command → Execution       │   │   │
│   │   │  "This command is authentic & fresh" │   │   │
│   │   └─────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

An attacker must breach **all three boundaries** independently to achieve RCE:
1. Steal a GitHub token (or compromise GitHub OAuth)
2. Obtain a paired client private key (stored on the client device only)
3. Forge a signed, timestamped command (requires the private key)

### Security Invariants (must hold at all times)

1. **No unsigned command reaches Opal.** Every command dispatched to
   `Opal.prompt/2` or `Opal.start_session/1` must have a valid signature
   from a trusted client key.

2. **No unpaired client receives events.** The daemon only forwards
   Opal events to clients whose public key is in the trusted list.

3. **The relay never sees plaintext payloads.** After key exchange,
   all payloads are E2E encrypted. Relay compromise yields nothing.

4. **Commands expire.** A signed command with a timestamp older than
   30 seconds is rejected. Replay window is minimal.

5. **Pairing requires physical presence.** The pairing code is displayed
   on the daemon's machine (logs or a management endpoint). An attacker
   who doesn't have access to the machine cannot pair.

---

**Goal**: Strip opal/ to a pure Elixir library. Delete the entire CLI — the
web UI replaces it. No more Ink, no more Node.js TUI, no more stdio transport.

### 1.0 Delete the CLI

The `cli/` directory is replaced entirely by `ui/` (web SPA) + `daemon/`.
Delete it all.

```
DELETED  cli/                         # Entire directory — Ink/React TUI
DELETED  scripts/codegen_ts.exs       # TypeScript codegen from RPC protocol
```

This removes:
- The Node.js TUI application (~5,000 LOC)
- The TypeScript SDK and stdio transport
- The codegen pipeline (protocol.ex → JSON schema → protocol.ts)
- All npm dependencies (ink, zustand, react, etc.)

No migration needed. The UI is a clean rewrite in the browser.

### 1.1 Delete the RPC layer

Remove the entire `lib/opal/rpc/` directory (~1,950 LOC):

```
DELETED  lib/opal/rpc/protocol.ex    # 942 LOC — method/event schema
DELETED  lib/opal/rpc/server.ex      # 801 LOC — stdio transport, dispatch
DELETED  lib/opal/rpc/rpc.ex         # 209 LOC — JSON-RPC encode/decode
DELETED  lib/mix/tasks/opal.gen.json_schema.ex  # schema codegen task
DELETED  priv/rpc_schema.json        # generated schema artifact
```

### 1.2 Remove RPC from the supervision tree

**File: `lib/opal/application.ex`**

```elixir
# BEFORE — conditional RPC server startup:
defmodule Opal.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Opal.Registry},
      {Registry, keys: :duplicate, name: Opal.Events.Registry},
      Opal.Shell.Process,
      {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one}
    ]

    children =
      if Application.get_env(:opal, :start_rpc, true) do
        children ++ [Opal.RPC.Server]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Opal.Supervisor)
  end
end

# AFTER — clean, no RPC references:
defmodule Opal.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Opal.Registry},
      {Registry, keys: :duplicate, name: Opal.Events.Registry},
      Opal.Shell.Process,
      {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Opal.Supervisor)
  end
end
```

Also remove the distribution helpers (`start_distribution/0`, `generate_cookie/0`,
`read_node_file/0`, `write_node_file/2`) — those were for node-to-node RPC.
The daemon handles its own networking now.

### 1.4 Replace `ask_user` RPC coupling with a callback

This is the **only** business logic that touches RPC. The `ask_user` tool
currently calls `Opal.RPC.Server.request_client/3` to block until the CLI
responds. Replace with a callback on the agent state.

**File: `lib/opal/agent/state.ex`** — add callbacks to the struct:

```elixir
# BEFORE:
defstruct [
  :session_id,
  :model,
  # ... existing fields ...
]

# AFTER — add a callbacks map:
defstruct [
  :session_id,
  :model,
  # ... existing fields ...
  callbacks: %{
    ask_user: &Opal.Callbacks.default_ask_user/1,
    confirm: &Opal.Callbacks.default_confirm/1
  }
]
```

**New file: `lib/opal/callbacks.ex`** — default implementations:

```elixir
defmodule Opal.Callbacks do
  @moduledoc """
  Default callback implementations for interactive agent operations.
  Override these by passing `:callbacks` in session options.
  """

  @doc "Default ask_user: auto-accepts with first choice or empty string."
  def default_ask_user(%{"choices" => [first | _]}), do: {:ok, first}
  def default_ask_user(_params), do: {:ok, ""}

  @doc "Default confirm: auto-accepts."
  def default_confirm(_params), do: {:ok, true}
end
```

**File: `lib/opal/tool/ask_user.ex`** — use the callback:

```elixir
# BEFORE:
def execute(args, context) do
  params = build_params(args)
  case Opal.RPC.Server.request_client("client/ask_user", params, :infinity) do
    {:ok, %{"answer" => answer}} -> {:ok, answer}
    {:error, reason} -> {:error, reason}
  end
end

# AFTER:
def execute(args, context) do
  params = build_params(args)
  callback = context.state.callbacks[:ask_user] || (&Opal.Callbacks.default_ask_user/1)
  callback.(params)
end
```

### 1.5 Clean up the public API

**File: `lib/opal.ex`** — the API is already clean. Ensure these functions
are the canonical interface:

```elixir
defmodule Opal do
  @moduledoc "Pure Elixir agent library."

  # Session lifecycle
  def start_session(opts \\ %{})     # → {:ok, pid}
  def stop_session(agent)            # → :ok
  def configure_session(pid, attrs)  # → :ok | {:error, reason}

  # Agent interaction
  def prompt(agent, text)            # → :ok (async, events via subscribe)
  def prompt_sync(agent, text, timeout \\ 120_000)  # → {:ok, response}
  def abort(agent)                   # → :ok
  def stream(agent, text)            # → Stream.t() (lazy enumerable)

  # Model control
  def set_model(pid, spec, opts \\ [])
  def set_thinking_level(agent, level)

  # Introspection
  def get_context(pid)               # → [message]
  def get_info(pid)                  # → info map
  def sync_messages(pid, messages)   # → :ok
end
```

### 1.6 Remove config flags

**File: `config/config.exs`** — remove `start_rpc` config:

```elixir
# DELETE this line:
config :opal, start_rpc: true
```

### 1.7 Update mix.exs

Remove any RPC-only dependencies (currently none — `jason` is used everywhere).
Remove the `opal.gen.json_schema` task from any aliases.

### 1.8 Dead code sweep

After deleting RPC, run a full dead-code audit before moving on:

```bash
# From opal/:
# 1. Compiler warnings catch undefined references
mix compile --warnings-as-errors

# 2. Find unused functions (xref)
mix xref unreachable

# 3. Find unused deps
mix deps.unlock --unused

# 4. Credo for style/dead code
mix credo --strict

# 5. Dialyzer for type errors from removed modules
mix dialyzer
```

**What to look for:**
- Config keys referencing deleted modules (`start_rpc`)
- Test helpers or fixtures that only served RPC tests
- Type specs referencing deleted structs
- `@moduledoc` or `@doc` mentioning JSON-RPC or Anubis
- Any `alias Opal.RPC.*` left behind
- Unused entries in the test coverage ignore list

**Result**: `opal/` is a pure library. Any Elixir process can start sessions,
send prompts, and subscribe to events with zero transport overhead.
Every remaining module is called. Every function is reachable.

---

## Phase 2: Build the Relay Server

**Goal**: A thin WebSocket router that matches daemons to clients.
~300 LOC of actual logic. Zero persistence. Stateless restarts.

### 2.1 Bootstrap the project

```bash
# From project root — plain Elixir, NOT Phoenix (too much boilerplate):
mix new relay --sup
cd relay
```

The relay doesn't need Phoenix. It's a WebSocket server with one route.
Plug + WebSockAdapter + Bandit is the entire stack — no generators, no
endpoint modules, no telemetry, no config sprawl.

**File: `relay/mix.exs`** — minimal deps:

```elixir
defp deps do
  [
    {:bandit, "~> 1.6"},             # HTTP/WebSocket server
    {:plug, "~> 1.16"},              # routing
    {:websock_adapter, "~> 0.5"},    # WebSocket upgrade
    {:jason, "~> 1.4"},              # JSON
    {:req, "~> 0.5"}                 # GitHub token verification
  ]
end
```

### 2.2 Connection registry

**File: `lib/relay/connections.ex`**

```elixir
defmodule Relay.Connections do
  @moduledoc "In-memory connection registry backed by ETS."

  @table :relay_connections

  @spec init() :: :ok
  def init do
    :ets.new(@table, [:bag, :public, :named_table])
    :ok
  end

  @spec register_daemon(integer(), String.t(), pid(), map()) :: reference()
  def register_daemon(user_id, machine_id, pid, metadata) do
    :ets.insert(@table, {user_id, :daemon, machine_id, pid, metadata})
    Process.monitor(pid)
  end

  @spec register_client(integer(), String.t(), pid()) :: reference()
  def register_client(user_id, client_id, pid) do
    :ets.insert(@table, {user_id, :client, client_id, pid})
    Process.monitor(pid)
  end

  @spec daemons_for(integer()) :: [map()]
  def daemons_for(user_id) do
    :ets.match_object(@table, {user_id, :daemon, :_, :_, :_})
    |> Enum.map(fn {_, _, machine_id, _pid, meta} ->
      Map.merge(meta, %{machine_id: machine_id, online: true})
    end)
  end

  @spec find_daemon(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_daemon(user_id, machine_id) do
    case :ets.match_object(@table, {user_id, :daemon, machine_id, :_, :_}) do
      [{_, _, _, pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @spec clients_for(integer()) :: [{integer(), :client, String.t(), pid()}]
  def clients_for(user_id) do
    :ets.match_object(@table, {user_id, :client, :_, :_})
  end

  @spec remove(pid()) :: :ok
  def remove(pid) do
    :ets.match_delete(@table, {:_, :_, :_, pid, :_})
    :ets.match_delete(@table, {:_, :_, :_, pid})
    :ok
  end
end
```

### 2.3 GitHub token verification

**File: `lib/relay/auth.ex`**

```elixir
defmodule Relay.Auth do
  @moduledoc "Verifies GitHub OAuth tokens with a TTL cache."

  @table :auth_cache
  @ttl_seconds 300

  @type identity :: %{user_id: integer(), login: String.t()}

  @spec init() :: :ok
  def init do
    :ets.new(@table, [:set, :public, :named_table])
    :ok
  end

  @spec verify_token(String.t()) :: {:ok, identity()} | {:error, :unauthorized}
  def verify_token(token) do
    case cached(token) do
      {:ok, _} = hit -> hit
      :miss -> fetch_and_cache(token)
    end
  end

  defp fetch_and_cache(token) do
    case Req.get("https://api.github.com/user",
           headers: [{"authorization", "Bearer #{token}"}]) do
      {:ok, %{status: 200, body: %{"id" => id, "login" => login}}} ->
        identity = %{user_id: id, login: login}
        cache(token, identity)
        {:ok, identity}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp cached(token) do
    case :ets.lookup(@table, token) do
      [{_, identity, expires}] when expires > System.monotonic_time(:second) ->
        {:ok, identity}
      _ ->
        :miss
    end
  end

  defp cache(token, identity) do
    expires = System.monotonic_time(:second) + @ttl_seconds
    :ets.insert(@table, {token, identity, expires})
  end
end
```

### 2.4 WebSocket handler

**File: `lib/relay/socket.ex`**

The entire relay brain. Pattern-match message types at function heads.

```elixir
defmodule Relay.Socket do
  @moduledoc "WebSocket handler. Routes messages between daemons and clients."
  @behaviour WebSock

  defstruct [:user_id, :role, :machine_id, :client_id]

  @type role :: :daemon | :client | nil

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, msg} -> handle_message(msg, state)
      {:error, _} -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:relay, _from, payload}, state) do
    {:push, {:text, Jason.encode!(payload)}, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Relay.Connections.remove(pid)
    {:stop, :normal, state}
  end

  # Auth — must be first message, user_id is nil
  defp handle_message(%{"type" => "auth", "token" => token}, %{user_id: nil} = state) do
    case Relay.Auth.verify_token(token) do
      {:ok, %{user_id: user_id} = identity} ->
        push(%{type: "authenticated", user_id: user_id, login: identity.login}, state)
        |> then(fn {_, frame, _} -> {:push, frame, %{state | user_id: user_id}} end)

      {:error, _} ->
        {:push, encode(%{type: "error", message: "unauthorized"}), state}
    end
  end

  # Register as daemon
  defp handle_message(%{"type" => "register", "machine_id" => mid} = msg, %{user_id: uid} = state)
       when uid != nil do
    metadata = Map.take(msg, ["hostname", "os", "sessions"])
    Relay.Connections.register_daemon(uid, mid, self(), metadata)
    broadcast_daemon_list(uid)
    {:ok, %{state | role: :daemon, machine_id: mid}}
  end

  # Register as client
  defp handle_message(%{"type" => "subscribe"}, %{user_id: uid} = state) when uid != nil do
    client_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Relay.Connections.register_client(uid, client_id, self())
    daemons = Relay.Connections.daemons_for(uid)
    {:push, encode(%{type: "daemons", list: daemons}), %{state | role: :client, client_id: client_id}}
  end

  # Client → Daemon
  defp handle_message(%{"type" => "to_daemon", "machine_id" => mid, "payload" => payload}, %{role: :client} = state) do
    with {:ok, pid} <- Relay.Connections.find_daemon(state.user_id, mid) do
      send(pid, {:relay, self(), payload})
    end
    {:ok, state}
  end

  # Daemon → specific Client
  defp handle_message(%{"type" => "to_client", "client_id" => cid, "payload" => payload}, %{role: :daemon} = state) do
    with {:ok, pid} <- Relay.Connections.find_client(state.user_id, cid) do
      send(pid, {:relay, self(), payload})
    end
    {:ok, state}
  end

  # Daemon → all Clients (event broadcast)
  defp handle_message(%{"type" => "broadcast", "payload" => payload}, %{role: :daemon} = state) do
    state.user_id
    |> Relay.Connections.clients_for()
    |> Enum.each(fn {_, _, _, pid} -> send(pid, {:relay, self(), payload}) end)
    {:ok, state}
  end

  defp handle_message(_msg, state), do: {:ok, state}

  defp broadcast_daemon_list(user_id) do
    daemons = Relay.Connections.daemons_for(user_id)
    payload = %{type: "daemons", list: daemons}
    user_id
    |> Relay.Connections.clients_for()
    |> Enum.each(fn {_, _, _, pid} -> send(pid, {:relay, self(), payload}) end)
  end

  defp encode(map), do: {:text, Jason.encode!(map)}
end
```

Also add `find_client/2` to `Relay.Connections`:

```elixir
@spec find_client(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
def find_client(user_id, client_id) do
  case :ets.match_object(@table, {user_id, :client, client_id, :_}) do
    [{_, _, _, pid}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

### 2.5 Router & Application

**File: `lib/relay/router.ex`**

```elixir
defmodule Relay.Router do
  @moduledoc "HTTP router. One WebSocket endpoint, one health check."
  use Plug.Router

  plug :match
  plug :dispatch

  get "/ws" do
    conn |> WebSockAdapter.upgrade(Relay.Socket, [], timeout: 60_000)
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

**File: `lib/relay/application.ex`**

```elixir
defmodule Relay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Relay.Connections.init()
    Relay.Auth.init()

    children = [
      {Bandit, plug: Relay.Router, port: port()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end

  defp port, do: Application.get_env(:relay, :port, 4000)
end
```

### 2.6 Deployment

```dockerfile
# relay/Dockerfile
FROM hexpm/elixir:1.19.0-erlang-27.2-alpine-3.21.3 AS build
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
RUN MIX_ENV=prod mix release

FROM alpine:3.21.3
COPY --from=build /app/_build/prod/rel/relay /app
CMD ["/app/bin/relay", "start"]
```

```toml
# relay/fly.toml
app = "opal-relay"
primary_region = "iad"

[http_service]
  internal_port = 4000
  force_https = true

[[services.ports]]
  port = 443
  handlers = ["tls", "http"]
```

---

## Phase 3: Build the Daemon

**Goal**: A fully headless Elixir application. No CLI, no TUI, no interactive
prompts. Starts as a system service, connects to the relay, manages Opal
sessions. All interaction happens remotely through the UI.

**Headless means:**
- No stdout output except structured logs (JSON to stderr)
- No stdin reads — ever
- No interactive `ask_user` prompts — routed through relay to UI
- Starts via `systemd`/`launchd`, not a terminal
- Crashes are restarted by the supervisor, not reported to a user
- Config via files and env vars, not flags or prompts

### 3.1 Bootstrap

```bash
mix new daemon --sup
cd daemon
```

**File: `daemon/mix.exs`**:

```elixir
defp deps do
  [
    {:opal, path: "../opal"},           # local dependency on the library
    {:mint_web_socket, "~> 1.0"},       # WebSocket client
    {:jason, "~> 1.4"}
  ]
end
```

### 3.2 Supervision tree

**File: `lib/daemon/application.ex`**

```elixir
defmodule Daemon.Application do
  @moduledoc "Headless daemon. No terminal interaction."
  use Application

  @impl true
  def start(_type, _args) do
    configure_logging()

    children = [
      Daemon.Machine,
      Daemon.Bridge,
      Daemon.SessionManager,
      {Daemon.RelayConnection, relay_url: relay_url(), token: token()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Daemon.Supervisor)
  end

  defp relay_url, do: Application.get_env(:daemon, :relay_url, "wss://opal-relay.fly.dev/ws")
  defp token, do: Opal.Auth.stored_token()

  defp configure_logging do
    # JSON logs to stderr — no stdout, no interactive output
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    :logger.update_handler_config(:default, :formatter,
      {:logger_formatter, %{template: [:time, " ", :level, " ", :msg, "\n"]}}
    )
  end
end
```

**File: `config/config.exs`**

```elixir
import Config

config :daemon,
  relay_url: System.get_env("OPAL_RELAY_URL", "wss://opal-relay.fly.dev/ws")

# All logs to stderr — stdout is never used
config :logger, :default_handler,
  config: %{type: :standard_error}

# No interactive features in Opal when running headless
config :opal,
  interactive: false
```

### 3.3 Machine identity

**File: `lib/daemon/machine.ex`**

```elixir
defmodule Daemon.Machine do
  use Agent

  @doc "Persistent machine identity. Stored in ~/.opal/machine_id"
  def start_link(_opts) do
    Agent.start_link(fn -> load_or_create() end, name: __MODULE__)
  end

  def id, do: Agent.get(__MODULE__, & &1.id)
  def hostname, do: Agent.get(__MODULE__, & &1.hostname)
  def metadata, do: Agent.get(__MODULE__, & &1)

  defp load_or_create do
    path = Path.join(opal_dir(), "machine_id")

    case File.read(path) do
      {:ok, id} ->
        %{id: String.trim(id), hostname: hostname(), os: os()}

      {:error, _} ->
        id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        File.mkdir_p!(opal_dir())
        File.write!(path, id)
        %{id: id, hostname: hostname(), os: os()}
    end
  end

  defp opal_dir, do: Path.join(System.user_home!(), ".opal")
  defp hostname, do: :inet.gethostname() |> elem(1) |> to_string()
  defp os, do: :os.type() |> elem(0) |> to_string()
end
```

### 3.4 Relay connection

**File: `lib/daemon/relay_connection.ex`**

```elixir
defmodule Daemon.RelayConnection do
  use GenServer
  require Logger

  defstruct [:conn, :websocket, :ref, :relay_url, :token, :buffer, retry_ms: 1_000]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_message(msg) do
    GenServer.cast(__MODULE__, {:send, msg})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      relay_url: opts[:relay_url],
      token: opts[:token],
      buffer: ""
    }
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    uri = URI.parse(state.relay_url)
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws

    case Mint.HTTP.connect(http_scheme, uri.host, uri.port) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(ws_scheme, conn, uri.path || "/", []) do
          {:ok, conn, ref} ->
            {:noreply, %{state | conn: conn, ref: ref, retry_ms: 1_000}}

          {:error, _, reason} ->
            Logger.warning("WebSocket upgrade failed: #{inspect(reason)}")
            schedule_reconnect(state)
        end

      {:error, reason} ->
        Logger.warning("Connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  def handle_info(message, state) when is_tuple(message) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, [{:data, _ref, data}]} ->
        websocket = state.websocket || upgrade_websocket(conn, state.ref)
        handle_frames(conn, websocket, data, state)

      {:ok, conn, _} ->
        {:noreply, %{state | conn: conn}}

      {:error, _, reason, _} ->
        Logger.warning("Stream error: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_cast({:send, msg}, state) do
    frame = {:text, Jason.encode!(msg)}
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
        {:noreply, %{state | conn: conn, websocket: websocket}}

      {:error, _, reason} ->
        Logger.warning("Send failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Internals ---

  defp handle_frames(conn, websocket, data, state) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        Enum.each(frames, &process_frame/1)
        {:noreply, %{state | conn: conn, websocket: websocket}}

      {:error, _, reason} ->
        Logger.warning("Decode error: #{inspect(reason)}")
        {:noreply, %{state | conn: conn}}
    end
  end

  defp process_frame({:text, text}) do
    case Jason.decode(text) do
      {:ok, msg} -> Daemon.Bridge.handle_relay_message(msg)
      _ -> :ok
    end
  end
  defp process_frame({:ping, _}), do: :ok
  defp process_frame({:close, _, _}), do: send(self(), :connect)
  defp process_frame(_), do: :ok

  defp schedule_reconnect(state) do
    delay = min(state.retry_ms, 30_000)
    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | retry_ms: delay * 2, conn: nil, websocket: nil}}
  end

  defp upgrade_websocket(conn, ref) do
    # After HTTP upgrade response, create the WebSocket
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, [])
    websocket
  end
end
```

### 3.5 Session manager

**File: `lib/daemon/session_manager.ex`**

```elixir
defmodule Daemon.SessionManager do
  use GenServer

  @moduledoc """
  Manages local Opal sessions. Tracks which sessions are running,
  subscribes to their events, and forwards events to the relay.
  """

  defstruct sessions: %{}  # %{session_id => pid}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def start_session(opts) do
    GenServer.call(__MODULE__, {:start, opts})
  end

  def stop_session(session_id) do
    GenServer.call(__MODULE__, {:stop, session_id})
  end

  def list_sessions do
    GenServer.call(__MODULE__, :list)
  end

  def prompt(session_id, text) do
    GenServer.call(__MODULE__, {:prompt, session_id, text})
  end

  # --- GenServer ---

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:start, opts}, _from, state) do
    # Inject ask_user callback that routes through the relay
    opts = Map.put(opts, :callbacks, %{
      ask_user: &Daemon.Bridge.relay_ask_user/1,
      confirm: &Daemon.Bridge.relay_confirm/1
    })

    case Opal.start_session(opts) do
      {:ok, pid} ->
        info = Opal.get_info(pid)
        session_id = info.session_id
        Opal.Events.subscribe(session_id)
        sessions = Map.put(state.sessions, session_id, pid)
        {:reply, {:ok, info}, %{state | sessions: sessions}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      pid ->
        Opal.stop_session(pid)
        Opal.Events.unsubscribe(session_id)
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
    end
  end

  def handle_call(:list, _from, state) do
    sessions = Enum.map(state.sessions, fn {id, pid} ->
      try do
        Opal.get_info(pid)
      catch
        _, _ -> %{session_id: id, status: :dead}
      end
    end)
    {:reply, sessions, state}
  end

  def handle_call({:prompt, session_id, text}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      pid ->
        Opal.prompt(pid, text)
        {:reply, :ok, state}
    end
  end

  # Forward Opal events to the relay
  @impl true
  def handle_info({:opal_event, session_id, event}, state) do
    Daemon.Bridge.forward_event(session_id, event)
    {:noreply, state}
  end
end
```

### 3.6 Bridge — routes between relay and Opal

**File: `lib/daemon/bridge.ex`**

```elixir
defmodule Daemon.Bridge do
  @moduledoc "Routes relay messages to Opal and Opal events to relay. Headless — no terminal I/O."
  use GenServer
  require Logger

  defstruct pending_requests: %{}  # %{request_id => from_pid}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # --- Public API ---

  @spec handle_relay_message(map()) :: :ok
  def handle_relay_message(msg), do: GenServer.cast(__MODULE__, {:relay, msg})

  @spec forward_event(String.t(), term()) :: :ok
  def forward_event(session_id, event) do
    Daemon.RelayConnection.send_message(%{
      type: "broadcast",
      payload: %{type: "event", session_id: session_id, event: serialize_event(event)}
    })
  end

  @doc "Blocks until UI responds via relay. Used as Opal callback — never touches stdin."
  @spec relay_ask_user(map()) :: {:ok, String.t()} | {:error, :timeout}
  def relay_ask_user(params) do
    GenServer.call(__MODULE__, {:ask_user, params}, :infinity)
  end

  @spec relay_confirm(map()) :: {:ok, boolean()} | {:error, :timeout}
  def relay_confirm(params) do
    GenServer.call(__MODULE__, {:confirm, params}, :infinity)
  end

  # --- GenServer ---

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:ask_user, params}, from, state) do
    request_id = generate_id()
    Daemon.RelayConnection.send_message(%{
      type: "broadcast",
      payload: %{type: "ask_user", params: params, request_id: request_id}
    })
    {:noreply, %{state | pending_requests: Map.put(state.pending_requests, request_id, from)}}
  end

  def handle_call({:confirm, params}, from, state) do
    request_id = generate_id()
    Daemon.RelayConnection.send_message(%{
      type: "broadcast",
      payload: %{type: "confirm", params: params, request_id: request_id}
    })
    {:noreply, %{state | pending_requests: Map.put(state.pending_requests, request_id, from)}}
  end

  @impl true
  def handle_cast({:relay, msg}, state) do
    state = dispatch(msg, state)
    {:noreply, state}
  end

  # --- Dispatch ---

  defp dispatch(%{"type" => "authenticated", "login" => login}, state) do
    Logger.info("Authenticated as #{login}")
    Daemon.RelayConnection.send_message(%{
      type: "register",
      machine_id: Daemon.Machine.id(),
      hostname: Daemon.Machine.hostname(),
      os: Daemon.Machine.metadata().os,
      sessions: Daemon.SessionManager.list_sessions()
    })
    state
  end

  defp dispatch(%{"type" => "message", "payload" => payload}, state) do
    dispatch_command(payload, state)
  end

  # UI responding to an ask_user/confirm request
  defp dispatch(%{"type" => "response", "request_id" => rid, "result" => result}, state) do
    case Map.pop(state.pending_requests, rid) do
      {nil, _} -> state
      {from, pending} ->
        GenServer.reply(from, {:ok, result})
        %{state | pending_requests: pending}
    end
  end

  defp dispatch(msg, state) do
    Logger.debug("Unhandled relay message: #{msg["type"]}")
    state
  end

  defp dispatch_command(%{"method" => "session/start"} = msg, state) do
    {:ok, info} = Daemon.SessionManager.start_session(msg["params"] || %{})
    reply(msg, info)
    state
  end

  defp dispatch_command(%{"method" => "session/stop", "params" => %{"session_id" => sid}}, state) do
    Daemon.SessionManager.stop_session(sid)
    state
  end

  defp dispatch_command(%{"method" => "session/list"} = msg, state) do
    reply(msg, %{sessions: Daemon.SessionManager.list_sessions()})
    state
  end

  defp dispatch_command(%{"method" => "agent/prompt", "params" => params} = msg, state) do
    Daemon.SessionManager.prompt(params["session_id"], params["text"])
    reply(msg, %{status: "ok"})
    state
  end

  defp dispatch_command(%{"method" => "agent/abort", "params" => %{"session_id" => sid}}, state) do
    Daemon.SessionManager.abort(sid)
    state
  end

  defp dispatch_command(msg, state) do
    Logger.warning("Unknown method: #{msg["method"]}")
    state
  end

  # --- Helpers ---

  defp reply(%{"client_id" => cid, "id" => rid}, result) do
    Daemon.RelayConnection.send_message(%{
      type: "to_client",
      client_id: cid,
      payload: %{type: "response", request_id: rid, result: result}
    })
  end
  defp reply(_, _), do: :ok

  defp serialize_event({type, data}) when is_atom(type), do: %{type: Atom.to_string(type), data: data}
  defp serialize_event(type) when is_atom(type), do: %{type: Atom.to_string(type)}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```

### 3.7 Running the daemon

The daemon is a headless service. No terminal required.

```bash
# Build a self-contained release:
cd daemon && MIX_ENV=prod mix release

# Install as system service (macOS):
cp _build/prod/rel/daemon/bin/daemon /usr/local/bin/opal-daemon
launchctl load ~/Library/LaunchAgents/com.opal.daemon.plist

# Or run directly (logs to stderr):
opal-daemon start
```

**File: `daemon/launchd/com.opal.daemon.plist`** (macOS):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.opal.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/opal-daemon</string>
    <string>start</string>
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/usr/local/var/log/opal-daemon.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPAL_RELAY_URL</key>
    <string>wss://opal-relay.fly.dev/ws</string>
  </dict>
</dict>
</plist>
```

**File: `daemon/systemd/opal-daemon.service`** (Linux):

```ini
[Unit]
Description=Opal Agent Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/opal-daemon start
Restart=always
RestartSec=5
Environment=OPAL_RELAY_URL=wss://opal-relay.fly.dev/ws
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## Phase 4: Build the UI (Bare MVP)

**Goal**: The absolute minimum to verify the full chain works. No CSS
framework, no component library, no Zustand, no build complexity. Plain
HTML5, vanilla TypeScript, one `index.html`. Ship it when `session/start`
+ `agent/prompt` + streaming events work end-to-end through the relay.

**No:**
- No CSS (browser defaults are fine)
- No React (vanilla DOM manipulation)
- No Zustand (state is local variables)
- No IndexedDB (localStorage for the token, that's it)
- No bundler (Vite's dev server + plain TS is enough)
- No component architecture (it's one file)

**Yes:**
- GitHub OAuth login
- See connected daemons
- Start a session on a daemon
- Send a prompt
- See streaming events as they arrive

### 4.1 Bootstrap

```bash
mkdir ui && cd ui
npm init -y
npm install -D vite typescript
```

**File: `ui/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true
  },
  "include": ["src"]
}
```

### 4.2 The entire MVP — one HTML file + one TS module

**File: `ui/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Opal</title>
</head>
<body>
  <div id="app">
    <section id="login-view">
      <h1>Opal</h1>
      <button id="login-btn">Login with GitHub</button>
    </section>

    <section id="main-view" hidden>
      <header>
        <span id="user-info"></span>
        <button id="logout-btn">Logout</button>
      </header>

      <h2>Machines</h2>
      <ul id="daemon-list"></ul>

      <h2>Sessions</h2>
      <button id="new-session-btn" disabled>New Session</button>
      <ul id="session-list"></ul>

      <div id="session-view" hidden>
        <h2>Session: <span id="session-id"></span></h2>
        <pre id="event-log"></pre>
        <form id="prompt-form">
          <textarea id="prompt-input" rows="3" placeholder="Send a prompt..."></textarea>
          <button type="submit">Send</button>
        </form>
      </div>
    </section>
  </div>
  <script type="module" src="/src/main.ts"></script>
</body>
</html>
```

**File: `ui/src/main.ts`**

```typescript
const RELAY_URL = "wss://opal-relay.fly.dev/ws";

// --- State (plain variables, no framework) ---

let token: string | null = localStorage.getItem("opal_token");
let ws: WebSocket | null = null;
let activeDaemon: string | null = null;
let activeSession: string | null = null;

// --- DOM refs ---

const $ = (id: string) => document.getElementById(id)!;
const loginView = $("login-view");
const mainView = $("main-view") as HTMLElement;
const daemonList = $("daemon-list");
const sessionList = $("session-list");
const sessionView = $("session-view") as HTMLElement;
const eventLog = $("event-log");
const promptInput = $("prompt-input") as HTMLTextAreaElement;

// --- Auth ---

$("login-btn").onclick = () => {
  // For MVP: paste token manually. Replace with OAuth device flow later.
  const t = prompt("Paste your GitHub token:");
  if (t) {
    localStorage.setItem("opal_token", t);
    token = t;
    connect();
  }
};

$("logout-btn").onclick = () => {
  localStorage.removeItem("opal_token");
  token = null;
  ws?.close();
  loginView.hidden = false;
  mainView.hidden = true;
};

// --- WebSocket ---

function connect() {
  if (!token) return;
  ws = new WebSocket(RELAY_URL);

  ws.onopen = () => {
    ws!.send(JSON.stringify({ type: "auth", token }));
  };

  ws.onmessage = (e: MessageEvent<string>) => {
    const msg = JSON.parse(e.data);
    handle(msg);
  };

  ws.onclose = () => {
    setTimeout(connect, 3000);
  };
}

function send(msg: Record<string, unknown>) {
  ws?.send(JSON.stringify(msg));
}

// --- Message handling ---

function handle(msg: Record<string, unknown>) {
  switch (msg.type) {
    case "authenticated":
      loginView.hidden = true;
      mainView.hidden = false;
      $("user-info").textContent = `Logged in as ${msg.login}`;
      send({ type: "subscribe" });
      break;

    case "daemons":
      renderDaemons(msg.list as DaemonInfo[]);
      break;

    case "message": {
      const payload = msg.payload as Record<string, unknown>;
      if (payload.type === "event") {
        appendEvent(payload);
      } else if (payload.type === "response") {
        console.log("Response:", payload);
      }
      break;
    }

    case "error":
      alert(`Error: ${msg.message}`);
      break;
  }
}

// --- Render ---

interface DaemonInfo {
  machine_id: string;
  hostname: string;
  online: boolean;
}

function renderDaemons(daemons: DaemonInfo[]) {
  daemonList.innerHTML = "";
  for (const d of daemons) {
    const li = document.createElement("li");
    li.textContent = `${d.online ? "🟢" : "🔴"} ${d.hostname} (${d.machine_id})`;
    li.style.cursor = "pointer";
    li.onclick = () => selectDaemon(d.machine_id);
    daemonList.appendChild(li);
  }
}

function selectDaemon(machineId: string) {
  activeDaemon = machineId;
  ($("new-session-btn") as HTMLButtonElement).disabled = false;
  // Request session list
  send({
    type: "to_daemon",
    machine_id: machineId,
    payload: { method: "session/list", params: {}, id: crypto.randomUUID() },
  });
}

function appendEvent(payload: Record<string, unknown>) {
  const event = payload.event as Record<string, unknown>;
  const line = `[${event.type}] ${JSON.stringify(event.data ?? "")}\n`;
  eventLog.textContent += line;
  eventLog.scrollTop = eventLog.scrollHeight;
}

// --- Actions ---

$("new-session-btn").onclick = () => {
  if (!activeDaemon) return;
  send({
    type: "to_daemon",
    machine_id: activeDaemon,
    payload: { method: "session/start", params: {}, id: crypto.randomUUID() },
  });
  // TODO: read session_id from response, set activeSession
  sessionView.hidden = false;
  eventLog.textContent = "";
};

$("prompt-form").onsubmit = (e: Event) => {
  e.preventDefault();
  if (!activeDaemon || !activeSession || !promptInput.value.trim()) return;
  send({
    type: "to_daemon",
    machine_id: activeDaemon,
    payload: {
      method: "agent/prompt",
      params: { session_id: activeSession, text: promptInput.value },
      id: crypto.randomUUID(),
    },
  });
  promptInput.value = "";
};

// --- Boot ---

if (token) {
  connect();
} else {
  loginView.hidden = false;
  mainView.hidden = true;
}
```

### 4.3 Run

```bash
cd ui && npx vite
# Opens at http://localhost:5173
```

That's the entire UI. ~150 lines of TypeScript. No dependencies beyond
Vite's dev server. When this works end-to-end — login, see daemons, start
session, send prompt, see streaming events — then layer in React, Zustand,
proper components, and IndexedDB persistence.

---

## Phase 5: Pairing Code Authentication

**Goal**: Allow daemon↔client trust without GitHub. Daemon generates a
short-lived code, client enters it, public keys are exchanged. All future
connections use challenge-response.

### 5.1 Daemon keypair generation

**File: `lib/daemon/crypto.ex`**

```elixir
defmodule Daemon.Crypto do
  @moduledoc """
  Handles keypair management, pairing, and E2E encryption.
  Keys stored in ~/.opal/keys/
  """

  @keys_dir Path.join(System.user_home!(), ".opal/keys")

  def init do
    File.mkdir_p!(@keys_dir)
    ensure_keypair()
  end

  # --- Keypair ---

  def ensure_keypair do
    case File.read(private_key_path()) do
      {:ok, _} -> :ok
      {:error, _} -> generate_and_store_keypair()
    end
  end

  def public_key do
    {:ok, priv} = File.read(private_key_path())
    {pub, _} = :crypto.generate_key(:eddh, :x25519, :binary.decode_unsigned(priv))
    pub
  end

  defp generate_and_store_keypair do
    {pub, priv} = :crypto.generate_key(:eddh, :x25519)
    File.write!(private_key_path(), priv)
    File.write!(public_key_path(), pub)
    {pub, priv}
  end

  defp private_key_path, do: Path.join(@keys_dir, "daemon.key")
  defp public_key_path, do: Path.join(@keys_dir, "daemon.pub")

  # --- Pairing codes ---

  @doc "Generate a human-readable pairing code. Format: XXXX-XXXX"
  def generate_pairing_code do
    :crypto.strong_rand_bytes(4)
    |> Base.encode32(case: :upper, padding: false)
    |> String.slice(0, 8)
    |> String.split_at(4)
    |> then(fn {a, b} -> "#{a}-#{b}" end)
  end

  # --- Trusted keys ---

  def trusted_keys do
    path = trusted_keys_path()
    case File.read(path) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      {:error, _} -> []
    end
  end

  def add_trusted_key(public_key, label \\ "unknown") do
    keys = trusted_keys()
    entry = %{key: public_key, label: label, added_at: DateTime.utc_now()}
    File.write!(trusted_keys_path(), :erlang.term_to_binary([entry | keys]))
  end

  def remove_trusted_key(fingerprint) do
    keys = Enum.reject(trusted_keys(), fn k ->
      fingerprint(k.key) == fingerprint
    end)
    File.write!(trusted_keys_path(), :erlang.term_to_binary(keys))
  end

  def is_trusted?(client_public_key) do
    Enum.any?(trusted_keys(), fn k -> k.key == client_public_key end)
  end

  def fingerprint(public_key) do
    :crypto.hash(:sha256, public_key) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp trusted_keys_path, do: Path.join(@keys_dir, "trusted_keys")

  # --- E2E encryption ---

  def derive_shared_secret(their_public_key) do
    {:ok, priv} = File.read(private_key_path())
    :crypto.compute_key(:eddh, their_public_key, priv, :x25519)
  end

  def encrypt(plaintext, shared_secret) do
    nonce = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :chacha20_poly1305, shared_secret, nonce, plaintext, "", true
    )
    nonce <> tag <> ciphertext
  end

  def decrypt(<<nonce::binary-12, tag::binary-16, ciphertext::binary>>, shared_secret) do
    :crypto.crypto_one_time_aead(
      :chacha20_poly1305, shared_secret, nonce, ciphertext, "", tag, false
    )
  end
end
```

### 5.2 Relay pairing support

**Add to `lib/relay/socket.ex`:**

```elixir
# Daemon requests a pairing code
defp handle_message(%{"type" => "request_pairing_code"}, state)
     when state.role == :daemon do
  code = generate_pairing_code()
  :ets.insert(:pairing_codes, {
    code,
    state.user_id,       # nil if using pairing-only auth
    state.machine_id,
    self(),
    System.monotonic_time(:second) + 300  # 5 min TTL
  })
  reply = Jason.encode!(%{type: "pairing_code", code: code})
  {:push, {:text, reply}, state}
end

# Client submits a pairing code
defp handle_message(%{"type" => "pair", "code" => code, "public_key" => client_pub}, state) do
  now = System.monotonic_time(:second)
  case :ets.lookup(:pairing_codes, code) do
    [{^code, _uid, _mid, daemon_pid, expires}] when expires > now ->
      # Forward client's public key to daemon
      send(daemon_pid, {:relay, self(), %{
        "type" => "pair_request",
        "client_public_key" => client_pub,
        "client_pid" => inspect(self())
      }})
      :ets.delete(:pairing_codes, code)
      {:ok, state}

    _ ->
      err = Jason.encode!(%{type: "error", message: "invalid or expired code"})
      {:push, {:text, err}, state}
  end
end
```

### 5.3 Pairing flow on the daemon side

**Add to `lib/daemon/bridge.ex`:**

```elixir
def handle_relay_message(%{"type" => "pair_request", "client_public_key" => key}) do
  # Automatically trust during pairing
  Daemon.Crypto.add_trusted_key(Base.decode64!(key), "paired-client")
  Logger.info("✅ New client paired: #{Daemon.Crypto.fingerprint(Base.decode64!(key))}")

  # Send our public key back
  our_pub = Daemon.Crypto.public_key() |> Base.encode64()
  Daemon.RelayConnection.send_message(%{
    type: "broadcast",
    payload: %{type: "paired", daemon_public_key: our_pub}
  })
end
```

### 5.4 CLI commands for key management

```bash
# Show pairing code:
$ opal daemon pair
🔑 Pairing code: KXNF-7T2M (expires in 5 minutes)

# List trusted clients:
$ opal daemon keys
  a1b2c3d4e5f6g7h8  paired-client  2026-02-27T10:00:00Z
  f8e7d6c5b4a3c2d1  macbook-air    2026-02-25T14:30:00Z

# Revoke a client:
$ opal daemon revoke a1b2c3d4e5f6g7h8
✅ Revoked client a1b2c3d4e5f6g7h8
```

---

## Phase 6: E2E Encryption + Command Signing

**Goal**: All message content is encrypted end-to-end. Every command is
signed and timestamped. Relay sees only opaque blobs. Replay is impossible.

This phase is **not optional** — it's the RCE prevention layer.

### 6.1 Command signing (daemon side)

Every command the daemon executes must be signed by a trusted client key.

**File: `lib/daemon/verify.ex`**

```elixir
defmodule Daemon.Verify do
  @moduledoc "Verifies command signatures and timestamps. Rejects unsigned or stale commands."

  @max_age_seconds 30

  @type signed_command :: %{
    payload: binary(),
    signature: binary(),
    public_key: binary(),
    timestamp: integer()
  }

  @spec verify(signed_command()) :: {:ok, map()} | {:error, atom()}
  def verify(%{payload: payload, signature: sig, public_key: pub, timestamp: ts}) do
    with :ok <- check_trusted(pub),
         :ok <- check_timestamp(ts),
         :ok <- check_signature(payload, sig, pub) do
      {:ok, Jason.decode!(payload)}
    end
  end

  defp check_trusted(pub) do
    if Daemon.Crypto.is_trusted?(pub), do: :ok, else: {:error, :untrusted_key}
  end

  defp check_timestamp(ts) do
    age = abs(System.os_time(:second) - ts)
    if age <= @max_age_seconds, do: :ok, else: {:error, :stale_command}
  end

  defp check_signature(payload, sig, pub) do
    message = payload <> <<timestamp::64>>
    if :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
```

**Updated `lib/daemon/bridge.ex`** — reject unsigned commands:

```elixir
defp dispatch(%{"type" => "message", "payload" => payload, "signature" => sig,
                "public_key" => pub, "timestamp" => ts}, state) do
  case Daemon.Verify.verify(%{
    payload: payload,
    signature: Base.decode64!(sig),
    public_key: Base.decode64!(pub),
    timestamp: ts
  }) do
    {:ok, command} ->
      dispatch_command(command, state)

    {:error, reason} ->
      Logger.warning("Rejected command: #{reason}")
      state
  end
end

# Unsigned messages are silently dropped
defp dispatch(%{"type" => "message"}, state) do
  Logger.warning("Rejected unsigned command")
  state
end
```

### 6.2 Command signing (client side)

**File: `ui/src/lib/signing.ts`**

```typescript
export async function signCommand(
  payload: Record<string, unknown>,
  privateKey: CryptoKey
): Promise<SignedCommand> {
  const timestamp = Math.floor(Date.now() / 1000);
  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));

  // Sign payload + timestamp
  const toSign = new Uint8Array(payloadBytes.length + 8);
  toSign.set(payloadBytes);
  new DataView(toSign.buffer).setBigUint64(payloadBytes.length, BigInt(timestamp));

  const signature = await crypto.subtle.sign("Ed25519", privateKey, toSign);
  const publicKey = await crypto.subtle.exportKey("raw", privateKey);

  return {
    payload: JSON.stringify(payload),
    signature: bytesToBase64(new Uint8Array(signature)),
    public_key: bytesToBase64(new Uint8Array(publicKey)),
    timestamp,
  };
}

interface SignedCommand {
  payload: string;
  signature: string;
  public_key: string;
  timestamp: number;
}
```

### 6.3 Encrypted envelope

Once both sides have a shared secret (from pairing or X25519 exchange),
every payload becomes encrypted:

```elixir
# Daemon side — encrypting outgoing events:
def forward_event(session_id, event) do
  payload = Jason.encode!(%{session_id: session_id, event: serialize_event(event)})
  encrypted = Daemon.Crypto.encrypt(payload, shared_secret())
  Daemon.RelayConnection.send_message(%{
    type: "broadcast",
    payload: %{type: "encrypted", data: Base.encode64(encrypted)}
  })
end
```

```typescript
// Client side — decrypting incoming events:
function handleMessage(msg: any) {
  if (msg.payload?.type === "encrypted") {
    const decrypted = decrypt(
      base64ToBytes(msg.payload.data),
      sharedSecret
    );
    const payload = JSON.parse(new TextDecoder().decode(decrypted));
    handleEvent(payload);
  }
}
```

### 6.4 Client-side crypto (Web Crypto API)

**File: `ui/src/lib/crypto.ts`**

```typescript
export async function generateKeyPair() {
  const keyPair = await crypto.subtle.generateKey(
    { name: "X25519" },
    true,
    ["deriveBits"]
  );
  return keyPair;
}

export async function deriveSharedSecret(
  privateKey: CryptoKey,
  publicKeyBytes: Uint8Array
) {
  const publicKey = await crypto.subtle.importKey(
    "raw",
    publicKeyBytes,
    { name: "X25519" },
    false,
    []
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "X25519", public: publicKey },
    privateKey,
    256
  );
  return new Uint8Array(bits);
}

export async function encrypt(
  plaintext: Uint8Array,
  key: Uint8Array
): Promise<Uint8Array> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const cryptoKey = await crypto.subtle.importKey(
    "raw", key, "AES-GCM", false, ["encrypt"]
  );
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    cryptoKey,
    plaintext
  );
  // nonce (12) + ciphertext (includes 16-byte tag)
  const result = new Uint8Array(12 + ciphertext.byteLength);
  result.set(nonce);
  result.set(new Uint8Array(ciphertext), 12);
  return result;
}

export async function decrypt(
  data: Uint8Array,
  key: Uint8Array
): Promise<Uint8Array> {
  const nonce = data.slice(0, 12);
  const ciphertext = data.slice(12);
  const cryptoKey = await crypto.subtle.importKey(
    "raw", key, "AES-GCM", false, ["decrypt"]
  );
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce },
    cryptoKey,
    ciphertext
  );
  return new Uint8Array(plaintext);
}
```

> Note: Web Crypto uses AES-GCM (native browser support) while the Elixir
> side uses ChaCha20-Poly1305. For interop, either standardize on AES-GCM
> on both sides (Erlang `:crypto` supports it) or use ChaCha20 via a JS
> library like `@noble/ciphers`. AES-GCM is simpler since it's built into
> both platforms.

---

## Testing Strategy

Every security boundary and protocol layer gets tests. No exceptions.
Tests are the proof that the security invariants hold.

### Relay tests (`relay/test/`)

```elixir
# test/relay/auth_test.exs
describe "Relay.Auth" do
  test "verify_token/1 returns identity for valid GitHub token"
  test "verify_token/1 returns error for invalid token"
  test "verify_token/1 caches results for TTL duration"
  test "verify_token/1 re-fetches after TTL expires"
end

# test/relay/connections_test.exs
describe "Relay.Connections" do
  test "register_daemon/4 stores connection and monitors process"
  test "register_client/3 stores connection and monitors process"
  test "daemons_for/1 returns only daemons for given user"
  test "daemons_for/1 returns empty list for unknown user"
  test "find_daemon/2 returns pid for existing daemon"
  test "find_daemon/2 returns error for unknown daemon"
  test "remove/1 cleans up all entries for dead process"
  test "cross-user isolation — user A cannot see user B's daemons"
end

# test/relay/socket_test.exs
describe "Relay.Socket" do
  # Auth
  test "rejects messages before authentication"
  test "authenticates with valid GitHub token"
  test "rejects invalid GitHub token"

  # Registration
  test "daemon registration adds to connections"
  test "client subscription returns daemon list"
  test "clients receive updated daemon list on new registration"

  # Routing
  test "client message reaches correct daemon"
  test "client message does NOT reach another user's daemon"
  test "daemon broadcast reaches all clients of same user"
  test "daemon broadcast does NOT reach other users' clients"
  test "to_client message reaches only specified client"

  # Cleanup
  test "daemon disconnect removes from connections"
  test "client disconnect removes from connections"
  test "clients notified when daemon disconnects"
end

# test/relay/security_test.exs
describe "Security" do
  test "user A cannot route messages to user B's daemons"
  test "unauthenticated WebSocket cannot send any commands"
  test "client cannot register as daemon"
  test "daemon cannot register as client"
  test "expired auth cache forces re-verification"
end
```

### Daemon tests (`daemon/test/`)

```elixir
# test/daemon/crypto_test.exs
describe "Daemon.Crypto" do
  # Keypair management
  test "ensure_keypair/0 generates keypair on first run"
  test "ensure_keypair/0 reuses existing keypair"
  test "public_key/0 derives correct public key from stored private key"

  # Pairing codes
  test "generate_pairing_code/0 returns XXXX-XXXX format"
  test "generate_pairing_code/0 generates unique codes"

  # Trusted keys
  test "add_trusted_key/2 persists key to disk"
  test "is_trusted?/1 returns true for added key"
  test "is_trusted?/1 returns false for unknown key"
  test "remove_trusted_key/1 removes by fingerprint"
  test "remove_trusted_key/1 is idempotent for unknown fingerprint"

  # Encryption round-trip
  test "encrypt/2 then decrypt/2 returns original plaintext"
  test "decrypt/2 fails with wrong shared secret"
  test "decrypt/2 fails with tampered ciphertext"
  test "decrypt/2 fails with tampered nonce"
  test "each encrypt/2 call produces different ciphertext (unique nonce)"
end

# test/daemon/verify_test.exs
describe "Daemon.Verify" do
  test "verify/1 accepts validly signed command from trusted key"
  test "verify/1 rejects command from untrusted key"
  test "verify/1 rejects command with invalid signature"
  test "verify/1 rejects command older than 30 seconds"
  test "verify/1 rejects command with future timestamp beyond tolerance"
  test "verify/1 rejects tampered payload (signature mismatch)"
  test "verify/1 rejects replayed command after key revocation"
end

# test/daemon/bridge_test.exs
describe "Daemon.Bridge" do
  # Dispatch
  test "session/start creates Opal session"
  test "session/stop stops existing session"
  test "session/list returns all active sessions"
  test "agent/prompt forwards to correct session"

  # Security enforcement
  test "rejects unsigned commands"
  test "rejects commands from untrusted keys"
  test "rejects stale commands (>30s old)"
  test "rejects commands with tampered payloads"

  # ask_user relay
  test "relay_ask_user/1 blocks until UI responds"
  test "relay_ask_user/1 correlates response by request_id"
  test "relay_confirm/1 blocks until UI responds"
end

# test/daemon/session_manager_test.exs
describe "Daemon.SessionManager" do
  test "start_session/1 starts Opal session and subscribes to events"
  test "stop_session/1 stops session and unsubscribes"
  test "list_sessions/0 returns info for all active sessions"
  test "prompt/2 forwards prompt to correct session"
  test "forwards Opal events to Bridge"
  test "handles session crash gracefully"
end

# test/daemon/relay_connection_test.exs
describe "Daemon.RelayConnection" do
  test "connects and authenticates on startup"
  test "reconnects with exponential backoff on disconnect"
  test "reconnect resets backoff on successful connection"
  test "sends messages through WebSocket"
  test "routes incoming frames to Bridge"
end
```

### Crypto interop tests

These verify that Elixir and TypeScript crypto produce compatible output.
Run as part of CI using a Node.js script that exercises the JS side.

```elixir
# test/daemon/crypto_interop_test.exs
describe "Crypto interop (Elixir ↔ TypeScript)" do
  test "Elixir encrypt → TypeScript decrypt round-trip"
  test "TypeScript encrypt → Elixir decrypt round-trip"
  test "shared secret derivation produces same result on both sides"
  test "TypeScript-signed command validates on Elixir side"
  test "Elixir-signed command validates on TypeScript side"
end
```

```typescript
// ui/src/lib/__tests__/crypto.test.ts
describe("crypto", () => {
  test("generateKeyPair produces valid X25519 keypair");
  test("deriveSharedSecret matches Elixir-derived secret");
  test("encrypt/decrypt round-trip");
  test("decrypt fails with wrong key");
  test("decrypt fails with tampered ciphertext");
});

// ui/src/lib/__tests__/signing.test.ts
describe("signing", () => {
  test("signCommand produces valid Ed25519 signature");
  test("signed command includes correct timestamp");
  test("different payloads produce different signatures");
  test("signature matches Elixir verification");
});
```

### UI tests (`ui/src/__tests__/`)

```typescript
// ui/src/__tests__/main.test.ts
// MVP tests — verify the basics work, nothing more
describe("MVP UI", () => {
  test("token saved to localStorage on login");
  test("token cleared on logout");
  test("WebSocket connects with token on boot");
  test("authenticated message shows main view");
  test("daemons message renders daemon list");
  test("clicking daemon enables New Session button");
  test("event messages append to event log pre");
  test("prompt form sends to_daemon message");
  test("reconnects on WebSocket close");
});
```

### Integration tests

End-to-end tests that verify the full chain works.

```elixir
# test/integration/full_chain_test.exs
describe "Full chain: UI → Relay → Daemon → Opal" do
  setup do
    # Start relay in test mode
    # Start daemon connected to test relay
    # Simulate client WebSocket connection
  end

  test "client authenticates, sees daemon, starts session, receives events"
  test "client sends prompt, receives streaming message_delta events"
  test "client ask_user request reaches UI and response reaches daemon"
  test "second client for same user sees same daemons"
  test "client for different user sees zero daemons"
  test "daemon disconnect updates client daemon list"
  test "daemon reconnect restores client daemon list"
end

# test/integration/security_integration_test.exs
describe "Security integration" do
  test "stolen token without paired key cannot execute commands"
  test "paired key from revoked client is rejected"
  test "replayed signed command is rejected (stale timestamp)"
  test "tampered encrypted payload fails decryption"
  test "relay cannot inject commands (E2E encryption)"
  test "cross-user isolation end-to-end"
end
```

---

## Summary: Build Order & Dependencies

```
Phase 1: Slim opal/ + delete cli/   ← Do first. Net negative LOC.
  │
  ├──► Phase 2: Relay                ← Independent Elixir app.
  │
  └──► Phase 3: Daemon               ← Depends on Phase 1 (clean opal/ API)
         │                              Depends on Phase 2 (relay to connect to)
         │
         └──► Phase 4: UI            ← Depends on Phase 2 + Phase 3
                │
                └──► Phase 5+6: Security  ← Pairing + E2E + signing.
                     (NOT optional)         Required before any real use.
```

**Phases 5 and 6 are security-critical.** Do not use the system with real
code on real machines until pairing keys, E2E encryption, and command
signing are in place. Without them, a stolen GitHub token = RCE on every
connected machine.

**Net LOC change:**

| Component              | LOC     | Complexity |
|------------------------|---------|------------|
| DELETE cli/            | -5,000  | None — just delete |
| DELETE opal/rpc/       | -1,950  | Low — delete + 1 refactor |
| NEW relay/             | +400    | Low — stateless WebSocket router |
| NEW daemon/            | +600    | Medium — session bridge + reconnect |
| NEW ui/ (bare MVP)     | +150    | Low — one HTML file, one TS module |
| NEW pairing codes      | +200    | Low — crypto is built-in |
| NEW E2E + signing      | +250    | Low — but needs interop testing |
| **Net**                | **-6,850** | **Smaller, cleaner codebase** |
