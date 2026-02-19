# Tools

Opal's built-in tools implement the `Opal.Tool` behaviour and are executed as supervised tasks during the agent loop.

## Tool Behaviour

Every tool implements four required callbacks, plus optional context-aware callbacks:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()           # JSON Schema
@callback execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()} | {:effect, term()}
@callback description(Opal.Tool.tool_context()) :: String.t()  # optional
@callback meta(map()) :: String.t()                            # optional
```

The agent converts tool modules to JSON Schema for the LLM. When the LLM requests a tool call, the agent looks up the module by name and calls `execute/2` inside a supervised task. Tools receive a context map with `working_dir`, `session_id`, `config`, `agent_pid`, and an `agent_state` snapshot; each call also includes `emit` and `call_id` for streamed output.

## Default Tools

| Tool          | Module               | Purpose                                                                |
| ------------- | -------------------- | ---------------------------------------------------------------------- |
| `read_file`   | `Opal.Tool.ReadFile`  | Read files with hashline-tagged output                                 |
| `edit_file`   | `Opal.Tool.EditFile`  | Edit by hash-anchored line references                                  |
| `write_file`  | `Opal.Tool.WriteFile` | Create or overwrite files                                              |
| `grep`        | `Opal.Tool.Grep`     | Cross-platform regex search with hashline-tagged output                |
| `shell`       | `Opal.Tool.Shell`    | Execute shell commands with streaming output                           |
| `sub_agent`   | `Opal.Tool.SubAgent` | Spawn parallel child agents                                            |
| `tasks`       | `Opal.Tool.Tasks`    | DAG-aware task tracker with auto-unblock                               |
| `use_skill`   | `Opal.Tool.UseSkill` | Load agent skills dynamically                                          |
| `ask_user`    | `Opal.Tool.AskUser`  | Ask the user a question (top-level agents)                             |
| `debug_state` | `Opal.Tool.DebugState` | Introspect agent runtime state and recent events (disabled by default) |

Each tool has a detailed doc in `docs/tools/`:

- [**read_file**](tools/read.md) — Read with hashline-tagged output for edit anchoring
- [**edit_file**](tools/edit.md) — Hash-anchored line editing (replace, insert, delete)
- [**write_file**](tools/write.md) — Create/overwrite files with encoding preservation
- [**grep**](tools/grep.md) — Cross-platform regex search with context and glob filtering
- [**shell**](tools/shell.md) — Streaming shell execution with tail-truncation
- [**sub_agent**](tools/sub-agent.md) — Spawn child agents with depth enforcement
- [**tasks**](tools/tasks.md) — DAG-aware task tracker with dependency validation and auto-unblock
- [**use_skill**](tools/use-skill.md) — Progressive skill loading
- [**ask_user**](tools/user-input.md) — User input with question escalation for sub-agents
- [**debug_state**](tools/debug.md) — Runtime self-introspection snapshot for troubleshooting

## MCP Tools

External tools from MCP servers are discovered at session start and wrapped as runtime modules implementing `Opal.Tool`. They appear alongside built-in tools — the agent and LLM treat them identically. See [mcp.md](mcp.md).

## Encoding Layer

`Opal.FileIO` handles two invisible artifacts that cause tool failures:

- **UTF-8 BOM** — stripped before matching/output, restored after edits
- **CRLF line endings** — normalized to LF for processing, restored after edits

This shared logic is used by `ReadFile`, `EditFile`, `WriteFile`, and `Grep` to prevent encoding corruption.

## Source

- `lib/opal/tool/tool.ex` — Behaviour definition
- `lib/opal/tool/` — All tool implementations
- `lib/opal/util/hashline.ex` — Hash computation and line tagging
- `lib/opal/util/file_io.ex` — BOM/CRLF handling and shared path/file I/O helpers
