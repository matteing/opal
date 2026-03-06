# Smoosh!

> **Status**: Spec / Draft
> **Scope**: `Opal.Agent`, `Opal.Tool`, `Opal.Agent.ToolRunner`

Just take that shell output and smooooooosh it down!

## Problem

Every tool call in an agent session dumps raw output directly into the context
window. A Playwright snapshot costs 56 KB. Twenty GitHub issues cost 59 KB. One
access log — 45 KB. After 30 minutes, 40% of a 200K window is gone.

Compaction (see [compaction.md](compaction.md)) recovers space _after the fact_
by summarizing older messages. Smoosh addresses the other side: **prevent
the waste from happening in the first place** by compressing tool outputs at the
point of emission.

These two systems are complementary, not overlapping (see
[detailed comparison](#compaction--overlap-analysis) in Integration Points):

| System     | When           | Strategy                    | Mechanism                    |
| ---------- | -------------- | --------------------------- | ---------------------------- |
| Compaction | After turns    | Summarize _old_ messages    | Direct provider call         |
| Smoosh     | At tool return | Compress _new_ tool outputs | Sub-agent (context isolation) |

Combined, they can extend effective session duration from ~30 minutes to ~3 hours
on a 200K window.

---

## Design Principles

1. **Native, not middleware.** Smoosh is built into the tool execution
   pipeline — not an MCP proxy or external server. Opal controls the full
   lifecycle.

2. **Pluggable, not invasive.** Smoosh logic lives in its own namespace
   (`Opal.Agent.Smoosh.*`). Integration with the rest of Opal is minimal:
   one optional callback on `Opal.Tool`, one hook in `ToolRunner`, one
   feature flag. If it doesn't work out, the Removal Recipe is ~10 deletions
   across the codebase.

3. **Opt-in per tool.** Not all tool outputs benefit from compression. A 200-byte
   `grep` result should pass through untouched. A 60 KB `shell` output running
   `gh issue list` should be compressed. Policy is declared as **data inside
   Smoosh**, not as callbacks on each tool module.

4. **Lossless-by-default for code.** File reads, diffs, and edit confirmations
   are never compressed. The agent needs exact content for code tasks. Smoosh
   targets _data_ outputs: logs, API responses, search results, analytics.

5. **Sub-agent as sandbox.** Compression runs through a child agent with a
   focused system prompt. The raw output never enters the parent's context
   window — only the sub-agent's distilled summary does.

6. **Knowledge base as overflow.** When tool output is too large even for a
   sub-agent, it's indexed into a per-session FTS5 store. The agent can
   search it later without re-fetching.

7. **Optional dependency.** The `exqlite` NIF is only required when the
   knowledge base is enabled. When smoosh is disabled or index_enabled is
   false, `exqlite` is never loaded. This keeps the default build lean.

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
                         │    │    │  Smoosh Compressor   │  │
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

A policy determines whether a tool result should be compressed. Classification
logic lives inside `Opal.Agent.Smoosh`, consulting each tool's declared policy
via the `smoosh/0` callback.

```elixir
defmodule Opal.Agent.Smoosh do
  @type policy :: :pass_through | :compress | :index_only

  @doc """
  Decide how to handle a tool result based on the tool module,
  output size, and agent configuration.
  """
  @spec classify(module(), String.t(), State.t()) :: policy()
  def classify(tool_module, output, state)

  @doc """
  Single-function hook for ToolRunner integration.
  Takes the raw tool result and returns the (possibly compressed) result.
  """
  @spec maybe_compress(module(), result(), State.t()) ::
          {result(), State.t()}
  def maybe_compress(tool_module, result, state)
end
```

**Rules (evaluated in order):**

| #   | Condition                              | Result          |
| --- | -------------------------------------- | --------------- |
| 1   | Smoosh disabled in config              | `:pass_through` |
| 2   | Tool declares `smoosh: :skip`          | `:pass_through` |
| 3   | Tool declares `smoosh: :always`        | `:compress`     |
| 4   | Output < threshold (default 4 KB)      | `:pass_through` |
| 5   | Output > hard limit (default 100 KB)   | `:index_only`   |
| 6   | Otherwise                              | `:compress`     |

The threshold is configurable via `config.features.smoosh.threshold_bytes`.

### 2. Tool Behaviour Extension

Add an optional callback to `Opal.Tool`:

```elixir
@callback smoosh() :: :auto | :skip | :always
@optional_callbacks [smoosh: 0]
```

Default: `:auto` (decided by size threshold). Since it's `@optional_callbacks`,
existing tools that don't implement it get `:auto` behaviour automatically —
Smoosh calls `function_exported?(tool_module, :smoosh, 0)` before invoking.

**Per-tool defaults:**

| Tool          | Mode    | Rationale                                  |
| ------------- | ------- | ------------------------------------------ |
| `read_file`   | `:skip` | Agent needs exact file contents            |
| `edit_file`   | `:skip` | Confirmation output is small and exact     |
| `write_file`  | `:skip` | Confirmation output is small               |
| `grep`        | `:skip` | Results are already structured and compact |
| `shell`       | `:auto` | Output varies wildly — size-gate it        |
| `sub_agent`   | `:auto` | Sub-agent responses can be large           |
| `debug_state` | `:skip` | Diagnostic output, agent needs full detail |
| `tasks`       | `:skip` | Small structured output                    |
| `ask_user`    | `:skip` | User input is always small and exact       |
| `use_skill`   | `:auto` | Skill output size is unpredictable         |
| `kb_search`   | `:skip` | Already from the knowledge base            |

### 3. Compressor Sub-Agent

When compression is triggered, a lightweight sub-agent is spawned with a
constrained system prompt and tool set (no tools — pure summarization).

```elixir
defmodule Opal.Agent.Smoosh.Compressor do
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
  Dual-table design: Porter-stemmed index for natural language queries,
  trigram index for substring/partial matches. BM25 ranking with
  title-boosted weights. Three-layer fallback search with fuzzy correction.
  """

  @type t :: %__MODULE__{db: reference(), session_id: String.t()}

  @doc "Open or create the knowledge base for a session."
  @spec open(session_id :: String.t()) :: {:ok, t()} | {:error, term()}

  @doc "Index raw content, chunked by logical boundaries. Re-indexing the same source label replaces previous chunks."
  @spec index(t(), source :: String.t(), content :: String.t(), opts :: keyword()) ::
          {:ok, %{source_id: integer(), chunks: integer(), code_chunks: integer()}}

  @doc "Search the index using 3-layer fallback (Porter → Trigram → Fuzzy)."
  @spec search(t(), query :: String.t(), opts :: keyword()) ::
          {:ok, [%{title: String.t(), content: String.t(), source: String.t(),
                   rank: float(), content_type: :code | :prose}]}

  @doc "List all indexed sources with chunk counts."
  @spec list_sources(t()) :: [%{label: String.t(), chunk_count: integer()}]

  @doc "Close the database."
  @spec close(t()) :: :ok
end
```

**Storage location:** `~/.opal/sessions/<session_id>/kb.sqlite3`

**Database pragmas:** WAL mode (`journal_mode = WAL`, `synchronous = NORMAL`)
for concurrent reads during writes and faster inserts. Same pattern as the
reference implementation.

**Schema:**

The knowledge base uses three tables: a `sources` metadata table, a
Porter-stemmed FTS5 table for natural language search, and a trigram FTS5 table
for substring/partial matching. A `vocabulary` table supports fuzzy correction.

```sql
-- Source tracking and dedup
CREATE TABLE sources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL,            -- tool name + context (e.g. "shell: gh issue list")
  chunk_count INTEGER NOT NULL DEFAULT 0,
  code_chunk_count INTEGER NOT NULL DEFAULT 0,
  indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Primary search index: Porter stemming + Unicode tokenization
CREATE VIRTUAL TABLE chunks USING fts5(
  title,                          -- heading hierarchy or section label
  content,                        -- the chunk text
  source_id UNINDEXED,            -- FK to sources.id (not searchable)
  content_type UNINDEXED,         -- 'code' | 'prose' (not searchable)
  tokenize='porter unicode61'
);

-- Secondary search index: trigram tokenization for substring matching
CREATE VIRTUAL TABLE chunks_trigram USING fts5(
  title,
  content,
  source_id UNINDEXED,
  content_type UNINDEXED,
  tokenize='trigram'
);

-- Vocabulary for fuzzy correction (Levenshtein-based)
CREATE TABLE vocabulary (
  word TEXT PRIMARY KEY
);
```

**BM25 ranking:** Search queries use `bm25(chunks, 2.0, 1.0)` — title matches
are weighted 2× over content matches. This prioritizes chunks whose heading
directly matches the query.

**Dedup on re-index:** When the same source label is indexed again (common in
iterative build-fix-build workflows), the previous chunks for that label are
deleted within the same transaction before inserting new ones.

**Search architecture — 3-layer fallback:**

| Layer | Strategy           | When used                                                                      |
| ----- | ------------------ | ------------------------------------------------------------------------------ |
| 1     | Porter (AND → OR)  | Default. Stemmed search handles inflections ("running" → "run")                |
| 2     | Trigram (AND → OR) | Fallback when Porter finds nothing. Matches substrings and partial identifiers |
| 3     | Fuzzy correction   | Last resort. Levenshtein distance against vocabulary table, then re-search     |

Each layer tries AND mode first (all terms must match), then falls back to OR
mode (any term matches). This cascading strategy ensures high precision when
possible while maintaining recall for difficult queries.

**Chunking strategies:**

| Content type      | Strategy                                                                                                                                | Max chunk size |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| Markdown          | Split by headings (H1–H4), keep code blocks intact, maintain heading hierarchy as title. Oversized chunks split at paragraph boundaries | 4 KB           |
| Plain text / logs | Blank-line splitting for naturally-sectioned output; fixed line groups (20 lines) with overlap for unstructured output                  | 4 KB           |
| JSON              | Walk object tree, use key paths as titles (analogous to heading hierarchy). Arrays batch by size                                        | 4 KB           |

The 4 KB chunk cap matches the reference implementation's `MAX_CHUNK_BYTES`
constant. Oversized chunks are split at paragraph boundaries to avoid cutting
mid-sentence.

**Elixir implementation — exqlite:**

The knowledge base uses [`exqlite`](https://github.com/elixir-sqlite/exqlite),
a direct SQLite3 NIF driver for Elixir. No Ecto — raw SQL via
`Exqlite.Sqlite3`, which matches Opal's no-Ecto architecture and gives full
control over FTS5 virtual tables, `bm25()` scoring, and `highlight()`.

**Dependency:**

```elixir
# mix.exs
{:exqlite, "~> 0.27"}
```

**FTS5 compile flag:** SQLite's bundled build does not enable FTS5 by default.
Opal must compile exqlite with the flag enabled:

```elixir
# config/config.exs
config :exqlite,
  force_build: true,
  make_env: %{"EXQLITE_SYSTEM_CFLAGS" => "-DSQLITE_ENABLE_FTS5=1"}
```

Alternatively, set `EXQLITE_USE_SYSTEM=1` at build time on systems where the
OS-provided `libsqlite3` already includes FTS5 (most Linux distros, Homebrew on
macOS). The `force_build` approach is preferred for reproducible builds and CI.

**GenServer wrapper:** `Opal.Agent.KnowledgeBase` should be a GenServer that
owns the SQLite connection and caches prepared statements in its state. SQLite
connections are not safe to share across processes — the GenServer serializes
access. This mirrors how `Opal.Session.Server` owns session state.

```elixir
defmodule Opal.Agent.KnowledgeBase do
  use GenServer

  alias Exqlite.Sqlite3

  defstruct [:db, :session_id, :stmts]

  # ── Lifecycle ──

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  @impl true
  def init(session_id) do
    path = Path.join([sessions_dir(), session_id, "kb.sqlite3"])
    File.mkdir_p!(Path.dirname(path))

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous = NORMAL")
    init_schema(db)
    stmts = prepare_statements(db)

    {:ok, %__MODULE__{db: db, session_id: session_id, stmts: stmts}}
  end

  # ── Schema ──

  defp init_schema(db) do
    Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS sources (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      label TEXT NOT NULL,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      code_chunk_count INTEGER NOT NULL DEFAULT 0,
      indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
    """)

    Sqlite3.execute(db, """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
      title,
      content,
      source_id UNINDEXED,
      content_type UNINDEXED,
      tokenize='porter unicode61'
    )
    """)

    Sqlite3.execute(db, """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_trigram USING fts5(
      title,
      content,
      source_id UNINDEXED,
      content_type UNINDEXED,
      tokenize='trigram'
    )
    """)

    Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS vocabulary (
      word TEXT PRIMARY KEY
    )
    """)
  end

  # ── Prepared statements (cached in state for hot paths) ──

  defp prepare_statements(db) do
    {:ok, search_porter} = Sqlite3.prepare(db, """
    SELECT c.title, c.content, c.content_type, s.label,
           bm25(chunks, 2.0, 1.0) AS rank,
           highlight(chunks, 1, char(2), char(3)) AS highlighted
    FROM chunks c
    JOIN sources s ON s.id = c.source_id
    WHERE chunks MATCH ?1
    ORDER BY rank
    LIMIT ?2
    """)

    {:ok, search_trigram} = Sqlite3.prepare(db, """
    SELECT c.title, c.content, c.content_type, s.label,
           bm25(chunks_trigram, 2.0, 1.0) AS rank,
           highlight(chunks_trigram, 1, char(2), char(3)) AS highlighted
    FROM chunks_trigram c
    JOIN sources s ON s.id = c.source_id
    WHERE chunks_trigram MATCH ?1
    ORDER BY rank
    LIMIT ?2
    """)

    {:ok, insert_chunk} = Sqlite3.prepare(db, """
    INSERT INTO chunks (title, content, source_id, content_type)
    VALUES (?1, ?2, ?3, ?4)
    """)

    %{
      search_porter: search_porter,
      search_trigram: search_trigram,
      insert_chunk: insert_chunk
    }
  end

  # ── Search (3-layer fallback) ──

  def search(pid, query, opts \\ []) do
    GenServer.call(pid, {:search, query, opts})
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 5)
    sanitized = sanitize_query(query)

    # Layer 1: Porter (AND then OR)
    results = execute_search(state.db, state.stmts.search_porter, sanitized, limit)

    results =
      if results == [] do
        or_query = sanitize_query(query, :or)
        execute_search(state.db, state.stmts.search_porter, or_query, limit)
      else
        results
      end

    # Layer 2: Trigram fallback
    results =
      if results == [] do
        execute_search(state.db, state.stmts.search_trigram, sanitized, limit)
      else
        results
      end

    {:reply, {:ok, results}, state}
  end

  defp execute_search(db, stmt, query, limit) do
    :ok = Sqlite3.bind(db, stmt, [query, limit])
    collect_rows(db, stmt, [])
  end

  defp collect_rows(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> collect_rows(db, stmt, [row_to_map(row) | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp sanitize_query(query, mode \\ :and) do
    joiner = if mode == :or, do: " OR ", else: " "

    query
    |> String.replace(~r/['"()\[\]*:^~]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in ~w[AND OR NOT NEAR]))
    |> Enum.map(&"\"#{&1}\"")
    |> Enum.join(joiner)
  end
end
```

**Key API patterns:**

| Operation | exqlite call | Notes |
|-----------|-------------|-------|
| Open DB | `Sqlite3.open(path)` | Returns `{:ok, db}` reference |
| Set pragmas | `Sqlite3.execute(db, "PRAGMA ...")` | Must be first calls after open |
| Create FTS5 table | `Sqlite3.execute(db, "CREATE VIRTUAL TABLE ...")` | Requires FTS5 compile flag |
| Prepare statement | `Sqlite3.prepare(db, sql)` | Cache in GenServer state |
| Bind + execute | `Sqlite3.bind(db, stmt, params)` then `Sqlite3.step(db, stmt)` | Step returns `{:row, list}` or `:done` |
| BM25 ranking | `bm25(table, title_weight, content_weight)` in SQL | Returns negative float (lower = better) |
| Highlighted excerpts | `highlight(table, col_idx, open_mark, close_mark)` in SQL | Use `char(2)`/`char(3)` as delimiters |
| Close DB | `Sqlite3.close(db)` | In GenServer `terminate/2` |

**Process lifecycle:** The KnowledgeBase GenServer is started under the
session's `DynamicSupervisor` (same as sub-agents). It is started lazily on
first index operation and terminated with the session. The `kb.sqlite3` file
persists on disk for the session's lifetime.

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
        query: %{type: "string", description: "Search query (supports stemming, substrings, and fuzzy matching)."},
        limit: %{type: "integer", description: "Max results to return.", default: 5},
        source: %{type: "string", description: "Filter results to a specific source label (substring match)."}
      },
      required: ["query"]
    }
  end

  def smoosh, do: :skip

  def execute(%{"query" => query} = args, context) do
    limit = Map.get(args, "limit", 5)
    source = Map.get(args, "source")
    # Uses searchWithFallback: Porter → Trigram → Fuzzy
    # ...
  end
end
```

**Tool guideline injection:** When smoosh is active and the knowledge base
is non-empty, `SystemPrompt.build_guidelines/2` appends a note:

```
<smoosh>
Some tool outputs were compressed to save context. The full data is indexed
in the session knowledge base. Use `kb_search` to retrieve specific details
when the compressed summary is insufficient.
</smoosh>
```

The `kb_search` tool is only included in the active tool set when the knowledge
base has been written to (lazy activation).

---

## Configuration

### Feature Flag — same pattern as sub_agents, skills, debug

Smoosh follows the existing `Config.Features` pattern exactly. Adding it means
one new key in the struct + one `merge_subsystem` call:

```elixir
# In Opal.Config.Features — the ONLY change to this file:
defstruct sub_agents: %{enabled: true},
          context: %{enabled: true, filenames: ["AGENTS.md", "OPAL.md"]},
          skills: %{enabled: true, extra_dirs: []},
          debug: %{enabled: false},
          smoosh: %{                              # ← new
            enabled: false,                       # off by default during rollout
            threshold_bytes: 4_096,               # compress outputs > 4 KB
            hard_limit_bytes: 102_400,            # index-only outputs > 100 KB
            compressor_model: nil,                # nil = auto-select cheapest
            index_enabled: true                   # enable knowledge base indexing
          }
```

**Tool gating** follows the existing pattern in `ToolRunner.active_tools/1`:

```elixir
# In ToolRunner — gate kb_search the same way debug_state and use_skill are gated:
{not config.features.smoosh.enabled, &(&1 == Opal.Tool.KbSearch)}
```

Hot-swappable via `Agent.configure/2` mid-session — same pattern as existing
feature flags.

### Optional Dependency — exqlite

The `exqlite` NIF is only needed when the knowledge base is active. It is
declared as an **optional dependency**:

```elixir
# mix.exs
{:exqlite, "~> 0.27", optional: true}
```

The `KnowledgeBase` module guards on availability at runtime:

```elixir
defmodule Opal.Agent.Smoosh.KnowledgeBase do
  @exqlite_available Code.ensure_loaded?(Exqlite.Sqlite3)

  def available?, do: @exqlite_available

  def open(session_id) do
    if @exqlite_available do
      # ... open DB ...
    else
      Logger.warning("Smoosh KB requires exqlite — install it to enable indexing")
      {:error, :exqlite_not_available}
    end
  end
end
```

When `exqlite` is not installed, Smoosh compression still works (sub-agent
path), but the `:index_only` path gracefully degrades to `:compress`. The
knowledge base and `kb_search` tool are simply not available.

---

## Integration Points

### ToolRunner — single hook, not inline logic

The integration is a **single function call** in `collect_result/4`, after the
tool's result is received. The existing `execute_tool/3` is **not modified** —
Smoosh hooks into the result collection path instead:

```elixir
# In Opal.Agent.ToolRunner — the ONLY change to this file:
def collect_result(ref, tc, {:ok, output} = result, %State{} = state) do
  tool_mod = resolve_tool(tc["name"], state)
  {result, state} = Opal.Agent.Smoosh.maybe_compress(tool_mod, result, state)
  # ... existing result collection logic continues unchanged ...
end
```

`Smoosh.maybe_compress/3` is the **single entry point**. When Smoosh is
disabled (the default), it returns `{result, state}` unchanged — a no-op.
When enabled, it classifies (consulting `tool_mod.smoosh/0`), compresses,
and/or indexes:

```elixir
defmodule Opal.Agent.Smoosh do
  def maybe_compress(_tool_mod, result, %{config: %{features: %{smoosh: %{enabled: false}}}} = state) do
    {result, state}  # no-op when disabled
  end

  def maybe_compress(tool_mod, {:ok, raw_output} = result, state) do
    case classify(tool_mod, raw_output, state) do
      :pass_through ->
        {result, state}

      :compress ->
        tool_name = tool_mod.name()
        {:ok, compressed} = Compressor.compress(raw_output, tool_name, state)
        state = maybe_index(raw_output, tool_name, state)
        emit_event(state, tool_name, raw_output, compressed)
        {{:ok, compressed}, state}

      :index_only ->
        tool_name = tool_mod.name()
        state = index(raw_output, tool_name, state)
        msg = "[Output indexed to knowledge base — #{byte_size(raw_output)} bytes. " <>
              "Use kb_search to query.]"
        emit_event(state, tool_name, raw_output, msg)
        {{:ok, msg}, state}
    end
  end

  def maybe_compress(_tool_mod, result, state), do: {result, state}

  # Consult the tool's optional smoosh/0 callback
  defp tool_policy(tool_mod) do
    if function_exported?(tool_mod, :smoosh, 0),
      do: tool_mod.smoosh(),
      else: :auto
  end
end
```

**Why `collect_result` not `execute_tool`:** The existing `execute_tool/3` is a
clean, focused function (call tool → rescue errors). Smoosh is a post-processing
concern. Hooking at the collection point keeps `execute_tool` unchanged and
makes the hook trivially removable (delete one line in `collect_result`).

### SystemPrompt — conditional guideline, self-contained

Smoosh injects its guideline via the existing rule table pattern in
`build_guidelines/2`. This is **one tuple** added to the rule list:

```elixir
# In Opal.Agent.SystemPrompt.guidelines/2 — ONE new rule:
{smoosh_active?(state) and kb_has_entries?(state),
 "Some tool outputs were compressed to save context. " <>
 "Use `kb_search` to retrieve specific details when the summary is insufficient."}
```

The helper `smoosh_active?/1` checks `state.config.features.smoosh.enabled`.
When Smoosh is removed, this one tuple is deleted.

### Compaction — overlap analysis

Smoosh and Compaction both reduce context usage via LLM summarization, which
raises the question of whether they duplicate effort. After reviewing both
implementations, they are **separate-purpose systems** that share one primitive.

**What differs (almost everything):**

| Dimension | Compaction | Smoosh |
|-----------|-----------|--------|
| **When** | Between turns (80% threshold or provider rejection) | At tool result collection, before result enters context |
| **What** | Old conversation messages (user + assistant + tool results) | Individual tool outputs (raw strings) |
| **Why** | Recover space from accumulated history | Prevent waste at point of emission |
| **Mechanism** | Direct `provider.stream()` call | Sub-agent (isolates raw output from parent context) |
| **Model** | Same model as the agent | Cheapest available (haiku-class) |
| **Output** | Single summary message replacing N messages | Compressed string replacing one tool result |
| **State change** | Mutates session path (`replace_path_segment`) | Returns modified result to `collect_result` |
| **Unique features** | Cut-point algorithm, split-turn detection, iterative summary merging, overflow recovery | FTS5 knowledge base, 3-layer search, per-tool policy |

**Why Smoosh uses a sub-agent but Compaction doesn't:** Compaction summarizes
messages that are *already in context* — the model has already seen them, so
there's no isolation benefit. Smoosh compresses raw output that has *never
entered the parent context* — using a sub-agent keeps 56 KB of Playwright HTML
out of the parent's window entirely. This is the core design difference and it
is intentional.

**What they share — `summarize_with_provider`:**

Compaction already has a clean `summarize_with_provider/3` function that calls
`provider.stream()` with a summarizer system prompt. The Smoosh Compressor
needs the same primitive (call a model with content → get summary back), just
wrapped in a sub-agent for isolation. Rather than duplicating this:

```elixir
# Shared primitive — already exists in Compaction:
Opal.Session.Compaction.summarize_with_provider(provider, model, prompt)

# Smoosh Compressor uses it inside the sub-agent's execution:
defmodule Opal.Agent.Smoosh.Compressor do
  def compress(raw_output, tool_name, state) do
    # Spawn sub-agent whose single turn calls the same summarize function
    Opal.Agent.Spawner.spawn_from_state(state, %{
      system_prompt: @compressor_prompt,
      model: pick_cheap_model(state),
      tools: [],  # no tools — pure summarization
      prompt: "Compress the following #{tool_name} output:\n\n#{raw_output}"
    })
  end
end
```

The sub-agent internally calls the provider via the normal agent loop, which
means the actual LLM call path is shared — no new provider integration needed.

**What they also share — `Opal.Agent.Token`:**

Both need to estimate token counts. Compaction already uses `Token.estimate/1`
(4 chars/token heuristic). Smoosh's `classify/3` can use `Token.estimate/1` for
its threshold comparison instead of raw `byte_size/1`, giving more accurate
classification that accounts for actual tokenization.

**Net result:** No code duplication needed. Smoosh reuses the agent loop for
its sub-agent LLM calls and `Token` for size estimation. No changes to
Compaction are required.

### Events

New events for observability:

```elixir
{:smoosh_compress, %{tool: name, raw_bytes: n, compressed_bytes: m}}
{:smoosh_index, %{tool: name, bytes: n, chunks: c}}
```

These are broadcast via `Opal.Agent.Emitter` and can be displayed in the CLI
status bar (e.g. "⚡ 56 KB → 299 B").

### Sub-Agents

Sub-agents spawned by `Opal.Tool.SubAgent` inherit the parent's smoosh
config. Each sub-agent gets its own knowledge base instance (scoped to its
session ID). This means sub-agent tool outputs are also compressed, preventing
the common pattern of sub-agents burning through context on data-heavy tasks.

---

## CLI Surface

### Status indicator

When smoosh is active, the CLI displays a compression indicator in the
tool execution output:

```
⚡ shell: 56.2 KB → 299 B (99.5% saved)
```

### `/smoosh` command

A new slash command to manage smoosh:

| Command                  | Effect                                   |
| ------------------------ | ---------------------------------------- |
| `/smoosh on`             | Enable smoosh for this session           |
| `/smoosh off`            | Disable smoosh                           |
| `/smoosh status`         | Show stats: total saved, KB entries, etc |
| `/smoosh search <query>` | Shorthand for `kb_search` tool           |

---

## Risks & Mitigations

| Risk                                   | Mitigation                                                                              |
| -------------------------------------- | --------------------------------------------------------------------------------------- |
| Compressor loses critical detail       | Conservative defaults: skip file ops, low threshold                                     |
| Compressor adds latency to tool calls  | Parallel execution; use fast model; only for large outputs                              |
| LLM hallucinates in compression        | System prompt forbids fabrication; structured output                                    |
| Knowledge base grows unbounded         | Per-session lifecycle; cleaned up with session                                          |
| Extra token cost from compressor calls | Net positive: compress 56 KB → 300 B saves far more tokens than the compressor consumes |
| Tool authors forget to set `smoosh`    | `:auto` default uses size heuristic — works without annotation                          |

---

## Module Boundary

All Smoosh code lives in a single namespace. This is the complete list of files
that would be added:

```
lib/opal/agent/smoosh/
├── smoosh.ex              # classify/3, maybe_compress/3
├── compressor.ex          # sub-agent compression
└── knowledge_base.ex      # FTS5 store (optional, requires exqlite)

lib/opal/tool/
└── kb_search.ex           # kb_search tool
```

Files **outside** the Smoosh namespace that are modified:

| File | Change | To remove |
|------|--------|-----------|
| `lib/opal/tool.ex` | Add `@callback smoosh()` + `@optional_callbacks` | Delete 2 lines |
| `lib/opal/tool/*.ex` | Add `def smoosh, do: :skip` to tools that need it | Delete 1 line per tool |
| `lib/opal/agent/tool_runner.ex` | One call to `Smoosh.maybe_compress/3` in `collect_result/4` | Delete 1 line |
| `lib/opal/agent/system_prompt.ex` | One rule tuple in `guidelines/2` | Delete 1 tuple |
| `lib/opal/config/features.ex` | `smoosh:` key in struct + `merge_subsystem` call | Delete 2 lines |

The `smoosh/0` callback is optional (`@optional_callbacks`), so tools that
don't declare it simply get `:auto` behaviour. Only tools that want `:skip`
need the one-liner. On removal, those one-liners become dead code that the
compiler warns about — easy to find and delete.

---

## Removal Recipe

If Smoosh doesn't work out, here is the complete removal procedure:

1. `rm -rf lib/opal/agent/smoosh/` — delete the namespace
2. `rm lib/opal/tool/kb_search.ex` — delete the search tool
3. In `lib/opal/tool.ex`: delete `@callback smoosh()` + `@optional_callbacks` (2 lines)
4. In each tool that has `def smoosh, do: :skip`: delete the function (grep for it)
5. In `tool_runner.ex`: delete the `Smoosh.maybe_compress` call (1 line)
6. In `system_prompt.ex`: delete the smoosh guideline tuple (1 tuple)
7. In `config/features.ex`: delete `smoosh:` from struct + merge call (2 lines)
8. In `mix.exs`: delete `{:exqlite, ...}` dep (1 line)
9. In `config/config.exs`: delete `:exqlite` config block if present (3 lines)

Step 4 is the only multi-file grep, but the compiler will flag all orphaned
`smoosh/0` functions as "this clause cannot match" once the callback is removed.

---

## Implementation Sequence

1. **`Opal.Tool` behaviour** — add optional `smoosh/0` callback (2 lines).
2. **`Opal.Agent.Smoosh`** — classification logic, `maybe_compress/3` entry point.
3. **`Config.Features`** — add `smoosh:` key (2 lines).
4. **`Opal.Agent.Smoosh.Compressor`** — sub-agent-based compression.
5. **`ToolRunner` hook** — one call to `maybe_compress/3` in `collect_result/4`.
6. **Tool annotations** — add `def smoosh, do: :skip` to file/code tools.
7. **Events & CLI** — compression events, status indicator.
8. **`Opal.Agent.Smoosh.KnowledgeBase`** — SQLite FTS5 dual-table store (Porter +
   trigram), BM25 ranking, chunking (markdown / plain-text / JSON), vocabulary
   extraction, dedup-on-reindex, 3-layer fallback search. Requires `exqlite`.
9. **`Opal.Tool.KbSearch`** — search tool with source filtering, lazy activation,
   system prompt guideline.
10. **`/smoosh` CLI command** — slash command for manual control.

Steps 1–7 form a useful MVP without the knowledge base. Steps 8–10 add the
overflow path for very large outputs.

---

## References

- [Context Mode](https://mksg.lu/blog/context-mode) — Mert Köseoğlu. Original
  concept and benchmarks. MCP-based implementation for Claude Code that
  compresses tool outputs via sandboxed execution and FTS5 knowledge base.
  Our Knowledge Base design (dual FTS5 tables, BM25 weights, 3-layer fallback
  search, chunking strategies) is adapted from this implementation.
  Source: [github.com/mksglu/claude-context-mode](https://github.com/mksglu/claude-context-mode).
- [exqlite](https://github.com/elixir-sqlite/exqlite) — Direct SQLite3 NIF
  driver for Elixir. Provides `Exqlite.Sqlite3` low-level API used by the
  Knowledge Base. Requires `SQLITE_ENABLE_FTS5=1` compile flag for FTS5 support.
- [SQLite FTS5 Extension](https://sqlite.org/fts5.html) — Official docs for
  FTS5 virtual tables, `bm25()` ranking, `highlight()`, and tokenizer options
  (`porter`, `unicode61`, `trigram`).
- [Compaction](compaction.md) — Opal's existing context recovery system.
- [Sub-Agent](tools/sub-agent.md) — Spawner architecture used by the compressor.
- [System Prompt](system-prompt.md) — Dynamic prompt assembly for guideline injection.
