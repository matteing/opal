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

Opal is two things:

- A **minimal coding agent CLI** you can use to build things.
- An **idiomatic Elixir library** you can drop into your app to get an agent system.

It features [built-in tools](docs/tools.md), an [MCP host](docs/mcp.md), support for [Agent Skills](https://agentskills.io), and a [JSON-RPC transport](docs/rpc.md) for cross-language integrations.

## What can it do?

Right now, Opal can:

- **Edit files** — reads, writes, and applies targeted edits efficiently.
- **Run shell commands** — executes builds, tests, linters, etc.
- **Debug and fix** — can diagnose issues and apply fixes, though expect some rough edges.
- **Parallelize work** — sub-agents are cheap OTP processes, so it can split tasks up easily.
- **Ask questions** — will ask for clarification when planning instead of guessing.

It's a hobby project. There's no permission or approval system yet — the agent can run any shell command and write to any file in your working directory. **No guardrails, no sandbox.** Use it on things you can afford to break. See [Disclaimer](#disclaimer).

In library usage, the harness can be cleanly integrated into Elixir (or other language) systems. When integrating with Elixir, you get no serialization boundary (just Erlang message passing). 

You could theoretically also network these nodes together and have agents talking to agents!? 

## Installing

```bash
npm i -g @unfinite/opal
opal
```

Or as an Elixir dependency: `{:opal, "~> 0.1"}`

[→ Full installation guide](docs/installing.md) — authentication, API keys, configuration, GitHub Enterprise.

## What's interesting about this?

**You can connect to a running agent and watch it think.** Opal uses Erlang distribution — connect from another terminal and stream every event from every agent and sub-agent in real time. Crack open `:observer` and see the full process tree, message queues, memory — everything. [→ Inspecting](docs/inspecting.md)

**Sub-agents are just processes.** Spawn a child agent — it gets its own message history, tools, and model. Runs in parallel, fully isolated. Parent dies? Sub-agents are cleaned up automatically. No thread pools, no `Promise.all`. Just OTP. [→ Supervision](docs/supervision.md)

**The process mailbox is the steering queue.** `Opal.steer(agent, "focus on tests instead")` drops a message into the GenServer's mailbox. Between tool executions, the agent checks for it. No polling, no callback chains. [→ Agent loop](docs/agent-loop.md)

**It's an embeddable library.** Add `{:opal, ...}` to your deps and the full harness lives inside your Elixir app — just Erlang message passing. Or consume it over JSON-RPC from any language. [→ SDK docs](docs/sdk.md)

## What you get

- **Interactive TUI** — fullscreen terminal chat (React/Ink) with streaming, model picker, thinking display
- **8 built-in tools** — `read_file`, `write_file`, `edit_file`, `shell`, `sub_agent`, `tasks`, `use_skill`, `ask_user` [→ Tools](docs/tools.md)
- **MCP host** — auto-discovers servers from `.vscode/mcp.json` and friends; stdio, SSE, streamable HTTP [→ MCP](docs/mcp.md)
- **Multiple providers** — GitHub Copilot + anything [ReqLLM](https://github.com/doughsay/req_llm) supports (Anthropic, OpenAI, Google, etc.) [→ Providers](docs/providers.md)
- **Auto-compaction & extended thinking** — LLM-powered summarization near context limits, configurable thinking levels [→ Compaction](docs/compaction.md) · [Reasoning](docs/reasoning.md)
- **Event system** — `Registry`-based pub/sub, subscribe from any process [→ OTP patterns](docs/otp.md)

## Architecture

An [Nx](https://nx.dev) monorepo with two projects:

| Project     | What it is |
| ----------- | ---------- |
| **`core/`** | The Elixir SDK — agent engine, tools, providers, sessions, MCP bridge, RPC server. Embeddable in any supervision tree. |
| **`cli/`**  | React/Ink terminal UI + typed TypeScript client SDK. Talks to core over JSON-RPC stdio. Published as `@unfinite/opal` on npm. |

[→ Full architecture](docs/index.md)

## CLI

```sh
opal                                       # interactive TUI
opal --model anthropic/claude-sonnet-4     # choose a model
opal -C /path/to/project                   # set working directory
opal --auto-confirm                         # skip tool confirmations
```

## Using Opal as a library

Add it to your supervision tree and you get everything — no external process, no serialization. [→ Full SDK docs](docs/sdk.md)

```elixir
{:ok, agent} = Opal.start_session(%{
  system_prompt: "You are a helpful coding assistant.",
  working_dir: "/path/to/project"
})

:ok = Opal.prompt(agent, "List all Elixir files")
:ok = Opal.steer(agent, "Actually, focus on the test files")
:ok = Opal.set_model(agent, "copilot/claude-sonnet-4")
:ok = Opal.stop_session(agent)
```

### Observability

Any process can subscribe to agent events in real time via `Registry`:

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

## Development

```sh
nx run-many -t deps       # install deps
nx run cli:dev             # run TUI in dev mode
nx run-many -t test        # tests
pnpm lint && pnpm format   # lint & format
```

## Principles

- **OTP first.** If there's an Erlang primitive for it, use that instead of building something new.
- **Minimal but useful.** Small core, big punch. Ship what matters, skip the rest.
- **Research-driven.** Stay current with the latest work on model adherence and agent outcomes.
- **Cross-platform.** Windows at work, macOS at home. Both are first-class.

## Why I built this

I wanted to understand how agent harnesses actually work — not just use one, but build one from the ground up. I studied [Pi](https://github.com/badlogic/pi-mono) and the more I stared at the problem — long-running loops, concurrent tool execution, process isolation, sub-agent orchestration — the more it looked like Erlang/OTP. So I built it. 

Sub-agents? Processes. Steering? Mailbox. Fault isolation? Supervision tree. Live debugging? Erlang distribution. I didn't have to build any of that. The language did that.

## Disclaimer

This is a hobby project. I work at Microsoft Azure, and our GitHub Copilot subscription provides the LLM access I use for development.

**This project is not affiliated with, endorsed by, or related to my employer in any way. Neither are my opinions, of which there are many ;)**

And from my beloved past at XDA Forums:

```cpp
#include <std_disclaimer.h>

/*
* Your warranty is now void.
*
* I am not responsible for bricked devices, dead SD cards,
* thermonuclear war, or you getting fired because the alarm app failed. Please
* do some research if you have any concerns about doing this to your device
* YOU are choosing to make these modifications, and if
* you point the finger at me for messing up your device, I will laugh at you.
*
* I am also not responsible for you getting in trouble for using any of the
* features in this ROM, including but not limited to Call Recording, secure
* flag removal etc.
*/
```


## License

[MIT](LICENSE) — Sergio Mattei
