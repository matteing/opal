# Smoosh!

> **Status**: Implemented
> **Scope**: `Opal.Agent.Smoosh.*`, `Opal.Tool.KbSearch`, `Opal.Agent.ToolRunner`

## The Algorithm at a Glance

Smoosh is a tool output compressor that keeps the agent's context window lean.
Here's what happens every time a tool returns output, and the jargon involved:

### Step 1: Should we compress this?

Each tool declares a policy (`:skip`, `:always`, or `:auto`). File reads and
grep are `:skip` — the agent needs exact text. Shell output is `:auto`, meaning
Smoosh decides by size: under 4 KB passes through, 4–100 KB gets compressed,
over 100 KB gets indexed.

### Step 2a: Compression (medium outputs)

A child agent with no tools reads the raw output and writes a structured
summary. The raw text never enters the parent agent's context — only the
summary does. Think of it as having an assistant read a 50-page report and hand
you a one-page brief.

### Step 2b: Indexing (huge outputs)

The raw text is split into small chunks (~4 KB each) and stored in a search
database. The agent gets a short "indexed, use kb_search to query" message
instead of the full output.

The search database uses **FTS5** and **BM25** — here's what those mean:

- **FTS5** (Full-Text Search 5) is a SQLite extension that builds an inverted
  index over text. Instead of scanning every document for your search term, it
  maintains a lookup table: word → list of documents containing it. Like the
  index at the back of a textbook, but automatic.

- **BM25** (Best Match 25) is a ranking formula. When your search matches
  multiple chunks, BM25 scores each one by: how rare the search terms are (rare
  terms = more relevant), how many times they appear, and how long the chunk is
  (shorter chunks with your term score higher). It's the same algorithm behind
  search engines. We weight title matches 2× over body matches.

### Step 3: Three-layer search fallback

When the agent searches with `kb_search`, the query cascades through three
layers until results are found:

| Layer | What it does | Example |
| ----- | ------------ | ------- |
| **Porter stemming** | Reduces words to roots. Matches inflections. | "running" matches "run", "runner", "runs" |
| **Trigram** | Matches any 3-character substring. Finds partial identifiers. | "auth" matches "authentication", "OAuth" |
| **Fuzzy correction** | Fixes typos using Levenshtein distance against a vocabulary table. | "authenticaton" corrects to "authentication" |

Each layer tries AND mode first (all terms must match), then OR mode (any term
matches). This gives 6 attempts total before returning empty.

**Levenshtein distance** counts the minimum single-character edits (insert,
delete, substitute) to transform one word into another. "cat" → "bat" is
distance 1. We allow 1 edit for short words (≤4 chars), 2 for medium (≤12),
3 for long.

**Stopwords** — common words like "the", "and", "with" — are filtered out of
the vocabulary table so fuzzy correction doesn't waste time comparing your
technical query against noise.

### The net effect

A 56 KB Playwright snapshot becomes a 300-byte summary. Twenty GitHub issues
(59 KB) become a 1 KB digest. The full data stays searchable via `kb_search`.
Context usage drops 90–99%, extending sessions from ~30 minutes to ~3 hours.

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

**Model selection:** The compressor automatically downshifts to the fastest model
in the same provider family — e.g. if the parent runs `claude-sonnet-4`, the
compressor uses `claude-haiku-4.5`. This keeps compression cheap and fast. You
can override this with the `compressor_model` config key.

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

**Search — 3-layer fallback (6 attempts):**

| Layer | Strategy | Mode | When used |
| ----- | -------- | ---- | --------- |
| 1a    | Porter   | AND  | Default — stemmed matching ("running" → "run") |
| 1b    | Porter   | OR   | Fallback when AND finds nothing |
| 2a    | Trigram  | AND  | Substring/partial identifier matching |
| 2b    | Trigram  | OR   | Broader substring match |
| 3a–3d | Fuzzy    | AND/OR | Levenshtein-correct misspelled terms, re-search Porter then Trigram |

Source filtering uses SQL-level `LIKE` via dedicated prepared statements
(`search_porter_filtered`, `search_trigram_filtered`) rather than post-query
filtering, for efficiency on large knowledge bases.

**Stopwords:** Common English words are excluded from vocabulary extraction,
keeping the fuzzy correction vocabulary clean and fast.

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
# Enable smoosh (enabled by default):
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

### Prepared Statements

The knowledge base caches 8 prepared statements at init:

| Statement | Purpose |
| --------- | ------- |
| `search_porter` | BM25 search on Porter-stemmed index |
| `search_porter_filtered` | Same, with `AND s.label LIKE ?` source filter |
| `search_trigram` | BM25 search on trigram index |
| `search_trigram_filtered` | Same, with source filter |
| `fuzzy_vocab` | Vocabulary lookup by word length range (for Levenshtein) |
| `insert_source` | Insert source metadata |
| `insert_porter` | Insert chunk into Porter FTS5 table |
| `insert_trigram` | Insert chunk into trigram FTS5 table |

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

Smoosh shows progress in two ways:

1. **ThinkingIndicator** — while compression or indexing is active, the input bar
   shows "Smooshing shell output…" or "Indexing shell output…".
2. **Timeline entries** — once complete, a status entry appears:

```
⊜ Compressed shell output (45.2 KB → 2.1 KB, 95% reduction)
⊜ Indexed shell output (120.5 KB) into knowledge base
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
| `opal/lib/opal/agent/smoosh/knowledge_base.ex` | New | SQLite FTS5 GenServer + 3-layer search + fuzzy correction |
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
| `cli/src/sdk/session.ts` | Modified | `smoosh: true` default |

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
- [context-mode SKILL.md](https://github.com/mksglu/context-mode/blob/main/skills/context-mode/SKILL.md) — skill definition with intent-driven search, sandboxed execution, and configuration details.
- [context-mode source](https://github.com/mksglu/context-mode) — TypeScript implementation: `store.ts` (FTS5 schema), `executor.ts` (sandboxed eval), `truncate.ts` (smart truncation).
- [BM25 (Okapi)](https://en.wikipedia.org/wiki/Okapi_BM25) — the ranking function used by FTS5. Balances term frequency, inverse document frequency, and document length normalization.
- [Levenshtein distance](https://en.wikipedia.org/wiki/Levenshtein_distance) — edit distance metric used in the fuzzy correction layer.
- [Porter stemming](https://tartarus.org/martin/PorterStemmer/) — the stemming algorithm used by FTS5's built-in Porter tokenizer to reduce words to roots.
- [exqlite](https://github.com/elixir-sqlite/exqlite) — SQLite3 NIF for Elixir.
- [SQLite FTS5](https://www.sqlite.org/fts5.html) — full-text search extension.
- [Compaction](compaction.md) — complementary system for summarizing old messages.
