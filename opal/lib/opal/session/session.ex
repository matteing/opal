defmodule Opal.Session do
  @moduledoc """
  Conversation tree with branching and DETS-backed persistence.

  Messages live in an ETS table keyed by ID, linked by `parent_id` into
  a tree. A `current_id` pointer tracks the active leaf. Branching simply
  moves the pointer; subsequent appends grow from the new position.

  Persistence uses DETS — Erlang terms written directly to disk, zero
  serialization overhead. DETS files live in the configured sessions dir.

  ## Usage

      {:ok, session} = Opal.Session.start_link(session_id: "abc")
      :ok = Opal.Session.append(session, message)
      path = Opal.Session.get_path(session)
      :ok = Opal.Session.branch(session, some_message_id)
      :ok = Opal.Session.save(session, "/path/to/sessions")
  """

  use GenServer

  # ── State ──────────────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            session_id: String.t(),
            table: :ets.table(),
            current_id: String.t() | nil,
            metadata: map(),
            sessions_dir: String.t() | nil
          }

    @enforce_keys [:session_id, :table]
    defstruct [:session_id, :table, current_id: nil, metadata: %{}, sessions_dir: nil]
  end

  # ── Public API ─────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_opts = if name = opts[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "Appends a message, setting its `parent_id` to the current leaf."
  @spec append(GenServer.server(), Opal.Message.t()) :: :ok
  def append(session, %Opal.Message{} = msg), do: GenServer.call(session, {:append, msg})

  @doc "Appends messages in order, chaining `parent_id`s."
  @spec append_many(GenServer.server(), [Opal.Message.t()]) :: :ok
  def append_many(session, msgs) when is_list(msgs),
    do: GenServer.call(session, {:append_many, msgs})

  @doc "Returns the message with the given ID, or `nil`."
  @spec get_message(GenServer.server(), String.t()) :: Opal.Message.t() | nil
  def get_message(session, id), do: GenServer.call(session, {:get_message, id})

  @doc "Returns the path from root to the current leaf."
  @spec get_path(GenServer.server()) :: [Opal.Message.t()]
  def get_path(session), do: GenServer.call(session, :get_path)

  @doc "Returns the full tree as nested `%{message: msg, children: [...]}`."
  @spec get_tree(GenServer.server()) :: [map()]
  def get_tree(session), do: GenServer.call(session, :get_tree)

  @doc "Moves the current pointer to `message_id`, creating a branch point."
  @spec branch(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def branch(session, message_id), do: GenServer.call(session, {:branch, message_id})

  @doc "Returns the current leaf message ID, or `nil` if empty."
  @spec current_id(GenServer.server()) :: String.t() | nil
  def current_id(session), do: GenServer.call(session, :current_id)

  @doc "Returns all messages (unordered)."
  @spec all_messages(GenServer.server()) :: [Opal.Message.t()]
  def all_messages(session), do: GenServer.call(session, :all_messages)

  @doc "Returns the session ID."
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(session), do: GenServer.call(session, :session_id)

  @doc "Gets a metadata value."
  @spec get_metadata(GenServer.server(), atom() | String.t()) :: term()
  def get_metadata(session, key), do: GenServer.call(session, {:get_metadata, key})

  @doc "Sets a metadata key-value pair."
  @spec set_metadata(GenServer.server(), atom() | String.t(), term()) :: :ok
  def set_metadata(session, key, value), do: GenServer.call(session, {:set_metadata, key, value})

  @doc "Persists the session to a DETS file in `dir`."
  @spec save(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def save(session, dir), do: GenServer.call(session, {:save, dir})

  @doc """
  Replaces a contiguous segment of messages with a summary.

  Used by compaction to collapse older messages while preserving the tree.
  """
  @spec replace_path_segment(GenServer.server(), [String.t()], Opal.Message.t()) :: :ok
  def replace_path_segment(session, ids, summary),
    do: GenServer.call(session, {:replace_path_segment, ids, summary})

  @doc """
  Lists saved sessions in a directory.

  Returns `[%{id: String.t(), path: String.t(), title: String.t() | nil, modified: NaiveDateTime.t()}]`,
  sorted newest-first.
  """
  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(dir) do
    with {:ok, files} <- File.ls(dir) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".dets"))
      |> Enum.flat_map(fn file ->
        path = Path.join(dir, file)

        with {:ok, stat} <- File.stat(path),
             {:ok, meta} <- read_dets_metadata(path) do
          [
            %{
              id: meta.session_id,
              path: path,
              title: meta.metadata[:title],
              modified: NaiveDateTime.from_erl!(stat.mtime)
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.sort_by(& &1.modified, {:desc, NaiveDateTime})
    else
      _ -> []
    end
  end

  # ── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    table = :ets.new(:opal_session, [:set, :private])

    state = %State{
      session_id: session_id,
      table: table,
      metadata: Keyword.get(opts, :metadata, %{}),
      sessions_dir: Keyword.get(opts, :sessions_dir)
    }

    state =
      case Keyword.get(opts, :load_from) do
        nil -> state
        path -> load_from_dets(state, path)
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:append, msg}, _from, state) do
    msg = %{msg | parent_id: state.current_id}
    :ets.insert(state.table, {msg.id, msg})
    {:reply, :ok, %{state | current_id: msg.id}}
  end

  def handle_call({:append_many, msgs}, _from, state) do
    state =
      Enum.reduce(msgs, state, fn msg, acc ->
        msg = %{msg | parent_id: acc.current_id}
        :ets.insert(acc.table, {msg.id, msg})
        %{acc | current_id: msg.id}
      end)

    {:reply, :ok, state}
  end

  def handle_call({:get_message, id}, _from, state) do
    reply =
      case :ets.lookup(state.table, id) do
        [{^id, msg}] -> msg
        [] -> nil
      end

    {:reply, reply, state}
  end

  def handle_call(:get_path, _from, state) do
    {:reply, walk_path(state.table, state.current_id), state}
  end

  def handle_call(:get_tree, _from, state) do
    {:reply, build_tree(state.table), state}
  end

  def handle_call({:branch, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, _}] -> {:reply, :ok, %{state | current_id: id}}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:current_id, _from, state), do: {:reply, state.current_id, state}

  def handle_call(:all_messages, _from, state) do
    {:reply, for({_id, msg} <- :ets.tab2list(state.table), do: msg), state}
  end

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  def handle_call({:get_metadata, key}, _from, state) do
    {:reply, Map.get(state.metadata, key), state}
  end

  def handle_call({:set_metadata, key, value}, _from, state) do
    {:reply, :ok, %{state | metadata: Map.put(state.metadata, key, value)}}
  end

  def handle_call({:save, dir}, _from, state) do
    {:reply, persist_to_dets(state, dir), state}
  end

  def handle_call({:replace_path_segment, ids, summary}, _from, state) do
    {:reply, :ok, do_replace_segment(state, ids, summary)}
  end

  @impl true
  def terminate(reason, state) do
    if reason != :normal do
      try do
        dir = state.sessions_dir || Opal.Config.sessions_dir(Opal.Config.new())
        persist_to_dets(state, dir)
      rescue
        _ -> :ok
      end
    end

    :ets.delete(state.table)
    :ok
  end

  # ── Tree Traversal ─────────────────────────────────────────────────

  defp walk_path(_table, nil), do: []

  defp walk_path(table, id) do
    case :ets.lookup(table, id) do
      [{^id, msg}] -> walk_path(table, msg.parent_id) ++ [msg]
      [] -> []
    end
  end

  defp build_tree(table) do
    by_parent =
      table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.group_by(& &1.parent_id)

    build_children(by_parent, nil)
  end

  defp build_children(by_parent, parent_id) do
    for msg <- Map.get(by_parent, parent_id, []) do
      %{message: msg, children: build_children(by_parent, msg.id)}
    end
  end

  # ── Segment Replacement (compaction) ───────────────────────────────

  defp do_replace_segment(state, ids_to_remove, summary) do
    id_set = MapSet.new(ids_to_remove)
    first_id = List.first(ids_to_remove)
    last_id = List.last(ids_to_remove)

    # Anchor the summary to the parent of the first removed message
    anchor_parent =
      case :ets.lookup(state.table, first_id) do
        [{_, msg}] -> msg.parent_id
        [] -> nil
      end

    summary = %{summary | parent_id: anchor_parent}

    # Re-parent children of the last removed message
    children_of_last =
      for {_, msg} <- :ets.tab2list(state.table),
          msg.parent_id == last_id,
          msg.id not in id_set,
          do: msg

    Enum.each(ids_to_remove, &:ets.delete(state.table, &1))
    :ets.insert(state.table, {summary.id, summary})

    Enum.each(children_of_last, fn msg ->
      :ets.insert(state.table, {msg.id, %{msg | parent_id: summary.id}})
    end)

    current_id = if state.current_id in id_set, do: summary.id, else: state.current_id
    %{state | current_id: current_id}
  end

  # ── DETS Persistence ───────────────────────────────────────────────

  @meta_key :__session_meta__

  defp persist_to_dets(state, dir) do
    File.mkdir_p!(dir)
    path = dets_path(dir, state.session_id)

    with {:ok, ref} <- :dets.open_file(dets_name(state.session_id), file: to_charlist(path)) do
      :dets.delete_all_objects(ref)

      meta = %{
        session_id: state.session_id,
        current_id: state.current_id,
        metadata: state.metadata
      }

      :dets.insert(ref, {@meta_key, meta})

      state.table |> :ets.tab2list() |> then(&:dets.insert(ref, &1))
      :dets.close(ref)
      :ok
    end
  end

  defp load_from_dets(state, path) do
    with {:ok, ref} <- :dets.open_file(dets_name(state.session_id), file: to_charlist(path)) do
      # Load metadata
      meta =
        case :dets.lookup(ref, @meta_key) do
          [{@meta_key, m}] -> m
          _ -> %{current_id: nil, metadata: %{}}
        end

      # Load messages into ETS
      :ets.delete_all_objects(state.table)

      :dets.foldl(
        fn
          {@meta_key, _}, acc ->
            acc

          {id, msg}, acc ->
            :ets.insert(state.table, {id, msg})
            acc
        end,
        :ok,
        ref
      )

      :dets.close(ref)
      %{state | current_id: meta.current_id, metadata: meta.metadata}
    else
      _ -> state
    end
  end

  # Opens a DETS file just long enough to read session metadata (for list_sessions).
  @spec read_dets_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_dets_metadata(path) do
    name = :"dets_peek_#{:erlang.phash2(path)}"

    with {:ok, ref} <- :dets.open_file(name, file: to_charlist(path)) do
      result =
        case :dets.lookup(ref, @meta_key) do
          [{@meta_key, meta}] -> {:ok, meta}
          _ -> {:error, :no_metadata}
        end

      :dets.close(ref)
      result
    end
  end

  defp dets_path(dir, session_id), do: Path.join(dir, "#{session_id}.dets")
  defp dets_name(session_id), do: :"opal_session_#{session_id}"
end
