defmodule Opal.Agent.ToolRunner do
  @moduledoc """
  Tool execution orchestration for the Agent loop.

  Spawns all tool calls in a batch concurrently under the session's
  `Task.Supervisor`. Each tool runs in its own task process with crash
  isolation and streaming output support. When every task in the batch
  completes (or crashes), results are collected and the next agent turn
  begins.
  """

  require Logger
  alias Opal.Agent.State

  @doc """
  Starts parallel execution of a batch of tool calls.

  All tool calls are spawned concurrently as supervised tasks. The agent
  remains responsive to abort, steer, and other messages while tools run.
  Results are collected as each task completes; when all are done,
  `finalize_tool_batch/1` continues to the next turn.
  """
  @spec start_tool_execution([map()], State.t()) :: State.t()
  def start_tool_execution(tool_calls, %State{} = state) do
    context = build_tool_context(state)

    state = %{
      state
      | status: :executing_tools,
        pending_tool_tasks: %{},
        tool_results: [],
        tool_context: context
    }

    # Spawn all tool calls concurrently
    Enum.reduce(tool_calls, state, &spawn_tool_task(&1, &2))
  end

  @doc """
  Handles a completed tool task. Records the result and finalizes
  the batch when all tasks are done.
  """
  @spec handle_tool_result(
          reference(),
          map(),
          {:ok, term()} | {:error, term()} | {:effect, term()},
          State.t()
        ) ::
          State.t()
  def handle_tool_result(ref, tc, {:effect, effect}, %State{} = state) do
    {result, state} = apply_effect(effect, state)
    handle_tool_result(ref, tc, result, state)
  end

  def handle_tool_result(ref, tc, result, %State{} = state) do
    broadcast(state, {:tool_execution_end, tc.name, tc.call_id, result})

    state = %{
      state
      | tool_results: [{tc, result} | state.tool_results],
        pending_tool_tasks: Map.delete(state.pending_tool_tasks, ref)
    }

    if map_size(state.pending_tool_tasks) == 0 do
      finalize_tool_batch(state)
    else
      state
    end
  end

  @doc """
  Finalizes the tool execution batch and continues to the next agent turn.

  Converts tool results to messages, handles skill auto-loading, checks for
  steering, and starts the next turn.
  """
  @spec finalize_tool_batch(State.t()) :: State.t()
  def finalize_tool_batch(%State{} = state) do
    results = Enum.reverse(state.tool_results)

    tool_result_messages =
      Enum.map(results, fn
        {tc, {:ok, output}} ->
          Opal.Message.tool_result(tc.call_id, tool_output_text(output))

        {tc, {:error, reason}} ->
          Opal.Message.tool_result(tc.call_id, tool_output_text(reason), true)
      end)

    state =
      state
      |> append_messages(tool_result_messages)
      |> Map.merge(%{pending_tool_tasks: %{}, tool_context: nil, tool_results: []})

    Opal.Agent.run_turn(state)
  end

  @doc """
  Cancels all in-flight tool tasks and resets execution state.
  """
  @spec cancel_all_tasks(State.t()) :: State.t()
  def cancel_all_tasks(%State{pending_tool_tasks: tasks} = state) when map_size(tasks) == 0 do
    state
  end

  def cancel_all_tasks(%State{pending_tool_tasks: tasks} = state) do
    Enum.each(tasks, fn {_ref, {task, _tc}} ->
      Task.shutdown(task, :brutal_kill)
    end)

    %{
      state
      | pending_tool_tasks: %{},
        tool_results: [],
        tool_context: nil
    }
  end

  @doc """
  Builds the shared context map passed to every tool execution.

  Creates a context map containing working directory, session info,
  configuration, and optional question handler for sub-agents.
  """
  @spec build_tool_context(State.t()) :: map()
  def build_tool_context(%State{} = state) do
    %{
      working_dir: state.working_dir,
      session_id: state.session_id,
      config: state.config,
      agent_pid: self(),
      agent_state: state
    }
    |> put_if(:question_handler, state.question_handler)
  end

  @doc """
  Executes a single tool, catching any exceptions.

  Returns {:ok, result} on success or {:error, reason} on failure.
  """
  @spec execute_single_tool(module() | nil, map(), map()) :: {:ok, term()} | {:error, String.t()}
  def execute_single_tool(nil, _args, _context) do
    {:error, "Tool not found"}
  end

  def execute_single_tool(tool_mod, args, context) do
    tool_mod.execute(args, context)
  rescue
    e ->
      Logger.error("Tool #{inspect(tool_mod)} raised: #{Exception.message(e)}")
      {:error, "Tool raised an exception: #{Exception.message(e)}"}
  end

  @doc """
  Finds a tool module by name from the list of available tools.
  """
  @spec find_tool_module(String.t(), [module()]) :: module() | nil
  def find_tool_module(name, tools), do: Enum.find(tools, &(&1.name() == name))

  @doc """
  Returns the list of active tools based on config and available skills.
  """
  @spec active_tools(State.t()) :: [module()]
  def active_tools(%State{
        tools: tools,
        disabled_tools: disabled_tools,
        config: config,
        available_skills: skills
      }) do
    disabled = MapSet.new(disabled_tools)

    # Feature gates: {disabled?, predicate}. Only active gates reject tools.
    gates = [
      {not config.features.sub_agents.enabled, &(&1 == Opal.Tool.SubAgent)},
      {not config.features.mcp.enabled, &mcp_tool_module?/1},
      {not config.features.debug.enabled, &(&1 == Opal.Tool.Debug)},
      {not (config.features.skills.enabled and skills != []), &(&1 == Opal.Tool.UseSkill)}
    ]

    rejectors = for {true, pred} <- gates, do: pred

    Enum.reject(tools, fn tool ->
      MapSet.member?(disabled, tool.name()) or Enum.any?(rejectors, & &1.(tool))
    end)
  end

  @doc """
  Processes pending steering messages if any exist.

  If steering messages are pending, injects them as user messages
  and returns updated state.
  """
  @spec check_for_steering(State.t()) :: State.t()
  def check_for_steering(%State{pending_steers: []} = state), do: state

  def check_for_steering(%State{pending_steers: steers} = state) do
    state =
      Enum.reduce(steers, state, fn text, acc ->
        Logger.debug("Steering message received: #{String.slice(text, 0, 50)}...")
        append_message(acc, Opal.Message.user(text))
      end)

    %{state | pending_steers: []}
  end

  @doc """
  Returns a path relative to working_dir, or the path unchanged if
  it's already relative or outside the working dir.
  """
  @spec make_relative(String.t(), String.t()) :: String.t()
  def make_relative(path, working_dir) do
    expanded = Path.expand(path, working_dir)

    case Path.relative_to(expanded, Path.expand(working_dir)) do
      ^expanded -> path
      relative -> relative
    end
  end

  # -- Private --

  # Spawns a single tool as a supervised task and tracks it in pending_tool_tasks.
  defp spawn_tool_task(tc, %State{} = state) do
    tool_mod = find_tool_module(tc.name, active_tools(state))
    meta = if tool_mod, do: Opal.Tool.meta(tool_mod, tc.arguments), else: tc.name

    Logger.debug(
      "Tool start session=#{state.session_id} tool=#{tc.name} args=#{inspect(tc.arguments, limit: 5, printable_limit: 200)}"
    )

    broadcast(state, {:tool_execution_start, tc.name, tc.call_id, tc.arguments, meta})

    emit = fn chunk -> broadcast(state, {:tool_output, tc.name, chunk}) end
    ctx = state.tool_context |> Map.put(:emit, emit) |> Map.put(:call_id, tc.call_id)

    task =
      Task.Supervisor.async_nolink(state.tool_supervisor, fn ->
        :proc_lib.set_label("tool:#{tc.name}")
        execute_single_tool(tool_mod, tc.arguments, ctx)
      end)

    %{state | pending_tool_tasks: Map.put(state.pending_tool_tasks, task.ref, {task, tc})}
  end

  defp broadcast(%State{} = state, event), do: Opal.Agent.EventLog.broadcast(state, event)

  defp append_message(%State{session: nil} = state, msg) do
    %{state | messages: [msg | state.messages]}
  end

  defp append_message(%State{session: session} = state, msg) do
    Opal.Session.append(session, msg)
    %{state | messages: [msg | state.messages]}
  end

  defp append_messages(%State{session: nil} = state, msgs) do
    %{state | messages: Enum.reverse(msgs) ++ state.messages}
  end

  defp append_messages(%State{session: session} = state, msgs) do
    Opal.Session.append_many(session, msgs)
    %{state | messages: Enum.reverse(msgs) ++ state.messages}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # Applies a tool effect to the agent state, returning {result, state}.
  # Effects let tools declare state mutations without re-entrant calls.
  @spec apply_effect(term(), State.t()) :: {{:ok, String.t()} | {:error, String.t()}, State.t()}
  defp apply_effect({:load_skill, skill_name}, %State{} = state) do
    if skill_name in state.active_skills do
      {{:ok, "Skill '#{skill_name}' is already loaded."}, state}
    else
      case Enum.find(state.available_skills, &(&1.name == skill_name)) do
        nil ->
          {{:error,
            "Skill '#{skill_name}' not found. Available: #{Enum.map_join(state.available_skills, ", ", & &1.name)}"},
           state}

        skill ->
          skill_msg = %Opal.Message{
            id: "skill:#{skill_name}",
            role: :user,
            content:
              "[System] Skill '#{skill.name}' activated. Instructions:\n\n#{skill.instructions}"
          }

          new_active = [skill_name | state.active_skills]
          state = append_message(%{state | active_skills: new_active}, skill_msg)
          broadcast(state, {:skill_loaded, skill_name, skill.description})

          {{:ok, "Skill '#{skill_name}' loaded. Its instructions are now in your context."},
           state}
      end
    end
  end

  defp mcp_tool_module?(tool_mod) when is_atom(tool_mod) do
    tool_mod |> Atom.to_string() |> String.starts_with?("Elixir.Opal.MCP.Tool.")
  end

  defp tool_output_text(output) when is_binary(output), do: output

  defp tool_output_text(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      {:error, _} -> inspect(output)
    end
  end
end
