<p align="center">
  <img src="./docs/assets/opal.gif" width="75" />
</p>

<h1 align="center">✦ Opal</h1>

<p align="center">
  <strong>A smol agent harness built with the magic of Elixir.</strong>
</p>

[![asciicast](https://asciinema.org/a/jvXcTlXIvBvPvXNG.svg)](https://asciinema.org/a/jvXcTlXIvBvPvXNG)

<p align="center">
  <small><i>⤴ Watch me in action! I'm fun, I promise!</i></small>
</p>

Opal is two things:

- A **small coding agent CLI** you can use to build things.
- An **idiomatic Elixir library** you can drop into your app to get an agent system.

It features support for the basics: [basic tools](), [auto-compaction](), and [extended thinking](). There's some niceties thrown in as well: discovery of [agent skills]() and a [JSON-RPC transport]() for building your own UI.

The only supported provider is [GitHub Copilot](), but it's been designed with the ability to add more if anyone uses it.

## What can it do?

Right now, Opal can:

- **Edit files** — reads, writes, and applies targeted edits.
- **Run shell commands** — executes builds, tests, linters, etc.
- **Debug and fix** — can diagnose issues and apply fixes.
- **Parallelize work** — sub-agents are cheap OTP processes, so it can plan + split tasks up easily.
- **Ask questions** — will ask for clarification when planning with a nice UI.

**Adjust expectations; this is a hobby project.** I built this for my own research use. There's no approval or permissions system. **No guardrails, no sandbox.** See [disclaimer](#disclaimer).

As a library, it can be cleanly dropped into any Elixir project. This is a convenient mode of use; you get no serialization boundary, just plain Erlang message passing. ✨

Also, you could theoretically also network Erlang nodes together and have agents talking to agents!?

## Installing

Opal works on both Windows and Unix-based systems.

```bash
# Install it from NPM
npm i -g @unfinite/opal
# Run it!
opal
```

Or as an Elixir dependency: `{:opal, "~> 0.1"}`

See the [setup guide](docs/installing.md) for authentication and configuration.

## What's interesting about this?

Mostly, the Erlang VM's [computing vision](https://www.youtube.com/watch?v=JvBT4XBdoUE&t=2356s).

**[Live introspection.](docs/inspecting.md)** Connect to a running agent from another terminal and stream every event in real time. See every thought, trace every call, and play with the live running system and its state. The BEAM enables unprecedented observability into agentic AI systems.

**[Won't break a sweat.](docs/supervision.md)** Run as many tools as you want. Spawn a child agent with its own context, tools, and model. You won't choke the system; it'll remain responsive. OTP's _supervision tree_ manages every process lifecycle; if the parent dies, children are [cleaned up automatically](docs/supervision.md). No thread pools. No manual resource cleanup.

**[Redirect the agent mid-flight.](docs/agent-loop.md)** Call `Opal.prompt(agent, "focus on tests instead")` while the agent is busy and it's queued, then picked up between tool calls. This works because every Erlang process has a _mailbox_ — a built-in message queue. The [agent loop](docs/agent-loop.md) checks it between steps. No polling, no callback chains.

**Embeddable as a library.** Add `{:opal, ...}` to your Elixir deps and the full agent system runs inside your app. Since it's all Erlang processes, there's no sidecar, no serialization — just message passing. Or consume it over [JSON-RPC](docs/rpc.md) from any language. See the [SDK docs](docs/sdk.md).

## Using Opal as a library

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

`Opal.stream/2` returns a lazy `Stream`. Compose with `Stream.filter/2`, `Enum.reduce/3`, or pipe into anything.

```elixir
# Block until it's done
{:ok, answer} = Opal.prompt_sync(agent, "What does the User module do?")

# Redirect mid-flight — queued in the agent's mailbox between tool calls
%{queued: true} = Opal.prompt(agent, "Focus on the tests instead")
```

### Built-in tools

| Tool          | Description                                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `read_file`   | Reads file contents with line-range slicing and hashline-tagged output for use with `edit_file`.                        |
| `edit_file`   | Edits files by hash-anchored line references from `read_file` output — no diffs, no reproduced content.                 |
| `write_file`  | Creates or overwrites a file entirely.                                                                                  |
| `grep`        | Cross-platform regex search with glob filtering. Output is hashline-tagged and `edit_file`-ready.                       |
| `shell`       | Runs commands in the working directory with streaming output.                                                           |
| `sub_agent`   | Spawns a child agent with its own context, tools, and model for isolated parallel work.                                 |
| `tasks`       | Persistent DAG task tracker on Erlang's DETS. Plan, order, unblock, and surface ready work for parallel dispatch.       |
| `ask_user`    | Pauses the agent to ask the user a question. Supports freeform and multiple-choice.                                     |
| `use_skill`   | Loads skill instructions from `.claude/skills/` (or similar dirs) into context on demand.                               |
| `debug_state` | This one is the coolest, allows the agent to **debug itself** by introspecting its own system state. Ain't that badass. |

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

I wanted to understand how agent harnesses work, not just use them.

I studied [Pi](https://github.com/badlogic/pi-mono) and the more I stared at the problem space--long-running loops, concurrent tool execution, process isolation, sub-agent orchestration--the more it looked like Erlang/OTP would be a great fit. So I built it.

This is a research project; I try to keep it up to date with the latest standards and any papers that pop up in arXiv.

## Future plans

- Proper SDK docs, NPM package
- Random gaps in functionality that come through!
- Subagents + agents talking to each other through message passing?
  - subagent X asked subagent Y a question
  - not sure if that would even work but whatevs
- A toy OpenClaw reimplementation using Opal

Let me know if there's any features you'd like baked in by filing an issue; no promises, but I'll try to get to them!

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

## AI Usage Disclosure

I use AI models heavily in the development of this project. It is _not_ vibe coded, though. What's the point of building something to learn if you skip the building part? :P

My approach has been to engineer the systems, plan deeply, then execute. When a chunk is done: feature freeze, then a manual/human pass through every file to ask questions & clear out tech debt. You can trust that every system in this repo has been carefully thought through!

[My thoughts on AI-assisted engineering.](https://news.ycombinator.com/item?id=47075660)

## References

See [citations](./docs/research/references.md).

## License

[MIT](LICENSE) — Sergio Mattei
