defmodule Opal.Agent.Collector do
  @moduledoc """
  Collects streamed text from an agent session by subscribing to events
  and accumulating message deltas until agent_end.
  """

  @doc """
  Collects the full text response from an agent session.

  Expects the caller to have already subscribed to events for the given session_id.
  Blocks until `:agent_end` is received or timeout.
  """
  @spec collect_response(String.t(), String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def collect_response(session_id, acc \\ "", timeout \\ 120_000) do
    receive do
      {:opal_event, ^session_id, {:message_delta, %{delta: delta}}} ->
        collect_response(session_id, acc <> delta, timeout)

      {:opal_event, ^session_id, {:agent_end, _messages}} ->
        {:ok, acc}

      {:opal_event, ^session_id, {:agent_end, _messages, _usage}} ->
        {:ok, acc}

      {:opal_event, ^session_id, {:error, reason}} ->
        {:error, reason}

      {:opal_event, ^session_id, _other} ->
        collect_response(session_id, acc, timeout)
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
