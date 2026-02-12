# Architecture Overview

Opal is a coding agent harness built on Elixir/OTP. The core (`core/`) provides the agent runtime, and the CLI (`cli/`) provides a TypeScript terminal UI connected via JSON-RPC over stdio.

## Process Model

Every agent session is an isolated OTP supervision tree. No global state is shared between sessions except the event registry.

```
Opal.Supervisor (:one_for_one)
├── Opal.Events.Registry          ← shared pub/sub backbone
└── Opal.SessionSupervisor        ← DynamicSupervisor, one child per session
    ├── SessionServer "a1b2c3"    ← :rest_for_one
    │   ├── Task.Supervisor       ← tool execution
    │   ├── DynamicSupervisor     ← sub-agents
    │   ├── Opal.Session          ← conversation tree (optional)
    │   └── Opal.Agent            ← agent loop
    └── SessionServer "d4e5f6"
        └── ...
```

## Request Flow

```
CLI (TypeScript)
  │
  ├─ JSON-RPC over stdio ──► Opal.RPC.Stdio ──► Opal.RPC.Handler
  │                                                    │
  │                                              Opal.Agent (GenServer)
  │                                              ┌─────┴──────┐
  │                                         Provider.stream   Tool execution
  │                                         (SSE → handle_info) (Task.Supervisor)
  │                                              │
  │                                         Opal.Session (ETS tree)
  │
  └─ Events (notifications) ◄── Opal.Events.Registry ◄── Agent broadcasts
```

## Subsystem Map

| Subsystem | What it does | Doc |
|-----------|-------------|-----|
| **Agent Loop** | GenServer implementing prompt → stream → tools → repeat | [agent-loop.md](agent-loop.md) |
| **Session** | Conversation tree with branching and persistence | [session.md](session.md) |
| **Compaction** | Summarizes old messages to stay within context window | [compaction.md](compaction.md) |
| **OTP Patterns** | GenServer patterns, Registry, ETS/DETS, message passing | [otp.md](otp.md) |
| **Supervision** | Per-session process trees, fault isolation, message passing | [supervision.md](supervision.md) |
| **Tools** | Built-in tool implementations (read, edit, write, shell, sub-agent) | [tools.md](tools.md) |
| **RPC** | JSON-RPC 2.0 protocol over stdio between CLI and server | [rpc.md](rpc.md) |
| **Providers** | LLM integration (auth, streaming, SSE parsing) | [providers.md](providers.md) |
| **MCP** | Model Context Protocol bridge for external tool servers | [mcp.md](mcp.md) |
| **SDK** | TypeScript client library for the JSON-RPC protocol | [sdk.md](sdk.md) |

## Key Design Decisions

- **Everything is a process.** The agent loop, session store, tool execution, and sub-agents are all GenServers or supervised tasks. The BEAM scheduler handles concurrency.
- **Per-session isolation.** Each session owns its entire process tree. Terminating a session cleanly stops all its tools, sub-agents, and streaming connections.
- **Provider-agnostic.** The agent loop never touches raw API formats. The `Provider` behaviour translates between semantic events and wire protocols.
- **Hashline editing.** `read_file` tags every line with a content hash. `edit_file` references lines by hash instead of reproducing content. See [tools/edit.md](tools/edit.md).
- **Registry pub/sub.** Events are plain Erlang terms routed via OTP's `Registry`. No message broker, no serialization overhead.

## Source Layout

```
core/lib/opal/
├── agent.ex                 # Agent loop GenServer
├── agent/                   # Overflow detection, retry, system prompt
├── session.ex               # Conversation tree (ETS)
├── session/                 # Compaction, branch summaries
├── events.ex                # Registry-based pub/sub
├── provider.ex              # Provider behaviour
├── provider/copilot.ex      # GitHub Copilot implementation
├── auth.ex                  # Device-code OAuth
├── tool.ex                  # Tool behaviour
├── tool/                    # Built-in tools (read, edit, write, shell, etc.)
├── mcp/                     # MCP bridge (client, discovery, supervisor)
├── rpc/                     # JSON-RPC protocol, handler, stdio transport
├── config.ex                # Runtime configuration
├── context.ex               # Project context discovery (AGENTS.md, skills)
├── token.ex                 # Token estimation heuristics
└── path.ex                  # Path safety (traversal prevention)
```
