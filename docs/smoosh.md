# Smoosh

> **Status**: Implemented
> **Scope**: `Opal.Agent.Smoosh.*`, `Opal.Tool.KbSearch`, `Opal.Agent.ToolRunner`

## How It Works (Plain English)

Every time an agent calls a tool — like running a shell command or searching
files — the tool returns raw output. Some outputs are small (a 50-byte grep
result), but others are huge (a 60 KB `gh issue list` dump). Left unchecked,
these large outputs eat through the context window. After 30 minutes, 40% of a
200K window can be gone.

**Smoosh** sits at the exit of every tool call and decides what to do with the
output before it enters the conversation:

1. **Small output?** Pass it through untouched.
2. **Medium output?** Compress it — a cheap sub-agent summarizes the key
   information into a fraction of the original size.
3. **Huge output?** Index it — store the full text in a per-session SQLite
   search database. The agent gets a short summary and can search the full
   data later with `kb_search`.

Code-related tools (file reads, edits, grep) are marked `:skip` — their output
is never compressed because the agent needs exact content for code tasks.

### How is this different from Compaction?

| System     | When           | What it does                     | How                          |
| ---------- | -------------- | -------------------------------- | ---------------------------- |
| Compaction | Between turns  | Summarize _old_ messages         | Direct LLM call              |
| Smoosh     | At tool return | Compress/index _new_ tool output | Sub-agent (context isolation) |

Compaction recovers space after the fact. Smoosh prevents waste before it
happens. Together, they extend effective session duration from ~30 minutes to
~3 hours on a 200K window.

---

## Architecture

```
  Tool Call Returns
        │
        ▼
  ┌─────────────┐     Policy check:
  │   classify   │──── smoosh/0 callback + byte thresholds
  └─────┬───────┘
        │
   ┌────┼────┐
   ▼    ▼    ▼
 pass  comp  index
   │    │     │
   │    ▼     ▼
   │  Sub-   KnowledgeBase
   │  Agent  (FTS5 index)
   │    │     │
   ▼    ▼     ▼
  Result enters conversation
```

### Classification Rules

Given a tool's declared policy and the output size:

1. Tool declares `smoosh: :skip` → **pass through** (never compress)
2. Tool declares `smoosh: :always` → **compress** (always)
3. Output < `threshold_bytes` (4 KB) → **pass through**
4. Output > `hard_limit_bytes` (100 KB) → **index only**
5. Otherwise → **compress**

---

## Components

### Tool Policy (`Opal.Tool` callback)

Each tool can declare its compression policy via an optional `smoosh/0` callback:

```elixir
# In any Opal.Tool module:
@impl true
def smoosh, do: :skip   # :auto | :skip | :always
```

Tools that don't implement the callback default to `:auto`. Currently these
tools declare `:skip` (code/file tools that need exact output):

- `ReadFile`, `EditFile`, `WriteFile`, `Grep`, `DebugState`, `Tasks`, `AskUser`, `KbSearch`

### Smoosh Module (`Opal.Agent.Smoosh`)

**File:** `opal/lib/opal/agent/smoosh/smoosh.ex`

Entry point called from `ToolRunner.collect_result/4`. Two public functions:

- `classify/3` — evaluates tool policy + size thresholds → `:pass_through | :compress | :index_only`
- `maybe_compress/3` — orchestrates the full flow: classify → compress/index → broadcast event

### Compressor (`Opal.Agent.Smoosh.Compressor`)

**File:** `opal/lib/opal/agent/smoosh/compressor.ex`

Spawns a lightweight sub-agent (no tools, pure summarization) to compress output.
Uses `Spawner.spawn_from_state/2` with a 30-second timeout. The sub-agent runs
in its own context so the raw output never pollutes the parent agent's window.

### Chunker (`Opal.Agent.Smoosh.Chunker`)

**File:** `opal/lib/opal/agent/smoosh/chunker.ex`

Splits content into ≤4 KB chunks for FTS5 indexing. Three strategies based on
detected content type:

| Content type | Strategy | Max chunk |
| ------------ | -------- | --------- |
| Markdown     | Split by headings (H1–H4), keep code blocks intact | 4 KB |
| JSON         | Walk object tree, use key paths as titles; batch arrays by size | 4 KB |
| Plain text   | Blank-line paragraphs, or fixed line groups with overlap | 4 KB |

### Knowledge Base (`Opal.Agent.Smoosh.KnowledgeBase`)

**File:** `opal/lib/opal/agent/smoosh/knowledge_base.ex`

A GenServer wrapping a per-session SQLite database with FTS5 full-text search.
Started lazily under the session's `DynamicSupervisor` on first index operation.
Registered in `Opal.Registry` as `{:knowledge_base, session_id}`.

**Storage:** `<sessions_dir>/<session_id>/kb.sqlite3`

**Schema:**

```sql
-- Source tracking and dedup
CREATE TABLE sources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL,
  chunk_count INTEGER NOT NULL DEFAULT 0,
  code_chunk_count INTEGER NOT NULL DEFAULT 0,
  indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Primary search: Porter stemming + Unicode tokenization
CREATE VIRTUAL TABLE chunks USING fts5(
  title, content,
  source_id UNINDEXED, content_type UNINDEXED,
  tokenize='porter unicode61'
);

-- Secondary search: trigram tokenization for substring matching
CREATE VIRTUAL TABLE chunks_trigram USING fts5(
  title, content,
  source_id UNINDEXED, content_type UNINDEXED,
  tokenize='trigram'
);

-- Vocabulary for fuzzy correction
CREATE TABLE vocabulary (word TEXT PRIMARY KEY);
```

**BM25 ranking:** Queries use `bm25(chunks, 2.0, 1.0)` — title matches weighted
2× over content matches.

**Search fallback (4 layers):**

| Layer | Strategy     | When used |
| ----- | ------------ | --------- |
| 1     | Porter AND   | Default — stemmed matching ("running" → "run") |
| 1b    | Porter OR    | Fallback when AND finds nothing |
| 2     | Trigram AND  | Substring/partial identifier matching |
| 2b    | Trigram OR   | Last resort broad match |

**Dedup:** Re-indexing the same source label deletes previous chunks in a
transaction before inserting new ones.

### KbSearch Tool (`Opal.Tool.KbSearch`)

**File:** `opal/lib/opal/tool/kb_search.ex`

Lets the agent search indexed content:

```
kb_search(query: "authentication bug", limit: 5, source: "shell")
```

Only included in the active tool set when the knowledge base has content
(checked via `KnowledgeBase.has_content?/1` in `ToolRunner.active_tools/1`).

### SystemPrompt Guideline

When `kb_search` is active, this guideline is injected:

> Some tool outputs were compressed or indexed to save context. The full data
> is searchable via `kb_search`. Use it when a compressed summary is
> insufficient or you need specific details from a previous tool output.

---

## Configuration

### Feature Flag

```elixir
# Enable smoosh (disabled by default):
Opal.Config.new(%{
  features: %{smoosh: true}
})

# With custom thresholds:
Opal.Config.new(%{
  features: %{
    smoosh: %{
      enabled: true,
      threshold_bytes: 8_192,       # compress above 8 KB (default: 4096)
      hard_limit_bytes: 204_800,    # index above 200 KB (default: 102400)
      compressor_model: "gpt-4.1",  # override model (default: nil = auto)
      index_enabled: true           # enable KB indexing (default: true)
    }
  }
})
```

Boolean shorthand `smoosh: true` enables with defaults. Map form allows
overriding individual settings.

### exqlite Dependency

The knowledge base uses [exqlite](https://github.com/elixir-sqlite/exqlite),
a direct SQLite3 NIF driver. FTS5 must be enabled at compile time:

```elixir
# config/config.exs
config :exqlite,
  force_build: true,
  make_env: %{"EXQLITE_SYSTEM_CFLAGS" => "-DSQLITE_ENABLE_FTS5=1"}
```

---

## CLI Surface

### Status Indicator

Smoosh events appear as status entries in the TUI timeline:

```
⊜ Smoosh: compressed shell output (45.2 KB → 2.1 KB, 95% reduction)
⊜ Smoosh: indexed shell output (120.5 KB) into knowledge base
```

### `/smoosh` Command

Toggle smoosh or check status:

```
/smoosh on      # Enable smoosh
/smoosh off     # Disable smoosh
/smoosh         # Show current status
```

### Config Panel

Smoosh appears in the `/opal` config panel as a toggleable feature alongside
Sub-agents, Skills, and Debug.

---

## Integration Points

### ToolRunner — single hook

Two lines in `collect_result/4`, after tool execution completes but before the
result enters the tool_results list:

```elixir
tool_mod = find_tool(tc.name, active_tools(state))
{result, state} = Opal.Agent.Smoosh.maybe_compress(tool_mod, result, state)
```

### Events

Two event types broadcast via `Emitter`:

- `{:smoosh_compress, %{tool, raw_bytes, compressed_bytes}}` — output was compressed
- `{:smoosh_index, %{tool, raw_bytes}}` — output was indexed into KB

Serialized over RPC as `smoosh_compress` and `smoosh_index` events.

### Supervision

The KnowledgeBase GenServer runs under the session's `DynamicSupervisor` (same
supervisor as sub-agents). Started lazily on first index operation. Terminated
automatically when the session ends.

---

## Module Boundary

| File | Change | Purpose |
| ---- | ------ | ------- |
| `opal/lib/opal/agent/smoosh/smoosh.ex` | New | Core: classify + maybe_compress |
| `opal/lib/opal/agent/smoosh/compressor.ex` | New | Sub-agent compression wrapper |
| `opal/lib/opal/agent/smoosh/chunker.ex` | New | Content splitting for FTS5 |
| `opal/lib/opal/agent/smoosh/knowledge_base.ex` | New | SQLite FTS5 GenServer |
| `opal/lib/opal/tool/kb_search.ex` | New | Search tool |
| `opal/lib/opal/tool/tool.ex` | Modified | `smoosh/0` optional callback |
| `opal/lib/opal/config.ex` | Modified | `smoosh:` feature flag |
| `opal/lib/opal/agent/tool_runner.ex` | Modified | 2-line hook + KB gate |
| `opal/lib/opal/agent/system_prompt.ex` | Modified | 1 guideline rule |
| `opal/lib/opal/rpc/protocol.ex` | Modified | 2 event definitions |
| `opal/lib/opal/rpc/server.ex` | Modified | Event serialization + feature key |
| `opal/lib/opal/tool/{7 tools}.ex` | Modified | `def smoosh, do: :skip` |
| `cli/src/state/timeline.ts` | Modified | Smoosh event rendering |
| `cli/src/hooks/use-opal-commands.ts` | Modified | `/smoosh` command |
| `cli/src/components/config-panel.tsx` | Modified | Smoosh toggle |
| `cli/src/sdk/session.ts` | Modified | `smoosh: false` default |

## Removal Recipe

If smoosh doesn't work out, removal is ~15 deletions:

1. Delete `opal/lib/opal/agent/smoosh/` (4 files)
2. Delete `opal/lib/opal/tool/kb_search.ex`
3. Delete `opal/test/opal/agent/smoosh/` (3 files)
4. Remove `smoosh/0` from `@optional_callbacks` in `tool.ex`
5. Remove 2 lines from `tool_runner.ex` (the hook + `kb_has_content?`)
6. Remove `smoosh:` from `Config.Features` struct + `merge_subsystem` call
7. Remove 1 rule from `system_prompt.ex`
8. Remove `{:exqlite, ...}` from `mix.exs` + config
9. `grep -r "def smoosh" opal/lib/opal/tool/` and delete each line
10. Remove smoosh events from `protocol.ex` and `server.ex`
11. Remove smoosh handling from CLI (`timeline.ts`, `use-opal-commands.ts`, `config-panel.tsx`, `session.ts`)
12. Regenerate TypeScript types

The compiler will flag any remaining references as warnings.

## References

- [Context Mode](https://mksg.lu/blog/context-mode) — reference implementation
  by Mustafa Kılıç (mksglu/claude-context-mode). Source of the FTS5 dual-table
  design, BM25 weights, and 3-layer search architecture.
- [exqlite](https://github.com/elixir-sqlite/exqlite) — SQLite3 NIF for Elixir.
- [SQLite FTS5](https://www.sqlite.org/fts5.html) — full-text search extension.
- [Compaction](compaction.md) — complementary system for summarizing old messages.
