defmodule Opal.Agent.Reducer do
  @moduledoc """
  State reducer helpers for the agent state machine.
  """

  alias Opal.Agent.State

  @valid_states [:idle, :running, :streaming, :executing_tools]

  @spec state_name(State.t()) :: :idle | :running | :streaming | :executing_tools
  def state_name(%State{status: status}) when status in @valid_states, do: status
end
