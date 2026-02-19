<p align="center">
  <img src="./docs/assets/opal.gif" width="75" />
</p>

<h1 align="center">✦ Opal</h1>

<p align="center">
  <strong>A minimal agent harness built with the magic of Elixir.</strong>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" width="700" />
</p>

Opal is two things:

- A **minimal coding agent CLI** you can use to build things.
- An **idiomatic Elixir library** you can drop into your app to get an agent system.

It features [built-in tools](docs/tools.md), an [MCP host](docs/mcp.md), support for [Agent Skills](https://agentskills.io), [auto-compaction](docs/compaction.md), [extended thinking](docs/reasoning.md), and a [JSON-RPC transport](docs/rpc.md) for cross-language integrations. Currently supports [GitHub Copilot](docs/providers.md) as the built-in provider, with a pluggable behaviour for adding more.

## What can it do?

Right now, Opal can:

- **Edit files** — reads, writes, and applies targeted edits efficiently.
- **Run shell commands** — executes builds, tests, linters, etc.
- **Debug and fix** — can diagnose issues and apply fixes, though expect some rough edges.
- **Parallelize work** — sub-agents are cheap OTP processes, so it can split tasks up easily.
- **Ask questions** — will ask for clarification when planning instead of guessing.

**Adjust expectations; it's a hobby project.** There's no permission or approval system yet — the agent can run any shell command and write to any file in your working directory. **No guardrails, no sandbox.** Use it on things you can afford to break. See [disclaimer](#disclaimer).

**The CLI code is a giant flying spaghetti monster.** While I've paid great attention to ensuring the Elixir is well-written, lightweight and idiomatic, I've not cared much about the CLI code. I'm manually rewriting all of it at the moment, which isn't too hard considering it's feature complete.

In library usage, the harness can be cleanly integrated into Elixir (or other language) systems. When integrating with Elixir, you get no serialization boundary (just Erlang message passing).

You could theoretically also network these nodes together and have agents talking to agents!?

## Installing

```bash
npm i -g @unfinite/opal
opal
```

Or as an Elixir dependency: `{:opal, "~> 0.1"}`

See the [installation guide](docs/installing.md) for authentication, API keys, configuration, and GitHub Enterprise setup.

## What's interesting about this?

**[Live introspection.](docs/inspecting.md)** Connect to a running agent from another terminal and stream every event in real time — what it's thinking, which tools it's calling, memory usage, the works. Under the hood, Elixir sits on the Erlang VM (the BEAM), which has built-in node-to-node networking. That means zero extra infrastructure for remote debugging.

**[Lightweight sub-agents.](docs/supervision.md)** Spawn a child agent with its own context, tools, and model. It runs in parallel, fully isolated. If the parent dies, children are [cleaned up automatically](docs/supervision.md). This is OTP's _supervision tree_ — a battle-tested pattern for managing process lifecycles — doing the heavy lifting. No thread pools, no manual resource cleanup.

**[Redirect the agent mid-flight.](docs/agent-loop.md)** Call `Opal.prompt(agent, "focus on tests instead")` while the agent is busy and it's queued, then picked up between tool calls. This works because every Erlang process has a _mailbox_ — a built-in message queue. The [agent loop](docs/agent-loop.md) checks it between steps. No polling, no callback chains.

**Embeddable as a library.** Add `{:opal, ...}` to your Elixir deps and the full agent system runs inside your app. Since it's all Erlang processes, there's no sidecar, no serialization — just message passing. Or consume it over [JSON-RPC](docs/rpc.md) from any language. See the [SDK docs](docs/sdk.md).

## CLI

```sh
opal                                       # interactive TUI
opal --model anthropic/claude-sonnet-4     # choose a model
opal -C /path/to/project                   # set working directory
opal --auto-confirm                         # skip tool confirmations
opal --debug                                # enable debug feature/tools for this session
```

## Providers

GitHub Copilot is the built-in provider — pass `provider/model` with `--model`:

```sh
opal --model copilot/claude-sonnet-4   # Copilot
opal --model anthropic/claude-sonnet-4 # Anthropic model IDs via Copilot
opal --model openai/gpt-4o             # OpenAI model IDs via Copilot
```

See the [provider docs](docs/providers.md) for API keys, model discovery, and custom providers.

## Using Opal as a library

Add it to your supervision tree and you get everything — no external process, no serialization. See the [SDK docs](docs/sdk.md) for the full API.

```elixir
{:ok, agent} = Opal.start_session(%{working_dir: "."})

# Stream events as they happen
Opal.stream(agent, "Refactor the auth module")
|> Enum.each(fn
  {:thinking_delta, %{delta: thought}} ->
    IO.write(IO.ANSI.faint() <> thought <> IO.ANSI.reset())

  {:message_delta, %{delta: text}} ->
    IO.write(text)

  {:tool_execution_start, name, _call_id, _args, _meta} ->
    IO.puts("  ⚡ #{name}")

  {:tool_execution_end, _name, _call_id, _result} ->
    IO.puts("  ✓")

  {:agent_end, _messages, _usage} ->
    IO.puts("\n✦ Done")

  _ ->
    :ok
end)
```

`Opal.stream/2` returns a lazy `Stream` — compose with `Stream.filter/2`, `Enum.reduce/3`, or pipe into anything.

```elixir
# Block until it's done
{:ok, answer} = Opal.prompt_sync(agent, "What does the User module do?")

# Redirect mid-flight — queued in the agent's mailbox between tool calls
%{queued: true} = Opal.prompt(agent, "Focus on the tests instead")
```

### Custom tools

Define tools declaratively with `use Opal.Tool`:

```elixir
defmodule MyApp.SearchTool do
  use Opal.Tool,
    name: "search",
    description: "Full-text search over the codebase"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}, context) do
    results = MyApp.Search.run(query, context.working_dir)
    {:ok, Enum.join(results, "\n")}
  end
end

{:ok, agent} = Opal.start_session(%{
  tools: [MyApp.SearchTool],
  working_dir: "."
})
```

## Development

```sh
mise run deps                      # install deps
mise run dev                       # run TUI in dev mode
mise run dev -- --debug             # run with debug feature/tools enabled
mise run test                      # tests
mise run lint && mise run format   # lint & format
mise run inspect                   # connect via iex to a running dev mode instance
```

## Principles

- **OTP first.** If there's an Erlang primitive for it, use that instead of building something new.
- **Minimal but useful.** Small core, big punch. Ship what matters, skip the rest.
- **Research-driven.** Stay current with the latest work on model adherence and agent outcomes.
- **Cross-platform.** Windows at work, macOS at home. Both are first-class.

## Why I built this

I wanted to understand how agent harnesses actually work — not just use one, but build one from the ground up. I studied [Pi](https://github.com/badlogic/pi-mono) and the more I stared at the problem — long-running loops, concurrent tool execution, process isolation, sub-agent orchestration — the more it looked like Erlang/OTP. So I built it.

Sub-agents? Processes. Steering? Mailbox. Fault isolation? Supervision tree. Live debugging? Erlang distribution. I didn't have to build any of that. The language did that.

## Future plans

- A more fully featured TUI
- Proper SDK docs, NPM package
- Random gaps in functionality that come through!
- Subagents + agents talking to each other through message passing?
  - subagent X asked subagent Y a question
  - not sure if that would even work but whatevs
- A toy OpenClaw reimplementation using Opal

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

## References

Standing on the shoulders of giants. Other references (papers, projects) are in the relevant documentation files.

- [Pi](https://pi.dev): The best open-source harness, huge source of inspiration
- [oh-my-pi](https://github.com/can1357/oh-my-pi): An awesome customization of Pi with so many goodies and tricks

## License

[MIT](LICENSE) — Sergio Mattei
