# `Opal.Events`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/events.ex#L1)

Registry-based publish/subscribe for session events.

Provides a lightweight pubsub mechanism built on `Registry` with `:duplicate`
keys, allowing multiple processes to subscribe to events from the same session.

The backing registry (`Opal.Events.Registry`) must be started as part of the
application supervision tree.

## Usage

    # In a subscriber process:
    Opal.Events.subscribe("session-123")

    # Receive events:
    receive do
      {:opal_event, "session-123", event} -> handle(event)
    end

    # In the session process:
    Opal.Events.broadcast("session-123", {:token, "hello"})

# `broadcast`

```elixir
@spec broadcast(String.t(), term()) :: :ok
```

Broadcasts an event to all processes subscribed to the given session ID,
plus any processes subscribed to the `:all` wildcard.

Each subscriber receives `{:opal_event, session_id, event}`.

# `subscribe`

```elixir
@spec subscribe(String.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
```

Subscribes the calling process to events for the given session ID.

The process will receive messages in the form `{:opal_event, session_id, event}`.
Multiple processes can subscribe to the same session ID.

# `subscribe_all`

```elixir
@spec subscribe_all() :: {:ok, pid()} | {:error, {:already_registered, pid()}}
```

Subscribes the calling process to events from **all** sessions.

The process receives the same `{:opal_event, session_id, event}` tuples
regardless of which session emitted them. Useful for inspectors and
debugging tools.

# `unsubscribe`

```elixir
@spec unsubscribe(String.t()) :: :ok
```

Unsubscribes the calling process from events for the given session ID.

# `unsubscribe_all`

```elixir
@spec unsubscribe_all() :: :ok
```

Unsubscribes the calling process from the wildcard subscription.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
