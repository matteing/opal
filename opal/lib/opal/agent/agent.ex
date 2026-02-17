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
        model: %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5"},
        tools: [Opal.Tool.Read, Opal.Tool.Write],
        working_dir: "/path/to/project"
      )

      :ok = Opal.Agent.prompt(pid, "List all files")

  Events are broadcast via `Opal.Events` using the session ID, so any
  subscriber can observe the full lifecycle in real time.
  """

  @behaviour :gen_statem

  # MapSet is opaque — Dialyzer can't see through recursive calls that thread it
  @dialyzer {:no_opaque, find_orphaned_calls: 3}

  require Logger
  alias Opal.Agent.{Emitter, State}

  # --- Public API ---

  @typedoc """
  Options for starting an agent.

  ## Required

    * `:session_id` — unique string identifier for this session
    * `:model` — an `Opal.Provider.Model.t()` struct
    * `:working_dir` — base directory for tool execution
    * `:tool_supervisor` — supervisor for spawning tool tasks

  ## Optional

    * `:system_prompt` — the system prompt string (default: `""`)
    * `:tools` — list of modules implementing `Opal.Tool` (default: `[]`)
    * `:disabled_tools` — tool names to disable at startup (default: `[]`)
    * `:provider` — module implementing `Opal.Provider` (default: from config)
    * `:config` — `Opal.Config.t()` (default: `Opal.Config.new()`)
    * `:session` — `true` to look up via Registry, or a pid (default: `nil`)
    * `:sub_agent_supervisor` — supervisor for child agents
    * `:mcp_supervisor` — supervisor for MCP server connections
    * `:mcp_servers` — MCP server config maps (default: `[]`)
  """
  @type start_opts :: [
          {:session_id, String.t()}
          | {:model, Opal.Provider.Model.t()}
          | {:working_dir, String.t()}
          | {:tool_supervisor, Supervisor.supervisor()}
          | {:system_prompt, String.t()}
          | {:tools, [module()]}
          | {:disabled_tools, [String.t()]}
          | {:provider, module()}
          | {:config, Opal.Config.t()}
          | {:session, boolean() | pid()}
          | {:sub_agent_supervisor, Supervisor.supervisor()}
          | {:mcp_supervisor, Supervisor.supervisor() | nil}
          | {:mcp_servers, [map()]}
        ]

  @doc """
  Starts the agent state machine. See `t:start_opts/0` for available options.
  """
  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  # Overrides the default child_spec so this module can be placed directly
  # in a supervision tree, e.g. `{Opal.Agent, opts}`.
  @spec child_spec(start_opts()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Sends a user prompt to the agent.

  If the agent is idle, it starts processing immediately (`queued: false`).
  If busy, the message is queued and applied between tool executions
  (`queued: true`).
  """
  @spec prompt(GenServer.server(), String.t()) :: %{queued: boolean()}
  def prompt(agent, text) when is_binary(text) do
    :gen_statem.call(agent, {:prompt, text})
  end

  @doc """
  Sends a follow-up prompt to the agent. Convenience alias for `prompt/2`.
  """
  @spec follow_up(GenServer.server(), String.t()) :: %{queued: boolean()}
  def follow_up(agent, text) when is_binary(text) do
    :gen_statem.call(agent, {:prompt, text})
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

  @doc """
  Returns the full message list that would be sent to the provider,
  including the system prompt and tool-result repairs.
  """
  @spec get_context(GenServer.server()) :: [Opal.Message.t()]
  def get_context(agent) do
    :gen_statem.call(agent, :get_context)
  end

  @doc """
  Hot-swaps the LLM model for subsequent turns.
  """
  @spec set_model(GenServer.server(), Opal.Provider.Model.t()) :: :ok
  def set_model(agent, %Opal.Provider.Model{} = model) do
    :gen_statem.call(agent, {:set_model, model})
  end

  @doc """
  Hot-swaps the provider module (e.g. `Opal.Provider.Copilot`) for subsequent turns.
  """
  @spec set_provider(GenServer.server(), module()) :: :ok
  def set_provider(agent, provider_module) when is_atom(provider_module) do
    :gen_statem.call(agent, {:set_provider, provider_module})
  end

  @doc """
  Replaces the agent's conversation history with the given messages.

  Used by the RPC layer to synchronize context when the client navigates
  to a different branch in the session tree.
  """
  @spec sync_messages(GenServer.server(), [Opal.Message.t()]) :: :ok
  def sync_messages(agent, messages) when is_list(messages) do
    :gen_statem.call(agent, {:sync_messages, messages})
  end

  @doc """
  Applies runtime configuration changes (feature toggles, enabled tools).

  ## Attrs

    * `:features` — `%{optional(atom()) => boolean()}` toggling feature flags
      (`:sub_agents`, `:skills`, `:mcp`, `:debug`)
    * `:enabled_tools` — `[String.t()]` names of tools to keep enabled;
      all others are disabled
  """
  @type config_attrs :: %{
          optional(:features) => %{optional(atom()) => boolean()},
          optional(:enabled_tools) => [String.t()]
        }
  @spec configure(GenServer.server(), config_attrs()) :: :ok
  def configure(agent, attrs) when is_map(attrs) do
    :gen_statem.call(agent, {:configure, attrs})
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

    session_pid = resolve_session(session_id, opts)

    %{entries: context_entries, files: context_files, skills: available_skills} =
      discover_context(config, working_dir)

    %{native: base_tools, mcp: mcp_tools} = resolve_tools(opts)

    state =
      %State{
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
        mcp_supervisor: Keyword.get(opts, :mcp_supervisor),
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        context_entries: context_entries,
        context_files: context_files,
        available_skills: available_skills,
        active_skills: [],
        token_usage: %{
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          context_window: Opal.Provider.Registry.context_window(model),
          current_context_tokens: 0
        }
      }
      |> maybe_recover_session()

    Emitter.clear(session_id)

    tools_str = base_tools |> Enum.map(& &1.name()) |> Enum.join(", ")

    Logger.debug(
      "Agent ready session=#{state.session_id} tools=[#{tools_str}] " <>
        "mcp_tools=#{length(mcp_tools)} skills=#{length(state.available_skills)}"
    )

    if context_files != [], do: Emitter.broadcast(state, {:context_discovered, context_files})

    {:ok, :idle, state}
  end

  # Resolves the Session process: the SessionServer passes session: true/false,
  # and the Session process is registered via Opal.Registry.
  @spec resolve_session(String.t(), keyword()) :: pid() | nil
  defp resolve_session(session_id, opts) do
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
  end

  # Discovers project context files and skills based on config feature flags.
  @spec discover_context(Opal.Config.t(), String.t()) :: %{
          entries: [%{path: String.t(), content: String.t()}],
          files: [String.t()],
          skills: [Opal.Skill.t()]
        }
  defp discover_context(config, working_dir) do
    if config.features.context.enabled or config.features.skills.enabled do
      entries =
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

      %{entries: entries, files: Enum.map(entries, & &1.path), skills: skills}
    else
      %{entries: [], files: [], skills: []}
    end
  end

  # Discovers native and MCP tools, returning them separately for logging.
  @spec resolve_tools(keyword()) :: %{native: [module()], mcp: [module()]}
  defp resolve_tools(opts) do
    native = Keyword.get(opts, :tools, [])
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    native_names = native |> Enum.map(& &1.name()) |> MapSet.new()
    mcp = discover_mcp_tools(mcp_servers, native_names)
    %{native: native, mcp: mcp}
  end

  # On restart, reloads conversation history from the surviving Session process.
  @spec maybe_recover_session(State.t()) :: State.t()
  defp maybe_recover_session(%State{session: nil} = state), do: state

  defp maybe_recover_session(%State{session: session} = state) do
    if Opal.Session.current_id(session) do
      messages = Opal.Session.get_path(session)
      Logger.info("Agent recovered session=#{state.session_id} messages=#{length(messages)}")
      Emitter.broadcast(state, {:agent_recovered})
      %{state | messages: Enum.reverse(messages)}
    else
      state
    end
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

  defp dispatch_state_event({:call, from}, message, state) do
    {reply, state} = handle_call(message, from, state)
    {:next_state, State.state_name(state), state, [{:reply, from, reply}]}
  end

  defp dispatch_state_event(:cast, message, state) do
    state = handle_cast(message, state)
    {:next_state, State.state_name(state), state}
  end

  defp dispatch_state_event(:info, message, state) do
    state = handle_info(message, state)
    {:next_state, State.state_name(state), state}
  end

  defp dispatch_state_event(_event_type, _event_content, state), do: {:keep_state, state}

  defp handle_cast(:abort, %State{} = state) do
    state = cancel_streaming(state)
    state = cancel_tool_execution(state)
    Emitter.broadcast(state, {:agent_abort})
    %{state | status: :idle}
  end

  defp handle_call({:prompt, text}, _from, %State{status: :idle} = state) do
    Logger.debug(
      "Prompt received session=#{state.session_id} len=#{String.length(text)} chars=\"#{String.slice(text, 0, 80)}\""
    )

    user_msg = Opal.Message.user(text)
    state = append_message(state, user_msg)
    state = %{state | status: :running}
    Emitter.broadcast(state, {:agent_start})
    state = run_turn_internal(state)
    {%{queued: false}, state}
  end

  defp handle_call({:prompt, text}, _from, %State{status: status} = state)
       when status in [:running, :streaming, :executing_tools] do
    Logger.debug(
      "Prompt queued while busy session=#{state.session_id} status=#{status} len=#{String.length(text)}"
    )

    Emitter.broadcast(state, {:message_queued, text})
    {%{queued: true}, %{state | pending_messages: state.pending_messages ++ [text]}}
  end

  defp handle_call(:get_state, _from, state) do
    {state, state}
  end

  defp handle_call(:get_context, _from, state) do
    {build_messages(state), state}
  end

  defp handle_call({:set_model, %Opal.Provider.Model{} = model}, _from, state) do
    Logger.debug(
      "Model changed session=#{state.session_id} from=#{state.model.id} to=#{model.id}"
    )

    {:ok, %{state | model: model}}
  end

  defp handle_call({:set_provider, provider_module}, _from, state)
       when is_atom(provider_module) do
    Logger.debug("Provider changed session=#{state.session_id} to=#{inspect(provider_module)}")
    {:ok, %{state | provider: provider_module}}
  end

  defp handle_call({:sync_messages, messages}, _from, state) do
    Logger.debug("Messages synced session=#{state.session_id} count=#{length(messages)}")
    {:ok, %{state | messages: Enum.reverse(messages)}}
  end

  defp handle_call({:configure, attrs}, _from, %State{} = state) do
    state =
      state
      |> maybe_update_feature(:sub_agents, get_in(attrs, [:features, :sub_agents]))
      |> maybe_update_feature(:skills, get_in(attrs, [:features, :skills]))
      |> maybe_update_feature(:mcp, get_in(attrs, [:features, :mcp]))
      |> maybe_update_feature(:debug, get_in(attrs, [:features, :debug]))
      |> maybe_update_enabled_tools(Map.get(attrs, :enabled_tools))

    {:ok, state}
  end

  @spec handle_info(term(), State.t()) :: State.t()

  # Tool task completed successfully — match ref against pending_tool_tasks map.
  defp handle_info(
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
  defp handle_info(
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
  defp handle_info(
         {ref, {:events, events}},
         %State{status: :streaming, streaming_ref: ref} = state
       ) do
    state = %{state | last_chunk_at: System.monotonic_time(:second)}

    state =
      Enum.reduce(events, state, fn event, acc ->
        Opal.Agent.Stream.handle_stream_event(event, acc)
      end)

    # If a stream error event was received, don't wait for :done
    if state.stream_errored do
      cancel_watchdog(state)
      %{state | stream_errored: false}
    else
      state
    end
  end

  defp handle_info({ref, :done}, %State{status: :streaming, streaming_ref: ref} = state) do
    finalize_response(state)
  end

  # SSE stream (from HTTP providers like Provider.Copilot)
  defp handle_info(message, %State{status: :streaming, streaming_resp: resp} = state)
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

        # If a stream error event was received, don't finalize — the response
        # is invalid. Discard any partial content and go idle.
        cond do
          state.stream_errored ->
            cancel_watchdog(state)
            %{state | status: :idle, stream_errored: false, streaming_resp: nil}

          :done in chunks ->
            finalize_response(state)

          true ->
            state
        end

      :unknown ->
        Logger.debug(
          "Req.parse_message returned :unknown for: #{inspect(message, limit: 3, printable_limit: 200)}"
        )

        state
    end
  end

  @stream_stall_warn_secs 10

  defp handle_info(:stream_watchdog, %State{status: :streaming, last_chunk_at: last} = state)
       when last != nil do
    elapsed = System.monotonic_time(:second) - last

    if elapsed >= @stream_stall_warn_secs do
      Emitter.broadcast(state, {:stream_stalled, elapsed})
    end

    watchdog = Process.send_after(self(), :stream_watchdog, 5_000)
    %{state | stream_watchdog: watchdog}
  end

  defp handle_info(:stream_watchdog, state) do
    state
  end

  # Retry timer fired — resume the turn if the agent is still running.
  # If the agent was aborted during the retry wait (status changed to :idle),
  # the timer is silently discarded.
  defp handle_info(:retry_turn, %State{status: :running} = state) do
    run_turn_internal(state)
  end

  defp handle_info(:retry_turn, state) do
    state
  end

  defp handle_info(message, state) do
    Logger.debug(
      "handle_info (status=#{state.status}): #{inspect(message, limit: 3, printable_limit: 200)}"
    )

    state
  end

  # --- Internal Loop Logic ---

  @doc """
  Builds messages for token estimation usage.
  Public wrapper around build_messages for the UsageTracker module.
  """
  @spec build_messages_for_usage(State.t()) :: [Opal.Message.t()]
  def build_messages_for_usage(%State{} = state) do
    build_messages(state)
  end

  @spec run_turn(State.t()) :: State.t()
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

    Emitter.broadcast(
      state,
      {:request_start, %{model: state.model.id, messages: length(all_messages)}}
    )

    case provider.stream(state.model, all_messages, tools) do
      {:ok, %Opal.Provider.EventStream{ref: ref, cancel_fun: cancel_fn}} ->
        Logger.debug("Provider event stream started (native events)")

        Emitter.broadcast(state, {:request_end})

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

        state

      {:ok, resp} ->
        Logger.debug(
          "Provider stream started. Response status: #{resp.status}, body type: #{inspect(resp.body.__struct__)}"
        )

        Emitter.broadcast(state, {:request_end})

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

        state

      {:error, reason} ->
        Logger.error("Provider stream failed: #{inspect(reason)}")

        # Three-way error classification:
        #   1. Context overflow → emergency compact and auto-retry
        #   2. Transient error  → exponential backoff retry
        #   3. Permanent error  → surface to user, go idle
        cond do
          Opal.Agent.Overflow.context_overflow?(reason) ->
            handle_overflow_compaction(state, reason)

          Opal.Agent.Retry.retryable?(reason) and state.retry_count < state.max_retries ->
            attempt = state.retry_count + 1

            delay =
              Opal.Agent.Retry.delay(attempt,
                base_ms: state.retry_base_delay_ms,
                max_ms: state.retry_max_delay_ms
              )

            Logger.info(
              "Retrying in #{delay}ms (attempt #{attempt}/#{state.max_retries}): #{inspect(reason)}"
            )

            Emitter.broadcast(state, {:retry, attempt, delay, reason})
            Process.send_after(self(), :retry_turn, delay)
            %{state | retry_count: attempt}

          true ->
            Emitter.broadcast(state, {:error, reason})
            %{state | status: :idle, retry_count: 0}
        end
    end
  end

  # Compacts the conversation if estimated context usage exceeds the threshold.
  #
  # Uses hybrid token estimation (Plan 13): combines the last actual usage
  # report with heuristic estimates for messages added since. This catches
  # growth *between* turns that the lagging `last_prompt_tokens` would miss.
  defp maybe_auto_compact(%State{} = state) do
    Opal.Agent.UsageTracker.maybe_auto_compact(state)
  end

  # ── Overflow Recovery ─────────────────────────────────────────────────
  #
  # When the provider rejects a request because the conversation exceeds
  # the context window, we aggressively compact (keeping only ~20% of
  # context) and auto-retry the turn. This is NOT counted as a retry
  # attempt — it's a structural recovery, not a transient-error retry.

  defp handle_overflow_compaction(%State{} = state, reason) do
    Opal.Agent.UsageTracker.handle_overflow_compaction(state, reason)
  end

  # Prepends system prompt as a system message.
  # `SystemPrompt.build/1` owns the full prompt layout — see that module
  # for the section order and XML-tag structure.
  defp build_messages(%State{} = state) do
    case Opal.Agent.SystemPrompt.build(state) do
      nil ->
        ensure_tool_results(Enum.reverse(state.messages))

      full_prompt ->
        system_msg = Opal.Message.system(full_prompt)
        [system_msg | ensure_tool_results(Enum.reverse(state.messages))]
    end
  end

  defp maybe_update_feature(%State{} = state, _key, nil), do: state

  defp maybe_update_feature(%State{config: config} = state, key, enabled)
       when is_boolean(enabled) do
    current = Map.fetch!(config.features, key)
    features = Map.put(config.features, key, Map.put(current, :enabled, enabled))
    state = %{state | config: %{config | features: features}}
    if key == :debug and not enabled, do: Emitter.clear(state.session_id)
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
      Emitter.broadcast(state, {:turn_end, assistant_msg, []})
      Opal.Agent.Tools.start_tool_execution(tool_calls, state)
    else
      # Drain any steering messages that arrived during this turn
      state = Opal.Agent.Tools.drain_pending_messages(state)
      last_msg = List.first(state.messages)

      if last_msg && last_msg.role == :user do
        # Pending messages were injected — continue with a new turn
        Emitter.broadcast(state, {:turn_end, assistant_msg, []})
        run_turn_internal(state)
      else
        context_window = Opal.Provider.Registry.context_window(state.model)

        final_usage =
          Map.merge(state.token_usage, %{
            context_window: context_window,
            current_context_tokens: state.last_prompt_tokens
          })

        Emitter.broadcast(state, {:agent_end, Enum.reverse(state.messages), final_usage})
        maybe_auto_save(state)
        %{state | status: :idle}
      end
    end
  end

  # Converts accumulated tool call maps into the message struct format.
  # Handles both pre-parsed arguments (from tool_call_done) and raw
  # accumulated JSON (from tool_call_delta, used by Chat Completions).
  # Filters out tool calls with missing call_id or name (malformed stream).
  defp finalize_tool_calls(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
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
    |> Enum.reject(fn tc -> tc.call_id == "" or tc.name == "" end)
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

  # Defense-in-depth: walks a chronological message list and ensures every
  # assistant message with tool_calls is immediately followed by matching
  # tool_results, and strips orphaned/out-of-place tool_results.
  #
  # This runs on the final list sent to the provider, catching corruption
  # regardless of source (compaction, abort, stream error, session reload).
  @doc false
  def ensure_tool_results(chronological_messages) do
    # First pass: collect all valid tool_call IDs from assistant messages
    valid_call_ids =
      Enum.reduce(chronological_messages, MapSet.new(), fn
        %{role: :assistant, tool_calls: tcs}, ids when is_list(tcs) and tcs != [] ->
          tcs
          |> Enum.map(&tool_call_id/1)
          |> Enum.filter(&is_binary/1)
          |> Enum.reduce(ids, &MapSet.put(&2, &1))

        _, ids ->
          ids
      end)

    # Second pass: relocate matched results directly after tool-calling
    # assistants, synthesize missing, and strip leftovers.
    do_ensure(chronological_messages, valid_call_ids, [])
  end

  defp do_ensure([], _valid_ids, acc), do: Enum.reverse(acc)

  # Strip standalone tool_results. Matched results are relocated by the
  # assistant branch below, so anything that reaches here is out-of-place.
  defp do_ensure([%{role: :tool_result, call_id: cid} | rest], valid_ids, acc) do
    if MapSet.member?(valid_ids, cid) do
      Logger.warning("Stripping out-of-place tool_result: #{cid}")
    else
      Logger.warning("Stripping orphaned tool_result with no matching tool_call: #{cid}")
    end

    do_ensure(rest, valid_ids, acc)
  end

  # For assistant messages with tool_calls, relocate all matching results so
  # they are adjacent, then synthesize any missing ones.
  defp do_ensure(
         [%{role: :assistant, tool_calls: tcs} = msg | rest],
         valid_ids,
         acc
       )
       when is_list(tcs) and tcs != [] do
    expected_ids =
      tcs
      |> Enum.map(&tool_call_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{matched: matched, rest: rest} = take_tool_results_for_ids(rest, MapSet.new(expected_ids))

    missing =
      expected_ids
      |> Enum.reject(&Map.has_key?(matched, &1))

    if missing != [] do
      Logger.warning(
        "Injecting #{length(missing)} synthetic tool_results for orphaned tool_calls"
      )
    end

    results =
      Enum.map(expected_ids, fn call_id ->
        Map.get(matched, call_id) ||
          Opal.Message.tool_result(call_id, "[Error: tool result missing]", true)
      end)

    new_acc = Enum.reverse([msg | results]) ++ acc
    do_ensure(rest, valid_ids, new_acc)
  end

  defp do_ensure([msg | rest], valid_ids, acc) do
    do_ensure(rest, valid_ids, [msg | acc])
  end

  defp take_tool_results_for_ids(messages, expected_ids) do
    {matched, kept_rev} =
      Enum.reduce(messages, {%{}, []}, fn
        %{role: :tool_result, call_id: cid} = msg, {found, kept} ->
          cond do
            is_binary(cid) and MapSet.member?(expected_ids, cid) and not Map.has_key?(found, cid) ->
              {Map.put(found, cid, msg), kept}

            is_binary(cid) and MapSet.member?(expected_ids, cid) ->
              Logger.warning("Dropping duplicate tool_result for call_id: #{cid}")
              {found, kept}

            true ->
              {found, [msg | kept]}
          end

        msg, {found, kept} ->
          {found, [msg | kept]}
      end)

    %{matched: matched, rest: Enum.reverse(kept_rev)}
  end

  defp tool_call_id(%{call_id: call_id}) when is_binary(call_id), do: call_id
  defp tool_call_id(%{"call_id" => call_id}) when is_binary(call_id), do: call_id
  defp tool_call_id(_), do: nil

  defp tool_call_ids(tool_calls) do
    Enum.reduce(tool_calls, [], fn tc, ids ->
      case tool_call_id(tc) do
        call_id when is_binary(call_id) -> [call_id | ids]
        _ -> ids
      end
    end)
    |> Enum.reverse()
  end

  # Scans ALL assistant messages with tool_calls and injects synthetic
  # "[Aborted]" results for any that lack matching tool_result messages.
  defp repair_orphaned_tool_calls(%State{messages: messages} = state) do
    case find_orphaned_calls(messages) do
      [] ->
        state

      orphaned_ids ->
        Logger.debug("Repairing #{length(orphaned_ids)} orphaned tool_calls")

        Enum.reduce(orphaned_ids, state, fn call_id, acc ->
          append_message(acc, Opal.Message.tool_result(call_id, "[Aborted by user]", true))
        end)
    end
  end

  # Returns call_ids from ALL assistant messages whose tool_calls lack
  # a corresponding tool_result anywhere after them (newest-first walk).
  defp find_orphaned_calls(messages) do
    find_orphaned_calls(messages, MapSet.new(), [])
  end

  defp find_orphaned_calls([], _result_ids, acc), do: acc

  defp find_orphaned_calls([%{role: :tool_result, call_id: cid} | rest], result_ids, acc) do
    find_orphaned_calls(rest, MapSet.put(result_ids, cid), acc)
  end

  defp find_orphaned_calls([%{role: :assistant, tool_calls: tcs} | rest], result_ids, acc)
       when is_list(tcs) and tcs != [] do
    orphans =
      tcs
      |> tool_call_ids()
      |> Enum.reject(&MapSet.member?(result_ids, &1))

    find_orphaned_calls(rest, result_ids, acc ++ orphans)
  end

  defp find_orphaned_calls([_ | rest], result_ids, acc) do
    find_orphaned_calls(rest, result_ids, acc)
  end

  # Auto-saves the session when the agent goes idle, if a Session process
  # is attached and auto_save is enabled in config.
  defp maybe_auto_save(%State{session: nil}), do: :ok

  defp maybe_auto_save(%State{session: session, config: config}) do
    if config.auto_save do
      dir = Opal.Config.sessions_dir(config)
      Opal.Session.save(session, dir)
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
