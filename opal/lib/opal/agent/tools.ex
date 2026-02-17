defmodule Opal.Agent.Tools do
  @moduledoc """
  Tool lifecycle orchestration for the agent loop.

  ## Accessing available tools

  Always use `active_tools/1` to get the tools the model should see.
  Never read `state.tools` directly — it is the raw registry and
  includes tools that may be disabled by feature flags or per-name
  disable lists. The filtering layers are:

  1. `state.tools` — full registry (all registered + MCP tools)
  2. `state.disabled_tools` — per-name disable list (config/RPC)
  3. Feature gates — structural toggles (MCP, sub-agents, debug, skills)

  `active_tools/1` applies layers 2 and 3 to produce the final set.
  """

  alias Opal.Agent.State
  alias Opal.Agent.ToolRunner

  @spec start_tool_execution([map()], State.t()) :: State.t()
  defdelegate start_tool_execution(tool_calls, state), to: ToolRunner

  @spec handle_tool_result(
          reference(),
          map(),
          {:ok, term()} | {:error, term()} | {:effect, term()},
          State.t()
        ) ::
          State.t()
  defdelegate handle_tool_result(ref, tc, result, state), to: ToolRunner

  @spec cancel_all_tasks(State.t()) :: State.t()
  defdelegate cancel_all_tasks(state), to: ToolRunner

  @spec active_tools(State.t()) :: [module()]
  defdelegate active_tools(state), to: ToolRunner

  @spec check_for_steering(State.t()) :: State.t()
  defdelegate check_for_steering(state), to: ToolRunner
end
