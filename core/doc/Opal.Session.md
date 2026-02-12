# `Opal.Session`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/session.ex#L1)

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

# `all_messages`

```elixir
@spec all_messages(GenServer.server()) :: [Opal.Message.t()]
```

Returns all messages in the session (unordered).

# `append`

```elixir
@spec append(GenServer.server(), Opal.Message.t()) :: :ok
```

Appends a message to the session tree.

The message's `parent_id` is set to the current leaf. After appending,
`current_id` advances to this new message.

# `append_many`

```elixir
@spec append_many(GenServer.server(), [Opal.Message.t()]) :: :ok
```

Appends multiple messages to the session tree in order.

Each message's parent_id is set to the previous message's id
(or the current leaf for the first one).

# `branch`

```elixir
@spec branch(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
```

Branches the conversation by setting the current pointer to the given message ID.

All subsequent `append/2` calls will build from this point, creating a new branch.
Returns `:ok` if the message exists, `{:error, :not_found}` otherwise.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `current_id`

```elixir
@spec current_id(GenServer.server()) :: String.t() | nil
```

Returns the current leaf message ID, or nil if empty.

# `get_message`

```elixir
@spec get_message(GenServer.server(), String.t()) :: Opal.Message.t() | nil
```

Returns the message with the given ID, or nil.

# `get_metadata`

```elixir
@spec get_metadata(GenServer.server(), atom() | String.t()) :: term()
```

Gets a metadata value by key.

# `get_path`

```elixir
@spec get_path(GenServer.server()) :: [Opal.Message.t()]
```

Returns the path from root to the current leaf as a list of messages.

# `get_tree`

```elixir
@spec get_tree(GenServer.server()) :: [map()]
```

Returns the full conversation tree as a nested structure.

Each node is `%{message: msg, children: [nodes...]}`.

# `list_sessions`

```elixir
@spec list_sessions(String.t()) :: [map()]
```

Lists saved session files in a directory.

Returns a list of `%{id: session_id, path: file_path, modified: DateTime.t()}`.

# `load`

```elixir
@spec load(GenServer.server(), String.t()) :: :ok | {:error, term()}
```

Loads a saved session from a JSONL file into a running Session process.

# `replace_path_segment`

```elixir
@spec replace_path_segment(GenServer.server(), [String.t()], Opal.Message.t()) :: :ok
```

Replaces a range of messages in the path with a summary message.

Used by compaction to collapse older messages while preserving the tree.

# `save`

```elixir
@spec save(GenServer.server(), String.t()) :: :ok | {:error, term()}
```

Persists the session to disk as an ETF file.

# `session_id`

```elixir
@spec session_id(GenServer.server()) :: String.t()
```

Returns the session ID.

# `set_metadata`

```elixir
@spec set_metadata(GenServer.server(), atom() | String.t(), term()) :: :ok
```

Sets a metadata key-value pair.

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts the session GenServer.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
