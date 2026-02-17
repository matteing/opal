# IEx Recipes

Common tasks for inspecting and debugging a running Opal agent from IEx.

Connect to a running instance with:

```bash
mise run inspect
```

All examples below assume you're in a connected IEx session.

---

## Session Discovery

```elixir
# List all active sessions
Opal.Inspect.sessions()
# => [{"abc123def456", #PID<0.456.0>}]

# Grab the first session (session_id + pid)
{sid, pid} = Opal.Inspect.first()

# Get the agent pid (auto-selects if only one session)
agent = Opal.Inspect.agent()

# Get a specific session's agent
agent = Opal.Inspect.agent("abc123def456")
```

## Quick Overview

```elixir
# One-line summary of the session state
Opal.Inspect.summary()
# => %{
#   session_id: "abc123",
#   status: :idle,
#   model: "copilot:claude-sonnet-4",
#   messages: 12,
#   tools: 8,
#   active_skills: ["git"],
#   ...
# }
```

## System Prompt

The assembled system prompt includes the raw prompt, discovered context
files, skill menu, tool guidelines, and runtime instructions — everything
the LLM sees as the system message.

```elixir
# Print the full assembled system prompt
Opal.Inspect.system_prompt() |> IO.puts()

# Open in your default editor/viewer as a temp .md file
Opal.Inspect.system_prompt(file: true)

# Write to a specific path
Opal.Inspect.system_prompt(file: "~/prompt.md")

# Just the raw system_prompt field (before context/skills/guidelines)
Opal.Inspect.state().system_prompt |> IO.puts()

# See what context files were discovered
Opal.Inspect.state().context_files
# => ["AGENTS.md", "docs/AGENTS.md"]

# See the raw context string injected into the prompt
Opal.Inspect.state().context |> IO.puts()
```

## Messages

```elixir
# All messages (newest first)
Opal.Inspect.messages()

# Last 3 messages
Opal.Inspect.messages(limit: 3)

# Only user messages
Opal.Inspect.messages(role: :user)

# Print the last user message
Opal.Inspect.messages(role: :user, limit: 1)
|> hd()
|> Map.get(:content)
|> IO.puts()

# Count messages by role
Opal.Inspect.messages()
|> Enum.frequencies_by(& &1.role)
# => %{user: 5, assistant: 5, tool_result: 8}
```

## Model & Provider

```elixir
# Current model
Opal.Inspect.model()
# => %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4"}

# Current provider module
Opal.Inspect.state().provider
# => Opal.Provider.Copilot

# Change model on a live session
Opal.Agent.set_model(Opal.Inspect.agent(), Opal.Provider.Model.new(:copilot, "gpt-4o"))
```

## Tools

```elixir
# List active tools
Opal.Inspect.tools()
# => [{"read_file", Opal.Tool.Read}, {"shell", Opal.Tool.Shell}, ...]

# Check disabled tools
Opal.Inspect.state().disabled_tools
```

## Skills

```elixir
# Available skills (discovered at startup)
Opal.Inspect.state().available_skills
|> Enum.map(& &1.name)

# Currently loaded skills
Opal.Inspect.state().active_skills

# Load a skill manually
Opal.Agent.load_skill(Opal.Inspect.agent(), "git")
```

## Token Usage

```elixir
# Current token usage
Opal.Inspect.state().token_usage
# => %{
#   prompt_tokens: 4200,
#   completion_tokens: 1800,
#   total_tokens: 6000,
#   context_window: 128000,
#   current_context_tokens: 4200
# }

# Check context utilization percentage
usage = Opal.Inspect.state().token_usage
Float.round(usage.current_context_tokens / usage.context_window * 100, 1)
# => 3.3
```

## Live Event Watching

```elixir
# Watch all events (colored, timestamped)
{:ok, watcher} = Opal.Inspect.watch()

# Stop watching
Process.exit(watcher, :normal)

# Watch a single session's events manually
Opal.Events.subscribe("session-id")
flush()  # prints buffered events
```

## Low-Level Access

```elixir
# Full state struct
state = Opal.Inspect.state()

# Dump full state to a temp file and open in $EDITOR
Opal.Inspect.dump_state()
# => "/tmp/opal-state-abc123def456.exs"

# Dump without auto-opening
Opal.Inspect.dump_state(open: false)

# Dump to a specific path
Opal.Inspect.dump_state(path: "~/agent-state.exs")

# gen_statem internal state (includes state name)
{state_name, state} = :sys.get_state(Opal.Inspect.agent())
# state_name is :idle, :running, :streaming, or :executing_tools

# Send a prompt programmatically
Opal.Agent.prompt(Opal.Inspect.agent(), "Hello!")

# Abort a running agent
Opal.Agent.abort(Opal.Inspect.agent())
```

## Session & Persistence

```elixir
# Get the session process
state = Opal.Inspect.state()
session = state.session

# Current conversation path (chronological)
Opal.Session.get_path(session) |> length()

# Session metadata
Opal.Session.get_metadata(session, :title)

# Force save
dir = Opal.Config.sessions_dir(state.config)
Opal.Session.save(session, dir)
```
