defmodule Opal.Agent.Compaction do
  @moduledoc """
  Context compaction and usage tracking facade.
  """

  alias Opal.Agent.State
  alias Opal.Agent.UsageTracker

  @spec maybe_auto_compact(State.t()) :: State.t()
  defdelegate maybe_auto_compact(state), to: UsageTracker

  @spec handle_overflow_compaction(State.t(), term()) :: {:noreply, State.t()}
  defdelegate handle_overflow_compaction(state, reason), to: UsageTracker

  @spec update_usage(map(), State.t()) :: State.t()
  defdelegate update_usage(usage, state), to: UsageTracker
end
