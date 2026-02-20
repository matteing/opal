defmodule Opal.Agent do
  @moduledoc """
  The agent loop — a `:gen_statem` orchestrating prompt → stream → tools → loop.

  ## State Diagram

  ```
      ┌──────┐  prompt   ┌─────────┐  stream   ┌───────────┐
      │ idle │──────────▶│ running │─────────▶│ streaming │
      └──┬───┘           └─────────┘           └─────┬─────┘
         │                    ▲                       │
         │          next_turn │            finalize   │
         │                    │                       ▼
         │               ┌────┴────┐        ┌─────────────────┐
         │               │  loop   │◁───────│ executing_tools │
         │               └─────────┘        └─────────────────┘
         │                                          │
         └──────────────── done ────────────────────┘
  ```

  Each box is a `:gen_statem` state function. Events are broadcast
  via `Opal.Events` keyed by session ID.

  ## Usage

      {:ok, pid} = Opal.Agent.start_link(
        session_id: "abc",
        model: %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5"},
        tools: [Opal.Tool.ReadFile, Opal.Tool.WriteFile],
        working_dir: "/project"
      )

      %{queued: false} = Opal.Agent.prompt(pid, "Hello")
  """

  @behaviour :gen_statem

  require Logger
  alias Opal.Agent.{Emitter, Repair, State, ToolRunner, UsageTracker}

  # ── Public API ────────────────────────────────────────────────────────

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

  @doc "Starts the agent state machine."
  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  @spec child_spec(start_opts()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  @doc """
  Sends a user prompt. Returns `%{queued: false}` when idle,
  `%{queued: true}` when the agent is busy (applied between tool calls).
  """
  @spec prompt(GenServer.server(), String.t()) :: %{queued: boolean()}
  def prompt(agent, text) when is_binary(text),
    do: :gen_statem.call(agent, {:prompt, text})

  @doc "Aborts the current run."
  @spec abort(GenServer.server()) :: :ok
  def abort(agent), do: :gen_statem.cast(agent, :abort)

  @doc "Returns the current agent state."
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(agent), do: :gen_statem.call(agent, :get_state)

  @doc "Returns the full message list including system prompt and repairs."
  @spec get_context(GenServer.server()) :: [Opal.Message.t()]
  def get_context(agent), do: :gen_statem.call(agent, :get_context)

  @doc "Hot-swaps the LLM model."
  @spec set_model(GenServer.server(), Opal.Provider.Model.t()) :: :ok
  def set_model(agent, %Opal.Provider.Model{} = model),
    do: :gen_statem.call(agent, {:set_model, model})

  @doc "Hot-swaps the provider module."
  @spec set_provider(GenServer.server(), module()) :: :ok
  def set_provider(agent, provider) when is_atom(provider),
    do: :gen_statem.call(agent, {:set_provider, provider})

  @doc "Replaces conversation history (used by RPC for branch navigation)."
  @spec sync_messages(GenServer.server(), [Opal.Message.t()]) :: :ok
  def sync_messages(agent, messages) when is_list(messages),
    do: :gen_statem.call(agent, {:sync_messages, messages})

  @doc "Applies runtime config: feature toggles and/or enabled tools."
  @type config_attrs :: %{
          optional(:features) => %{optional(atom()) => boolean()},
          optional(:enabled_tools) => [String.t()]
        }
  @spec configure(GenServer.server(), config_attrs()) :: :ok
  def configure(agent, attrs) when is_map(attrs),
    do: :gen_statem.call(agent, {:configure, attrs})

  # ── gen_statem Callbacks ──────────────────────────────────────────────

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Registry.register(Opal.Registry, {:agent, session_id}, nil)
    :proc_lib.set_label("agent:#{session_id}")

    model = Keyword.fetch!(opts, :model)
    working_dir = Keyword.fetch!(opts, :working_dir)
    config = Keyword.get(opts, :config, Opal.Config.new())
    provider = Keyword.get(opts, :provider, config.provider)

    %{entries: entries, files: files, skills: skills} = discover_context(config, working_dir)
    %{native: native, mcp: mcp} = resolve_tools(opts)

    state =
      %State{
        session_id: session_id,
        system_prompt: Keyword.get(opts, :system_prompt, ""),
        model: model,
        tools: native ++ mcp,
        disabled_tools: Keyword.get(opts, :disabled_tools, []),
        working_dir: working_dir,
        config: config,
        provider: provider,
        session: resolve_session(session_id, opts),
        tool_supervisor: Keyword.fetch!(opts, :tool_supervisor),
        sub_agent_supervisor: Keyword.get(opts, :sub_agent_supervisor),
        mcp_supervisor: Keyword.get(opts, :mcp_supervisor),
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        context_entries: entries,
        context_files: files,
        available_skills: skills,
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
    if files != [], do: Emitter.broadcast(state, {:context_discovered, files})

    Logger.debug(
      "Agent ready session=#{session_id} " <>
        "tools=[#{Enum.map_join(native, ", ", & &1.name())}] " <>
        "mcp=#{length(mcp)} skills=#{length(skills)}"
    )

    {:ok, :idle, state}
  end

  # ╔═══════════════════════════════════════════════════════════════════╗
  # ║  :idle — waiting for a prompt                                    ║
  # ╚═══════════════════════════════════════════════════════════════════╝

  @doc false
  def idle({:call, from}, {:prompt, text}, state) do
    Logger.debug("Prompt received session=#{state.session_id} len=#{String.length(text)}")

    state =
      state
      |> State.append_message(Opal.Message.user(text))
      |> Map.put(:status, :running)

    Emitter.broadcast(state, {:message_applied, text})
    Emitter.broadcast(state, {:agent_start})

    {:next_state, :running, state,
     [{:reply, from, %{queued: false}}, {:next_event, :internal, :run_turn}]}
  end

  def idle({:call, from}, msg, state), do: shared_call(from, msg, state)
  def idle(:cast, :abort, state), do: do_abort(state)
  def idle(_event_type, _event, state), do: {:keep_state, state}

  # ╔═══════════════════════════════════════════════════════════════════╗
  # ║  :running — about to call the provider or waiting to retry       ║
  # ╚═══════════════════════════════════════════════════════════════════╝

  @doc false
  def running(:internal, :run_turn, state), do: run_turn(state)
  def running(:info, :retry_turn, state), do: run_turn(state)
  def running({:call, from}, {:prompt, text}, state), do: enqueue(from, text, state)
  def running({:call, from}, msg, state), do: shared_call(from, msg, state)
  def running(:cast, :abort, state), do: do_abort(state)
  def running(_event_type, _event, state), do: {:keep_state, state}

  # ╔═══════════════════════════════════════════════════════════════════╗
  # ║  :streaming — consuming LLM response chunks                     ║
  # ╚═══════════════════════════════════════════════════════════════════╝

  @stall_ms 10_000

  # SSE stream (HTTP providers like Copilot)
  def streaming(:info, msg, %State{streaming_resp: resp} = state) when resp != nil do
    case Req.parse_message(resp, msg) do
      {:ok, chunks} when is_list(chunks) ->
        state = fold_sse(chunks, state)

        cond do
          state.stream_errored != false ->
            recover_stream_error(%{state | streaming_resp: nil})

          :done in chunks ->
            finalize_response(state)

          true ->
            {:keep_state, state, [stall_timeout()]}
        end

      :unknown ->
        {:keep_state, state}
    end
  end

  # Stall detection — fires when no chunks arrive within @stall_ms
  def streaming(:state_timeout, :stall_check, state) do
    Emitter.broadcast(state, {:stream_stalled, div(@stall_ms, 1_000)})
    {:keep_state, state, [{:state_timeout, 5_000, :stall_check}]}
  end

  def streaming({:call, from}, {:prompt, text}, state), do: enqueue(from, text, state)
  def streaming({:call, from}, msg, state), do: shared_call(from, msg, state)
  def streaming(:cast, :abort, state), do: do_abort(state)
  def streaming(_event_type, _event, state), do: {:keep_state, state}

  # ╔═══════════════════════════════════════════════════════════════════╗
  # ║  :executing_tools — running tool calls concurrently              ║
  # ╚═══════════════════════════════════════════════════════════════════╝

  @doc false
  # Tool task completed
  def executing_tools(
        :info,
        {ref, result},
        %State{pending_tool_tasks: tasks} = state
      )
      when is_reference(ref) and is_map_key(tasks, ref) do
    {task, tc} = Map.fetch!(tasks, ref)
    Process.demonitor(task.ref, [:flush])
    ToolRunner.collect_result(ref, tc, result, state) |> next()
  end

  # Tool task crashed
  def executing_tools(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        %State{pending_tool_tasks: tasks} = state
      )
      when is_map_key(tasks, ref) do
    {_task, tc} = Map.fetch!(tasks, ref)
    Logger.error("Tool crashed: #{inspect(reason)}")

    ToolRunner.collect_result(ref, tc, {:error, "Tool crashed: #{inspect(reason)}"}, state)
    |> next()
  end

  def executing_tools({:call, from}, {:prompt, text}, state), do: enqueue(from, text, state)
  def executing_tools({:call, from}, msg, state), do: shared_call(from, msg, state)
  def executing_tools(:cast, :abort, state), do: do_abort(state)
  def executing_tools(_event_type, _event, state), do: {:keep_state, state}

  # ── Shared Call Dispatch ──────────────────────────────────────────────

  defp shared_call(from, msg, state) do
    {reply, state} = handle_call(msg, state)
    {:keep_state, state, [{:reply, from, reply}]}
  end

  defp handle_call(:get_state, state), do: {state, state}
  defp handle_call(:get_context, state), do: {build_messages(state), state}

  defp handle_call({:set_model, model}, state) do
    Logger.debug("Model → #{model.id} session=#{state.session_id}")
    {:ok, %{state | model: model}}
  end

  defp handle_call({:set_provider, provider}, state) do
    Logger.debug("Provider → #{inspect(provider)} session=#{state.session_id}")
    {:ok, %{state | provider: provider}}
  end

  defp handle_call({:sync_messages, messages}, state) do
    Logger.debug("Messages synced session=#{state.session_id} count=#{length(messages)}")
    {:ok, %{state | messages: Enum.reverse(messages)}}
  end

  defp handle_call({:configure, attrs}, state), do: {:ok, apply_config(state, attrs)}

  # ── Prompt Queuing ────────────────────────────────────────────────────

  defp enqueue(from, text, state) do
    Logger.debug("Prompt queued session=#{state.session_id}")
    Emitter.broadcast(state, {:message_queued, text})

    {:keep_state, %{state | pending_messages: state.pending_messages ++ [text]},
     [{:reply, from, %{queued: true}}]}
  end

  # ── Turn Lifecycle ────────────────────────────────────────────────────

  defp run_turn(state) do
    state = state |> UsageTracker.maybe_auto_compact(&build_messages/1) |> repair_orphans()
    messages = build_messages(state)
    tools = ToolRunner.active_tools(state)

    Logger.debug(
      "Turn start session=#{state.session_id} msgs=#{length(messages)} tools=#{length(tools)}"
    )

    Emitter.broadcast(
      state,
      {:request_start, %{model: state.model.id, messages: length(messages)}}
    )

    case state.provider.stream(state.model, messages, tools,
           tool_context: %{working_dir: state.working_dir}
         ) do
      {:ok, resp} ->
        Emitter.broadcast(state, {:request_end})
        {:next_state, :streaming, begin_stream(state, streaming_resp: resp), [stall_timeout()]}

      {:error, reason} ->
        Logger.error("Provider stream failed: #{inspect(reason)}")
        handle_provider_error(state, reason)
    end
  end

  defp begin_stream(state, transport) do
    base = %{
      state
      | status: :streaming,
        streaming_resp: nil,
        current_text: "",
        current_tool_calls: [],
        current_thinking: nil,
        message_started: false,
        last_chunk_at: System.monotonic_time(:second),
        stream_watchdog: nil
    }

    Enum.reduce(transport, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp stall_timeout, do: {:state_timeout, @stall_ms, :stall_check}

  # ── Stream Folding ───────────────────────────────────────────────────

  defp fold_sse(chunks, state) do
    Enum.reduce(chunks, touch(state), fn
      {:data, data}, acc -> Opal.Agent.Stream.parse_sse_data(data, acc)
      _other, acc -> acc
    end)
  end

  defp touch(state), do: %{state | last_chunk_at: System.monotonic_time(:second)}

  # ── Response Finalization ─────────────────────────────────────────────

  defp finalize_response(state) do
    tool_calls = finalize_tool_calls(state.current_tool_calls)

    thinking =
      if state.current_thinking not in [nil, ""],
        do: [thinking: state.current_thinking],
        else: []

    assistant = Opal.Message.assistant(state.current_text, tool_calls, thinking)

    state =
      state
      |> State.append_message(assistant)
      |> Map.merge(%{
        streaming_resp: nil,
        status: :running,
        retry_count: 0
      })

    dispatch(state, assistant, tool_calls)
  end

  # Overflow detected during streaming → compact and retry
  defp dispatch(%{overflow_detected: true} = state, _assistant, _tcs) do
    UsageTracker.handle_overflow(%{state | overflow_detected: false}, :usage_overflow)
    |> next()
  end

  # Model requested tool calls → execute them
  defp dispatch(state, assistant, tcs) when tcs != [] do
    Emitter.broadcast(state, {:turn_end, assistant, []})
    ToolRunner.execute_batch(tcs, state) |> next()
  end

  # No tool calls → drain pending messages or finish
  defp dispatch(state, assistant, []) do
    state = ToolRunner.drain_pending(state)

    if match?(%{role: :user}, List.first(state.messages)) do
      Emitter.broadcast(state, {:turn_end, assistant, []})
      run_turn(state)
    else
      finish(state)
    end
  end

  defp finish(state) do
    context_window = Opal.Provider.Registry.context_window(state.model)

    usage =
      Map.merge(state.token_usage, %{
        context_window: context_window,
        current_context_tokens: state.last_prompt_tokens
      })

    Emitter.broadcast(state, {:agent_end, Enum.reverse(state.messages), usage})
    auto_save(state)
    {:next_state, :idle, %{state | status: :idle}}
  end

  defp finalize_tool_calls(raw) do
    raw
    |> Enum.map(fn tc ->
      args = tc[:arguments] || decode_args(tc[:arguments_json])
      %{call_id: tc[:call_id] || "", name: tc[:name] || "", arguments: args}
    end)
    |> Enum.reject(&(&1.call_id == "" or &1.name == ""))
  end

  defp decode_args(nil), do: %{}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, args} -> args
      {:error, _} -> %{}
    end
  end

  # ── Error Handling ────────────────────────────────────────────────────

  defp handle_provider_error(state, reason) do
    cond do
      Opal.Agent.Overflow.context_overflow?(reason) ->
        UsageTracker.handle_overflow(state, reason) |> next()

      Opal.Agent.Retry.retryable?(reason) and state.retry_count < state.max_retries ->
        schedule_retry(state, reason)

      true ->
        Emitter.broadcast(state, {:error, reason})
        {:next_state, :idle, %{state | status: :idle, retry_count: 0}}
    end
  end

  defp recover_stream_error(%{stream_errored: reason} = state) when reason != false do
    if Opal.Agent.Overflow.context_overflow?(reason) do
      UsageTracker.handle_overflow(%{state | stream_errored: false}, reason) |> next()
    else
      {:next_state, :idle, %{state | status: :idle, stream_errored: false}}
    end
  end

  defp schedule_retry(state, reason) do
    attempt = state.retry_count + 1

    delay =
      Opal.Agent.Retry.delay(attempt,
        base_ms: state.retry_base_delay_ms,
        max_ms: state.retry_max_delay_ms
      )

    Logger.info("Retrying in #{delay}ms (attempt #{attempt}/#{state.max_retries})")
    Emitter.broadcast(state, {:retry, attempt, delay, reason})
    Process.send_after(self(), :retry_turn, delay)
    {:next_state, :running, %{state | status: :running, retry_count: attempt}}
  end

  # ── Abort ─────────────────────────────────────────────────────────────

  defp do_abort(state) do
    state = state |> cancel_stream() |> cancel_tools()
    Emitter.broadcast(state, {:agent_abort})
    {:next_state, :idle, %{state | status: :idle}}
  end

  defp cancel_stream(%{streaming_resp: nil} = state), do: state

  defp cancel_stream(%{streaming_resp: resp} = state) do
    Req.cancel_async_response(resp)
    %{State.reset_stream_fields(state) | streaming_resp: nil}
  end

  defp cancel_tools(state),
    do: state |> ToolRunner.cancel_all() |> repair_orphans()

  # ── Continuation ──────────────────────────────────────────────────────
  #
  # ToolRunner and UsageTracker return `{:next_turn, state}` to loop
  # or `%State{}` to stay put. Translate to gen_statem tuples.

  defp next({:next_turn, state}), do: run_turn(%{state | status: :running})
  defp next(%State{} = state), do: {:next_state, state.status, state}

  # ── Messages ──────────────────────────────────────────────────────────

  defp build_messages(state) do
    repaired = state.messages |> Enum.reverse() |> Repair.ensure_tool_results()

    case Opal.Agent.SystemPrompt.build(state) do
      nil -> repaired
      prompt -> [Opal.Message.system(prompt) | repaired]
    end
  end

  defp repair_orphans(%State{messages: messages} = state) do
    case Repair.find_orphaned_calls(messages) do
      [] ->
        state

      ids ->
        Logger.debug("Repairing #{length(ids)} orphaned tool_calls")

        Enum.reduce(ids, state, fn id, acc ->
          State.append_message(acc, Opal.Message.tool_result(id, "[Aborted by user]", true))
        end)
    end
  end

  # ── Configuration ─────────────────────────────────────────────────────

  @feature_keys [:sub_agents, :skills, :mcp, :debug]

  defp apply_config(state, attrs) do
    state
    |> apply_features(Map.get(attrs, :features, %{}))
    |> apply_enabled_tools(Map.get(attrs, :enabled_tools))
  end

  defp apply_features(state, features) when is_nil(features) or map_size(features) == 0, do: state

  defp apply_features(state, features) do
    Enum.reduce(@feature_keys, state, fn key, acc ->
      case Map.get(features, key) do
        enabled when is_boolean(enabled) -> toggle_feature(acc, key, enabled)
        _ -> acc
      end
    end)
  end

  defp toggle_feature(%{config: config} = state, key, enabled) do
    current = Map.fetch!(config.features, key)
    features = Map.put(config.features, key, Map.put(current, :enabled, enabled))
    state = %{state | config: %{config | features: features}}
    if key == :debug and not enabled, do: Emitter.clear(state.session_id)
    state
  end

  defp apply_enabled_tools(state, nil), do: state

  defp apply_enabled_tools(%{tools: tools} = state, enabled) when is_list(enabled) do
    enabled_set = MapSet.new(enabled)
    disabled = tools |> Enum.map(& &1.name()) |> Enum.reject(&MapSet.member?(enabled_set, &1))
    %{state | disabled_tools: disabled}
  end

  # ── Init Helpers ──────────────────────────────────────────────────────

  defp resolve_session(session_id, opts) do
    case Keyword.get(opts, :session) do
      true ->
        case Opal.Util.Registry.lookup({:session, session_id}) do
          {:ok, pid} -> pid
          {:error, _} -> nil
        end

      pid when is_pid(pid) ->
        pid

      _ ->
        nil
    end
  end

  defp discover_context(config, dir) do
    entries =
      if config.features.context.enabled,
        do: Opal.Context.discover_context(dir, filenames: config.features.context.filenames),
        else: []

    skills =
      if config.features.skills.enabled,
        do: Opal.Context.discover_skills(dir, extra_dirs: config.features.skills.extra_dirs),
        else: []

    %{entries: entries, files: Enum.map(entries, & &1.path), skills: skills}
  end

  defp resolve_tools(opts) do
    native = Keyword.get(opts, :tools, [])
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    native_names = native |> Enum.map(& &1.name()) |> MapSet.new()
    %{native: native, mcp: discover_mcp(mcp_servers, native_names)}
  end

  defp maybe_recover_session(%State{session: nil} = state), do: state

  defp maybe_recover_session(%State{session: session} = state) do
    if Opal.Session.current_id(session) do
      messages = Opal.Session.get_path(session)
      Logger.info("Agent recovered session=#{state.session_id} msgs=#{length(messages)}")
      Emitter.broadcast(state, {:agent_recovered})
      %{state | messages: Enum.reverse(messages)}
    else
      state
    end
  end

  defp auto_save(%{session: nil}), do: :ok

  defp auto_save(%{session: session, config: config}) do
    if config.auto_save, do: Opal.Session.save(session, Opal.Config.sessions_dir(config))
  end

  defp discover_mcp([], _names), do: []

  defp discover_mcp(servers, names) do
    Opal.MCP.Bridge.discover_tool_modules(servers, names)
  catch
    kind, reason ->
      Logger.warning("MCP discovery failed: #{inspect(kind)} #{inspect(reason)}")
      []
  end
end
