defmodule Opal.Agent do
  @moduledoc """
  `:gen_statem` implementing the core agent loop.

  Manages the lifecycle of an agent session: receiving user prompts, streaming
  LLM responses via a provider, executing tool calls concurrently, and looping
  until the model produces a final text response with no tool calls.

  ## Usage

      {:ok, pid} = Opal.Agent.start_link(
        session_id: "session-abc",
        system_prompt: "You are a coding assistant.",
        model: %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5"},
        tools: [Opal.Tool.Read, Opal.Tool.Write],
        working_dir: "/path/to/project"
      )

      :ok = Opal.Agent.prompt(pid, "List all files")

  Events are broadcast via `Opal.Events` using the session ID, so any
  subscriber can observe the full lifecycle in real time.
  """

  @behaviour :gen_statem
  require Logger
  alias Opal.Agent.State

  # --- Public API ---

  @doc """
  Starts the agent state machine.

  ## Options

    * `:session_id` — unique string identifier for this session (required)
    * `:system_prompt` — the system prompt string (default: `""`)
    * `:model` — an `Opal.Model.t()` struct (required)
    * `:tools` — list of modules implementing `Opal.Tool` (default: `[]`)
    * `:working_dir` — base directory for tool execution (required)
    * `:provider` — module implementing `Opal.Provider` (default: `Opal.Provider.Copilot`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Sends an asynchronous user prompt to the agent.

  Appends a user message, sets status to `:running`, and begins a new LLM turn.
  Returns `:ok` immediately.
  """
  @spec prompt(GenServer.server(), String.t()) :: :ok
  def prompt(agent, text) when is_binary(text) do
    :gen_statem.cast(agent, {:prompt, text})
  end

  @doc """
  Injects a steering message into the agent.

  If the agent is idle, this behaves like `prompt/2`. If the agent is running
  or streaming, the steering message is queued in the GenServer mailbox and
  picked up between tool executions.
  """
  @spec steer(GenServer.server(), String.t()) :: :ok
  def steer(agent, text) when is_binary(text) do
    :gen_statem.cast(agent, {:steer, text})
  end

  @doc """
  Sends a follow-up prompt to the agent. Convenience alias for `prompt/2`.
  """
  @spec follow_up(GenServer.server(), String.t()) :: :ok
  def follow_up(agent, text) when is_binary(text) do
    :gen_statem.cast(agent, {:prompt, text})
  end

  @doc """
  Aborts the current agent run.

  If streaming, cancels the response. Sets status to `:idle`.
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(agent) do
    :gen_statem.cast(agent, :abort)
  end

  @doc """
  Returns the current agent state synchronously.
  """
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(agent) do
    :gen_statem.call(agent, :get_state)
  end

  @spec get_context(GenServer.server()) :: [Opal.Message.t()]
  def get_context(agent) do
    :gen_statem.call(agent, :get_context)
  end

  @spec set_model(GenServer.server(), Opal.Model.t()) :: :ok
  def set_model(agent, %Opal.Model{} = model) do
    :gen_statem.call(agent, {:set_model, model})
  end

  @spec set_provider(GenServer.server(), module()) :: :ok
  def set_provider(agent, provider_module) when is_atom(provider_module) do
    :gen_statem.call(agent, {:set_provider, provider_module})
  end

  @spec sync_messages(GenServer.server(), [Opal.Message.t()]) :: :ok
  def sync_messages(agent, messages) when is_list(messages) do
    :gen_statem.call(agent, {:sync_messages, messages})
  end

  @spec configure(GenServer.server(), map()) :: :ok
  def configure(agent, attrs) when is_map(attrs) do
    :gen_statem.call(agent, {:configure, attrs})
  end

  @doc """
  Loads a skill by name into the agent's active context.

  Returns `{:ok, skill_name}` if loaded, `{:already_loaded, skill_name}` if
  already active, or `{:error, reason}` if the skill is not found.
  """
  @spec load_skill(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:already_loaded, String.t()} | {:error, String.t()}
  def load_skill(agent, skill_name) do
    :gen_statem.call(agent, {:load_skill, skill_name})
  end

  @doc """
  Returns the current platform as `:linux`, `:macos`, or `:windows`.
  """
  @spec platform(GenServer.server()) :: :linux | :macos | :windows
  def platform(_agent) do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      {:win32, _} -> :windows
    end
  end

  # --- :gen_statem callbacks ---

  @impl :gen_statem
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Registry.register(Opal.Registry, {:agent, session_id}, nil)
    :proc_lib.set_label("agent:#{session_id}")

    model = Keyword.fetch!(opts, :model)
    working_dir = Keyword.fetch!(opts, :working_dir)
    config = Keyword.get(opts, :config, Opal.Config.new())
    provider = Keyword.get(opts, :provider, config.provider)

    Logger.debug(
      "Agent init session=#{session_id} model=#{model.provider}:#{model.id} dir=#{working_dir}"
    )

    # Resolve session: the SessionServer passes session: true/false,
    # and the Session process is registered via Opal.Registry.
    session_pid =
      case Keyword.get(opts, :session) do
        true ->
          case Registry.lookup(Opal.Registry, {:session, session_id}) do
            [{pid, _}] -> pid
            [] -> nil
          end

        pid when is_pid(pid) ->
          pid

        _ ->
          nil
      end

    # Discover project context files and skills
    {context, context_files, available_skills} =
      if config.features.context.enabled or config.features.skills.enabled do
        ctx_files =
          if config.features.context.enabled do
            Opal.Context.discover_context(working_dir,
              filenames: config.features.context.filenames
            )
          else
            []
          end

        skills =
          if config.features.skills.enabled do
            Opal.Context.discover_skills(working_dir,
              extra_dirs: config.features.skills.extra_dirs
            )
          else
            []
          end

        context_str =
          Opal.Context.build_context(working_dir,
            filenames:
              if(config.features.context.enabled, do: config.features.context.filenames, else: [])
          )

        file_paths = Enum.map(ctx_files, & &1.path)
        {context_str, file_paths, skills}
      else
        {"", [], []}
      end

    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    mcp_supervisor = Keyword.get(opts, :mcp_supervisor)

    # Discover MCP tools, passing native tool names for collision detection
    base_tools = Keyword.get(opts, :tools, [])
    native_names = base_tools |> Enum.map(& &1.name()) |> MapSet.new()
    mcp_tools = discover_mcp_tools(mcp_servers, native_names)

    state = %State{
      session_id: session_id,
      system_prompt: Keyword.get(opts, :system_prompt, ""),
      model: model,
      tools: base_tools ++ mcp_tools,
      disabled_tools: Keyword.get(opts, :disabled_tools, []),
      working_dir: working_dir,
      config: config,
      provider: provider,
      session: session_pid,
      tool_supervisor: Keyword.fetch!(opts, :tool_supervisor),
      sub_agent_supervisor: Keyword.get(opts, :sub_agent_supervisor),
      mcp_supervisor: mcp_supervisor,
      mcp_servers: mcp_servers,
      context: context,
      context_files: context_files,
      available_skills: available_skills,
      active_skills: [],
      question_handler: Keyword.get(opts, :question_handler),
      token_usage: %{
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        context_window: Opal.Models.context_window(model),
        current_context_tokens: 0
      }
    }

    # On restart, reload conversation history from the surviving Session process
    state =
      if session_pid && Opal.Session.current_id(session_pid) do
        messages = Opal.Session.get_path(session_pid)
        Logger.info("Agent recovered session=#{session_id} messages=#{length(messages)}")
        broadcast(state, {:agent_recovered})
        %{state | messages: Enum.reverse(messages)}
      else
        state
      end

    Opal.Agent.EventLog.clear(session_id)

    tools_str = base_tools |> Enum.map(& &1.name()) |> Enum.join(", ")

    Logger.debug(
      "Agent ready session=#{session_id} tools=[#{tools_str}] mcp_tools=#{length(mcp_tools)} skills=#{length(available_skills)}"
    )

    # Emit context discovered event if any context files were found
    if context_files != [] do
      broadcast(state, {:context_discovered, context_files})
    end

    {:ok, :idle, state}
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  def idle(event_type, event_content, %State{} = state) do
    dispatch_state_event(event_type, event_content, %{state | status: :idle})
  end

  def running(event_type, event_content, %State{} = state) do
    dispatch_state_event(event_type, event_content, %{state | status: :running})
  end

  def streaming(event_type, event_content, %State{} = state) do
    dispatch_state_event(event_type, event_content, %{state | status: :streaming})
  end

  def executing_tools(event_type, event_content, %State{} = state) do
    dispatch_state_event(event_type, event_content, %{state | status: :executing_tools})
  end

  defp dispatch_state_event(:enter, _old_state, state), do: {:keep_state, state}

  defp dispatch_state_event({:call, from}, message, state) do
    case handle_call(message, from, state) do
      {:reply, reply, new_state} ->
        {:next_state, Opal.Agent.Reducer.state_name(new_state), new_state,
         [{:reply, from, reply}]}
    end
  end

  defp dispatch_state_event(:cast, message, state) do
    handle_cast(message, state)
    |> Opal.Agent.Effects.from_legacy()
  end

  defp dispatch_state_event(:info, message, state) do
    handle_info(message, state)
    |> Opal.Agent.Effects.from_legacy()
  end

  defp dispatch_state_event(_event_type, _event_content, state), do: {:keep_state, state}

  def handle_cast({:prompt, text}, %State{status: :idle} = state) do
    Logger.debug(
      "Prompt received session=#{state.session_id} len=#{String.length(text)} chars=\"#{String.slice(text, 0, 80)}\""
    )

    user_msg = Opal.Message.user(text)
    state = append_message(state, user_msg)
    state = %{state | status: :running}
    broadcast(state, {:agent_start})
    run_turn_internal(state)
  end

  def handle_cast({:prompt, text}, %State{status: status} = state)
      when status in [:running, :streaming, :executing_tools] do
    Logger.debug(
      "Prompt queued while busy session=#{state.session_id} status=#{status} len=#{String.length(text)}"
    )

    {:noreply, %{state | pending_steers: state.pending_steers ++ [text]}}
  end

  def handle_cast({:steer, text}, %State{status: :idle} = state) do
    # When idle, steering acts like a prompt
    user_msg = Opal.Message.user(text)
    state = append_message(state, user_msg)
    state = %{state | status: :running}
    broadcast(state, {:agent_start})
    run_turn_internal(state)
  end

  def handle_cast({:steer, text}, %State{status: status} = state)
      when status in [:running, :streaming, :executing_tools] do
    # Queue steering message — drained between tool executions
    {:noreply, %{state | pending_steers: state.pending_steers ++ [text]}}
  end

  def handle_cast(:abort, %State{} = state) do
    state = cancel_streaming(state)
    state = cancel_tool_execution(state)
    broadcast(state, {:agent_abort})
    {:noreply, %{state | status: :idle}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_context, _from, state) do
    {:reply, build_messages(state), state}
  end

  def handle_call({:set_model, %Opal.Model{} = model}, _from, state) do
    Logger.debug(
      "Model changed session=#{state.session_id} from=#{state.model.id} to=#{model.id}"
    )

    {:reply, :ok, %{state | model: model}}
  end

  def handle_call({:set_provider, provider_module}, _from, state) when is_atom(provider_module) do
    Logger.debug("Provider changed session=#{state.session_id} to=#{inspect(provider_module)}")
    {:reply, :ok, %{state | provider: provider_module}}
  end

  def handle_call({:sync_messages, messages}, _from, state) do
    Logger.debug("Messages synced session=#{state.session_id} count=#{length(messages)}")
    {:reply, :ok, %{state | messages: Enum.reverse(messages)}}
  end

  def handle_call({:configure, attrs}, _from, %State{} = state) do
    state =
      state
      |> maybe_update_feature(:sub_agents, get_in(attrs, [:features, :sub_agents]))
      |> maybe_update_feature(:skills, get_in(attrs, [:features, :skills]))
      |> maybe_update_feature(:mcp, get_in(attrs, [:features, :mcp]))
      |> maybe_update_feature(:debug, get_in(attrs, [:features, :debug]))
      |> maybe_update_enabled_tools(Map.get(attrs, :enabled_tools))

    {:reply, :ok, state}
  end

  def handle_call({:load_skill, skill_name}, _from, %State{} = state) do
    if skill_name in state.active_skills do
      {:reply, {:already_loaded, skill_name}, state}
    else
      case Enum.find(state.available_skills, &(&1.name == skill_name)) do
        nil ->
          {:reply,
           {:error,
            "Skill '#{skill_name}' not found. Available: #{Enum.map_join(state.available_skills, ", ", & &1.name)}"},
           state}

        skill ->
          # Inject instructions as a conversation message (ages out during compaction)
          skill_msg = %Opal.Message{
            id: "skill:#{skill_name}",
            role: :user,
            content:
              "[System] Skill '#{skill.name}' activated. Instructions:\n\n#{skill.instructions}"
          }

          new_active = [skill_name | state.active_skills]
          state = append_message(%{state | active_skills: new_active}, skill_msg)

          broadcast(state, {:skill_loaded, skill_name, skill.description})

          {:reply, {:ok, skill_name}, state}
      end
    end
  end

  # Tool task completed successfully — match ref against pending_tool_tasks map.
  def handle_info(
        {ref, result},
        %State{
          status: :executing_tools,
          pending_tool_tasks: tasks
        } = state
      )
      when is_reference(ref) and is_map_key(tasks, ref) do
    {task, tc} = Map.fetch!(tasks, ref)
    Process.demonitor(task.ref, [:flush])
    Opal.Agent.Tools.handle_tool_result(ref, tc, result, state)
  end

  # Tool task crashed — match ref against pending_tool_tasks map.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{
          status: :executing_tools,
          pending_tool_tasks: tasks
        } = state
      )
      when is_map_key(tasks, ref) do
    {_task, tc} = Map.fetch!(tasks, ref)
    error_msg = "Tool execution crashed: #{inspect(reason)}"
    Logger.error(error_msg)
    Opal.Agent.Tools.handle_tool_result(ref, tc, {:error, error_msg}, state)
  end

  # Native event stream (from EventStream providers like Provider.LLM)
  def handle_info(
        {ref, {:events, events}},
        %State{status: :streaming, streaming_ref: ref} = state
      ) do
    state = %{state | last_chunk_at: System.monotonic_time(:second)}

    state =
      Enum.reduce(events, state, fn event, acc ->
        Opal.Agent.Stream.handle_stream_event(event, acc)
      end)

    {:noreply, state}
  end

  def handle_info({ref, :done}, %State{status: :streaming, streaming_ref: ref} = state) do
    finalize_response(state)
  end

  # SSE stream (from HTTP providers like Provider.Copilot)
  def handle_info(message, %State{status: :streaming, streaming_resp: resp} = state)
      when resp != nil do
    case Req.parse_message(resp, message) do
      {:ok, chunks} when is_list(chunks) ->
        Logger.debug("SSE chunks received: #{inspect(chunks, limit: 3, printable_limit: 200)}")

        state = %{state | last_chunk_at: System.monotonic_time(:second)}

        state =
          Enum.reduce(chunks, state, fn
            {:data, data}, acc -> Opal.Agent.Stream.parse_sse_data(data, acc)
            :done, acc -> acc
            _other, acc -> acc
          end)

        # If :done was in the chunk list, finalize
        if :done in chunks do
          finalize_response(state)
        else
          {:noreply, state}
        end

      :unknown ->
        Logger.debug(
          "Req.parse_message returned :unknown for: #{inspect(message, limit: 3, printable_limit: 200)}"
        )

        {:noreply, state}
    end
  end

  @stream_stall_warn_secs 10

  def handle_info(:stream_watchdog, %State{status: :streaming, last_chunk_at: last} = state)
      when last != nil do
    elapsed = System.monotonic_time(:second) - last

    if elapsed >= @stream_stall_warn_secs do
      broadcast(state, {:stream_stalled, elapsed})
    end

    watchdog = Process.send_after(self(), :stream_watchdog, 5_000)
    {:noreply, %{state | stream_watchdog: watchdog}}
  end

  def handle_info(:stream_watchdog, state) do
    {:noreply, state}
  end

  # Retry timer fired — resume the turn if the agent is still running.
  # If the agent was aborted during the retry wait (status changed to :idle),
  # the timer is silently discarded.
  def handle_info(:retry_turn, %State{status: :running} = state) do
    run_turn_internal(state)
  end

  def handle_info(:retry_turn, state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug(
      "handle_info (status=#{state.status}): #{inspect(message, limit: 3, printable_limit: 200)}"
    )

    {:noreply, state}
  end

  # --- Internal Loop Logic ---

  # Look up context window from LLMDB. Falls back to 128k if not found.
  defp model_context_window(model), do: Opal.Models.context_window(model)

  @doc """
  Builds messages for token estimation usage.
  Public wrapper around build_messages for the UsageTracker module.
  """
  @spec build_messages_for_usage(State.t()) :: [Opal.Message.t()]
  def build_messages_for_usage(%State{} = state) do
    build_messages(state)
  end

  @spec run_turn(State.t()) :: term()
  def run_turn(%State{} = state) do
    run_turn_internal(state)
  end

  # Starts a new LLM turn: converts messages/tools, initiates streaming.
  # Auto-compacts if context usage exceeds threshold.
  defp run_turn_internal(%State{} = state) do
    state = maybe_auto_compact(state)
    # Defense-in-depth: repair any orphaned tool_calls before sending
    state = repair_orphaned_tool_calls(state)

    provider = state.provider
    all_messages = build_messages(state)
    tools = Opal.Agent.Tools.active_tools(state)

    Logger.debug(
      "Turn start session=#{state.session_id} messages=#{length(all_messages)} tools=#{length(tools)} model=#{state.model.id}"
    )

    broadcast(state, {:request_start, %{model: state.model.id, messages: length(all_messages)}})

    case provider.stream(state.model, all_messages, tools) do
      {:ok, %Opal.Provider.EventStream{ref: ref, cancel_fun: cancel_fn}} ->
        Logger.debug("Provider event stream started (native events)")

        broadcast(state, {:request_end})

        watchdog = Process.send_after(self(), :stream_watchdog, 10_000)

        state = %{
          state
          | streaming_resp: nil,
            streaming_ref: ref,
            streaming_cancel: cancel_fn,
            status: :streaming,
            current_text: "",
            current_tool_calls: [],
            current_thinking: nil,
            last_chunk_at: System.monotonic_time(:second),
            stream_watchdog: watchdog
        }

        {:noreply, state}

      {:ok, resp} ->
        Logger.debug(
          "Provider stream started. Response status: #{resp.status}, body type: #{inspect(resp.body.__struct__)}"
        )

        broadcast(state, {:request_end})

        watchdog = Process.send_after(self(), :stream_watchdog, 10_000)

        state = %{
          state
          | streaming_resp: resp,
            streaming_ref: nil,
            streaming_cancel: nil,
            status: :streaming,
            current_text: "",
            current_tool_calls: [],
            current_thinking: nil,
            last_chunk_at: System.monotonic_time(:second),
            stream_watchdog: watchdog
        }

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Provider stream failed: #{inspect(reason)}")

        # Three-way error classification:
        #   1. Context overflow → emergency compact and auto-retry
        #   2. Transient error  → exponential backoff retry
        #   3. Permanent error  → surface to user, go idle
        cond do
          Opal.Agent.Overflow.context_overflow?(reason) ->
            handle_overflow_compaction(state, reason)

          Opal.Agent.Retries.retryable?(reason) and state.retry_count < state.max_retries ->
            attempt = state.retry_count + 1

            delay =
              Opal.Agent.Retries.delay(attempt,
                base_ms: state.retry_base_delay_ms,
                max_ms: state.retry_max_delay_ms
              )

            Logger.info(
              "Retrying in #{delay}ms (attempt #{attempt}/#{state.max_retries}): #{inspect(reason)}"
            )

            broadcast(state, {:retry, attempt, delay, reason})
            Process.send_after(self(), :retry_turn, delay)
            {:noreply, %{state | retry_count: attempt}}

          true ->
            broadcast(state, {:error, reason})
            {:noreply, %{state | status: :idle, retry_count: 0}}
        end
    end
  end

  # Compacts the conversation if estimated context usage exceeds the threshold.
  #
  # Uses hybrid token estimation (Plan 13): combines the last actual usage
  # report with heuristic estimates for messages added since. This catches
  # growth *between* turns that the lagging `last_prompt_tokens` would miss.
  defp maybe_auto_compact(%State{} = state) do
    Opal.Agent.Compaction.maybe_auto_compact(state)
  end

  # ── Overflow Recovery ─────────────────────────────────────────────────
  #
  # When the provider rejects a request because the conversation exceeds
  # the context window, we aggressively compact (keeping only ~20% of
  # context) and auto-retry the turn. This is NOT counted as a retry
  # attempt — it's a structural recovery, not a transient-error retry.

  # Without a session process we can't compact — surface the raw error.
  defp handle_overflow_compaction(%State{session: nil} = state, reason) do
    Opal.Agent.Compaction.handle_overflow_compaction(state, reason)
  end

  defp handle_overflow_compaction(%State{} = state, reason) do
    Opal.Agent.Compaction.handle_overflow_compaction(state, reason)
  end

  # Prepends system prompt (with discovered context, skill menu, and
  # tool usage guidelines appended) as a system message.
  defp build_messages(
         %State{
           system_prompt: prompt,
           context: context,
           messages: messages,
           config: config,
           available_skills: skills
         } = state
       )
       when (prompt != "" and prompt != nil) or (context != "" and context != nil) do
    # Build skill menu if skills are available
    skill_menu =
      if config.features.skills.enabled and skills != [] do
        summaries = Enum.map_join(skills, "\n", &Opal.Skill.summary/1)

        "\n\n## Available Skills\n\nUse the `use_skill` tool to load a skill's full instructions when relevant.\n\n#{summaries}"
      else
        ""
      end

    # Build dynamic tool guidelines based on which tools are active
    # (prevents the LLM from using shell for read/edit/write operations)
    tool_guidelines =
      Opal.Agent.SystemPrompt.build_guidelines(Opal.Agent.Tools.active_tools(state))

    # Planning instructions — tell the agent where to write plan.md
    planning = planning_instructions(state)

    full_prompt =
      [prompt || "", context || "", skill_menu, tool_guidelines, planning]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    system_msg = %Opal.Message{
      id: "system",
      role: :system,
      content: full_prompt
    }

    [system_msg | Enum.reverse(messages)]
  end

  defp build_messages(%State{messages: messages}), do: Enum.reverse(messages)

  # Returns planning instructions for the system prompt, or "" for sub-agents.
  defp planning_instructions(%State{config: config, session_id: session_id, session: session}) do
    if session != nil do
      session_dir = Path.join(Opal.Config.sessions_dir(config), session_id)

      """

      ## Planning

      For complex multi-step tasks, create a plan document at:
        #{session_dir}/plan.md

      Write your plan before starting implementation. Update it as you
      complete steps. The user can review the plan at any time with Ctrl+Y.
      """
    else
      ""
    end
  end

  defp maybe_update_feature(%State{} = state, _key, nil), do: state

  defp maybe_update_feature(%State{config: config} = state, key, enabled)
       when is_boolean(enabled) do
    current = Map.fetch!(config.features, key)
    features = Map.put(config.features, key, Map.put(current, :enabled, enabled))
    state = %{state | config: %{config | features: features}}
    if key == :debug and not enabled, do: Opal.Agent.EventLog.clear(state.session_id)
    state
  end

  defp maybe_update_feature(%State{} = state, _key, _invalid), do: state

  defp maybe_update_enabled_tools(%State{} = state, nil), do: state

  defp maybe_update_enabled_tools(%State{tools: tools} = state, enabled_tools)
       when is_list(enabled_tools) do
    enabled = MapSet.new(enabled_tools)
    all_tool_names = Enum.map(tools, & &1.name())
    disabled = Enum.reject(all_tool_names, &MapSet.member?(enabled, &1))
    %{state | disabled_tools: disabled}
  end

  # --- Response Finalization ---

  # Called when the SSE stream is complete. Creates the assistant message,
  # then either executes tool calls or ends the agent loop.
  defp finalize_response(%State{} = state) do
    cancel_watchdog(state)

    Logger.debug(
      "Finalizing response. Text: #{inspect(String.slice(state.current_text, 0, 100))}. Tool calls: #{inspect(length(state.current_tool_calls))}"
    )

    tool_calls = finalize_tool_calls(state.current_tool_calls)

    thinking_opt =
      if state.current_thinking && state.current_thinking != "" do
        [thinking: state.current_thinking]
      else
        []
      end

    assistant_msg = Opal.Message.assistant(state.current_text, tool_calls, thinking_opt)
    state = append_message(state, assistant_msg)

    # A successful response resets the retry counter — consecutive failures
    # are what we're guarding against, not total failures over a session.
    state = %{state | streaming_resp: nil, status: :running, retry_count: 0}

    # Check usage-based overflow before continuing. If the provider reported
    # input tokens exceeding the context window on this turn, compact now
    # before the next turn makes things worse.
    if state.overflow_detected do
      handle_overflow_compaction(%{state | overflow_detected: false}, :usage_overflow)
    else
      finalize_response_continue(state, tool_calls, assistant_msg)
    end
  end

  # Continues finalization after overflow check passes.
  defp finalize_response_continue(state, tool_calls, assistant_msg) do
    if tool_calls != [] do
      broadcast(state, {:turn_end, assistant_msg, []})
      Opal.Agent.Tools.start_tool_execution(tool_calls, state)
    else
      # Drain any steering messages that arrived during this turn
      state = Opal.Agent.Tools.check_for_steering(state)
      last_msg = List.first(state.messages)

      if last_msg && last_msg.role == :user do
        # Steers were injected — continue with a new turn
        broadcast(state, {:turn_end, assistant_msg, []})
        run_turn_internal(state)
      else
        context_window = model_context_window(state.model)

        final_usage =
          Map.merge(state.token_usage, %{
            context_window: context_window,
            current_context_tokens: state.last_prompt_tokens
          })

        broadcast(state, {:agent_end, Enum.reverse(state.messages), final_usage})
        maybe_auto_save(state)
        {:noreply, %{state | status: :idle}}
      end
    end
  end

  # Converts accumulated tool call maps into the message struct format.
  # Handles both pre-parsed arguments (from tool_call_done) and raw
  # accumulated JSON (from tool_call_delta, used by Chat Completions).
  defp finalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      arguments =
        tc[:arguments] ||
          case Jason.decode(tc[:arguments_json] || "{}") do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

      %{
        call_id: tc[:call_id] || "",
        name: tc[:name] || "",
        arguments: arguments
      }
    end)
  end

  # --- Tool Execution ---

  # Cancels all in-progress tool executions if present.
  # Injects synthetic tool_result messages for any orphaned tool_calls
  # so the message history stays valid for the provider.
  defp cancel_tool_execution(%State{} = state) do
    state = Opal.Agent.Tools.cancel_all_tasks(state)
    repair_orphaned_tool_calls(state)
  end

  # Cancels an in-progress streaming response if present.
  defp cancel_streaming(%State{streaming_resp: nil, streaming_ref: nil} = state), do: state

  defp cancel_streaming(%State{streaming_ref: ref, streaming_cancel: cancel_fn} = state)
       when ref != nil do
    cancel_watchdog(state)
    if is_function(cancel_fn, 0), do: cancel_fn.()

    %{
      state
      | streaming_ref: nil,
        streaming_cancel: nil,
        current_text: "",
        current_tool_calls: [],
        current_thinking: nil,
        stream_watchdog: nil,
        last_chunk_at: nil
    }
  end

  defp cancel_streaming(%State{streaming_resp: resp} = state) do
    cancel_watchdog(state)
    Req.cancel_async_response(resp)

    %{
      state
      | streaming_resp: nil,
        current_text: "",
        current_tool_calls: [],
        current_thinking: nil,
        stream_watchdog: nil,
        last_chunk_at: nil
    }
  end

  defp cancel_watchdog(%{stream_watchdog: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_watchdog(_), do: :ok

  # Broadcasts an event to all subscribers of this session.
  defp broadcast(%State{} = state, event), do: Opal.Agent.EventLog.broadcast(state, event)

  # Appends a single message. When a Session process is attached, the message
  # is also stored in the session tree. The local messages list is always
  # updated for LLM context building.
  defp append_message(%State{session: nil} = state, msg) do
    %{state | messages: [msg | state.messages]}
  end

  defp append_message(%State{session: session} = state, msg) do
    Opal.Session.append(session, msg)
    %{state | messages: [msg | state.messages]}
  end

  # Finds the most recent assistant message with tool_calls that lack
  # matching tool_result messages and injects synthetic "[Aborted]" results.
  defp repair_orphaned_tool_calls(%State{messages: messages} = state) do
    # Messages are stored newest-first. Walk until we find an assistant
    # with tool_calls, then check if results exist after it.
    case find_orphaned_calls(messages) do
      [] ->
        state

      orphaned_ids ->
        Logger.debug("Repairing #{length(orphaned_ids)} orphaned tool_calls after abort")

        Enum.reduce(orphaned_ids, state, fn call_id, acc ->
          append_message(acc, Opal.Message.tool_result(call_id, "[Aborted by user]", true))
        end)
    end
  end

  # Returns call_ids from the most recent assistant message's tool_calls
  # that have no corresponding tool_result in the messages above it.
  defp find_orphaned_calls(messages) do
    find_orphaned_calls(messages, MapSet.new())
  end

  defp find_orphaned_calls([], _result_ids), do: []

  defp find_orphaned_calls([%{role: :tool_result, call_id: cid} | rest], result_ids) do
    find_orphaned_calls(rest, MapSet.put(result_ids, cid))
  end

  defp find_orphaned_calls([%{role: :assistant, tool_calls: tcs} | _], result_ids)
       when is_list(tcs) and tcs != [] do
    tcs
    |> Enum.map(& &1["id"])
    |> Enum.filter(&(&1 != nil))
    |> Enum.reject(&MapSet.member?(result_ids, &1))
  end

  defp find_orphaned_calls([_ | rest], result_ids) do
    find_orphaned_calls(rest, result_ids)
  end

  # Auto-saves the session when the agent goes idle, if a Session process
  # is attached and auto_save is enabled in config.
  defp maybe_auto_save(%State{session: nil}), do: :ok

  defp maybe_auto_save(%State{session: session, config: config} = state) do
    if config.auto_save do
      maybe_generate_title(state)
      dir = Opal.Config.sessions_dir(config)
      Opal.Session.save(session, dir)
    end
  end

  # Generates a session title from the first user message if none exists yet.
  # Uses the LLM to produce a concise ~5 word summary.
  defp maybe_generate_title(%State{session: session, config: config, messages: messages} = state) do
    if config.auto_title do
      existing = Opal.Session.get_metadata(session, :title)

      if existing == nil and length(messages) >= 2 do
        first_user_msg = Enum.find(messages, fn m -> m.role == :user end)

        if first_user_msg do
          Task.Supervisor.start_child(state.tool_supervisor, fn ->
            generate_session_title(state, first_user_msg.content)
          end)
        end
      end
    end
  end

  defp generate_session_title(
         %State{session: session, model: model, provider: provider},
         user_text
       ) do
    prompt_text = String.slice(user_text, 0, 500)

    title_messages = [
      %Opal.Message{
        id: "sys",
        role: :system,
        content:
          "Generate a concise 3-6 word title for this conversation. Reply with ONLY the title, no quotes or punctuation."
      },
      Opal.Message.user(prompt_text)
    ]

    case provider.stream(model, title_messages, []) do
      {:ok, resp} ->
        title = Opal.Provider.StreamCollector.collect_text(resp, provider, 10_000)

        if title != "" do
          clean = title |> String.trim() |> String.slice(0, 60)
          Opal.Session.set_metadata(session, :title, clean)
        end

      {:error, _} ->
        :ok
    end
  end

  # Discovers MCP tools from connected servers and returns runtime modules.
  # Silently returns [] if no MCP servers are configured or if discovery fails.
  defp discover_mcp_tools([], _existing_names), do: []

  defp discover_mcp_tools(mcp_servers, existing_names) do
    Opal.MCP.Bridge.discover_tool_modules(mcp_servers, existing_names)
  catch
    kind, reason ->
      Logger.warning("MCP tool discovery failed: #{inspect(kind)} #{inspect(reason)}")
      []
  end
end
