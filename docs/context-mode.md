# Context Mode

> **Status**: Spec / Draft
> **Scope**: `Opal.Agent`, `Opal.Tool`, `Opal.Agent.ToolRunner`

## Problem

Every tool call in an agent session dumps raw output directly into the context
window. A Playwright snapshot costs 56 KB. Twenty GitHub issues cost 59 KB. One
access log — 45 KB. After 30 minutes, 40% of a 200K window is gone.

Compaction (see [compaction.md](compaction.md)) recovers space *after the fact*
by summarizing older messages. Context mode addresses the other side: **prevent
the waste from happening in the first place** by compressing tool outputs at the
point of emission.

These two systems are complementary:

| System       | When            | Strategy                         |
| ------------ | --------------- | -------------------------------- |
| Compaction   | After turns     | Summarize *old* messages         |
| Context Mode | At tool return  | Compress *new* tool outputs      |

Combined, they can extend effective session duration from ~30 minutes to ~3 hours
on a 200K window.

---

## Design Principles

1. **Native, not middleware.** Context mode is built into the tool execution
   pipeline — not an MCP proxy or external server. Opal controls the full
   lifecycle.

2. **Opt-in per tool.** Not all tool outputs benefit from compression. A 200-byte
   `grep` result should pass through untouched. A 60 KB `shell` output running
   `gh issue list` should be compressed. Tools declare their intent.

3. **Lossless-by-default for code.** File reads, diffs, and edit confirmations
   are never compressed. The agent needs exact content for code tasks. Context
   mode targets *data* outputs: logs, API responses, search results, analytics.

4. **Sub-agent as sandbox.** Compression runs through a child agent with a
   focused system prompt. The raw output never enters the parent's context
   window — only the sub-agent's distilled summary does.

5. **Knowledge base as overflow.** When tool output is too large even for a
   sub-agent, it's indexed into a per-session FTS5 store. The agent can
   search it later without re-fetching.

---

## Architecture

```
                         ┌──────────────────────────────────┐
                         │         Parent Agent             │
                         │                                  │
  User prompt ──────────►│  ToolRunner.execute_batch/2      │
                         │    │                             │
                         │    ├─► read_file → pass-through  │
                         │    │                             │
                         │    ├─► shell (small) → pass-thru │
                         │    │                             │
                         │    ├─► shell (large) ──────┐     │
                         │    │                       │     │
                         │    │    ┌──────────────────▼──┐  │
                         │    │    │  Context Compressor  │  │
                         │    │    │  (sub-agent)         │  │
                         │    │    │                      │  │
                         │    │    │  raw → summary       │  │
                         │    │    │  raw → index (FTS5)  │  │
                         │    │    └──────────┬───────────┘  │
                         │    │               │              │
                         │    ◄───────────────┘              │
                         │    │  compressed result           │
                         │    │  enters parent context       │
                         │    │                              │
                         └────┴──────────────────────────────┘
```

### Data flow

1. Tool executes, produces raw output string.
2. `ToolRunner` checks the output against the **compression policy** (see below).
3. If compression is triggered, raw output is sent to a **compressor sub-agent**
   that returns a structured summary. Optionally, the raw output is also indexed
   into the session's **knowledge base**.
4. The compressed result (not the raw output) is returned to the parent agent as
   the tool result.
5. The parent agent sees a concise result and a note that full data is available
   via the `kb_search` tool if needed.

---

## Components

### 1. Compression Policy

A policy determines whether a tool result should be compressed. This runs
synchronously in `ToolRunner` after `execute/2` returns.

```elixir
defmodule Opal.Agent.ContextMode do
  @type policy :: :pass_through | :compress | :index_only

  @doc """
  Decide how to handle a tool result based on the tool module,
  output size, and agent configuration.
  """
  @spec classify(module(), String.t(), State.t()) :: policy()
  def classify(tool_module, output, state)
end
```

**Rules (evaluated in order):**

| # | Condition                              | Result          |
|---|----------------------------------------|-----------------|
| 1 | Context mode disabled in config        | `:pass_through` |
| 2 | Tool declares `context_mode: :skip`    | `:pass_through` |
| 3 | Tool declares `context_mode: :always`  | `:compress`     |
| 4 | Output < threshold (default 4 KB)      | `:pass_through` |
| 5 | Output > hard limit (default 100 KB)   | `:index_only`   |
| 6 | Otherwise                              | `:compress`     |

The threshold is configurable via `config.features.context_mode.threshold_bytes`.

### 2. Tool Behaviour Extension

Add an optional callback to `Opal.Tool`:

```elixir
@callback context_mode() :: :auto | :skip | :always
```

Default: `:auto` (decided by size threshold).

**Per-tool defaults:**

| Tool           | Mode      | Rationale                                    |
| -------------- | --------- | -------------------------------------------- |
| `read_file`    | `:skip`   | Agent needs exact file contents              |
| `edit_file`    | `:skip`   | Confirmation output is small and exact       |
| `write_file`   | `:skip`   | Confirmation output is small                 |
| `grep`         | `:skip`   | Results are already structured and compact   |
| `shell`        | `:auto`   | Output varies wildly — size-gate it          |
| `sub_agent`    | `:auto`   | Sub-agent responses can be large             |
| `debug_state`  | `:skip`   | Diagnostic output, agent needs full detail   |
| `tasks`        | `:skip`   | Small structured output                      |
| `ask_user`     | `:skip`   | User input is always small and exact         |
| `use_skill`    | `:auto`   | Skill output size is unpredictable           |

### 3. Compressor Sub-Agent

When compression is triggered, a lightweight sub-agent is spawned with a
constrained system prompt and tool set (no tools — pure summarization).

```elixir
defmodule Opal.Agent.ContextMode.Compressor do
  @doc """
  Compress a tool result using a sub-agent summarizer.
  Returns the compressed output string.
  """
  @spec compress(String.t(), tool_name :: String.t(), State.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def compress(raw_output, tool_name, parent_state)
end
```

**Compressor system prompt** (sketch):

```
You are a context compression agent. Your job is to distill tool output into
the minimum information needed for a coding task.

Rules:
- Preserve ALL: error messages, stack traces, file paths, line numbers,
  code snippets, version numbers, command outputs that indicate success/failure.
- Summarize: repetitive data, verbose logs, large API responses, HTML content.
- Format: use structured output (bullet points, key-value pairs). No prose.
- Never fabricate data. If you're unsure whether something is important, keep it.
```

**Model selection:** Use the cheapest/fastest model available. The compressor
prompt is simple — a small model suffices. Default to the parent's model with a
preference for `haiku`-class if available.

**Concurrency:** Compression sub-agents are spawned under the session's existing
`DynamicSupervisor`, same as regular sub-agents. Multiple compressions can run
in parallel (one per tool call in the batch).

### 4. Knowledge Base

A per-session SQLite FTS5 store for indexing large tool outputs that exceed even
the compressor's capacity. The agent can search it later via a new `kb_search`
tool.

```elixir
defmodule Opal.Agent.KnowledgeBase do
  @moduledoc """
  Per-session full-text search index backed by SQLite FTS5.
  Stores chunked tool outputs with BM25 ranking and Porter stemming.
  """

  @type t :: %__MODULE__{db: reference(), session_id: String.t()}

  @doc "Open or create the knowledge base for a session."
  @spec open(session_id :: String.t()) :: {:ok, t()} | {:error, term()}

  @doc "Index raw content, chunked by logical boundaries."
  @spec index(t(), source :: String.t(), content :: String.t()) :: :ok

  @doc "Search the index, returning ranked chunks."
  @spec search(t(), query :: String.t(), opts :: keyword()) ::
          {:ok, [%{source: String.t(), content: String.t(), rank: float()}]}

  @doc "Close the database."
  @spec close(t()) :: :ok
end
```

**Storage location:** `~/.opal/sessions/<session_id>/kb.sqlite3`

**Chunking strategy:**
- Markdown: split by headings, keep code blocks intact.
- Logs: split by timestamp boundaries or fixed line count (100 lines).
- Generic: fixed-size chunks (2 KB) with 200-byte overlap.

**Schema:**

```sql
CREATE VIRTUAL TABLE chunks USING fts5(
  source,       -- tool name + call context (e.g. "shell: gh issue list")
  content,      -- the chunk text
  tokenize = 'porter'
);
```

### 5. `kb_search` Tool

A new tool that lets the agent query the knowledge base:

```elixir
defmodule Opal.Tool.KbSearch do
  @behaviour Opal.Tool

  def name, do: "kb_search"
  def description, do: "Search the session knowledge base for previously indexed tool outputs."

  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Search query (supports stemming)."},
        limit: %{type: "integer", description: "Max results to return.", default: 5}
      },
      required: ["query"]
    }
  end

  def context_mode, do: :skip

  def execute(%{"query" => query} = args, context) do
    # ...
  end
end
```

**Tool guideline injection:** When context mode is active and the knowledge base
is non-empty, `SystemPrompt.build_guidelines/2` appends a note:

```
<context-mode>
Some tool outputs were compressed to save context. The full data is indexed
in the session knowledge base. Use `kb_search` to retrieve specific details
when the compressed summary is insufficient.
</context-mode>
```

The `kb_search` tool is only included in the active tool set when the knowledge
base has been written to (lazy activation).

---

## Configuration

Context mode is controlled under `config.features.context_mode`:

```elixir
%{
  context_mode: %{
    enabled: false,                # off by default during rollout
    threshold_bytes: 4_096,        # compress outputs > 4 KB
    hard_limit_bytes: 102_400,     # index-only outputs > 100 KB
    compressor_model: nil,         # nil = auto-select cheapest available
    index_enabled: true            # enable knowledge base indexing
  }
}
```

Hot-swappable via `Agent.configure/2` mid-session — same pattern as existing
feature flags.

---

## Integration Points

### ToolRunner

The primary integration is in `Opal.Agent.ToolRunner.execute_tool/3`, after the
tool's `execute/2` returns:

```elixir
def execute_tool(tool_module, args, context) do
  case tool_module.execute(args, context) do
    {:ok, raw_output} ->
      case ContextMode.classify(tool_module, raw_output, context.agent_state) do
        :pass_through ->
          {:ok, raw_output}

        :compress ->
          {:ok, compressed} = Compressor.compress(raw_output, tool_module.name(), context.agent_state)
          maybe_index(raw_output, tool_module.name(), context)
          {:ok, compressed}

        :index_only ->
          :ok = index(raw_output, tool_module.name(), context)
          {:ok, "[Output indexed to knowledge base — #{byte_size(raw_output)} bytes. " <>
                "Use kb_search to query.]"}
      end

    other ->
      other
  end
end
```

### Compaction

Context mode reduces the *rate* at which context fills. Compaction remains the
safety net. No changes to compaction are required — they are independent systems
operating at different points in the pipeline.

When compaction summarizes messages that contain compressed tool results, the
compressed results are already concise, making compaction summaries higher
quality (less information loss per compaction cycle).

### Events

New events for observability:

```elixir
{:context_mode_compress, %{tool: name, raw_bytes: n, compressed_bytes: m}}
{:context_mode_index, %{tool: name, bytes: n, chunks: c}}
```

These are broadcast via `Opal.Agent.Emitter` and can be displayed in the CLI
status bar (e.g. "⚡ 56 KB → 299 B").

### Sub-Agents

Sub-agents spawned by `Opal.Tool.SubAgent` inherit the parent's context mode
config. Each sub-agent gets its own knowledge base instance (scoped to its
session ID). This means sub-agent tool outputs are also compressed, preventing
the common pattern of sub-agents burning through context on data-heavy tasks.

---

## CLI Surface

### Status indicator

When context mode is active, the CLI displays a compression indicator in the
tool execution output:

```
⚡ shell: 56.2 KB → 299 B (99.5% saved)
```

### `/context` command

A new slash command to manage context mode:

| Command                     | Effect                                   |
| --------------------------- | ---------------------------------------- |
| `/context on`               | Enable context mode for this session     |
| `/context off`              | Disable context mode                     |
| `/context status`           | Show stats: total saved, KB entries, etc |
| `/context search <query>`   | Shorthand for `kb_search` tool           |

---

## Risks & Mitigations

| Risk                                      | Mitigation                                          |
| ----------------------------------------- | --------------------------------------------------- |
| Compressor loses critical detail           | Conservative defaults: skip file ops, low threshold  |
| Compressor adds latency to tool calls      | Parallel execution; use fast model; only for large outputs |
| LLM hallucinates in compression            | System prompt forbids fabrication; structured output |
| Knowledge base grows unbounded             | Per-session lifecycle; cleaned up with session       |
| Extra token cost from compressor calls     | Net positive: compress 56 KB → 300 B saves far more tokens than the compressor consumes |
| Tool authors forget to set `context_mode`  | `:auto` default uses size heuristic — works without annotation |

---

## Implementation Sequence

1. **`Opal.Agent.ContextMode`** — classification logic, config wiring, feature flag.
2. **`Opal.Tool` behaviour extension** — add optional `context_mode/0` callback.
3. **`Opal.Agent.ContextMode.Compressor`** — sub-agent-based compression.
4. **`ToolRunner` integration** — post-execute classification and dispatch.
5. **Events & CLI** — compression events, status indicator.
6. **`Opal.Agent.KnowledgeBase`** — SQLite FTS5 store, chunking, search.
7. **`Opal.Tool.KbSearch`** — search tool, lazy activation, system prompt note.
8. **`/context` CLI command** — slash command for manual control.

Steps 1–5 form a useful MVP without the knowledge base. Steps 6–8 add the
overflow path for very large outputs.

---

## References

- [Context Mode (mksg.lu)](https://mksg.lu/blog/context-mode) — Original concept
  and benchmarks. MCP-based implementation for Claude Code.
- [Compaction](compaction.md) — Opal's existing context recovery system.
- [Sub-Agent](tools/sub-agent.md) — Spawner architecture used by the compressor.
- [System Prompt](system-prompt.md) — Dynamic prompt assembly for guideline injection.
