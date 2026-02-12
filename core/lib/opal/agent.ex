defmodule Opal.Agent do
  @moduledoc """
  GenServer implementing the core agent loop.

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

  use GenServer
  require Logger

  defmodule State do
    @moduledoc """
    Internal state for `Opal.Agent`.

    Tracks conversation history, streaming state, accumulated response text
    and tool calls, and the provider module used for LLM communication.
    """

    @type t :: %__MODULE__{
            session_id: String.t(),
            system_prompt: String.t(),
            messages: [Opal.Message.t()],
            model: Opal.Model.t(),
            tools: [module()],
            working_dir: String.t(),
            config: Opal.Config.t(),
            status: :idle | :running | :streaming,
            streaming_resp: Req.Response.t() | nil,
            current_text: String.t(),
            current_tool_calls: [map()],
            pending_tool_calls: MapSet.t(),
            pending_steers: [String.t()],
            status_tag_buffer: String.t(),
            provider: module(),
            session: pid() | nil,
            tool_supervisor: atom() | pid(),
            sub_agent_supervisor: atom() | pid(),
            mcp_supervisor: atom() | pid() | nil,
            mcp_servers: [map()],
            context: String.t(),
            context_files: [String.t()],
            available_skills: [Opal.Skill.t()],
            active_skills: [String.t()],
            token_usage: map(),
            # Retry state — tracks exponential backoff across consecutive failures
            retry_count: non_neg_integer(),
            max_retries: pos_integer(),
            retry_base_delay_ms: pos_integer(),
            retry_max_delay_ms: pos_integer(),
            # Overflow detection — set when usage reports exceed context window
            overflow_detected: boolean()
          }

    @enforce_keys [:session_id, :model, :working_dir, :config]
    defstruct [
      :session_id,
      :model,
      :working_dir,
      :config,
      :streaming_resp,
      system_prompt: "",
      messages: [],
      tools: [],
      status: :idle,
      current_text: "",
      current_tool_calls: [],
      pending_tool_calls: MapSet.new(),
      pending_steers: [],
      status_tag_buffer: "",
      provider: Opal.Provider.Copilot,
      session: nil,
      tool_supervisor: nil,
      sub_agent_supervisor: nil,
      mcp_supervisor: nil,
      mcp_servers: [],
      context: "",
      context_files: [],
      available_skills: [],
      active_skills: [],
      token_usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, context_window: 0, current_context_tokens: 0},
      last_prompt_tokens: 0,
      last_chunk_at: nil,
      stream_watchdog: nil,
      # Retry: exponential backoff for transient provider errors (see Opal.Agent.Retry)
      retry_count: 0,
      max_retries: 3,
      retry_base_delay_ms: 2_000,
      retry_max_delay_ms: 60_000,
      # Overflow: flag set when usage-reported tokens exceed the context window
      overflow_detected: false,
      # Hybrid estimation: snapshot of message count when usage was last reported.
      # Messages added after this index are estimated heuristically.
      last_usage_msg_index: 0
    ]
  end

  # --- Public API ---

  @doc """
  Starts the agent GenServer.

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
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends an asynchronous user prompt to the agent.

  Appends a user message, sets status to `:running`, and begins a new LLM turn.
  Returns `:ok` immediately.
  """
  @spec prompt(GenServer.server(), String.t()) :: :ok
  def prompt(agent, text) when is_binary(text) do
    GenServer.cast(agent, {:prompt, text})
  end

  @doc """
  Injects a steering message into the agent.

  If the agent is idle, this behaves like `prompt/2`. If the agent is running
  or streaming, the steering message is queued in the GenServer mailbox and
  picked up between tool executions.
  """
  @spec steer(GenServer.server(), String.t()) :: :ok
  def steer(agent, text) when is_binary(text) do
    GenServer.cast(agent, {:steer, text})
  end

  @doc """
  Sends a follow-up prompt to the agent. Convenience alias for `prompt/2`.
  """
  @spec follow_up(GenServer.server(), String.t()) :: :ok
  def follow_up(agent, text) when is_binary(text) do
    GenServer.cast(agent, {:prompt, text})
  end

  @doc """
  Aborts the current agent run.

  If streaming, cancels the response. Sets status to `:idle`.
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(agent) do
    GenServer.cast(agent, :abort)
  end

  @doc """
  Returns the current agent state synchronously.
  """
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc """
  Loads a skill by name into the agent's active context.

  Returns `{:ok, skill_name}` if loaded, `{:already_loaded, skill_name}` if
  already active, or `{:error, reason}` if the skill is not found.
  """
  @spec load_skill(GenServer.server(), String.t()) :: {:ok, String.t()} | {:already_loaded, String.t()} | {:error, String.t()}
  def load_skill(agent, skill_name) do
    GenServer.call(agent, {:load_skill, skill_name})
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

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    :proc_lib.set_label("agent:#{session_id}")

    model = Keyword.fetch!(opts, :model)
    working_dir = Keyword.fetch!(opts, :working_dir)
    config = Keyword.get(opts, :config, Opal.Config.new())
    provider = Keyword.get(opts, :provider, config.provider)

    Logger.debug("Agent init session=#{session_id} model=#{model.provider}:#{model.id} dir=#{working_dir}")

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
        ctx_files = if config.features.context.enabled do
          Opal.Context.discover_context(working_dir, filenames: config.features.context.filenames)
        else
          []
        end

        skills = if config.features.skills.enabled do
          Opal.Context.discover_skills(working_dir, extra_dirs: config.features.skills.extra_dirs)
        else
          []
        end

        context_str = Opal.Context.build_context(working_dir,
          filenames: if(config.features.context.enabled, do: config.features.context.filenames, else: [])
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
      token_usage: %{
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        context_window: Opal.Models.context_window(model),
        current_context_tokens: 0
      }
    }

    tools_str = base_tools |> Enum.map(& &1.name()) |> Enum.join(", ")
    Logger.debug("Agent ready session=#{session_id} tools=[#{tools_str}] mcp_tools=#{length(mcp_tools)} skills=#{length(available_skills)}")

    # Emit context discovered event if any context files were found
    if context_files != [] do
      broadcast(state, {:context_discovered, context_files})
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:prompt, text}, %State{} = state) do
    Logger.debug("Prompt received session=#{state.session_id} len=#{String.length(text)} chars=\"#{String.slice(text, 0, 80)}\"")
    user_msg = Opal.Message.user(text)
    state = append_message(state, user_msg)
    state = %{state | status: :running}
    broadcast(state, {:agent_start})
    run_turn(state)
  end

  def handle_cast({:steer, text}, %State{status: :idle} = state) do
    # When idle, steering acts like a prompt
    user_msg = Opal.Message.user(text)
    state = append_message(state, user_msg)
    state = %{state | status: :running}
    broadcast(state, {:agent_start})
    run_turn(state)
  end

  def handle_cast({:steer, text}, %State{status: status} = state)
      when status in [:running, :streaming] do
    # Queue steering message — drained between tool executions
    {:noreply, %{state | pending_steers: state.pending_steers ++ [text]}}
  end

  def handle_cast(:abort, %State{} = state) do
    state = cancel_streaming(state)
    broadcast(state, {:agent_abort})
    {:noreply, %{state | status: :idle}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, build_messages(state), state}
  end

  @impl true
  def handle_call({:set_model, %Opal.Model{} = model}, _from, state) do
    Logger.debug("Model changed session=#{state.session_id} from=#{state.model.id} to=#{model.id}")
    {:reply, :ok, %{state | model: model}}
  end

  @impl true
  def handle_call({:set_provider, provider_module}, _from, state) when is_atom(provider_module) do
    Logger.debug("Provider changed session=#{state.session_id} to=#{inspect(provider_module)}")
    {:reply, :ok, %{state | provider: provider_module}}
  end

  @impl true
  def handle_call({:sync_messages, messages}, _from, state) do
    Logger.debug("Messages synced session=#{state.session_id} count=#{length(messages)}")
    {:reply, :ok, %{state | messages: messages}}
  end

  @impl true
  def handle_call({:load_skill, skill_name}, _from, %State{} = state) do
    if skill_name in state.active_skills do
      {:reply, {:already_loaded, skill_name}, state}
    else
      case Enum.find(state.available_skills, &(&1.name == skill_name)) do
        nil ->
          {:reply, {:error, "Skill '#{skill_name}' not found. Available: #{Enum.map_join(state.available_skills, ", ", & &1.name)}"}, state}

        skill ->
          # Inject instructions as a conversation message (ages out during compaction)
          skill_msg = %Opal.Message{
            id: "skill:#{skill_name}",
            role: :user,
            content: "[System] Skill '#{skill.name}' activated. Instructions:\n\n#{skill.instructions}"
          }

          new_active = [skill_name | state.active_skills]
          state = append_message(%{state | active_skills: new_active}, skill_msg)

          broadcast(state, {:skill_loaded, skill_name, skill.description})

          {:reply, {:ok, skill_name}, state}
      end
    end
  end

  @impl true
  def handle_info(message, %State{status: :streaming, streaming_resp: resp} = state)
      when resp != nil do
    case Req.parse_message(resp, message) do
      {:ok, chunks} when is_list(chunks) ->
        Logger.debug("SSE chunks received: #{inspect(chunks, limit: 3, printable_limit: 200)}")

        state = %{state | last_chunk_at: System.monotonic_time(:second)}

        state =
          Enum.reduce(chunks, state, fn
            {:data, data}, acc -> parse_sse_data(data, acc)
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
    run_turn(state)
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

  @auto_compact_threshold 0.80

  # Look up context window from LLMDB. Falls back to 128k if not found.
  defp model_context_window(model), do: Opal.Models.context_window(model)

  # Starts a new LLM turn: converts messages/tools, initiates streaming.
  # Auto-compacts if context usage exceeds threshold.
  defp run_turn(%State{} = state) do
    state = maybe_auto_compact(state)

    provider = state.provider
    all_messages = build_messages(state)
    tools = active_tools(state)

    Logger.debug("Turn start session=#{state.session_id} messages=#{length(all_messages)} tools=#{length(tools)} model=#{state.model.id}")
    broadcast(state, {:request_start, %{model: state.model.id, messages: length(all_messages)}})

    case provider.stream(state.model, all_messages, tools) do
      {:ok, resp} ->
        Logger.debug(
          "Provider stream started. Response status: #{resp.status}, body type: #{inspect(resp.body.__struct__)}"
        )
        broadcast(state, {:request_end})

        watchdog = Process.send_after(self(), :stream_watchdog, 10_000)

        state = %{
          state
          | streaming_resp: resp,
            status: :streaming,
            current_text: "",
            current_tool_calls: [],
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

          Opal.Agent.Retry.retryable?(reason) and state.retry_count < state.max_retries ->
            attempt = state.retry_count + 1

            delay =
              Opal.Agent.Retry.delay(attempt,
                base_ms: state.retry_base_delay_ms,
                max_ms: state.retry_max_delay_ms
              )

            Logger.info("Retrying in #{delay}ms (attempt #{attempt}/#{state.max_retries}): #{inspect(reason)}")
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
  defp maybe_auto_compact(%State{session: session, model: model} = state)
       when is_pid(session) do
    context_window = model_context_window(model)

    # Build hybrid estimate: actual usage base + heuristic for trailing messages
    estimated_tokens = estimate_current_tokens(state, context_window)
    ratio = estimated_tokens / context_window

    if ratio >= @auto_compact_threshold do
      Logger.info("Auto-compacting: ~#{estimated_tokens} estimated tokens / #{context_window} context (#{Float.round(ratio * 100, 1)}%)")
      broadcast(state, {:compaction_start, length(state.messages)})

      case Opal.Session.Compaction.compact(session,
             provider: state.provider,
             model: state.model,
             keep_recent_tokens: div(context_window, 4)) do
        :ok ->
          new_path = Opal.Session.get_path(session)
          broadcast(state, {:compaction_end, length(state.messages), length(new_path)})
          %{state | messages: new_path, last_prompt_tokens: 0, last_usage_msg_index: 0}

        {:error, reason} ->
          Logger.warning("Auto-compaction failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp maybe_auto_compact(state), do: state

  # Builds a token estimate using the hybrid approach:
  # - If we have a recent usage report, use it as a calibrated base and add
  #   heuristic estimates for messages added since.
  # - If no usage data yet, fall back to full heuristic estimation.
  defp estimate_current_tokens(%State{} = state, _context_window) do
    if state.last_prompt_tokens > 0 do
      # Messages added after the last usage report
      messages_since = Enum.drop(state.messages, state.last_usage_msg_index)
      Opal.Token.hybrid_estimate(state.last_prompt_tokens, messages_since)
    else
      # No usage data yet — estimate the full context heuristically
      Opal.Token.estimate_context(build_messages(state))
    end
  end

  # ── Overflow Recovery ─────────────────────────────────────────────────
  #
  # When the provider rejects a request because the conversation exceeds
  # the context window, we aggressively compact (keeping only ~20% of
  # context) and auto-retry the turn. This is NOT counted as a retry
  # attempt — it's a structural recovery, not a transient-error retry.

  # Without a session process we can't compact — surface the raw error.
  defp handle_overflow_compaction(%State{session: nil} = state, reason) do
    Logger.error("Context overflow but no session attached — cannot compact")
    broadcast(state, {:error, {:overflow_no_session, reason}})
    {:noreply, %{state | status: :idle}}
  end

  defp handle_overflow_compaction(%State{session: session, model: model} = state, reason) do
    context_window = model_context_window(model)

    # Aggressive keep budget: retain only ~20% of the context window so
    # the retried turn has plenty of headroom.
    keep_tokens = div(context_window, 5)

    Logger.info("Context overflow detected — compacting to #{keep_tokens} tokens")
    broadcast(state, {:compaction_start, :overflow})

    case Opal.Session.Compaction.compact(session,
           provider: state.provider,
           model: state.model,
           keep_recent_tokens: keep_tokens,
           force: true) do
      :ok ->
        new_path = Opal.Session.get_path(session)
        broadcast(state, {:compaction_end, length(state.messages), length(new_path)})
        state = %{state | messages: new_path, last_prompt_tokens: 0, overflow_detected: false, last_usage_msg_index: 0}

        # Auto-retry the turn immediately after compaction
        run_turn(state)

      {:error, compact_error} ->
        Logger.error("Overflow compaction failed: #{inspect(compact_error)}")
        broadcast(state, {:error, {:overflow_compact_failed, reason, compact_error}})
        {:noreply, %{state | status: :idle}}
    end
  end

  # Prepends system prompt (with discovered context, skill menu, and
  # tool usage guidelines appended) as a system message.
  defp build_messages(%State{system_prompt: prompt, context: context, messages: messages, available_skills: skills} = state)
       when (prompt != "" and prompt != nil) or (context != "" and context != nil) do
    # Build skill menu if skills are available
    skill_menu =
      if skills != [] do
        summaries = Enum.map_join(skills, "\n", &Opal.Skill.summary/1)
        "\n\n## Available Skills\n\nUse the `use_skill` tool to load a skill's full instructions when relevant.\n\n#{summaries}"
      else
        ""
      end

    # Build dynamic tool guidelines based on which tools are active
    # (prevents the LLM from using shell for read/edit/write operations)
    tool_guidelines = Opal.Agent.SystemPrompt.build_guidelines(active_tools(state))

    full_prompt =
      [prompt || "", context || "", skill_menu, tool_guidelines]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    system_msg = %Opal.Message{
      id: "system",
      role: :system,
      content: full_prompt
    }

    [system_msg | messages]
  end

  defp build_messages(%State{messages: messages}), do: messages

  # Parses raw SSE data, dispatching events for each line.
  defp parse_sse_data(data, state) do
    binary = IO.iodata_to_binary(data)

    Logger.debug(
      "SSE raw data (#{byte_size(binary)} bytes): #{inspect(String.slice(binary, 0, 300))}"
    )

    binary
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, fn line, acc ->
      case line do
        "data: [DONE]" ->
          acc

        "data: " <> json_data ->
          dispatch_sse_events(json_data, acc)

        # Handle raw JSON error responses (no SSE prefix)
        "{" <> _ = json_data ->
          dispatch_sse_events(json_data, acc)

        _ ->
          acc
      end
    end)
  end

  # Decodes a single SSE JSON line and dispatches all parsed events.
  defp dispatch_sse_events(json_data, state) do
    events = state.provider.parse_stream_event(json_data)
    Logger.debug("Parsed SSE events: #{inspect(events, limit: 5, printable_limit: 200)}")

    Enum.reduce(events, state, fn event, acc ->
      handle_stream_event(event, acc)
    end)
  end

  # --- Stream Event Handlers ---

  defp handle_stream_event({:text_start, _info}, state) do
    broadcast(state, {:message_start})
    state
  end

  defp handle_stream_event({:text_delta, delta}, state) do
    {clean_delta, state} = extract_status_tags(delta, state)

    unless clean_delta == "" do
      broadcast(state, {:message_delta, %{delta: clean_delta}})
    end

    %{state | current_text: state.current_text <> clean_delta}
  end

  defp handle_stream_event({:text_done, text}, state) do
    %{state | current_text: text}
  end

  defp handle_stream_event({:thinking_start, _info}, state) do
    broadcast(state, {:thinking_start})
    state
  end

  defp handle_stream_event({:thinking_delta, delta}, state) do
    broadcast(state, {:thinking_delta, %{delta: delta}})
    state
  end

  defp handle_stream_event({:tool_call_start, info}, state) do
    # Start a new tool call accumulator
    tool_call = %{
      call_id: info[:call_id],
      name: info[:name],
      arguments_json: ""
    }

    %{state | current_tool_calls: state.current_tool_calls ++ [tool_call]}
  end

  defp handle_stream_event({:tool_call_delta, delta}, state) do
    # Append to the last tool call's arguments JSON
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _} ->
          state.current_tool_calls

        {last_tc, rest} ->
          rest ++ [%{last_tc | arguments_json: last_tc.arguments_json <> delta}]
      end

    %{state | current_tool_calls: updated}
  end

  defp handle_stream_event({:tool_call_done, info}, state) do
    # Finalize the tool call with parsed arguments
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _} ->
          # No in-progress tool call — create one from the done event
          [
            %{
              call_id: info[:call_id],
              name: info[:name],
              arguments: info[:arguments] || %{}
            }
          ]

        {last_tc, rest} ->
          # Merge final info into the accumulated tool call
          arguments =
            info[:arguments] ||
              case Jason.decode(last_tc[:arguments_json] || "{}") do
                {:ok, parsed} -> parsed
                {:error, _} -> %{}
              end

          finalized = %{
            call_id: info[:call_id] || last_tc[:call_id],
            name: info[:name] || last_tc[:name],
            arguments: arguments
          }

          rest ++ [finalized]
      end

    %{state | current_tool_calls: updated}
  end

  defp handle_stream_event({:usage, usage}, state) do
    # Handle both Chat Completions keys (prompt_tokens) and Responses API keys (input_tokens)
    prompt = Map.get(usage, "prompt_tokens", Map.get(usage, :prompt_tokens,
               Map.get(usage, "input_tokens", Map.get(usage, :input_tokens, 0)))) || 0
    completion = Map.get(usage, "completion_tokens", Map.get(usage, :completion_tokens,
                   Map.get(usage, "output_tokens", Map.get(usage, :output_tokens, 0)))) || 0
    total = Map.get(usage, "total_tokens", Map.get(usage, :total_tokens, prompt + completion)) || 0

    token_usage = %{
      state.token_usage |
      prompt_tokens: state.token_usage.prompt_tokens + prompt,
      completion_tokens: state.token_usage.completion_tokens + completion,
      total_tokens: state.token_usage.total_tokens + total,
      current_context_tokens: prompt
    }

    state = %{state | token_usage: token_usage, last_prompt_tokens: prompt, last_usage_msg_index: length(state.messages)}
    context_window = model_context_window(state.model)

    broadcast(state, {:usage_update, %{state.token_usage | context_window: context_window}})

    # Flag usage-based overflow so finalize_response/1 can trigger compaction
    # before the *next* turn pushes past the limit.
    if Opal.Agent.Overflow.usage_overflow?(prompt, context_window) do
      Logger.warning("Usage overflow: #{prompt} input tokens > #{context_window} context window")
      %{state | overflow_detected: true}
    else
      state
    end
  end

  defp handle_stream_event({:response_done, info}, state) do
    # Responses API includes usage inline; Chat Completions sends it separately via {:usage, ...}
    case Map.get(info, :usage, %{}) do
      usage when usage != %{} -> handle_stream_event({:usage, usage}, state)
      _ -> state
    end
  end

  defp handle_stream_event({:error, reason}, state) do
    Logger.error("Stream error: #{inspect(reason)}")
    broadcast(state, {:error, reason})
    %{state | status: :idle, streaming_resp: nil}
  end

  defp handle_stream_event(_unknown, state), do: state

  # --- Response Finalization ---

  # Called when the SSE stream is complete. Creates the assistant message,
  # then either executes tool calls or ends the agent loop.
  defp finalize_response(%State{} = state) do
    cancel_watchdog(state)

    Logger.debug(
      "Finalizing response. Text: #{inspect(String.slice(state.current_text, 0, 100))}. Tool calls: #{inspect(length(state.current_tool_calls))}"
    )

    tool_calls = finalize_tool_calls(state.current_tool_calls)

    assistant_msg = Opal.Message.assistant(state.current_text, tool_calls)
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
      execute_tool_calls(tool_calls, state)
    else
      # Drain any steering messages that arrived during this turn
      state = check_for_steering(state)
      last_msg = List.last(state.messages)

      if last_msg && last_msg.role == :user do
        # Steers were injected — continue with a new turn
        broadcast(state, {:turn_end, assistant_msg, []})
        run_turn(state)
      else
        context_window = model_context_window(state.model)
        final_usage = Map.merge(state.token_usage, %{
          context_window: context_window,
          current_context_tokens: state.last_prompt_tokens
        })
        broadcast(state, {:agent_end, state.messages, final_usage})
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

  # Executes tool calls sequentially, checking for user steers between each
  # call. When a steer is detected, all remaining tool calls in the batch
  # are skipped — the LLM will see the skip messages alongside the user's
  # new instructions and decide how to proceed.
  #
  # Sequential execution trades parallelism for responsiveness: the user
  # can redirect the agent mid-batch instead of waiting for all tools to
  # finish (some of which may be destructive writes or shell commands).
  defp execute_tool_calls(tool_calls, %State{} = state) do
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
          result = execute_single_tool_supervised(tc, st, context)
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

    # Process any steers that arrived during the last tool execution
    state = check_for_steering(state)

    # Start next turn
    run_turn(state)
  end

  # Builds the shared context map passed to every tool execution.
  defp build_tool_context(%State{} = state) do
    %{
      working_dir: state.working_dir,
      session_id: state.session_id,
      config: state.config,
      agent_pid: self(),
      agent_state: state
    }
  end

  # Runs a single tool call under the session's Task.Supervisor.
  # Broadcasts lifecycle events and catches task crashes.
  defp execute_single_tool_supervised(tc, %State{} = state, context) do
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

  # Selectively receives `:steer` GenServer casts from the process mailbox
  # without blocking. Uses a zero timeout so it returns immediately when
  # there are no pending steers — this is the mechanism that lets us check
  # for user redirection between sequential tool calls.
  defp drain_mailbox_steers(state) do
    receive do
      {:"$gen_cast", {:steer, text}} ->
        state = %{state | pending_steers: state.pending_steers ++ [text]}
        drain_mailbox_steers(state)
    after
      0 -> state
    end
  end

  # Executes a single tool, catching any exceptions.
  defp execute_single_tool(nil, _args, _context) do
    {:error, "Tool not found"}
  end

  defp execute_single_tool(tool_mod, args, context) do
    tool_mod.execute(args, context)
  rescue
    e ->
      Logger.error("Tool #{inspect(tool_mod)} raised: #{Exception.message(e)}")
      {:error, "Tool raised an exception: #{Exception.message(e)}"}
  end

  # Finds the tool module whose name/0 matches the given name string.
  defp find_tool_module(name, tools) do
    Enum.find(tools, fn tool_mod ->
      tool_mod.name() == name
    end)
  end

  # Returns the tools list with config-gated tools filtered out.
  defp active_tools(%State{tools: tools, config: config, available_skills: skills}) do
    tools
    |> then(fn t ->
      if config.features.sub_agents.enabled, do: t, else: Enum.reject(t, &(&1 == Opal.Tool.SubAgent))
    end)
    |> then(fn t ->
      if skills != [], do: t, else: Enum.reject(t, &(&1 == Opal.Tool.UseSkill))
    end)
  end

  # Drains pending steering messages queued while agent was busy.
  defp check_for_steering(%State{pending_steers: []} = state), do: state

  defp check_for_steering(%State{pending_steers: steers} = state) do
    state = Enum.reduce(steers, state, fn text, acc ->
      Logger.debug("Steering message received: #{String.slice(text, 0, 50)}...")
      append_message(acc, Opal.Message.user(text))
    end)
    %{state | pending_steers: []}
  end

  # Cancels an in-progress streaming response if present.
  defp cancel_streaming(%State{streaming_resp: nil} = state), do: state

  defp cancel_streaming(%State{streaming_resp: resp} = state) do
    cancel_watchdog(state)
    Req.cancel_async_response(resp)
    %{state | streaming_resp: nil, current_text: "", current_tool_calls: [], stream_watchdog: nil, last_chunk_at: nil}
  end

  defp cancel_watchdog(%{stream_watchdog: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end
  defp cancel_watchdog(_), do: :ok

  # Broadcasts an event to all subscribers of this session.
  defp broadcast(%State{session_id: session_id}, event) do
    Opal.Events.broadcast(session_id, event)
  end

  # Appends a single message. When a Session process is attached, the message
  # is also stored in the session tree. The local messages list is always
  # updated for LLM context building.
  defp append_message(%State{session: nil} = state, msg) do
    %{state | messages: state.messages ++ [msg]}
  end

  defp append_message(%State{session: session} = state, msg) do
    Opal.Session.append(session, msg)
    %{state | messages: state.messages ++ [msg]}
  end

  # Appends multiple messages at once.
  defp append_messages(%State{session: nil} = state, msgs) do
    %{state | messages: state.messages ++ msgs}
  end

  defp append_messages(%State{session: session} = state, msgs) do
    Opal.Session.append_many(session, msgs)
    %{state | messages: state.messages ++ msgs}
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

  defp generate_session_title(%State{session: session, model: model, provider: provider}, user_text) do
    prompt_text = String.slice(user_text, 0, 500)

    title_messages = [
      %Opal.Message{id: "sys", role: :system, content: "Generate a concise 3-6 word title for this conversation. Reply with ONLY the title, no quotes or punctuation."},
      Opal.Message.user(prompt_text)
    ]

    case provider.stream(model, title_messages, []) do
      {:ok, resp} ->
        title = collect_stream_text(resp, provider, "")

        if title != "" do
          clean = title |> String.trim() |> String.slice(0, 60)
          Opal.Session.set_metadata(session, :title, clean)
        end

      {:error, _} ->
        :ok
    end
  end

  # Synchronously collects all text from a streaming response.
  defp collect_stream_text(resp, provider, acc) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} when is_list(chunks) ->
            new_acc =
              Enum.reduce(chunks, acc, fn
                {:data, data}, text_acc ->
                  binary = IO.iodata_to_binary(data)

                  binary
                  |> String.split("\n", trim: true)
                  |> Enum.reduce(text_acc, fn
                    "data: [DONE]", inner -> inner
                    "data: " <> json, inner ->
                      events = provider.parse_stream_event(json)

                      Enum.reduce(events, inner, fn
                        {:text_delta, delta}, t -> t <> delta
                        _, t -> t
                      end)

                    _, inner -> inner
                  end)

                :done, text_acc -> text_acc
                _, text_acc -> text_acc
              end)

            if :done in chunks do
              new_acc
            else
              collect_stream_text(resp, provider, new_acc)
            end

          :unknown ->
            collect_stream_text(resp, provider, acc)
        end
    after
      10_000 -> acc
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

  defp result_tag({:ok, _}), do: "ok"
  defp result_tag({:error, _}), do: "error"
  defp result_tag(_), do: "unknown"

  # Extracts <status>...</status> tags from streaming text deltas.
  # Tags may span multiple deltas, so we buffer partial matches.
  # Returns {clean_text, updated_state} with tags stripped and broadcast.
  defp extract_status_tags(delta, %State{status_tag_buffer: buf} = state) do
    text = buf <> delta

    case Regex.run(~r/<status>(.*?)<\/status>/s, text) do
      [full_match, status_text] ->
        broadcast(state, {:status_update, String.trim(status_text)})
        clean = String.replace(text, full_match, "", global: false)
        # Recurse in case there are multiple tags in one chunk
        {more_clean, state} = extract_status_tags("", %{state | status_tag_buffer: ""})
        {clean <> more_clean, state}

      nil ->
        # Check if we might be in the middle of a tag
        cond do
          String.contains?(text, "<status>") and not String.contains?(text, "</status>") ->
            # Partial open tag — buffer everything from <status> onward
            [before | _] = String.split(text, "<status>", parts: 2)
            rest = String.slice(text, String.length(before)..-1//1)
            {before, %{state | status_tag_buffer: rest}}

          String.ends_with?(text, "<") or
          String.ends_with?(text, "<s") or
          String.ends_with?(text, "<st") or
          String.ends_with?(text, "<sta") or
          String.ends_with?(text, "<stat") or
          String.ends_with?(text, "<statu") or
            String.ends_with?(text, "<status") ->
            # Might be start of a tag — buffer the trailing potential match
            idx = String.length(text) - partial_tag_length(text)
            {String.slice(text, 0, idx), %{state | status_tag_buffer: String.slice(text, idx..-1//1)}}

          true ->
            {text, %{state | status_tag_buffer: ""}}
        end
    end
  end

  defp partial_tag_length(text) do
    suffixes = ["<status", "<statu", "<stat", "<sta", "<st", "<s", "<"]
    Enum.find_value(suffixes, 0, fn s ->
      if String.ends_with?(text, s), do: String.length(s)
    end)
  end
end
