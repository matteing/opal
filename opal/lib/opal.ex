defmodule Opal do
  @moduledoc """
  Public API for the Opal coding agent SDK.

  Provides functions to start agent sessions, send prompts (async and sync),
  and manage session lifecycle. All agent events are broadcast via
  `Opal.Events` for real-time observability.

  Session defaults (model, tools, shell, data_dir) come from `Opal.Config`
  and can be overridden per-session.

  ## Quick Start

      {:ok, agent} = Opal.start_session(%{
        system_prompt: "You are a helpful coding assistant.",
        working_dir: "/path/to/project"
      })

      :ok = Opal.prompt(agent, "List all Elixir files")

      # Or synchronously:
      {:ok, response} = Opal.prompt_sync(agent, "What is 2 + 2?")
  """

  @doc """
  Starts a new agent session with the given configuration.

  All keys are optional — defaults come from `config :opal` via `Opal.Config`.

  ## Config Keys

    * `:model` — model specification. Accepts any form that `Opal.Provider.Model.coerce/2` supports:
      * A `{provider, model_id}` tuple (e.g. `{:anthropic, "claude-sonnet-4-5"}`)
      * A `"provider:model_id"` string (e.g. `"anthropic:claude-sonnet-4-5"`)
      * A bare model ID string defaults to Copilot (e.g. `"claude-sonnet-4-5"`)
    * `:tools` — list of modules implementing `Opal.Tool`
    * `:system_prompt` — the system prompt string (default: `""`)
    * `:working_dir` — base directory for tool execution (default: current dir)
    * `:provider` — module implementing `Opal.Provider` (default: `Opal.Provider.Copilot`)
    * `:session` — if `true`, starts an `Opal.Session` process for persistence/branching
    * `:shell` — shell type for `Opal.Tool.Shell` (default: platform auto-detect)
    * `:data_dir` — override data directory (default: `~/.opal`)

  ## Examples

      # Minimal — everything from config :opal
      {:ok, agent} = Opal.start_session(%{working_dir: "/project"})

      # Use Copilot (default provider)
      {:ok, agent} = Opal.start_session(%{
        model: {:copilot, "gpt-5"},
        working_dir: "/project"
      })
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, term()}
  def start_session(config) when is_map(config) do
    opts = build_session_opts(config)

    Opal.Config.ensure_dirs!(opts[:config])

    case DynamicSupervisor.start_child(Opal.SessionSupervisor, {Opal.SessionServer, opts}) do
      {:ok, session_server} ->
        agent = Opal.SessionServer.agent(session_server)
        {:ok, agent}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sends a prompt to the agent. Returns `%{queued: boolean}`.

  If the agent is idle, it starts immediately. If busy, the message is
  queued and applied between tool executions.

  Subscribe to `Opal.Events` with the session ID to receive streaming output.
  """
  @spec prompt(GenServer.server(), String.t()) :: %{queued: boolean()}
  def prompt(agent, text) do
    Opal.Agent.prompt(agent, text)
  end

  @doc """
  Sends a prompt and waits synchronously for the final response.

  Subscribes to the agent's events, sends the prompt, and collects text
  deltas until `:agent_end` is received. Returns the accumulated text.

  ## Options

    * `timeout` — maximum wait time in milliseconds (default: `60_000`)
  """
  @spec prompt_sync(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def prompt_sync(agent, text, timeout \\ 60_000) do
    state = Opal.Agent.get_state(agent)
    Opal.Events.subscribe(state.session_id)
    Opal.Agent.prompt(agent, text)
    Opal.Agent.Collector.collect_response(state.session_id, "", timeout)
  after
    state = Opal.Agent.get_state(agent)
    Opal.Events.unsubscribe(state.session_id)
  end

  @doc """
  Aborts the current agent run.
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(agent) do
    Opal.Agent.abort(agent)
  end

  @doc """
  Changes the model on a running agent session.

  The new model takes effect on the next prompt. Conversation history is preserved.

  Accepts any model specification that `Opal.Provider.Model.coerce/2` supports:

    * A `"provider:model_id"` string (e.g. `"copilot:claude-sonnet-4-5"`)
    * A `{provider, model_id}` tuple (e.g. `{:copilot, "gpt-5"}`)
    * An `%Opal.Provider.Model{}` struct

  ## Examples

      Opal.set_model(agent, {:copilot, "gpt-5"})
      Opal.set_model(agent, "claude-sonnet-4-5")
      Opal.set_model(agent, "claude-sonnet-4-5", thinking_level: :high)
  """
  @spec set_model(pid(), Opal.Provider.Model.t() | String.t() | {atom(), String.t()}, keyword()) ::
          :ok
  def set_model(agent, model_spec, opts \\ []) do
    model = Opal.Provider.Model.coerce(model_spec, opts)
    Opal.Agent.set_model(agent, model)
  end

  @doc """
  Returns the full context window (system prompt + all messages) for a session.
  """
  @spec get_context(pid()) :: [Opal.Message.t()]
  def get_context(agent) do
    Opal.Agent.get_context(agent)
  end

  @doc """
  Stops a session and cleans up.

  Terminates the entire session supervision tree (agent, tools, sub-agents).
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(agent) when is_pid(agent) do
    # The agent's parent is the SessionServer supervisor
    case find_session_server(agent) do
      {:ok, session_server} ->
        DynamicSupervisor.terminate_child(Opal.SessionSupervisor, session_server)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a curated info map for the given agent.

  Useful for inspecting agent state without depending on internal structs.
  The returned map includes:

    * `:session_id` — unique session identifier
    * `:session_dir` — on-disk path for session persistence
    * `:status` — current agent status (`:idle`, `:running`, etc.)
    * `:model` — the active `%Opal.Provider.Model{}` struct
    * `:provider` — provider module (e.g. `Opal.Provider.Copilot`)
    * `:session` — session process pid (or `nil`)
    * `:working_dir` — base directory for tool execution
    * `:context_files` — list of discovered context files
    * `:available_skills` — list of available skill structs
    * `:mcp_servers` — list of connected MCP servers
    * `:tools` — list of tool modules
    * `:message_count` — number of messages in the conversation
    * `:token_usage` — token usage statistics
  """
  @spec get_info(pid()) :: map()
  def get_info(agent) do
    state = Opal.Agent.get_state(agent)
    session_dir = Path.join(Opal.Config.sessions_dir(state.config), state.session_id)

    %{
      session_id: state.session_id,
      session_dir: session_dir,
      status: state.status,
      model: state.model,
      provider: state.provider,
      session: state.session,
      working_dir: state.working_dir,
      context_files: state.context_files,
      available_skills: state.available_skills,
      mcp_servers: state.mcp_servers,
      tools: state.tools,
      message_count: length(state.messages),
      token_usage: state.token_usage
    }
  end

  @doc """
  Syncs the agent's message list with the given messages.

  Typically used after session compaction to update the agent with
  the compacted message history.
  """
  @spec sync_messages(pid(), list()) :: :ok
  def sync_messages(agent, messages) do
    Opal.Agent.sync_messages(agent, messages)
  end

  @doc """
  Sets the thinking level on the agent's current model.

  Updates only the thinking level while preserving the current model
  and provider. Returns `:ok`.

  ## Examples

      Opal.set_thinking_level(agent, :high)
      Opal.set_thinking_level(agent, :off)
  """
  @spec set_thinking_level(pid(), atom()) :: :ok
  def set_thinking_level(agent, level) do
    state = Opal.Agent.get_state(agent)
    model = %{state.model | thinking_level: level}
    Opal.Agent.set_model(agent, model)
  end

  @doc """
  Updates runtime feature/tool configuration for a running session.
  """
  @spec configure_session(pid(), map()) :: :ok
  def configure_session(agent, attrs) when is_map(attrs) do
    Opal.Agent.configure(agent, attrs)
  end

  @doc """
  Returns a lazy `Stream` of agent events for a prompt.

  Subscribes to the agent's event bus, sends the prompt, and yields
  `{event_type, payload}` tuples until the agent finishes (`:agent_end`).

  ## Examples

      {:ok, agent} = Opal.start_session(%{working_dir: "."})

      Opal.stream(agent, "List all files")
      |> Enum.each(fn
        {:message_delta, %{delta: text}} -> IO.write(text)
        {:agent_end, _} -> IO.puts("\\nDone!")
        _other -> :ok
      end)

  The stream is lazy — events are received on demand. It terminates
  automatically when `:agent_end` or `:error` is received.
  """
  @spec stream(GenServer.server(), String.t()) :: Enumerable.t()
  def stream(agent, text) do
    Stream.resource(
      fn ->
        state = Opal.Agent.get_state(agent)
        session_id = state.session_id
        Opal.Events.subscribe(session_id)
        Opal.Agent.prompt(agent, text)
        session_id
      end,
      fn
        {:done, session_id} ->
          {:halt, session_id}

        session_id ->
          receive do
            {:opal_event, ^session_id, {:agent_end, _} = event} ->
              {[event], {:done, session_id}}

            {:opal_event, ^session_id, {:agent_end, _, _} = event} ->
              {[event], {:done, session_id}}

            {:opal_event, ^session_id, {:error, _} = event} ->
              {[event], {:done, session_id}}

            {:opal_event, ^session_id, event} ->
              {[event], session_id}
          after
            120_000 ->
              {[{:error, :timeout}], {:done, session_id}}
          end
      end,
      fn
        {:done, session_id} -> Opal.Events.unsubscribe(session_id)
        session_id -> Opal.Events.unsubscribe(session_id)
      end
    )
  end

  # --- Private Helpers ---

  # Builds the full opts list for SessionServer from user-provided config.
  # Priority: explicit opts → saved settings → defaults.
  @spec build_session_opts(map()) :: keyword()
  defp build_session_opts(config) do
    cfg = Opal.Config.new(config)
    model = resolve_model(config, cfg)
    tools = Map.get(config, :tools) || cfg.default_tools

    [
      session_id: Map.get(config, :session_id) || Opal.Id.session(),
      system_prompt: Map.get(config, :system_prompt, ""),
      model: model,
      tools: tools,
      disabled_tools: resolve_disabled_tools(config, tools),
      working_dir: Map.get(config, :working_dir, File.cwd!()),
      config: cfg,
      provider: resolve_provider(config, cfg),
      session: Map.get(config, :session, false)
    ]
  end

  defp resolve_model(config, cfg) do
    model_opts =
      case config[:thinking_level],
        do: (
          nil -> []
          level -> [thinking_level: level]
        )

    case config[:model] do
      nil ->
        base =
          case Opal.Settings.get("default_model") do
            saved when is_binary(saved) and saved != "" -> saved
            _ -> cfg.default_model
          end

        Opal.Provider.Model.coerce(base, model_opts)

      spec ->
        Opal.Provider.Model.coerce(spec, model_opts)
    end
  end

  defp resolve_provider(config, cfg) do
    case config[:provider] do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> cfg.provider
    end
  end

  defp resolve_disabled_tools(config, tools) do
    all_names = Enum.map(tools, & &1.name())

    case config[:tool_names] do
      names when is_list(names) ->
        enabled = MapSet.new(names)
        Enum.reject(all_names, &MapSet.member?(enabled, &1))

      _ ->
        case config[:disabled_tools] do
          names when is_list(names) -> names
          _ -> []
        end
    end
  end

  # Finds the SessionServer supervisor that owns the given agent pid.
  defp find_session_server(agent) do
    case Process.info(agent, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$ancestors") do
          [parent | _] when is_pid(parent) -> {:ok, parent}
          _ -> :error
        end

      nil ->
        :error
    end
  end
end
