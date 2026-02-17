# Opal Project Guide

**Opal** is a coding agent harness and runtime built with Elixir that provides a clean, OTP-native architecture for building AI coding agents.

## Project Overview

This is a monorepo with two main components:

- **`opal/`** - The Opal SDK (Elixir project) providing the agent engine, tools, providers, and MCP bridge
- **`cli/`** - Terminal UI application that consumes the core library for interactive agent sessions

The project leverages Elixir/OTP's strengths: supervision trees, GenServers, process isolation, and fault tolerance.

## Architecture Principles

- **Everything is a Process** - Agent loops, sessions, and tools are GenServers/processes
- **OTP-First Design** - Process mailbox for steering, Registry pub/sub, supervision trees
- **Cross-Platform** - All code must work on macOS, Linux, **and Windows**. No POSIX assumptions; avoid hard-coded `/` path separators, shell-specific syntax, or Unix-only APIs. Use `Path` helpers and `:os.type()` / `System.cmd` abstractions. The CLI and core must build and run on Windows.

## Key Components

### Core Modules

- `Opal.Agent` - Main agent loop GenServer with tool execution
- `Opal.Session` - Conversation tree management and persistence
- `Opal.Events` - Registry-based event system for real-time streaming

### Built-in Tools

All tools implement `Opal.Tool` behavior:

- `read_file` - File reading with hashline-tagged output (`N:hash|content`), offset/limit support
- `write_file` - File writing with auto-created parent directories
- `edit_file` - Hash-anchored line editing (replace, insert_after, insert_before) using tags from `read_file`
- `grep` - Cross-platform regex search with hashline-tagged output, directory walking, glob filtering
- `shell` - Cross-platform shell execution with streaming output
- `sub_agent` - Spawn child agents for delegated tasks
- `tasks` - DETS-backed task tracker

## Development Workflow

### Quick Start

```bash
# Install dependencies
mise run deps

# Run TUI in dev mode
mise run dev

# Run tests
mise run test

# Build CLI
mise run build
```

### Verifying Your Work

After completing any task, always run these checks before considering the work done:

```bash
# Lint — checks formatting + code quality for all projects
mise run lint

# Fix — auto-fix formatting and lint issues
mise run format

# Build — compile everything (includes codegen for CLI)
mise run build
```

These checks are enforced by pre-commit hooks (via Lefthook) and in CI. If `lint` fails, run `format` to auto-fix.

### Remote Debugging

```bash
# Start with Erlang distribution
opal --sname myagent@localhost

# Connect from another terminal
opal --connect myagent@localhost --inspect
```

## Configuration

### Environment Variables

- `OPAL_DATA_DIR` - Root directory for Opal data (sessions, logs, auth)
- `OPAL_SHELL` - Shell for tool execution (bash, zsh, sh, powershell, cmd)
- `OPAL_COPILOT_DOMAIN` - GitHub domain for auth (default: github.com)

### Context Discovery

The agent automatically discovers project context:

- `AGENTS.md` - Primary agent instructions
- `OPAL.md` - Opal-specific instructions
- `.agents/` and `.opal/` hidden directory variants

## Code Style

### Prefer Named Maps Over Positional Tuples

Use maps with named keys for function return values. Positional tuples are hard to read at call sites when the elements aren't self-evident.

**Tuples are fine for:**

- Idiomatic Elixir patterns: `{:ok, value}`, `{:error, reason}`, `{:noreply, state}`
- `Enum.reduce` accumulators (internal, not returned to callers)
- 2-element pairs where meaning is obvious from context

**Use maps when:**

- Returning 2+ related values from a helper function
- The caller destructures the result — named keys document intent

```elixir
# Bad — caller sees {entries, files, skills} with no context
defp discover_context(config, dir) do
  {entries, file_paths, skills}
end

# Good — self-documenting at the call site
defp discover_context(config, dir) do
  %{entries: entries, files: file_paths, skills: skills}
end

# Fine — idiomatic {:ok, _} / {:error, _}
def execute(args, ctx), do: {:ok, result}
```

### Specs and Types

- Add `@spec` to all public functions and meaningful private helpers
- Use `@type` / `@typep` to name complex types instead of inlining them in specs
- Use `@typedoc` on public types

## Code Patterns

### Agent Interaction

```elixir
# Start session
{:ok, agent} = Opal.start_session(%{
  system_prompt: "You are a helpful assistant",
  working_dir: "/path/to/project"
})

# Send prompt
%{queued: false} = Opal.prompt(agent, "List all files")

# Send another prompt while busy — queued and applied between tool calls
%{queued: true} = Opal.prompt(agent, "Focus on tests instead")
```

### Tool Implementation

```elixir
defmodule MyTool do
  @behaviour Opal.Tool

  @impl true
  def name, do: "my_tool"

  @impl true
  def description, do: "Does something useful"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string", "description" => "Input text"}
      },
      "required" => ["input"]
    }
  end

  @impl true
  def execute(%{"input" => input}, _context) do
    {:ok, "Result: #{input}"}
  end
end
```

## File Structure

```
opal/lib/opal/
├── agent.ex              # Main agent GenServer
├── agent/                # Agent loop internals (stream, tool_runner, retry, etc.)
├── auth.ex               # Authentication system
├── config.ex             # Typed configuration
├── context.ex            # Walk-up context discovery
├── events.ex             # Registry-based event system
├── session.ex            # Session management
├── session_server.ex     # Session GenServer
├── provider/             # LLM provider implementations
├── tool/                 # Built-in tool implementations
├── mcp/                  # MCP bridge components
└── rpc/                  # JSON-RPC server

cli/src/
├── app.tsx               # TUI application (React/Ink)
├── bin.ts                # Entry point
├── components/           # UI components
├── hooks/                # React hooks
└── sdk/                  # TypeScript SDK client
```

This codebase leverages Elixir's mature concurrency and fault-tolerance primitives. Focus on using OTP patterns rather than fighting against them.
