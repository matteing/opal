defmodule Opal.Agent.Smoosh.KnowledgeBase do
  @moduledoc """
  Per-session full-text search index backed by SQLite FTS5.

  Dual-table design: Porter-stemmed index for natural language queries,
  trigram index for substring/partial matches. BM25 ranking with
  title-boosted weights. Three-layer fallback search: Porter → Trigram →
  Fuzzy (Levenshtein correction against vocabulary).

  ## Process lifecycle

  Started lazily under the session's `DynamicSupervisor` on first index
  operation. Registered in `Opal.Registry` as `{:knowledge_base, session_id}`.
  Terminated when the session ends.

  ## Storage

  SQLite database at `<sessions_dir>/<session_id>/kb.sqlite3`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Opal.Agent.Smoosh.Chunker

  require Logger

  @stopwords MapSet.new(~w[
    the and for are but not you all can had her was one our out has his how
    its may new now old see way who did get got let say she too use will with
    this that from they been have many some them than each make like just over
    such take into year your good could would about which their there other
    after should through also more most only very when what then these those
    being does done both same still while where here were much
    update updates updated deps dev tests test add added fix fixed run
    running using
  ])

  defstruct [:db, :session_id, :stmts, :source_count]

  @type t :: %__MODULE__{
          db: reference(),
          session_id: String.t(),
          stmts: map(),
          source_count: non_neg_integer()
        }

  # ── Public API ──

  @doc "Start the KnowledgeBase under the given supervisor."
  @spec start_link(String.t(), String.t()) :: GenServer.on_start()
  def start_link(session_id, sessions_dir) do
    GenServer.start_link(__MODULE__, {session_id, sessions_dir},
      name: {:via, Registry, {Opal.Registry, {:knowledge_base, session_id}}}
    )
  end

  @doc "Look up a running KnowledgeBase by session ID."
  @spec lookup(String.t()) :: {:ok, pid()} | :not_started
  def lookup(session_id) do
    case Registry.lookup(Opal.Registry, {:knowledge_base, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_started
    end
  end

  @doc """
  Ensure a KnowledgeBase is running for the session. Starts one if needed.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec ensure_started(String.t(), pid() | atom(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(session_id, supervisor, sessions_dir) do
    case lookup(session_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_started ->
        spec = {__MODULE__, {session_id, sessions_dir}}

        case DynamicSupervisor.start_child(supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Index content into the knowledge base. Deduplicates by source label."
  @spec index(pid(), String.t(), String.t(), keyword()) ::
          {:ok, %{source_id: integer(), chunks: non_neg_integer()}}
          | {:error, term()}
  def index(pid, source_label, content, opts \\ []) do
    GenServer.call(pid, {:index, source_label, content, opts}, 30_000)
  end

  @doc "Search with 3-layer fallback: Porter → Trigram → Fuzzy correction."
  @spec search(pid(), String.t(), keyword()) :: {:ok, [map()]}
  def search(pid, query, opts \\ []) do
    GenServer.call(pid, {:search, query, opts}, 10_000)
  end

  @doc "List all indexed sources."
  @spec list_sources(pid()) :: [map()]
  def list_sources(pid) do
    GenServer.call(pid, :list_sources)
  end

  @doc "Returns true if the knowledge base has indexed content."
  @spec has_content?(pid()) :: boolean()
  def has_content?(pid) do
    GenServer.call(pid, :has_content?)
  end

  # ── GenServer callbacks ──

  @impl true
  def init({session_id, sessions_dir}) do
    dir = Path.join(sessions_dir, session_id)
    File.mkdir_p!(dir)
    path = Path.join(dir, "kb.sqlite3")

    case Sqlite3.open(path) do
      {:ok, db} ->
        :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
        :ok = Sqlite3.execute(db, "PRAGMA synchronous = NORMAL")
        init_schema(db)
        stmts = prepare_statements(db)
        source_count = count_sources(db)

        Logger.debug("[smoosh-kb] opened #{path} (#{source_count} sources)")

        {:ok,
         %__MODULE__{
           db: db,
           session_id: session_id,
           stmts: stmts,
           source_count: source_count
         }}

      {:error, reason} ->
        {:stop, {:sqlite_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:index, source_label, content, opts}, _from, state) do
    case do_index(state, source_label, content, opts) do
      {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:search, query, opts}, _from, state) do
    results = do_search(state, query, opts)
    {:reply, {:ok, results}, state}
  end

  def handle_call(:list_sources, _from, state) do
    sources = do_list_sources(state.db)
    {:reply, sources, state}
  end

  def handle_call(:has_content?, _from, state) do
    {:reply, state.source_count > 0, state}
  end

  @impl true
  def terminate(_reason, %{db: db} = _state) do
    Sqlite3.close(db)
    :ok
  end

  # ── Indexing ──

  defp do_index(state, source_label, content, opts) do
    %{db: db, stmts: stmts} = state
    chunks = Chunker.chunk(content, Keyword.merge([label: source_label], opts))

    :ok = Sqlite3.execute(db, "BEGIN TRANSACTION")

    try do
      # Dedup: remove old chunks for same source
      delete_source_chunks(db, source_label)

      # Insert source
      :ok = Sqlite3.bind(stmts.insert_source, [source_label, length(chunks), count_code(chunks)])
      :done = Sqlite3.step(db, stmts.insert_source)
      :ok = Sqlite3.reset(stmts.insert_source)
      source_id = last_insert_rowid(db)

      # Insert chunks into both FTS tables
      for chunk <- chunks do
        ct = Atom.to_string(chunk.content_type)
        insert_chunk(stmts, db, chunk.title, chunk.content, source_id, ct)
      end

      # Extract vocabulary
      extract_vocabulary(db, chunks)

      :ok = Sqlite3.execute(db, "COMMIT")

      result = %{source_id: source_id, chunks: length(chunks)}
      {:ok, result, %{state | source_count: state.source_count + 1}}
    rescue
      e ->
        Sqlite3.execute(db, "ROLLBACK")
        {:error, Exception.message(e)}
    end
  end

  defp delete_source_chunks(db, label) do
    # Find source IDs for this label
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT id FROM sources WHERE label = ?1")
    :ok = Sqlite3.bind(stmt, [label])
    source_ids = collect_column(db, stmt)
    Sqlite3.release(db, stmt)

    for sid <- source_ids do
      {:ok, d1} = Sqlite3.prepare(db, "DELETE FROM chunks WHERE source_id = ?1")
      :ok = Sqlite3.bind(d1, [sid])
      :done = Sqlite3.step(db, d1)
      Sqlite3.release(db, d1)

      {:ok, d2} = Sqlite3.prepare(db, "DELETE FROM chunks_trigram WHERE source_id = ?1")
      :ok = Sqlite3.bind(d2, [sid])
      :done = Sqlite3.step(db, d2)
      Sqlite3.release(db, d2)
    end

    {:ok, del} = Sqlite3.prepare(db, "DELETE FROM sources WHERE label = ?1")
    :ok = Sqlite3.bind(del, [label])
    :done = Sqlite3.step(db, del)
    Sqlite3.release(db, del)
  end

  defp insert_chunk(stmts, db, title, content, source_id, content_type) do
    :ok = Sqlite3.bind(stmts.insert_porter, [title, content, source_id, content_type])
    :done = Sqlite3.step(db, stmts.insert_porter)
    :ok = Sqlite3.reset(stmts.insert_porter)

    :ok = Sqlite3.bind(stmts.insert_trigram, [title, content, source_id, content_type])
    :done = Sqlite3.step(db, stmts.insert_trigram)
    :ok = Sqlite3.reset(stmts.insert_trigram)
  end

  defp extract_vocabulary(db, chunks) do
    words =
      chunks
      |> Enum.flat_map(fn %{content: c, title: t} ->
        (c <> " " <> t)
        |> String.downcase()
        |> String.split(~r/[^a-z0-9_]+/, trim: true)
        |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
      end)
      |> Enum.uniq()

    {:ok, ins} = Sqlite3.prepare(db, "INSERT OR IGNORE INTO vocabulary (word) VALUES (?1)")

    for word <- words do
      :ok = Sqlite3.bind(ins, [word])
      Sqlite3.step(db, ins)
      :ok = Sqlite3.reset(ins)
    end

    Sqlite3.release(db, ins)
  end

  # ── Search ──

  defp do_search(state, query, opts) do
    limit = Keyword.get(opts, :limit, 5)
    source_filter = Keyword.get(opts, :source, nil)
    sanitized_and = sanitize_query(query, :and)
    sanitized_or = sanitize_query(query, :or)

    porter = pick_search_stmt(state.stmts, :porter, source_filter)
    trigram = pick_search_stmt(state.stmts, :trigram, source_filter)

    # Layer 1: Porter AND → OR
    results = execute_search(state.db, porter, sanitized_and, limit, source_filter)

    results =
      if results == [] do
        execute_search(state.db, porter, sanitized_or, limit, source_filter)
      else
        results
      end

    # Layer 2: Trigram AND → OR
    results =
      if results == [] do
        execute_search(state.db, trigram, sanitized_and, limit, source_filter)
      else
        results
      end

    results =
      if results == [] do
        execute_search(state.db, trigram, sanitized_or, limit, source_filter)
      else
        results
      end

    # Layer 3: Fuzzy correction → re-search Porter AND → OR, Trigram AND → OR
    if results == [] do
      case fuzzy_correct_query(state, query) do
        nil ->
          []

        corrected ->
          corrected_and = sanitize_query(corrected, :and)
          corrected_or = sanitize_query(corrected, :or)

          fuzzy_results = execute_search(state.db, porter, corrected_and, limit, source_filter)

          fuzzy_results =
            if fuzzy_results == [],
              do: execute_search(state.db, porter, corrected_or, limit, source_filter),
              else: fuzzy_results

          fuzzy_results =
            if fuzzy_results == [],
              do: execute_search(state.db, trigram, corrected_and, limit, source_filter),
              else: fuzzy_results

          if fuzzy_results == [],
            do: execute_search(state.db, trigram, corrected_or, limit, source_filter),
            else: fuzzy_results
      end
    else
      results
    end
  end

  defp pick_search_stmt(stmts, :porter, nil), do: stmts.search_porter
  defp pick_search_stmt(stmts, :porter, _), do: stmts.search_porter_filtered
  defp pick_search_stmt(stmts, :trigram, nil), do: stmts.search_trigram
  defp pick_search_stmt(stmts, :trigram, _), do: stmts.search_trigram_filtered

  defp execute_search(_db, _stmt, "", _limit, _source_filter), do: []

  defp execute_search(db, stmt, query, limit, nil) do
    :ok = Sqlite3.bind(stmt, [query, limit])
    rows = collect_search_rows(db, stmt)
    :ok = Sqlite3.reset(stmt)
    rows
  end

  defp execute_search(db, stmt, query, limit, source_filter) do
    :ok = Sqlite3.bind(stmt, [query, "%#{source_filter}%", limit])
    rows = collect_search_rows(db, stmt)
    :ok = Sqlite3.reset(stmt)
    rows
  end

  defp collect_search_rows(db, stmt) do
    case Sqlite3.step(db, stmt) do
      {:row, [title, content, content_type, label, rank, highlighted]} ->
        row = %{
          title: title,
          content: content,
          content_type: parse_content_type(content_type),
          source: label,
          rank: rank,
          highlighted: highlighted
        }

        [row | collect_search_rows(db, stmt)]

      :done ->
        []
    end
  end

  defp parse_content_type("code"), do: :code
  defp parse_content_type(_), do: :prose

  # ── Fuzzy Correction ──

  # Correct a query by finding vocabulary words within Levenshtein edit distance.
  @spec fuzzy_correct_query(t(), String.t()) :: String.t() | nil
  defp fuzzy_correct_query(state, query) do
    words =
      query
      |> String.downcase()
      |> String.trim()
      |> String.split(~r/\s+/)
      |> Enum.filter(&(String.length(&1) >= 3))

    if words == [] do
      nil
    else
      corrected = Enum.map(words, &(fuzzy_correct_word(state, &1) || &1))

      if corrected == words do
        nil
      else
        Enum.join(corrected, " ")
      end
    end
  end

  defp fuzzy_correct_word(state, word) do
    max_dist = max_edit_distance(String.length(word))
    min_len = String.length(word) - max_dist
    max_len = String.length(word) + max_dist

    :ok = Sqlite3.bind(state.stmts.fuzzy_vocab, [min_len, max_len])
    candidates = collect_column(state.db, state.stmts.fuzzy_vocab)
    :ok = Sqlite3.reset(state.stmts.fuzzy_vocab)

    {best_word, best_dist} =
      Enum.reduce(candidates, {nil, max_dist + 1}, fn candidate, {bw, bd} ->
        if candidate == word do
          # Exact match — no correction needed
          {nil, 0}
        else
          dist = levenshtein(word, candidate)
          if dist < bd, do: {candidate, dist}, else: {bw, bd}
        end
      end)

    # Exact match found (dist == 0) means no correction needed
    if best_dist == 0, do: nil, else: if(best_dist <= max_dist, do: best_word, else: nil)
  end

  defp max_edit_distance(len) when len <= 4, do: 1
  defp max_edit_distance(len) when len <= 12, do: 2
  defp max_edit_distance(_), do: 3

  @doc false
  @spec levenshtein(String.t(), String.t()) :: non_neg_integer()
  def levenshtein(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    a_len = length(a_chars)
    b_len = length(b_chars)

    cond do
      a_len == 0 ->
        b_len

      b_len == 0 ->
        a_len

      true ->
        prev = Enum.to_list(0..b_len)

        {final_row, _} =
          Enum.reduce(a_chars, {prev, 1}, fn a_ch, {prev_row, i} ->
            row =
              Enum.reduce(Enum.zip(b_chars, 1..b_len), [i], fn {b_ch, j}, acc ->
                cost = if a_ch == b_ch, do: 0, else: 1
                above = Enum.at(prev_row, j)
                left = hd(acc)
                diag = Enum.at(prev_row, j - 1)
                [min(min(above + 1, left + 1), diag + cost) | acc]
              end)

            {Enum.reverse(row), i + 1}
          end)

        List.last(final_row)
    end
  end

  @doc false
  def sanitize_query(query, mode \\ :and) do
    joiner = if mode == :or, do: " OR ", else: " "

    query
    |> String.replace(~r/['"()\[\]*:^~]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in ~w[AND OR NOT NEAR]))
    |> Enum.map(&"\"#{&1}\"")
    |> Enum.join(joiner)
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

  defp prepare_statements(db) do
    {:ok, search_porter} =
      Sqlite3.prepare(db, """
      SELECT c.title, c.content, c.content_type, s.label,
             bm25(chunks, 2.0, 1.0) AS rank,
             highlight(chunks, 1, char(2), char(3)) AS highlighted
      FROM chunks c
      JOIN sources s ON s.id = c.source_id
      WHERE chunks MATCH ?1
      ORDER BY rank
      LIMIT ?2
      """)

    {:ok, search_porter_filtered} =
      Sqlite3.prepare(db, """
      SELECT c.title, c.content, c.content_type, s.label,
             bm25(chunks, 2.0, 1.0) AS rank,
             highlight(chunks, 1, char(2), char(3)) AS highlighted
      FROM chunks c
      JOIN sources s ON s.id = c.source_id
      WHERE chunks MATCH ?1 AND s.label LIKE ?2
      ORDER BY rank
      LIMIT ?3
      """)

    {:ok, search_trigram} =
      Sqlite3.prepare(db, """
      SELECT c.title, c.content, c.content_type, s.label,
             bm25(chunks_trigram, 2.0, 1.0) AS rank,
             highlight(chunks_trigram, 1, char(2), char(3)) AS highlighted
      FROM chunks_trigram c
      JOIN sources s ON s.id = c.source_id
      WHERE chunks_trigram MATCH ?1
      ORDER BY rank
      LIMIT ?2
      """)

    {:ok, search_trigram_filtered} =
      Sqlite3.prepare(db, """
      SELECT c.title, c.content, c.content_type, s.label,
             bm25(chunks_trigram, 2.0, 1.0) AS rank,
             highlight(chunks_trigram, 1, char(2), char(3)) AS highlighted
      FROM chunks_trigram c
      JOIN sources s ON s.id = c.source_id
      WHERE chunks_trigram MATCH ?1 AND s.label LIKE ?2
      ORDER BY rank
      LIMIT ?3
      """)

    {:ok, fuzzy_vocab} =
      Sqlite3.prepare(db, """
      SELECT word FROM vocabulary WHERE length(word) BETWEEN ?1 AND ?2
      """)

    {:ok, insert_source} =
      Sqlite3.prepare(
        db,
        "INSERT INTO sources (label, chunk_count, code_chunk_count) VALUES (?1, ?2, ?3)"
      )

    {:ok, insert_porter} =
      Sqlite3.prepare(db, """
      INSERT INTO chunks (title, content, source_id, content_type)
      VALUES (?1, ?2, ?3, ?4)
      """)

    {:ok, insert_trigram} =
      Sqlite3.prepare(db, """
      INSERT INTO chunks_trigram (title, content, source_id, content_type)
      VALUES (?1, ?2, ?3, ?4)
      """)

    %{
      search_porter: search_porter,
      search_porter_filtered: search_porter_filtered,
      search_trigram: search_trigram,
      search_trigram_filtered: search_trigram_filtered,
      fuzzy_vocab: fuzzy_vocab,
      insert_source: insert_source,
      insert_porter: insert_porter,
      insert_trigram: insert_trigram
    }
  end

  # ── Helpers ──

  defp last_insert_rowid(db) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT last_insert_rowid()")
    {:row, [id]} = Sqlite3.step(db, stmt)
    Sqlite3.release(db, stmt)
    id
  end

  defp count_sources(db) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT count(*) FROM sources")
    {:row, [count]} = Sqlite3.step(db, stmt)
    Sqlite3.release(db, stmt)
    count
  end

  defp count_code(chunks) do
    Enum.count(chunks, &(&1.content_type == :code))
  end

  defp collect_column(db, stmt) do
    case Sqlite3.step(db, stmt) do
      {:row, [val]} -> [val | collect_column(db, stmt)]
      :done -> []
    end
  end

  defp do_list_sources(db) do
    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "SELECT label, chunk_count, indexed_at FROM sources ORDER BY indexed_at DESC"
      )

    rows = collect_source_rows(db, stmt)
    Sqlite3.release(db, stmt)
    rows
  end

  defp collect_source_rows(db, stmt) do
    case Sqlite3.step(db, stmt) do
      {:row, [label, count, indexed_at]} ->
        [
          %{label: label, chunk_count: count, indexed_at: indexed_at}
          | collect_source_rows(db, stmt)
        ]

      :done ->
        []
    end
  end

  # ── child_spec for DynamicSupervisor ──

  def child_spec({session_id, sessions_dir}) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id, sessions_dir]},
      restart: :temporary,
      type: :worker
    }
  end
end
