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

  # File-modifying tools whose "path" argument should trigger skill globs.
  @file_tools ~w(write_file edit_file)

  @doc """
  Starts parallel execution of a batch of tool calls.

  All tool calls are spawned concurrently as supervised tasks. The GenServer
  remains responsive to abort, steer, and other messages while tools run.
  Results are collected as each task completes; when all are done,
  `finalize_tool_batch/1` continues to the next turn.

  Returns `{:noreply, state}` with status set to `:executing_tools`.
  """
  @spec start_tool_execution([map()], State.t()) :: {:noreply, State.t()}
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
    state = Enum.reduce(tool_calls, state, &spawn_tool_task(&1, &2))

    {:noreply, state}
  end

  @doc """
  Handles a completed tool task. Records the result and finalizes
  the batch when all tasks are done.
  """
  @spec handle_tool_result(reference(), map(), {:ok, term()} | {:error, term()}, State.t()) ::
          {:noreply, State.t()}
  def handle_tool_result(ref, tc, result, %State{} = state) do
    broadcast(state, {:tool_execution_end, tc.name, tc.call_id, result})

    state = %{
      state
      | tool_results: state.tool_results ++ [{tc, result}],
        pending_tool_tasks: Map.delete(state.pending_tool_tasks, ref)
    }

    if map_size(state.pending_tool_tasks) == 0 do
      finalize_tool_batch(state)
    else
      {:noreply, state}
    end
  end

  @doc """
  Finalizes the tool execution batch and continues to the next agent turn.

  Converts tool results to messages, handles skill auto-loading, checks for
  steering, and starts the next turn.
  """
  @spec finalize_tool_batch(State.t()) :: {:noreply, State.t()}
  def finalize_tool_batch(%State{} = state) do
    results = state.tool_results

    tool_result_messages =
      Enum.map(results, fn {tc, result} ->
        case result do
          {:ok, output} -> Opal.Message.tool_result(tc.call_id, tool_output_text(output))
          {:error, reason} -> Opal.Message.tool_result(tc.call_id, tool_output_text(reason), true)
        end
      end)

    state = append_messages(state, tool_result_messages)
    state = maybe_auto_load_skills(results, state)
    state = check_for_steering(state)
    state = %{state | pending_tool_tasks: %{}, tool_context: nil, tool_results: []}

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
    ctx = %{
      working_dir: state.working_dir,
      session_id: state.session_id,
      config: state.config,
      agent_pid: self(),
      agent_state: state
    }

    if state.question_handler do
      Map.put(ctx, :question_handler, state.question_handler)
    else
      ctx
    end
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
  def find_tool_module(name, tools) do
    Enum.find(tools, fn tool_mod ->
      tool_mod.name() == name
    end)
  end

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

    tools
    |> Enum.reject(&MapSet.member?(disabled, &1.name()))
    |> then(fn t ->
      if config.features.sub_agents.enabled,
        do: t,
        else: Enum.reject(t, &(&1 == Opal.Tool.SubAgent))
    end)
    |> then(fn t ->
      if config.features.mcp.enabled, do: t, else: Enum.reject(t, &mcp_tool_module?/1)
    end)
    |> then(fn t ->
      if config.features.debug.enabled,
        do: t,
        else: Enum.reject(t, &(&1 == Opal.Tool.Debug))
    end)
    |> then(fn t ->
      if config.features.skills.enabled and skills != [],
        do: t,
        else: Enum.reject(t, &(&1 == Opal.Tool.UseSkill))
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

  @doc """
  After a batch of tool calls, checks whether any file-modifying tool
  touched a path that matches an inactive skill's globs.
  """
  @spec maybe_auto_load_skills([{map(), term()}], State.t()) :: State.t()
  def maybe_auto_load_skills(_results, %State{available_skills: []} = state), do: state

  def maybe_auto_load_skills(
        _results,
        %State{config: %{features: %{skills: %{enabled: false}}}} = state
      ),
      do: state

  def maybe_auto_load_skills(results, %State{} = state) do
    # Collect relative paths from successful file-modifying tool calls
    touched_paths =
      results
      |> Enum.flat_map(fn
        {%{name: name, arguments: %{"path" => path}}, {:ok, _}} when name in @file_tools ->
          [make_relative(path, state.working_dir)]

        _ ->
          []
      end)

    if touched_paths == [] do
      state
    else
      # Find skills with matching globs that aren't already active
      matching =
        state.available_skills
        |> Enum.reject(&(&1.name in state.active_skills))
        |> Enum.filter(fn skill ->
          Enum.any?(touched_paths, &Opal.Skill.matches_path?(skill, &1))
        end)

      Enum.reduce(matching, state, fn skill, acc ->
        Logger.debug("Auto-loading skill '#{skill.name}' (glob matched)")

        skill_msg = %Opal.Message{
          id: "skill:#{skill.name}",
          role: :user,
          content:
            "[System] Skill '#{skill.name}' auto-activated (file matched glob). Instructions:\n\n#{skill.instructions}"
        }

        new_active = [skill.name | acc.active_skills]
        acc = append_message(%{acc | active_skills: new_active}, skill_msg)
        broadcast(acc, {:skill_loaded, skill.name, skill.description})
        acc
      end)
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

  defp mcp_tool_module?(tool_mod) when is_atom(tool_mod) do
    tool_mod
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Opal.MCP.Tool.")
  end

  defp tool_output_text(output) when is_binary(output), do: output

  defp tool_output_text(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      {:error, _} -> inspect(output)
    end
  end
end
