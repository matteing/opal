# Opal Project Guide

**Opal** is a coding agent harness and runtime built with Elixir that provides a clean, OTP-native architecture for building AI coding agents.

## Project Overview

This is an Elixir monorepo with two main components:

- **`core/`** - The Opal SDK (Elixir library) providing the agent engine, tools, providers, and MCP bridge
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
- `shell` - Cross-platform shell execution with streaming output
- `sub_agent` - Spawn child agents for delegated tasks
- `tasks` - DETS-backed task tracker

## Development Workflow

### Quick Start

```bash
# Install dependencies
nx run-many -t deps

# Run TUI with auto-recompilation
cd cli && mix opal

# Run tests
nx run-many -t test

# Build binary
nx run cli:escript
```

### Verifying Your Work

After completing any task, always run these checks before considering the work done:

```bash
# Lint — checks formatting + code quality for all projects
pnpm lint

# Fix — auto-fix formatting and lint issues
pnpm format

# Build — compile everything (includes codegen for CLI)
pnpm build
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

- `OPAL_MODEL` - Default LLM model
- `OPAL_WORKING_DIR` - Agent working directory
- `OPAL_LOG_LEVEL` - Logging verbosity

### Context Discovery

The agent automatically discovers project context:

- `AGENTS.md` - Primary agent instructions
- `OPAL.md` - Opal-specific instructions
- `.agents/` and `.opal/` hidden directory variants

## Code Patterns

### Agent Interaction

```elixir
# Start session
{:ok, agent} = Opal.start_session(%{
  system_prompt: "You are a helpful assistant",
  working_dir: "/path/to/project"
})

# Send prompt (async)
:ok = Opal.prompt(agent, "List all files")

# Steer mid-execution
:ok = Opal.steer(agent, "Focus on tests instead")
```

### Tool Implementation

```elixir
defmodule MyTool do
  @behaviour Opal.Tool

  @impl true
  def spec do
    %{
      name: "my_tool",
      description: "Does something useful",
      parameters: %{
        type: "object",
        properties: %{
          input: %{type: "string", description: "Input text"}
        },
        required: ["input"]
      }
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
core/lib/opal/
├── agent.ex              # Main agent GenServer
├── session.ex            # Session management
├── events.ex             # Event system
├── provider/              # LLM provider implementations
├── tool/                  # Built-in tool implementations
├── mcp/                   # MCP bridge components
└── rpc/                   # JSON-RPC server

cli/lib/opal/cli/
├── app.ex                 # TUI application
├── main.ex                # Binary entry point
└── views/                 # UI components
```

This codebase leverages Elixir's mature concurrency and fault-tolerance primitives. Focus on using OTP patterns rather than fighting against them.
