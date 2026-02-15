defmodule Opal.Agent.Effects do
  @moduledoc """
  Converts legacy loop returns into `:gen_statem` transitions.
  """

  alias Opal.Agent.Reducer
  alias Opal.Agent.State

  @spec from_legacy({:noreply, State.t()}) ::
          {:next_state, :idle | :running | :streaming | :executing_tools, State.t()}
  def from_legacy({:noreply, %State{} = state}) do
    {:next_state, Reducer.state_name(state), state}
  end
end
