defmodule Opal.Session do
  @moduledoc """
  GenServer managing a conversation tree with branching and persistence.

  Each message is stored in an ETS table keyed by its ID, with a parent_id
  forming a tree structure. A `current_id` pointer tracks the active leaf,
  enabling branching by rewinding to any past message.

  ## Usage

      {:ok, session} = Opal.Session.start_link(session_id: "abc")
      :ok = Opal.Session.append(session, message)
      path = Opal.Session.get_path(session)
      tree = Opal.Session.get_tree(session)
      :ok = Opal.Session.branch(session, some_message_id)
      :ok = Opal.Session.save(session, "/path/to/sessions")
  """

  use GenServer

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            session_id: String.t(),
            table: :ets.table(),
            current_id: String.t() | nil,
            metadata: map()
          }

    @enforce_keys [:session_id, :table]
    defstruct [:session_id, :table, current_id: nil, metadata: %{}]
  end

  # --- Public API ---

  @doc "Starts the session GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc """
  Appends a message to the session tree.

  The message's `parent_id` is set to the current leaf. After appending,
  `current_id` advances to this new message.
  """
  @spec append(GenServer.server(), Opal.Message.t()) :: :ok
  def append(session, %Opal.Message{} = message) do
    GenServer.call(session, {:append, message})
  end

  @doc """
  Appends multiple messages to the session tree in order.

  Each message's parent_id is set to the previous message's id
  (or the current leaf for the first one).
  """
  @spec append_many(GenServer.server(), [Opal.Message.t()]) :: :ok
  def append_many(session, messages) when is_list(messages) do
    GenServer.call(session, {:append_many, messages})
  end

  @doc """
  Returns the message with the given ID, or nil.
  """
  @spec get_message(GenServer.server(), String.t()) :: Opal.Message.t() | nil
  def get_message(session, message_id) do
    GenServer.call(session, {:get_message, message_id})
  end

  @doc """
  Returns the path from root to the current leaf as a list of messages.
  """
  @spec get_path(GenServer.server()) :: [Opal.Message.t()]
  def get_path(session) do
    GenServer.call(session, :get_path)
  end

  @doc """
  Returns the full conversation tree as a nested structure.

  Each node is `%{message: msg, children: [nodes...]}`.
  """
  @spec get_tree(GenServer.server()) :: [map()]
  def get_tree(session) do
    GenServer.call(session, :get_tree)
  end

  @doc """
  Branches the conversation by setting the current pointer to the given message ID.

  All subsequent `append/2` calls will build from this point, creating a new branch.
  Returns `:ok` if the message exists, `{:error, :not_found}` otherwise.
  """
  @spec branch(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def branch(session, message_id) do
    GenServer.call(session, {:branch, message_id})
  end

  @doc """
  Returns the path from root to the given message ID as a list of messages.

  Unlike `get_path/1`, which returns the path to the current leaf, this
  returns the path to any arbitrary message in the tree. Used by branch
  summarization to compare paths and find common ancestors.
  """
  @spec get_path_to(GenServer.server(), String.t()) :: [Opal.Message.t()]
  def get_path_to(session, message_id) do
    GenServer.call(session, {:get_path_to, message_id})
  end

  @doc """
  Branches to a new point, optionally summarizing the abandoned branch.

  When `summarize: true` is passed, generates a compact summary of the
  abandoned branch and appends it at the new branch point. This gives the
  LLM context about what was tried so it doesn't repeat failed approaches.

  ## Options

    * `:summarize` — whether to generate a branch summary (default: `false`)
    * `:provider` — LLM provider module for summary generation
    * `:model` — `%Opal.Model{}` for summary generation
    * `:strategy` — set to `:skip` to disable summarization
  """
  @spec branch_with_summary(GenServer.server(), String.t(), keyword()) ::
          :ok | {:error, :not_found}
  def branch_with_summary(session, target_id, opts \\ []) do
    current = current_id(session)
    result = branch(session, target_id)

    case result do
      :ok when current != nil ->
        if Keyword.get(opts, :summarize, false) do
          case Opal.Session.BranchSummary.summarize_abandoned(
                 session,
                 current,
                 target_id,
                 opts
               ) do
            {:ok, nil} -> :ok
            {:ok, summary_msg} -> append(session, summary_msg)
            {:error, _} -> :ok
          end
        end

        :ok

      other ->
        other
    end
  end

  @doc """
  Returns the current leaf message ID, or nil if empty.
  """
  @spec current_id(GenServer.server()) :: String.t() | nil
  def current_id(session) do
    GenServer.call(session, :current_id)
  end

  @doc """
  Returns all messages in the session (unordered).
  """
  @spec all_messages(GenServer.server()) :: [Opal.Message.t()]
  def all_messages(session) do
    GenServer.call(session, :all_messages)
  end

  @doc """
  Returns the session ID.
  """
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc """
  Gets a metadata value by key.
  """
  @spec get_metadata(GenServer.server(), atom() | String.t()) :: term()
  def get_metadata(session, key) do
    GenServer.call(session, {:get_metadata, key})
  end

  @doc """
  Sets a metadata key-value pair.
  """
  @spec set_metadata(GenServer.server(), atom() | String.t(), term()) :: :ok
  def set_metadata(session, key, value) do
    GenServer.call(session, {:set_metadata, key, value})
  end

  @doc """
  Persists the session to disk as an ETF file.
  """
  @spec save(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def save(session, dir) do
    GenServer.call(session, {:save, dir})
  end

  @doc """
  Loads a saved session from a JSONL file into a running Session process.
  """
  @spec load(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def load(session, path) do
    GenServer.call(session, {:load, path})
  end

  @doc """
  Lists saved session files in a directory.

  Returns a list of `%{id: session_id, path: file_path, modified: DateTime.t()}`.
  """
  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file ->
          path = Path.join(dir, file)
          id = String.trim_trailing(file, ".jsonl")
          stat = File.stat!(path)
          title = read_session_title(path)

          %{
            id: id,
            path: path,
            title: title,
            modified: stat.mtime |> NaiveDateTime.from_erl!()
          }
        end)
        |> Enum.sort_by(& &1.modified, {:desc, NaiveDateTime})

      {:error, _} ->
        []
    end
  end

  @doc """
  Replaces a range of messages in the path with a summary message.

  Used by compaction to collapse older messages while preserving the tree.
  """
  @spec replace_path_segment(GenServer.server(), [String.t()], Opal.Message.t()) :: :ok
  def replace_path_segment(session, message_ids, summary_message) do
    GenServer.call(session, {:replace_path_segment, message_ids, summary_message})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    table = :ets.new(:opal_session, [:set, :private])

    state = %State{
      session_id: session_id,
      table: table,
      current_id: nil,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:append, message}, _from, state) do
    message = %{message | parent_id: state.current_id}
    :ets.insert(state.table, {message.id, message})
    {:reply, :ok, %{state | current_id: message.id}}
  end

  def handle_call({:append_many, messages}, _from, state) do
    state =
      Enum.reduce(messages, state, fn msg, acc ->
        msg = %{msg | parent_id: acc.current_id}
        :ets.insert(acc.table, {msg.id, msg})
        %{acc | current_id: msg.id}
      end)

    {:reply, :ok, state}
  end

  def handle_call({:get_message, id}, _from, state) do
    result =
      case :ets.lookup(state.table, id) do
        [{^id, msg}] -> msg
        [] -> nil
      end

    {:reply, result, state}
  end

  def handle_call(:get_path, _from, state) do
    path = build_path(state.table, state.current_id)
    {:reply, path, state}
  end

  def handle_call({:get_path_to, message_id}, _from, state) do
    path = build_path(state.table, message_id)
    {:reply, path, state}
  end

  def handle_call(:get_tree, _from, state) do
    tree = build_tree(state.table)
    {:reply, tree, state}
  end

  def handle_call({:branch, message_id}, _from, state) do
    case :ets.lookup(state.table, message_id) do
      [{^message_id, _msg}] ->
        {:reply, :ok, %{state | current_id: message_id}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:current_id, _from, state) do
    {:reply, state.current_id, state}
  end

  def handle_call(:all_messages, _from, state) do
    messages =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_id, msg} -> msg end)

    {:reply, messages, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:get_metadata, key}, _from, state) do
    {:reply, Map.get(state.metadata, key), state}
  end

  def handle_call({:set_metadata, key, value}, _from, state) do
    metadata = Map.put(state.metadata, key, value)
    {:reply, :ok, %{state | metadata: metadata}}
  end

  def handle_call({:save, dir}, _from, state) do
    result = do_save(state, dir)
    {:reply, result, state}
  end

  def handle_call({:load, path}, _from, state) do
    case do_load(state.table, path) do
      {:ok, loaded_state} ->
        {:reply, :ok,
         %{state | current_id: loaded_state.current_id, metadata: loaded_state.metadata}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:replace_path_segment, ids_to_remove, summary}, _from, state) do
    state = do_replace_segment(state, ids_to_remove, summary)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # --- Internal Helpers ---

  # Walks parent_id pointers from current_id back to root, returns in order.
  defp build_path(_table, nil), do: []

  defp build_path(table, current_id) do
    do_build_path(table, current_id, [])
  end

  defp do_build_path(_table, nil, acc), do: acc

  defp do_build_path(table, id, acc) do
    case :ets.lookup(table, id) do
      [{^id, msg}] -> do_build_path(table, msg.parent_id, [msg | acc])
      [] -> acc
    end
  end

  # Builds a nested tree from all messages in the ETS table.
  defp build_tree(table) do
    all = :ets.tab2list(table) |> Enum.map(fn {_id, msg} -> msg end)

    # Group by parent_id
    by_parent = Enum.group_by(all, & &1.parent_id)

    # Build from roots (parent_id == nil)
    build_children(by_parent, nil)
  end

  defp build_children(by_parent, parent_id) do
    children = Map.get(by_parent, parent_id, [])

    Enum.map(children, fn msg ->
      %{
        message: msg,
        children: build_children(by_parent, msg.id)
      }
    end)
  end

  # Persists session state as JSONL (one JSON object per line).
  # Line 1: session metadata (session_id, current_id, metadata)
  # Lines 2+: one message per line
  defp do_save(state, dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{state.session_id}.jsonl")

    messages = :ets.tab2list(state.table) |> Enum.map(fn {_id, msg} -> msg end)

    header =
      Jason.encode!(%{
        session_id: state.session_id,
        current_id: state.current_id,
        metadata: state.metadata
      })

    lines =
      [header | Enum.map(messages, &message_to_json/1)]
      |> Enum.join("\n")

    File.write(path, lines <> "\n")
  end

  # Loads session state from JSONL into the ETS table.
  defp do_load(table, path) do
    case File.read(path) do
      {:ok, content} ->
        [header_line | message_lines] =
          content
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))

        header = Jason.decode!(header_line)

        # Clear existing data
        :ets.delete_all_objects(table)

        # Insert all messages
        Enum.each(message_lines, fn line ->
          msg = json_to_message(Jason.decode!(line))
          :ets.insert(table, {msg.id, msg})
        end)

        {:ok,
         %{
           current_id: header["current_id"],
           metadata: atomize_metadata(Map.get(header, "metadata", %{}))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message_to_json(%Opal.Message{} = msg) do
    map = %{
      id: msg.id,
      parent_id: msg.parent_id,
      role: msg.role,
      content: msg.content,
      is_error: msg.is_error
    }

    map =
      if msg.tool_calls && msg.tool_calls != [] do
        Map.put(
          map,
          :tool_calls,
          Enum.map(msg.tool_calls, fn tc ->
            %{call_id: tc.call_id, name: tc.name, arguments: tc.arguments}
          end)
        )
      else
        map
      end

    map = if msg.call_id, do: Map.put(map, :call_id, msg.call_id), else: map
    map = if msg.name, do: Map.put(map, :name, msg.name), else: map
    # Persist structured metadata (compaction summaries, file-op tracking, etc.)
    map = if msg.metadata, do: Map.put(map, :metadata, msg.metadata), else: map

    Jason.encode!(map)
  end

  defp json_to_message(data) do
    tool_calls =
      case data["tool_calls"] do
        nil ->
          nil

        list ->
          Enum.map(list, fn tc ->
            %{call_id: tc["call_id"], name: tc["name"], arguments: tc["arguments"]}
          end)
      end

    # Restore structured metadata, converting string keys to atoms for
    # consistent access (e.g. msg.metadata.read_files).
    metadata =
      case data["metadata"] do
        nil -> nil
        m when is_map(m) -> atomize_metadata(m)
      end

    %Opal.Message{
      id: data["id"],
      parent_id: data["parent_id"],
      role: String.to_existing_atom(data["role"]),
      content: data["content"],
      tool_calls: tool_calls,
      call_id: data["call_id"],
      name: data["name"],
      is_error: data["is_error"] || false,
      metadata: metadata
    }
  end

  defp atomize_metadata(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_to_atom(k), v} end)
  end

  defp atomize_metadata(_), do: %{}

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp safe_to_atom(key), do: key

  # Replaces a contiguous segment of the current path with a summary message.
  # The summary message bridges the gap: its parent_id is set to the parent
  # of the first removed message, and any children of the last removed message
  # get re-parented to the summary.
  defp do_replace_segment(state, ids_to_remove, summary) do
    id_set = MapSet.new(ids_to_remove)

    # Find the parent of the first message to remove (the anchor point)
    first_id = List.first(ids_to_remove)
    last_id = List.last(ids_to_remove)

    first_msg =
      case :ets.lookup(state.table, first_id) do
        [{_, msg}] -> msg
        [] -> nil
      end

    # Set summary's parent to the first removed message's parent
    summary = %{summary | parent_id: first_msg && first_msg.parent_id}

    # Find children of the last removed message and re-parent them
    all_msgs = :ets.tab2list(state.table) |> Enum.map(fn {_, msg} -> msg end)

    children_of_last =
      Enum.filter(all_msgs, fn msg ->
        msg.parent_id == last_id and msg.id not in id_set
      end)

    # Remove old messages
    Enum.each(ids_to_remove, fn id -> :ets.delete(state.table, id) end)

    # Insert summary
    :ets.insert(state.table, {summary.id, summary})

    # Re-parent children
    Enum.each(children_of_last, fn msg ->
      updated = %{msg | parent_id: summary.id}
      :ets.insert(state.table, {updated.id, updated})
    end)

    # Update current_id if it was one of the removed messages
    current_id =
      if state.current_id in id_set do
        summary.id
      else
        state.current_id
      end

    %{state | current_id: current_id}
  end

  # Reads the title from a saved ETF file's metadata without fully loading it.
  defp read_session_title(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, file} ->
        line = IO.read(file, :line)
        File.close(file)

        case Jason.decode(line || "") do
          {:ok, header} -> get_in(header, ["metadata", "title"])
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
