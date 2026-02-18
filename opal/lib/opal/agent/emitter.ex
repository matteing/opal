defmodule Opal.Agent.Emitter do
  @moduledoc """
  Canonical event emitter for the agent loop.

  Broadcasts events to all session subscribers via `Opal.Events` and
  conditionally records them in a bounded ETS ring buffer for debug
  introspection (when `features.debug.enabled` is true).
  """

  alias Opal.Agent.State

  @table :opal_agent_event_log
  @max_entries 400
  @max_limit 500

  @doc """
  Broadcasts an event and conditionally stores it in the debug log.
  """
  @spec broadcast(State.t(), term()) :: :ok
  def broadcast(%State{session_id: session_id, config: config}, event) do
    if debug_enabled?(config), do: append(session_id, event)
    Opal.Events.broadcast(session_id, event)
  end

  @doc """
  Returns recent logged events (newest first) for a session.
  """
  @spec recent(String.t(), pos_integer()) :: [%{timestamp_ms: integer(), event: term()}]
  def recent(session_id, limit \\ 50) when is_binary(session_id) and is_integer(limit) do
    ensure_table()
    limit = Opal.Util.Number.clamp(limit, 1, @max_limit)

    @table
    |> :ets.lookup(session_id)
    |> Enum.sort_by(fn {_, ts, _} -> ts end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_, ts, event} -> %{timestamp_ms: ts, event: event} end)
  end

  @doc """
  Clears all logged events for a session.
  """
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  defp append(session_id, event) do
    ensure_table()
    ts = System.system_time(:millisecond)
    :ets.insert(@table, {session_id, ts, event})
    trim(session_id)
    :ok
  end

  defp trim(session_id) do
    entries = :ets.lookup(@table, session_id)
    overflow = length(entries) - @max_entries

    if overflow > 0 do
      entries
      |> Enum.sort_by(fn {_, ts, _} -> ts end)
      |> Enum.take(overflow)
      |> Enum.each(&:ets.delete_object(@table, &1))
    end
  end

  defp debug_enabled?(%{features: %{debug: %{enabled: true}}}), do: true
  defp debug_enabled?(_), do: false

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [
          :named_table,
          :public,
          :duplicate_bag,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
