<p align="center">
  <img src="./docs/assets/opal.gif" width="75" />
</p>

<h1 align="center">✦ Opal</h1>

<p align="center">
  <strong>A minimal coding agent harness and runtime, built with the magic of Elixir.</strong>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" width="700" />
</p>

---

Opal is two things:

- A **minimal coding agent CLI** you can use to build things.
- An **idiomatic Elixir library** you can drop into your app to get an agent system.

Opal features a base set of tools, an MCP host, support for [Agent Skills](https://agentskills.io) and a JSON-RPC transport for cross-language integrations. 

## Installing

```bash
# Install it!
npm i -g @unfinite/opal
# Start it!
opal
# Integrate it!
# {:opal, "~> 0.1"}
```

## What's interesting about this?

**You can connect to a running agent and watch it think.** Opal uses Erlang distribution — from another terminal, connect to a live session and stream every event from every agent and sub-agent in real time:

```sh
# In development mode
iex --sname inspector --cookie opal --remsh opal
```

Crack open `:observer` and you can see the full process tree, message queues, memory — everything. You can directly tap into and tinker with your running agent's state. That's a cool level of observability that only Elixir/Erlang allows!

**Sub-agents are just processes.** Want to delegate a task to a child agent? Spawn one. It gets its own message history, its own tools, its own model. Runs in parallel, fully isolated. If the parent dies, sub-agents are cleaned up automatically. No thread pools, no `Promise.all`. Just OTP processes.

**The process mailbox is the steering queue.** Need to redirect an agent mid-run? `Opal.steer(agent, "focus on tests instead")` drops a message into the GenServer's mailbox. Between tool executions, the agent checks for it. No polling, no callback chains. The programming paradigm works so well for this kind of task.

**SSE streaming lands in `handle_info/2`.** The LLM response streams via `Req` with `into: :self` — SSE chunks arrive directly as messages in the GenServer's mailbox. The agent loop processes them alongside tool results, steering messages, and abort signals using the same `receive` block.

**It's an embeddable library.** Add `{:opal, ...}` to your deps and the full harness lives inside your Elixir app. No external process, no JSON-RPC overhead, no language interop — just Erlang message passing. Or run it headless as a JSON-RPC 2.0 daemon and consume it from any language.

## What you get

- **Interactive TUI** — fullscreen terminal chat UI (React/Ink)
- **Daemon mode** — headless JSON-RPC 2.0 over stdio. Consume from any language.
- **Sub-agents** — delegate tasks to child agents as isolated processes
- **MCP host** — connects to MCP servers (stdio, SSE, streamable HTTP transports)
- **Built-in tools** — `read_file`, `write_file`, `edit_file`, `shell`, `sub_agent`, `tasks`, `use_skill`, `ask_user`
- **Skills** — drop instruction sets into your project per [agentskills.io](https://agentskills.io), Opal discovers and loads them on demand.
- **Event system** — `Registry`-based pub/sub. Subscribe from any process, build whatever you want on top.
- **Multiple providers** — GitHub Copilot out of the box, plus any provider supported by [ReqLLM](https://github.com/doughsay/req_llm) (Anthropic, OpenAI, Google, etc.)
- **Auto-compaction** — LLM-powered conversation summarization when context nears capacity
- **Extended thinking** — configurable thinking levels (`:off`, `:low`, `:medium`, `:high`)
- **Cross-platform** — Linux, macOS, Windows.

## Architecture

The repo is an [Nx](https://nx.dev)-managed monorepo with two projects:

| Project     | What it is                                                                                                                                                                                     |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`core/`** | **Opal SDK** — the agent engine as an Elixir library. Tools, providers, sessions, MCP bridge, RPC server. Add `{:opal, ...}` to your deps and embed the whole thing in your supervision tree.  |
| **`cli/`**  | **Opal CLI** — a React/Ink terminal UI and typed client SDK. Talks to core over JSON-RPC 2.0 stdio. Also published as `@unfinite/opal` on npm with an importable TypeScript client. |

## CLI

```sh
opal                                          # interactive TUI
opal --model anthropic/claude-sonnet-4        # choose a model
opal -C /path/to/project                      # set working directory
opal --auto-confirm                            # skip tool confirmations
opal --help
```

| Flag                               | What it does                                  |
| ---------------------------------- | --------------------------------------------- |
| `--model <provider/id>`            | Model to use (e.g. `copilot/claude-sonnet-4`) |
| `--working-dir`, `-C <dir>`        | Working directory                             |
| `--auto-confirm`                   | Auto-confirm all tool executions              |
| `--verbose`, `-v`                  | Verbose output                                |

## Using Opal as a library

This is the part I'm most excited about. The `core/` project is an embeddable Elixir library — add it to your supervision tree and you get everything. No external process, no RPC, no serialization. Just Erlang message passing.

```elixir
# mix.exs
defp deps do
  [{:opal, path: "../opal/core"}]
end
```

```elixir
# Start a session — it's a supervised process tree
{:ok, agent} = Opal.start_session(%{
  system_prompt: "You are a helpful coding assistant.",
  working_dir: "/path/to/project"
})

# Async — subscribe to Opal.Events for streaming output
:ok = Opal.prompt(agent, "List all Elixir files")

# Sync — blocks until the agent finishes
{:ok, response} = Opal.prompt_sync(agent, "What does this module do?")

# Steer mid-run — injected between tool executions
:ok = Opal.steer(agent, "Actually, focus on the test files")

# Follow up after the agent finishes
:ok = Opal.follow_up(agent, "Now write tests for those")

# Abort an in-flight response
:ok = Opal.abort(agent)

# Change models on the fly
:ok = Opal.set_model(agent, "copilot/claude-sonnet-4")

# Set thinking level
:ok = Opal.set_thinking_level(agent, :high)

# Clean up
:ok = Opal.stop_session(agent)
```

### Observability

Any process can subscribe to agent events in real time. The event system is built on `Registry`, so it's fast and it's what Elixir developers already know:

```elixir
Opal.Events.subscribe(session_id)

receive do
  {:opal_event, ^session_id, {:message_delta, %{delta: text}}} ->
    IO.write(text)
  {:opal_event, ^session_id, {:tool_execution_start, %{name: name}}} ->
    IO.puts("Running tool: #{name}")
  {:opal_event, ^session_id, {:agent_end, _}} ->
    IO.puts("Done.")
end
```

`Opal.Events.subscribe_all()` gives you events from _every_ session — useful for dashboards, logging, or just poking around.

## RPC interface

The core includes a built-in JSON-RPC 2.0 server over stdio, which is how the TypeScript CLI communicates with the Elixir agent engine. You can also consume it from any language to build your own client.

The RPC protocol supports 16+ methods including `session/start`, `agent/prompt`, `agent/steer`, `agent/abort`, `model/set`, `thinking/set`, `session/compact`, and more. The protocol spec is defined declaratively in Elixir and used to codegen the TypeScript client types.

See [the docs](docs/index.md) for the full schema.

## Development

```sh
# Install deps
nx run-many -t deps

# Run the TUI in dev mode
nx run cli:dev

# Tests
nx run-many -t test
nx run core:test

# Lint / format
pnpm lint
pnpm format
```

### Nx targets

| Target         | Core | CLI | Description                                      |
| -------------- | ---- | --- | ------------------------------------------------ |
| `dev`          | —    | ✓   | Run TUI (`node dist/bin.js`)                     |
| `build`        | ✓    | ✓   | Compile (core: `mix compile`, cli: `tsc`)        |
| `test`         | ✓    | —   | Run ExUnit tests                                 |
| `lint`         | ✓    | ✓   | Check formatting                                 |
| `format`       | ✓    | ✓   | Auto-format code                                 |
| `deps`         | ✓    | ✓   | Fetch dependencies                               |
| `docs`         | ✓    | —   | Generate ex_doc                                  |
| `codegen`      | —    | ✓   | Generate TypeScript protocol types from Elixir   |
| `codegen:check`| —    | ✓   | Verify generated types are up to date            |

## Providers

Opal ships with two providers:

- **GitHub Copilot** (`Opal.Provider.Copilot`) — supports Chat Completions API and Responses API, device-code OAuth with auto-refresh, GitHub Enterprise support. This is the default.
- **ReqLLM** (`Opal.Provider.LLM`) — a generic provider powered by [ReqLLM](https://github.com/doughsay/req_llm) that supports Anthropic, OpenAI, Google, Groq, OpenRouter, xAI, AWS Bedrock, and more.

Set the model with a `provider/model` string: `copilot/claude-sonnet-4` uses Copilot, anything else routes through ReqLLM (e.g. `anthropic/claude-sonnet-4`).

## Core Principles

These ideas guide my development of Opal:

- **When in doubt, OTP.** Try to use Erlang/OTP primitives as much as possible.
- **Minimal but useful.** Tiny core but packing a punch.
- **Research project.** Aiming to keep up to date with the latest research into model adherence and improvement of outcomes.
- **Cross platform.** I use Windows at work and macOS at home.

## Why I built this

I wanted to understand how agent harnesses actually work — not just use one, but build one from the ground up. I studied [Pi](https://github.com/badlogic/pi-mono) and thought the architecture was smart. And the more I stared at the problem — long-running loops, concurrent tool execution, process isolation, sub-agent orchestration — the more it looked like my experience with Elixir.

So I built it. It took dramatically fewer lines of code than I expected with good help from Copilot CLI. Sub-agents? Processes. Steering? Mailbox. Fault isolation? Supervision tree. Live debugging? Erlang. I didn't have to build any of that.

This is a hobby project and a research project. It's inspired by Pi with some more features — Elixir's process model makes features like sub-agents and concurrent tool execution essentially free, so there's no reason to leave them out. 

This is by no means a production system at the current time. It's very experimental.

## Disclaimer

This is a personal hobby project. I work at Microsoft Azure, and our GitHub Copilot subscription provides the LLM access I use for development.

**This project is not affiliated with, endorsed by, or related to my employer in any way. Neither are my opinions.**

## License

[MIT](LICENSE) — Sergio Mattei
