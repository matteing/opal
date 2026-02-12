defmodule Opal.Events do
  @moduledoc """
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
  """

  @registry Opal.Events.Registry

  @doc """
  Subscribes the calling process to events for the given session ID.

  The process will receive messages in the form `{:opal_event, session_id, event}`.
  Multiple processes can subscribe to the same session ID.
  """
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def subscribe(session_id) when is_binary(session_id) do
    Registry.register(@registry, session_id, [])
  end

  @doc """
  Subscribes the calling process to events from **all** sessions.

  The process receives the same `{:opal_event, session_id, event}` tuples
  regardless of which session emitted them. Useful for inspectors and
  debugging tools.
  """
  @spec subscribe_all() :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def subscribe_all do
    Registry.register(@registry, :all, [])
  end

  @doc """
  Broadcasts an event to all processes subscribed to the given session ID,
  plus any processes subscribed to the `:all` wildcard.

  Each subscriber receives `{:opal_event, session_id, event}`.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(session_id, event) when is_binary(session_id) do
    msg = {:opal_event, session_id, event}

    Registry.dispatch(@registry, session_id, fn entries ->
      for {pid, _value} <- entries, do: send(pid, msg)
    end)

    Registry.dispatch(@registry, :all, fn entries ->
      for {pid, _value} <- entries, do: send(pid, msg)
    end)
  end

  @doc """
  Unsubscribes the calling process from events for the given session ID.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    Registry.unregister(@registry, session_id)
  end

  @doc """
  Unsubscribes the calling process from the wildcard subscription.
  """
  @spec unsubscribe_all() :: :ok
  def unsubscribe_all do
    Registry.unregister(@registry, :all)
  end
end
