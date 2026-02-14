defmodule Opal.Agent.Tools do
  @moduledoc """
  Tool lifecycle orchestration for the agent loop.
  """

  alias Opal.Agent.State
  alias Opal.Agent.ToolRunner

  @spec start_tool_execution([map()], State.t()) :: {:noreply, State.t()}
  defdelegate start_tool_execution(tool_calls, state), to: ToolRunner

  @spec handle_tool_result(reference(), map(), {:ok, term()} | {:error, term()}, State.t()) ::
          {:noreply, State.t()}
  defdelegate handle_tool_result(ref, tc, result, state), to: ToolRunner

  @spec cancel_all_tasks(State.t()) :: State.t()
  defdelegate cancel_all_tasks(state), to: ToolRunner

  @spec active_tools(State.t()) :: [module()]
  defdelegate active_tools(state), to: ToolRunner

  @spec check_for_steering(State.t()) :: State.t()
  defdelegate check_for_steering(state), to: ToolRunner
end
