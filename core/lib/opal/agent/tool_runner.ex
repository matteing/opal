defmodule Opal.Agent.ToolRunner do
  @moduledoc """
  Tool execution orchestration for the Agent loop.

  Handles sequential execution of tool calls with steering support, task supervision,
  and auto-loading of skills based on file modifications. Each tool runs under the
  session's Task.Supervisor with crash isolation and streaming output support.
  """

  require Logger
  alias Opal.Agent.State

  # File-modifying tools whose "path" argument should trigger skill globs.
  @file_tools ~w(write_file edit_file)

  @doc """
  Starts non-blocking execution of a batch of tool calls.

  Instead of executing tools synchronously, this function sets up the state
  for sequential tool execution via handle_info callbacks. This allows the
  GenServer to remain responsive to abort, steer, and other messages while
  tools are running.

  Returns {:noreply, state} with status set to :executing_tools.
  """
  @spec start_tool_execution([map()], State.t()) :: {:noreply, State.t()}
  def start_tool_execution(tool_calls, %State{} = state) do
    context = build_tool_context(state)
    state = %{state | 
      status: :executing_tools,
      remaining_tool_calls: tool_calls,
      tool_results: [],
      tool_context: context
    }
    dispatch_next_tool(state)
  end

  @doc """
  Dispatches the next tool in the queue or finalizes if all tools are done.

  This function is called from agent.ex handle_info callbacks and must be public.
  Checks for steering before starting the next tool, allowing user interruption.
  """
  @spec dispatch_next_tool(State.t()) :: {:noreply, State.t()}
  def dispatch_next_tool(%State{remaining_tool_calls: []} = state) do
    # All tools done — finalize
    finalize_tool_batch(state)
  end

  def dispatch_next_tool(%State{remaining_tool_calls: [tc | rest]} = state) do
    # Check for steering before starting next tool
    state = drain_mailbox_steers(state)
    
    if state.pending_steers != [] do
      # Skip remaining tools
      skipped = Enum.map([tc | rest], fn tc -> 
        broadcast(state, {:tool_skipped, tc.name, tc.call_id})
        {tc, {:error, "Skipped — user sent a steering message"}} 
      end)
      state = %{state | 
        remaining_tool_calls: [],
        tool_results: state.tool_results ++ skipped
      }
      finalize_tool_batch(state)
    else
      tool_mod = find_tool_module(tc.name, active_tools(state))
      meta = if tool_mod, do: Opal.Tool.meta(tool_mod, tc.arguments), else: tc.name
      
      Logger.debug("Tool start session=#{state.session_id} tool=#{tc.name} args=#{inspect(tc.arguments, limit: 5, printable_limit: 200)}")
      broadcast(state, {:tool_execution_start, tc.name, tc.call_id, tc.arguments, meta})
      
      emit = fn chunk -> broadcast(state, {:tool_output, tc.name, chunk}) end
      ctx = state.tool_context |> Map.put(:emit, emit) |> Map.put(:call_id, tc.call_id)
      
      task = Task.Supervisor.async_nolink(state.tool_supervisor, fn ->
        :proc_lib.set_label("tool:#{tc.name}")
        execute_single_tool(tool_mod, tc.arguments, ctx)
      end)
      
      state = %{state | 
        remaining_tool_calls: rest,
        pending_tool_task: {task.ref, tc}
      }
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
    tool_result_messages = Enum.map(results, fn {tc, result} ->
      case result do
        {:ok, output} -> Opal.Message.tool_result(tc.call_id, output)
        {:error, reason} -> Opal.Message.tool_result(tc.call_id, reason, true)
      end
    end)
    
    state = append_messages(state, tool_result_messages)
    state = maybe_auto_load_skills(results, state)
    state = check_for_steering(state)
    state = %{state | pending_tool_task: nil, tool_context: nil, tool_results: []}
    
    Opal.Agent.run_turn(state)
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
  Legacy blocking tool execution for compatibility.
  
  This is kept as execute_tool_calls_sync in case any tests depend on it.
  """
  @spec execute_tool_calls_sync([map()], State.t()) :: term()
  def execute_tool_calls_sync(tool_calls, %State{} = state) do
    context = build_tool_context(state)

    {results, state} =
      Enum.reduce(tool_calls, {[], state}, fn tc, {acc, st} ->
        # Drain pending steer casts from the process mailbox before each tool
        st = drain_mailbox_steers(st)

        if st.pending_steers != [] do
          # User sent a steering message — skip this and all remaining tools.
          # The cascade works because once pending_steers is non-empty,
          # every subsequent iteration hits this branch too.
          broadcast(st, {:tool_skipped, tc.name, tc.call_id})
          result = {tc, {:error, "Skipped — user sent a steering message"}}
          {[result | acc], st}
        else
          result = execute_single_tool_supervised_sync(tc, st, context)
          {[result | acc], st}
        end
      end)

    results = Enum.reverse(results)

    # Convert results to tool_result messages
    tool_result_messages =
      Enum.map(results, fn {tc, result} ->
        case result do
          {:ok, output} ->
            Opal.Message.tool_result(tc.call_id, output)

          {:error, reason} ->
            Opal.Message.tool_result(tc.call_id, reason, true)
        end
      end)

    state = append_messages(state, tool_result_messages)

    # Auto-load skills whose globs match files touched by this batch
    state = maybe_auto_load_skills(results, state)

    # Process any steers that arrived during the last tool execution
    state = check_for_steering(state)

    # Start next turn by calling the main agent function
    Opal.Agent.run_turn(state)
  end

  @doc """
  Legacy blocking single tool execution with Task.await.
  
  Kept for compatibility with execute_tool_calls_sync.
  """
  @spec execute_single_tool_supervised_sync(map(), State.t(), map()) :: {map(), term()}
  def execute_single_tool_supervised_sync(tc, %State{} = state, context) do
    tool_mod = find_tool_module(tc.name, active_tools(state))
    meta = if tool_mod, do: Opal.Tool.meta(tool_mod, tc.arguments), else: tc.name

    Logger.debug("Tool start session=#{state.session_id} tool=#{tc.name} args=#{inspect(tc.arguments, limit: 5, printable_limit: 200)}")
    broadcast(state, {:tool_execution_start, tc.name, tc.call_id, tc.arguments, meta})

    started_at = System.monotonic_time(:millisecond)

    # Provide an emit callback so tools can stream output chunks
    emit = fn chunk -> broadcast(state, {:tool_output, tc.name, chunk}) end
    ctx = context |> Map.put(:emit, emit) |> Map.put(:call_id, tc.call_id)

    result =
      Task.Supervisor.async_nolink(state.tool_supervisor, fn ->
        :proc_lib.set_label("tool:#{tc.name}")
        execute_single_tool(tool_mod, tc.arguments, ctx)
      end)
      |> Task.await(:infinity)

    elapsed = System.monotonic_time(:millisecond) - started_at
    Logger.debug("Tool done session=#{state.session_id} tool=#{tc.name} elapsed=#{elapsed}ms result=#{result_tag(result)}")
    broadcast(state, {:tool_execution_end, tc.name, tc.call_id, result})

    {tc, result}
  catch
    # Task.await/2 re-raises EXIT signals from crashed tasks. We catch
    # them here so a single tool crash doesn't bring down the agent —
    # the error is recorded as a tool_result and the LLM decides how
    # to proceed.
    :exit, reason ->
      error_msg = "Tool execution crashed: #{inspect(reason)}"
      Logger.error(error_msg)
      broadcast(state, {:tool_execution_end, tc.name, tc.call_id, {:error, error_msg}})
      {tc, {:error, error_msg}}
  end

  @doc """
  Selectively receives :steer GenServer casts from the process mailbox.

  Uses a zero timeout so it returns immediately when there are no pending 
  steers — this is the mechanism that lets us check for user redirection 
  between sequential tool calls.
  """
  @spec drain_mailbox_steers(State.t()) :: State.t()
  def drain_mailbox_steers(state) do
    receive do
      {:"$gen_cast", {:steer, text}} ->
        state = %{state | pending_steers: state.pending_steers ++ [text]}
        drain_mailbox_steers(state)
    after
      0 -> state
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
  def active_tools(%State{tools: tools, config: config, available_skills: skills}) do
    tools
    |> then(fn t ->
      if config.features.sub_agents.enabled, do: t, else: Enum.reject(t, &(&1 == Opal.Tool.SubAgent))
    end)
    |> then(fn t ->
      if skills != [], do: t, else: Enum.reject(t, &(&1 == Opal.Tool.UseSkill))
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
    state = Enum.reduce(steers, state, fn text, acc ->
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
          content: "[System] Skill '#{skill.name}' auto-activated (file matched glob). Instructions:\n\n#{skill.instructions}"
        }

        new_active = [skill.name | acc.active_skills]
        acc = append_message(%{acc | active_skills: new_active}, skill_msg)
        broadcast(acc, {:skill_loaded, skill.name, skill.description})
        acc
      end)
    end
  end

  # Private helper functions

  defp result_tag({:ok, _}), do: "ok"
  defp result_tag({:error, _}), do: "error"
  defp result_tag(_), do: "unknown"

  defp broadcast(%State{session_id: session_id}, event) do
    Opal.Events.broadcast(session_id, event)
  end

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
end