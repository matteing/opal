# Repository Restructuring Proposal

This document captures the chosen direction for restructuring Opal's repository layout and build system. It distills the decisions made from the broader [architecture exploration](architecture-exploration.md).

## Goals

1. **Elixir front-and-center.** `mix test` works at the root. Hex publishing is natural. Elixir contributors clone and go.
2. **CLI stays first-class.** The terminal UI is a primary product — it lives at `cli/`, not buried in `clients/typescript/cli/`.
3. **Simple core.** A kernel/batteries boundary keeps the agent engine focused and prevents dependency creep.
4. **One tool to rule them all.** mise replaces Nx, manages tool versions _and_ task orchestration in a single config.
5. **No unnecessary infrastructure.** No pnpm workspace. No Nx. No umbrella (yet). Earn complexity when it's needed.

### Non-goals

- **Backwards compatibility.** Opal is pre-1.0. We will break APIs, directory layouts, and conventions freely in service of getting the architecture right. No deprecation cycles, no migration guides for pre-release consumers.

---

## Repository Layout

```
opal/
├── lib/opal/                      # Kernel — minimal agent engine
│   ├── agent.ex                   # Agent loop (:gen_statem)
│   ├── agent/                     # Stream parsing, tool_runner, retry, compaction
│   ├── session.ex                 # Session management
│   ├── session/                   # Conversation tree, persistence, builder
│   ├── events.ex                  # Registry-based pub/sub
│   ├── provider.ex                # Provider behaviour + EventStream struct
│   ├── tool.ex                    # Tool behaviour (no implementations)
│   ├── config.ex                  # Typed configuration
│   ├── context.ex                 # Walk-up context discovery (AGENTS.md, etc.)
│   ├── message.ex                 # Message types
│   ├── model.ex                   # Model/provider resolution
│   └── token.ex                   # Token counting
├── lib/opal/ext/                  # Batteries — default implementations
│   ├── tools/                     # read_file, edit_file, write_file, shell, sub_agent, etc.
│   ├── providers/                 # Copilot, LLM (ReqLLM adapter)
│   ├── mcp/                       # MCP bridge, client, resources
│   ├── rpc/                       # JSON-RPC server, stdio transport, protocol
│   └── auth/                      # GitHub Copilot auth
├── lib/opal.ex                    # Public API facade
├── mix.exs                        # Root mix project — {:opal, "~> 0.2"}
├── test/
├── config/
├── priv/
│   └── rpc_schema.json
│
├── cli/                           # First-class TUI (top-level peer, not nested)
│   ├── src/
│   │   ├── app.tsx
│   │   ├── bin.ts
│   │   ├── components/
│   │   ├── hooks/
│   │   └── sdk/                   # TS client (extract to own package later)
│   ├── package.json               # @unfinite/opal
│   └── tsconfig.json
│
├── docs/
├── scripts/
├── .mise.toml                     # Task runner + tool versions (replaces Nx)
└── .prettierrc                    # Shared Prettier config (optional)
```

### Key Decisions

**Root IS the Elixir project.** `mix.exs` lives at the repo root. No `packages/core/` indirection. Elixir tooling (ExDoc, Dialyzer, Credo) works without path gymnastics.

**CLI is a top-level peer.** `cli/src/app.tsx` is one level deep, same as today's `packages/cli/src/app.tsx`. It's the primary product, not a nested consumer.

**No pnpm workspace.** With a single TypeScript project (`cli/`), there's nothing to link. `pnpm-workspace.yaml` and the root `package.json` are deleted. CLI dependencies live in `cli/package.json`. Shared config (Prettier, ESLint) either moves into `cli/` or becomes a root dotfile (`.prettierrc`). Lefthook stays at root and calls `mise run lint`.

**Not an umbrella — yet.** The kernel/batteries boundary is a module convention enforced by a Credo rule or CI check. This gives 80% of the value of an umbrella at 20% of the cost. If the kernel stabilizes and separate Hex packages become valuable, extracting `opal_kernel` is mechanical because the edges are already clean.

---

## Kernel vs. Batteries

Everything under `lib/opal/*.ex` is the kernel. Everything under `lib/opal/ext/` is batteries.

**The rule: nothing in `lib/opal/*.ex` may import from `lib/opal/ext/`.** Dependencies flow one way — batteries depend on kernel, never the reverse.

| Kernel (`lib/opal/`)             | Batteries (`lib/opal/ext/`)                |
|----------------------------------|--------------------------------------------|
| `Opal.Agent` (gen_statem)        | `Opal.Ext.Tool.Read/Edit/Write/Shell`      |
| `Opal.Session` + tree            | `Opal.Ext.Tool.SubAgent/Debug/Tasks`       |
| `Opal.Events` (pub/sub)          | `Opal.Ext.Provider.Copilot/LLM`            |
| `Opal.Provider` behaviour        | `Opal.Ext.MCP.*` (bridge, client)          |
| `Opal.Tool` behaviour            | `Opal.Ext.RPC.*` (stdio, handler, protocol)|
| `Opal.Config`                    | `Opal.Ext.Auth.*` (GitHub Copilot)         |
| `Opal.Message`                   | `Opal.Application` (supervision tree)      |
| `Provider.EventStream` (struct)  |                                             |

---

## Tool DX: `use Opal.Tool`

Today tools implement the `Opal.Tool` behaviour with separate callback functions for `name/0`, `description/0`, `parameters/0`, etc. This works but is verbose. A `use Opal.Tool` macro should provide a cleaner declaration:

```elixir
defmodule OpalTools.GitHub do
  use Opal.Tool,
    name: "github",
    description: "Interact with GitHub API",
    group: :integrations

  @config [:github_token]

  @impl true
  def parameters, do: %{...}

  @impl true
  def execute(args, context) do
    token = context.config[:github_token]
    # ...
  end
end
```

The macro should:
- Auto-derive `name/0` from the module name if not specified
- Validate the parameter schema at compile time
- Support `@config` declarations for required environment/config

Tools are **always explicitly registered** — passed as a list to `Opal.start_session/1` or declared in config. No auto-discovery, no classpath scanning. Explicit is better.

```elixir
{:ok, agent} = Opal.start_session(%{
  tools: [OpalTools.GitHub, OpalTools.Jira, MyApp.DeployTool]
})
```

---

## Provider DX: `use Opal.Provider`

Same pattern as tools. Providers should be packageable as separate Hex packages with a clean `use` macro:

```elixir
# In a separate hex package: opal_provider_anthropic
defmodule OpalProvider.Anthropic do
  use Opal.Provider,
    name: :anthropic,
    models: ["claude-sonnet-4", "claude-opus-4"]

  @impl true
  def stream(model, messages, tools, opts) do
    # Direct Anthropic API integration
  end
end
```

Today `Opal.Provider.LLM` uses ReqLLM as a universal adapter, which is practical but limits provider-specific features. A plugin system would let providers ship optimizations (native streaming, provider-specific tool formats, custom retry logic) without bloating core.

This is a goal if it can be supported cleanly — the `Opal.Provider` behaviour already exists, so the main work is ensuring the interface is stable enough for external packages to depend on.

---

## CLI Surface

Opal has two binaries: **`opal`** (the TypeScript TUI client) and **`opal-server`** (the Elixir OTP backend). They communicate over JSON-RPC 2.0 on stdio. This section maps the entire CLI surface as it exists today, identifies gaps, and proposes improvements.

### Current: `opal` (CLI client)

**Entry point:** `packages/cli/src/bin.ts` — a yargs-based parser that renders a React/Ink TUI.

| Flag | Alias | Type | Description |
|---|---|---|---|
| `--model` | | `string` | Model to use (e.g. `copilot/claude-sonnet-4`) |
| `--working-dir` | `-C` | `string` | Working directory for the session |
| `--session` | `-s` | `string` | Resume a previous session by ID |
| `--verbose` | `-v` | `boolean` | Verbose output |
| `--auto-confirm` | | `boolean` | Auto-confirm all tool executions |
| `--debug` | | `boolean` | Enable debug tools for the session |

**No subcommands.** The CLI is a single interactive TUI mode — there's no `opal session list`, `opal config`, or `opal version`. The exit message prints `Resume this session: opal --session "<id>"`.

**Slash commands** (in-session, handled by the TUI, not by the server):

| Command | Description |
|---|---|
| `/model` | Show current model |
| `/model <provider:id>` | Switch model |
| `/models` | Interactive model picker |
| `/agents` | List active sub-agents |
| `/agents <n\|main>` | Switch view to sub-agent or main |
| `/opal` | Open configuration menu (features, tools) |
| `/compact` | Compact conversation history |
| `/debug` | Toggle RPC message panel |
| `/help` | Show help |

### Current: `opal-server` (Elixir backend)

**Entry point:** `Opal.Application` — a pure OTP app. No CLI arg parsing, no escript main, no `OptionParser`. Started via `mix run --no-halt` (dev) or as a Burrito-wrapped native binary.

**No flags, by design.** `opal-server` is a pure JSON-RPC runtime. It boots, attaches to stdio, and speaks protocol. There are no subcommands, no `--verbose`, no `--data-dir`. Configuration that affects runtime behavior (`OPAL_DATA_DIR`, `OPAL_SHELL`, `OPAL_COPILOT_DOMAIN`) uses environment variables — the correct mechanism for process-level config set by the parent (the CLI). Everything else is controlled via RPC calls after the connection is established.

This is intentional minimalism, not a gap. The server is a component managed by the CLI, not a user-facing tool. Adding CLI flags would create a second configuration surface that competes with the protocol. Any capability the server needs to expose — log level, diagnostics, Erlang node setup — should be an RPC method so all clients (TUI, SDK, scripts) can use it uniformly.

**Resolution chain** (how the CLI finds the server):
1. `opal-server` on `$PATH` (user-installed Burrito binary)
2. Bundled platform binary in `releases/` (shipped with npm package)
3. Monorepo dev mode: `elixir --sname opal -S mix run --no-halt` in `opal/`

### RPC Protocol Surface

All capabilities are exposed as JSON-RPC 2.0 methods, defined in `Opal.RPC.Protocol` (single source of truth) and dispatched by `Opal.RPC.Handler`.

**Client → Server Methods (19):**

| Method | Description |
|---|---|
| `session/start` | Create a new session (model, working_dir, tools, MCP servers, system_prompt) |
| `agent/prompt` | Send user prompt to agent |
| `agent/steer` | Mid-stream steering message |
| `agent/abort` | Abort the running agent |
| `agent/state` | Get agent state (status, model, message count, tools) |
| `session/list` | List saved sessions |
| `session/branch` | Branch conversation at a specific entry |
| `session/compact` | Compact conversation history |
| `models/list` | List available models (optionally filtered by provider) |
| `model/set` | Change model mid-session |
| `thinking/set` | Set reasoning effort level (off/low/medium/high) |
| `auth/status` | Probe auth readiness across providers |
| `auth/login` | Start device-code OAuth flow |
| `auth/poll` | Poll for device-code authorization |
| `auth/set_key` | Save an API key for a provider |
| `tasks/list` | List active tasks for a session |
| `settings/get` | Get all persistent user settings |
| `settings/save` | Save user settings (merged) |
| `opal/config/get` | Get runtime config for a session (feature flags, tools, distribution) |
| `opal/config/set` | Update runtime config (feature flags, tools, distribution) |
| `opal/ping` | Liveness check |

**Server → Client Requests (3):**

| Method | Description |
|---|---|
| `client/confirm` | Ask user for tool execution confirmation (allow/deny/allow_session) |
| `client/input` | Ask user for freeform text (optionally masked for secrets) |
| `client/ask_user` | Ask user a question with optional multiple-choice answers |

**Event Notifications (16 types, all via `agent/event`):**

`agent_start`, `agent_end`, `agent_abort`, `message_start`, `message_delta`, `thinking_start`, `thinking_delta`, `tool_execution_start`, `tool_execution_end`, `turn_end`, `error`, `context_discovered`, `skill_loaded`, `sub_agent_event`, `usage_update`, `status_update`, `agent_recovered`

### Dev scripts

| Script | Purpose |
|---|---|
| `scripts/inspect.sh` | Connect an IEx shell to a running Opal node via `--remsh` |
| `scripts/opal-rpc.exs` | One-off RPC call via `mix run` (e.g. `opal/ping`, `auth/status`) |
| `scripts/opal-session.exs` | Boot a session, send a prompt, stream events — headless test harness |

### Gaps

1. **No `--version` / `--help` beyond yargs.** Neither binary prints a version. `opal --version` should exist.

2. **No non-interactive mode.** There's no way to do `opal "prompt" --no-tui` and get output on stdout. The only headless path is `scripts/opal-session.exs`, which requires the Elixir toolchain. A real scriptable mode (`opal run "List all files" -C /tmp`) would unlock CI, pre-commit hooks, and piping.

3. **No `opal session` subcommand family.** Session management is only reachable via `--session` (resume) and the `/compact` slash command. Missing: `opal session list`, `opal session show <id>`, `opal session delete <id>`, `opal session export <id>`.

4. **No `opal auth` subcommand.** Login flow is only triggered interactively when the TUI detects missing credentials. Should be: `opal auth login`, `opal auth status`, `opal auth set-key <provider>`.

5. **No `opal config` subcommand.** Settings/config is only accessible via the `/opal` slash command or raw RPC calls. Should be: `opal config get`, `opal config set <key> <value>`.

6. **Erlang distribution not exposed via config.** Today, connecting an IEx shell to a running Opal node requires knowing the node name and cookie, which are written to `~/.opal/node` at boot and require the `scripts/inspect.sh` helper. This should be controllable via the existing `opal/config/set` method: setting `distribution: {name: "opal", cookie: "abc"}` starts distribution, setting `distribution: null` stops it, and `opal/config/get` returns the current state. The CLI can then offer `opal --sname` without the user needing to know Erlang internals.

7. **No `--prompt` / positional arg for quick one-shots.** `opal "What is this project?"` doesn't work — the TUI always starts. A positional arg could start the TUI pre-loaded with that prompt, or in `--no-tui` mode just run it headlessly.

8. **Version/capability negotiation is missing.** The RPC protocol has no `opal/version` or `opal/capabilities` method. If the CLI and server are different versions, there's silent incompatibility. Adding a version handshake in `session/start` (or a standalone method) would catch this early.

9. **No `opal doctor` / `opal check`.** No way to verify the installation: is the server binary present? Is auth working? Is the Elixir version correct? A diagnostic command would cut support issues.

### Proposed CLI structure

```
opal [prompt]                       # Start TUI (or headless with --no-tui)
opal [prompt] --no-tui              # Headless: print response to stdout
opal --session <id>                 # Resume session
opal --model <provider/id>          # Override model
opal -C <dir>                       # Working directory
opal --auto-confirm                 # Skip confirmations
opal --verbose                      # Verbose output
opal --version                      # Print opal + server versions
opal --sname <name>                 # Start with Erlang distribution (short name)
opal --cookie <cookie>              # Set Erlang cookie (default: random)

opal auth login                     # Device-code OAuth login
opal auth status                    # Show auth state
opal auth set-key <provider>        # Save API key (prompts for value)

opal session list                   # List saved sessions
opal session show <id>              # Show session summary
opal session delete <id>            # Delete a session
opal session export <id>            # Export session as JSON

opal config get [key]               # Show config (all or specific key)
opal config set <key> <value>       # Set config value

opal doctor                         # Check installation health
```

The subcommands should be conventional CLI (no TUI) — they run, print, and exit. The TUI is reserved for the default interactive mode.

**Priority order:** `--version` and non-interactive mode are the most impactful. Subcommands for auth and session are quality-of-life. `opal doctor` is nice-to-have.

---

## Edges to Cut

The kernel currently has compile-time references to batteries. These must be refactored before the split is clean:

1. **`ToolRunner` hard-codes tool module identity checks** — `&1 == Opal.Tool.SubAgent`, `&1 == Opal.Tool.Debug`, `&1 == Opal.Tool.UseSkill`. **Fix:** Add a `tags/0` callback to `Opal.Tool` behaviour. Tools declare `:sub_agent`, `:debug`, `:skill`, `:mcp`, etc. The kernel filters by tag, never by module identity.

2. **`Opal.Agent` calls `Opal.MCP.Bridge.discover_tool_modules/2` directly.** **Fix:** Accept MCP discovery as an optional callback/module in config, or use `Code.ensure_loaded?/1` with a behaviour.

3. **`Opal.Agent` calls `Opal.Provider.StreamCollector.collect_text/3`** for auto-titling. **Fix:** Move `StreamCollector` to kernel (it's provider-agnostic stream utilities) or make title generation a hook.

4. **`Opal.Application` references `Opal.RPC.Stdio`** in the supervision tree. **Fix:** Already config-guarded via `start_rpc: false`. Move the conditional child addition to batteries-owned setup, or keep as-is since it's runtime-conditional.

---

## Build & Orchestration: mise

[mise](https://mise.jdx.dev/) replaces **both** Nx (task orchestration) **and** tool version management in a single `.mise.toml`.

```toml
# .mise.toml
min_version = "2025.1"

[tools]
erlang = "27.2"
elixir = "1.18.3-otp-27"
node = { version = "22", postinstall = "corepack enable" }

[env]
OPAL_SHELL = "zsh"

# ── Build pipeline ────────────────────────────────────────────
# sources/outputs enable skip-if-unchanged — replaces Nx caching

[tasks."build:core"]
description = "Compile Elixir core"
run = "mix compile --warnings-as-errors"
sources = ["lib/**/*.ex", "mix.exs", "mix.lock"]
outputs = ["_build/dev/**/*.beam"]

[tasks.codegen]
description = "Generate TS types from Elixir schemas"
depends = ["build:core"]
run = "mix run scripts/codegen_ts.exs"
sources = ["lib/opal/rpc/**/*.ex", "scripts/codegen_ts.exs"]
outputs = ["cli/src/sdk/types.ts"]

[tasks."build:cli"]
description = "Compile TypeScript CLI"
depends = ["codegen"]
dir = "cli"
run = "npx tsc"
sources = ["cli/src/**/*.{ts,tsx}", "cli/tsconfig.json"]
outputs = ["cli/dist/**/*.js"]

[tasks.build]
description = "Full build: core → codegen → CLI"
depends = ["build:cli"]  # chain resolves build:core → codegen

# ── Test (independent — wildcard runs them in parallel) ───────

[tasks."test:core"]
description = "Run Elixir tests"
run = "mix test"

[tasks."test:cli"]
description = "Run CLI tests"
dir = "cli"
run = "npx vitest run"

[tasks.test]
description = "Run all tests"
depends = ["test:*"]

# ── Lint & Format ─────────────────────────────────────────────

[tasks."lint:core"]
run = "mix format --check-formatted"

[tasks."lint:cli"]
dir = "cli"
run = ["pnpm lint", "pnpm format:check"]

[tasks.lint]
depends = ["lint:*"]

[tasks."format:core"]
run = "mix format"

[tasks."format:cli"]
dir = "cli"
run = ["pnpm lint:fix", "pnpm format"]

[tasks.format]
depends = ["format:*"]

# ── Dev & Setup ───────────────────────────────────────────────

[tasks."deps:core"]
run = "mix deps.get"

[tasks."deps:cli"]
dir = "cli"
run = "pnpm install"

[tasks.deps]
description = "Install all dependencies"
depends = ["deps:*"]

[tasks.dev]
description = "Build and launch the CLI (with Erlang distribution for debugging)"
depends = ["build"]
dir = "cli"
run = "node dist/bin.js --sname opal"
```

### Why mise

- **Solves two problems at once.** Task running + tool version management. One config file, one tool.
- **Zero Node.js dependency for orchestration.** Nx requires Node.js just to _run the build_. mise is a standalone Rust binary.
- **Human-readable.** `.mise.toml` is self-documenting. Compare with 180 lines of `nx.json` + `project.json` across three files.
- **Cross-platform.** Windows, macOS, Linux with the same config.
- **File-based caching without the magic.** `sources`/`outputs` skip tasks when inputs haven't changed — same benefit as Nx caching but explicit and predictable.
- **"Clone and go."** New contributors get `mise install && mise run build`. No need to independently discover Erlang 27, Elixir 1.18, Node 22.

### Modern mise features used

| Feature | What it replaces |
|---|---|
| `min_version` | Nothing — new safety net ensuring compatible mise |
| `postinstall` on tools | Manual "run corepack enable after installing Node" step |
| `sources`/`outputs` | Nx's intelligent caching |
| `dir` | `cd cli &&` shell boilerplate |
| `depends = ["test:*"]` | Manually listing every sub-task |
| Task grouping with `:` | Flat task names |
| `description` | Comments / guessing |

### Additional capabilities to explore

- **`run_windows`** — per-task Windows override (`run_windows = "npx.cmd tsc"`)
- **`mise.local.toml`** — gitignored local overrides for personal env vars or task tweaks
- **`watch_files` hook** — trigger rebuilds on file changes for dev-mode workflows
- **CI integration** — `jdx/mise-action@v3` GitHub Action installs mise + all tools in one step
- **File-based tasks** — complex scripts in `mise-tasks/` as separate files with shebangs

---

## The "5-Minute" Experience

A new consumer should be able to go from zero to running agent in under 5 minutes. This is a core design constraint.

**For Elixir consumers:**

```elixir
# mix.exs
{:opal, "~> 0.2"}

# lib/my_app.ex
{:ok, agent} = Opal.start_session(%{
  model: "copilot:claude-sonnet-4",
  working_dir: ".",
  tools: [MyApp.SearchTool, MyApp.DeployTool]
})

for event <- Opal.stream(agent, "Deploy the latest build") do
  IO.inspect(event)
end
```

Today this mostly works, but consumers must manually subscribe to `Opal.Events` and collect messages. `Opal.stream/2` doesn't exist yet.

**Proposed:** Add `Opal.stream/2` returning an Elixir `Stream` (lazy enumerable):

```elixir
def stream(agent, prompt) do
  Stream.resource(
    fn -> subscribe_and_prompt(agent, prompt) end,
    fn state -> receive_next_event(state) end,
    fn state -> cleanup(state) end
  )
end
```

This is the most natural Elixir interface — composable with `Enum`, `Stream`, and `Flow`.

**For TypeScript consumers:**

```typescript
import { Session } from "@opal/sdk";

const session = await Session.start({
  model: "copilot:claude-sonnet-4",
  workingDir: ".",
  autoConfirm: true,
});

for await (const event of session.prompt("List all files")) {
  console.log(event);
}

session.close();
```

This already works today — the SDK's `prompt()` returns `AsyncIterable<AgentEvent>` — but it's buried inside the CLI package. Extracting `@opal/sdk` makes this the primary interface.

---

## New Contributor Experience

```bash
git clone https://github.com/scohen/opal
cd opal
mise install       # installs exact Erlang 27.2, Elixir 1.18, Node 22
mise run deps      # mix deps.get + pnpm install (parallel)
mise run build     # compile → codegen → tsc (skips if unchanged)
mise run test      # mix test + vitest (parallel)
```

---

## Phases

### Phase 0: Groundwork (no user-visible changes)

Prerequisite refactors that make later phases clean. Can ship as normal PRs against the current layout.

1. **Tool tags refactor.** Replace hard-coded tool module identity checks in `ToolRunner` (`&1 == Opal.Tool.SubAgent`, etc.) with a `tags/0` callback on `Opal.Tool` behaviour. The kernel filters by tag, never by module name. This is a prerequisite for the kernel/batteries split.
2. **Decouple MCP discovery.** `Opal.Agent` calls `Opal.MCP.Bridge.discover_tool_modules/2` directly. Accept MCP discovery as an optional callback/module in config.
3. **Move `StreamCollector` to kernel.** It's provider-agnostic stream utilities but currently lives in provider code. Moving it unblocks the one-way dependency rule.
4. **Add `opal/version` RPC method.** Return protocol version, server version, and capabilities. The CLI can use this for compatibility checks before the version handshake becomes critical.

**Exit criteria:** `mix test` green, no hard-coded module identity checks in kernel-destined code.

### Phase 1: Repo layout + build system

The big move. One branch, one PR. Everything moves at once to avoid a half-migrated state.

1. **Move Elixir project to root.** `packages/core/` contents become root-level `lib/`, `mix.exs`, `test/`, `config/`, `priv/`.
2. **Move CLI to `cli/`.** `packages/cli/` → `cli/`.
3. **Replace Nx with mise.** Drop `nx.json`, `project.json` files, `pnpm-workspace.yaml`, root `package.json` scripts. Add `.mise.toml`. Update CI to use `jdx/mise-action@v3`.
4. **Delete root `package.json`.** CLI owns its own `package.json`. Root only has `.mise.toml`, `mix.exs`, Lefthook config.
5. **Update Lefthook.** Pre-commit hooks call `mise run lint` instead of `pnpm lint`.
6. **Update codegen paths.** `scripts/codegen_ts.exs` outputs to `cli/src/sdk/` instead of `packages/cli/src/sdk/`.

**Exit criteria:** `mise run build && mise run test && mise run lint` all pass. CI green. `mix test` works at root with no path prefix.

### Phase 2: Kernel/batteries boundary

Module reorganization within `lib/opal/`. No public API changes.

1. **Split `lib/opal/ext/`.** Move tools, providers, MCP, RPC, and auth into `lib/opal/ext/` per the layout diagram.
2. **Add CI boundary check.** Credo rule or Mix task that fails if any `lib/opal/*.ex` file imports from `lib/opal/ext/`.
3. **Namespace batteries.** Rename `Opal.Tool.Read` → `Opal.Ext.Tool.Read`, `Opal.RPC.Handler` → `Opal.Ext.RPC.Handler`, etc. Update all references.
4. **Update codegen.** TypeScript codegen script references the new module paths.

**Exit criteria:** `mix test` green. CI boundary check passes. No `lib/opal/*.ex` depends on `lib/opal/ext/`.

### Phase 3: DX improvements

New public-facing APIs and macros. Each ships independently.

1. **`use Opal.Tool` macro.** Declarative tool definition with compile-time validation, auto-derived names, `@config` declarations.
2. **`use Opal.Provider` macro.** Declarative provider definition with model declarations and packageable structure.
3. **`Opal.stream/2`.** Native Elixir `Stream.resource/3`-based streaming API. The 5-minute experience for Elixir consumers.
4. **JSON Schema as intermediate protocol artifact.** Codegen reads schema, not Elixir AST. Decouples TypeScript types from Elixir compilation.
5. **`examples/` directory.** Runnable examples for Elixir consumers: basic prompting, custom tools, streaming, sub-agents.

**Exit criteria:** `Opal.stream/2` works in IEx. Examples run out of the box. `use Opal.Tool` compiles and validates.

### Phase 4: CLI surface

New subcommands and modes for `opal`. Each ships independently.

1. **`opal --version`.** Print CLI version + server version (via `opal/version` RPC from Phase 0).
2. **Positional prompt arg.** `opal "What is this project?"` pre-loads the prompt into the TUI.
3. **`opal auth` subcommand.** `opal auth login`, `opal auth status`, `opal auth set-key <provider>`. Conventional CLI, no TUI.
4. **`opal session` subcommand.** `opal session list`, `opal session show <id>`, `opal session delete <id>`.
5. **Non-interactive / headless mode.** `opal "prompt" --no-tui` prints response to stdout. Unlocks CI, scripting, piping.
6. **`opal doctor`.** Check installation health: server binary, auth, versions, connectivity.

**Exit criteria:** `opal --version` prints versions. `opal auth status` works without starting the TUI. Headless mode exits cleanly with output on stdout.

### Phase 4.5: Remote debugging

Expose Erlang distribution setup via the existing `opal/config/set` / `opal/config/get` RPC methods and wire it into the CLI. No new RPC methods needed — distribution is just runtime config with a side effect.

1. **Distribution as config.** `opal/config/set` accepts a `distribution` key. Setting `{"distribution": {"name": "opal", "cookie": "abc123"}}` calls `Node.start/2` and `Node.set_cookie/2` as a side effect, then returns `{"distribution": {"node": "opal@hostname", "cookie": "abc123"}}`. Setting `{"distribution": null}` calls `Node.stop/0`. `opal/config/get` returns the current distribution state (or `null` if not active).
2. **`--sname` / `--cookie` CLI flags.** The CLI passes these to `opal/config/set` with the `distribution` key immediately after the RPC connection is established. If `--sname` is provided without `--cookie`, a random cookie is generated.
3. **TUI status message.** When distribution is enabled, the CLI emits a system message in the skills/context area: `Instance exposed at opal@hostname (cookie: abc123)`. This gives the user the exact incantation for `iex --remsh`.
4. **`mise run dev` defaults.** The dev task passes `--sname opal` by default, so `mise run dev` always starts with distribution enabled. The TUI shows the connection info on startup.

**Exit criteria:** `mise run dev` shows node connection info. `iex --sname debug --cookie <cookie> --remsh opal@hostname` connects successfully. `opal --sname mynode` works for production installs.

### Phase 5: Packaging (when demand warrants)

1. **Extract `@opal/sdk`** from `cli/src/sdk/` into its own npm package.
2. **Publish to Hex** as `{:opal, "~> 0.2"}`.
3. **Evaluate umbrella.** If the kernel is stable and external Hex packages depend on it, extract `opal_kernel` as a separate app.

**Exit criteria:** Consumer packages can `npm install @opal/sdk` or `{:opal, "~> 0.2"}` and run an agent without cloning the repo.

### Phase dependency graph

```
Phase 0 ──→ Phase 1 ──→ Phase 2 ──→ Phase 3
               │                       │
               ├── Phase 4 ───────────→│
               │      │                │
               │      └─ Phase 4.5 ───→│
               │                       │
               └───────────────────────└──→ Phase 5
```

Phase 0 must land first (clean edges). Phase 1 depends on it. After Phase 1, Phases 2 and 4 can run in parallel. Phase 4.5 depends on Phase 4 (needs the CLI flag infrastructure). Phase 3 depends on Phase 2 (needs the kernel/batteries boundary for `use Opal.Tool`). Phase 5 is gated on demand, not on a technical prerequisite.

---

## Open Questions

- Should `@opal/sdk` be in this repo or a separate one?
- Is JSON Schema the right intermediate format, or should we go straight to OpenAPI/AsyncAPI?
- Should tools be extracted into separate Hex packages (e.g. `opal_tool_shell`)? Aids tree-shaking but adds release overhead.
- What's the minimum viable contract testing setup between Elixir and TypeScript?

---

## Inspiration

- [Livebook](https://github.com/livebook-dev/livebook) — Elixir at root, JS frontend as `assets/`
- [Ecto](https://github.com/elixir-ecto/ecto) — Core (`ecto`) separated from adapters (`ecto_sql`) via packages. The module boundary here is the same principle, deferred to a later lifecycle stage.
- [Commanded](https://github.com/commanded/commanded) — Separate core CQRS/ES from adapters
