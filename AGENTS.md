# Opal Project Guide

**Opal** is a coding agent harness built with Elixir/OTP for AI coding agents.

## Architecture

- **Everything is a Process** - Agent loops, sessions, and tools are GenServers
- **Cross-Platform** - Works on macOS, Linux, and Windows

## Components

- `opal/` - Elixir SDK (agent engine, tools, providers)
- `cli/` - Terminal UI application

## Built-in Tools

- `read_file`, `write_file`, `edit_file` - File operations with hashline tags
- `grep` - Cross-platform search with glob filtering
- `shell` - Cross-platform command execution
- `sub_agent` - Spawn child agents for parallel work
- `tasks` - Task tracker for planning

## Development

```bash
mise run dev    # Run TUI
mise run test   # Run tests
mise run lint   # Check code quality
```