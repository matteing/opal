defmodule Opal.Agent.ToolRunner do
  @moduledoc """
  Concurrent tool execution for the agent loop.

  Spawns tool calls as supervised tasks, collects results with crash
  isolation, and advances to the next turn when the batch completes.
  """

  require Logger
  alias Opal.Agent.{Emitter, State}

  # ── Types ──────────────────────────────────────────────────────────

  @typedoc "Outcome of a single tool execution."
  @type result :: {:ok, term()} | {:error, String.t()}

  # ── Batch Lifecycle ────────────────────────────────────────────────

  @doc """
  Spawns all tool calls concurrently as supervised tasks.
  """
  @spec execute_batch([map()], State.t()) :: State.t()
  def execute_batch(tool_calls, %State{} = state) do
    state = %{
      state
      | status: :executing_tools,
        pending_tool_tasks: %{},
        tool_results: [],
        tool_context: build_context(state)
    }

    Enum.reduce(tool_calls, state, &spawn_task/2)
  end

  @doc """
  Records a completed tool result. Finalizes the batch when all tasks complete.
  """
  @spec collect_result(reference(), map(), result() | {:effect, term()}, State.t()) ::
          State.t() | {:next_turn, State.t()}
  def collect_result(ref, tc, {:effect, effect}, %State{} = state) do
    {result, state} = apply_effect(effect, state)
    collect_result(ref, tc, result, state)
  end

  def collect_result(ref, tc, result, %State{} = state) do
    Emitter.broadcast(state, {:tool_execution_end, tc.name, tc.call_id, result})

    state = %{
      state
      | tool_results: [{tc, result} | state.tool_results],
        pending_tool_tasks: Map.delete(state.pending_tool_tasks, ref)
    }

    if map_size(state.pending_tool_tasks) == 0, do: finalize(state), else: state
  end

  @doc """
  Cancels all in-flight tool tasks and resets execution state.
  """
  @spec cancel_all(State.t()) :: State.t()
  def cancel_all(%State{pending_tool_tasks: tasks} = state) when map_size(tasks) == 0, do: state

  def cancel_all(%State{pending_tool_tasks: tasks} = state) do
    for {_ref, {task, _tc}} <- tasks, do: Task.shutdown(task, :brutal_kill)
    %{state | pending_tool_tasks: %{}, tool_results: [], tool_context: nil}
  end

  # ── Tool Registry ─────────────────────────────────────────────────

  @doc """
  Returns the filtered set of tools for this turn, applying feature
  gates and the disabled-tools list.
  """
  @spec active_tools(State.t()) :: [module()]
  def active_tools(%State{
        tools: tools,
        disabled_tools: disabled_tools,
        config: config,
        available_skills: skills
      }) do
    disabled = MapSet.new(disabled_tools)

    gates = [
      {not config.features.sub_agents.enabled, &(&1 == Opal.Tool.SubAgent)},
      {not config.features.mcp.enabled, &mcp_module?/1},
      {not config.features.debug.enabled, &(&1 == Opal.Tool.Debug)},
      {not (config.features.skills.enabled and skills != []), &(&1 == Opal.Tool.UseSkill)}
    ]

    rejectors = for {true, pred} <- gates, do: pred

    Enum.reject(tools, fn tool ->
      MapSet.member?(disabled, tool.name()) or Enum.any?(rejectors, & &1.(tool))
    end)
  end

  @doc """
  Finds a tool module by name.
  """
  @spec find_tool(String.t(), [module()]) :: module() | nil
  def find_tool(name, tools), do: Enum.find(tools, &(&1.name() == name))

  @doc """
  Executes a single tool, rescuing any raised exceptions.
  """
  @spec execute_tool(module() | nil, map(), map()) :: result()
  def execute_tool(nil, _args, _ctx), do: {:error, "Tool not found"}

  def execute_tool(tool_mod, args, ctx) do
    tool_mod.execute(args, ctx)
  rescue
    e ->
      Logger.error("Tool #{inspect(tool_mod)} raised: #{Exception.message(e)}")
      {:error, "Tool raised an exception: #{Exception.message(e)}"}
  end

  # ── Pending Messages ──────────────────────────────────────────────

  @doc """
  Drains messages queued while the agent was busy, injecting them
  as user turns.
  """
  @spec drain_pending(State.t()) :: State.t()
  def drain_pending(%State{pending_messages: []} = state), do: state

  def drain_pending(%State{pending_messages: pending} = state) do
    state =
      Enum.reduce(pending, state, fn text, acc ->
        Logger.debug("Pending message applied: #{String.slice(text, 0, 50)}...")
        Emitter.broadcast(acc, {:message_applied, text})
        State.append_message(acc, Opal.Message.user(text))
      end)

    %{state | pending_messages: []}
  end

  # ── Private ────────────────────────────────────────────────────────

  @spec build_context(State.t()) :: map()
  defp build_context(%State{} = state) do
    %{
      working_dir: state.working_dir,
      session_id: state.session_id,
      config: state.config,
      agent_pid: self(),
      agent_state: state
    }
  end

  @spec spawn_task(map(), State.t()) :: State.t()
  defp spawn_task(tc, %State{} = state) do
    tool_mod = find_tool(tc.name, active_tools(state))
    meta = if tool_mod, do: Opal.Tool.meta(tool_mod, tc.arguments), else: tc.name

    Logger.debug("Tool start session=#{state.session_id} tool=#{tc.name}")
    Emitter.broadcast(state, {:tool_execution_start, tc.name, tc.call_id, tc.arguments, meta})

    emit = fn chunk -> Emitter.broadcast(state, {:tool_output, tc.name, chunk}) end
    ctx = Map.merge(state.tool_context, %{emit: emit, call_id: tc.call_id})

    task =
      Task.Supervisor.async_nolink(state.tool_supervisor, fn ->
        :proc_lib.set_label("tool:#{tc.name}")
        execute_tool(tool_mod, tc.arguments, ctx)
      end)

    %{state | pending_tool_tasks: Map.put(state.pending_tool_tasks, task.ref, {task, tc})}
  end

  @spec finalize(State.t()) :: {:next_turn, State.t()}
  defp finalize(%State{} = state) do
    messages =
      state.tool_results
      |> Enum.reverse()
      |> Enum.map(fn
        {tc, {:ok, output}} -> Opal.Message.tool_result(tc.call_id, to_text(output))
        {tc, {:error, reason}} -> Opal.Message.tool_result(tc.call_id, to_text(reason), true)
      end)

    state =
      state
      |> State.append_messages(messages)
      |> Map.merge(%{pending_tool_tasks: %{}, tool_context: nil, tool_results: []})

    {:next_turn, state}
  end

  @spec apply_effect(term(), State.t()) :: {result(), State.t()}
  defp apply_effect({:load_skill, skill_name}, %State{} = state) do
    cond do
      skill_name in state.active_skills ->
        {{:ok, "Skill '#{skill_name}' is already loaded."}, state}

      skill = Enum.find(state.available_skills, &(&1.name == skill_name)) ->
        msg = %Opal.Message{
          id: "skill:#{skill_name}",
          role: :user,
          content:
            "[System] Skill '#{skill.name}' activated. Instructions:\n\n#{skill.instructions}"
        }

        state =
          State.append_message(%{state | active_skills: [skill_name | state.active_skills]}, msg)

        Emitter.broadcast(state, {:skill_loaded, skill_name, skill.description})
        {{:ok, "Skill '#{skill_name}' loaded. Its instructions are now in your context."}, state}

      true ->
        available = Enum.map_join(state.available_skills, ", ", & &1.name)
        {{:error, "Skill '#{skill_name}' not found. Available: #{available}"}, state}
    end
  end

  @spec mcp_module?(module()) :: boolean()
  defp mcp_module?(mod),
    do: mod |> Atom.to_string() |> String.starts_with?("Elixir.Opal.MCP.Tool.")

  @spec to_text(term()) :: String.t()
  defp to_text(output) when is_binary(output), do: output

  defp to_text(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      {:error, _} -> inspect(output)
    end
  end
end
