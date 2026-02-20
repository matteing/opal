defmodule Opal do
  @moduledoc """
  Public API for the Opal coding-agent SDK.

  Start sessions, send prompts, and stream events — all backed by OTP
  supervision and `Opal.Events` pub/sub.

      {:ok, agent} = Opal.start_session(%{working_dir: "."})

      Opal.stream(agent, "List all Elixir files")
      |> Enum.each(fn
        {:message_delta, %{delta: text}} -> IO.write(text)
        {:agent_end, _} -> IO.puts("\\nDone!")
        _ -> :ok
      end)
  """

  alias Opal.{Agent, Config, Events, Id, Provider.Model, SessionServer, Settings}

  # -- Types ------------------------------------------------------------------

  @typedoc "Model specification: struct, `\"provider:id\"` string, `{provider, id}` tuple, or `{provider, id, thinking_level}` triple."
  @type model_spec :: Model.t() | String.t() | {atom(), String.t()} | {atom(), String.t(), atom()}

  @typedoc "Options for `start_session/1`. All keys optional; defaults from `Opal.Config`."
  @type session_opts :: %{
          optional(:model) => model_spec(),
          optional(:tools) => [module()],
          optional(:system_prompt) => String.t(),
          optional(:working_dir) => String.t(),
          optional(:provider) => module(),
          optional(:session) => boolean(),
          optional(:session_id) => String.t(),
          optional(:disabled_tools) => [String.t()]
        }

  @typedoc "Agent introspection snapshot returned by `get_info/1`."
  @type info :: %{
          session_id: String.t(),
          session_dir: String.t(),
          status: :idle | :running | :streaming | :executing_tools,
          model: Model.t(),
          provider: module(),
          session: pid() | nil,
          working_dir: String.t(),
          context_files: [String.t()],
          available_skills: [map()],
          mcp_servers: [map()],
          tools: [module()],
          message_count: non_neg_integer(),
          token_usage: map()
        }

  @info_keys ~w(session_id status model provider session working_dir
                context_files available_skills mcp_servers tools token_usage)a

  # -- Session lifecycle ------------------------------------------------------

  @doc """
  Starts a new agent session.

  All keys are optional — defaults from `Opal.Config`.
  See `t:session_opts/0` for the full option set.

      {:ok, agent} = Opal.start_session(%{working_dir: "/project"})
      {:ok, agent} = Opal.start_session(%{model: "gpt-5", working_dir: "."})
  """
  @spec start_session(session_opts()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ %{}) when is_map(opts) do
    child_opts = build_child_opts(opts)
    Config.ensure_dirs!(child_opts[:config])

    with {:ok, server} <-
           DynamicSupervisor.start_child(Opal.SessionSupervisor, {SessionServer, child_opts}) do
      {:ok, SessionServer.agent(server)}
    end
  end

  @doc "Stops a session, terminating the entire supervision tree."
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(agent) when is_pid(agent) do
    with {:ok, server} <- find_session_server(agent) do
      DynamicSupervisor.terminate_child(Opal.SessionSupervisor, server)
    end
  end

  # -- Prompting --------------------------------------------------------------

  @doc """
  Sends a prompt to the agent.

  Returns immediately. If the agent is busy, the message is queued
  and applied between tool executions.
  """
  @spec prompt(GenServer.server(), String.t()) :: %{queued: boolean()}
  def prompt(agent, text), do: Agent.prompt(agent, text)

  @doc """
  Sends a prompt and blocks until the full response is collected.

      {:ok, text} = Opal.prompt_sync(agent, "What is 2 + 2?")
  """
  @spec prompt_sync(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def prompt_sync(agent, text, timeout \\ 60_000) do
    sid = Agent.get_state(agent).session_id
    Events.subscribe(sid)

    try do
      Agent.prompt(agent, text)
      Agent.Collector.collect_response(sid, "", timeout)
    after
      Events.unsubscribe(sid)
    end
  end

  @doc "Aborts the current agent run."
  @spec abort(GenServer.server()) :: :ok
  def abort(agent), do: Agent.abort(agent)

  # -- Streaming --------------------------------------------------------------

  @doc """
  Returns a lazy `Stream` of `{event_type, payload}` tuples for a prompt.

      Opal.stream(agent, "Refactor this module")
      |> Enum.each(fn
        {:message_delta, %{delta: text}} -> IO.write(text)
        {:agent_end, _} -> IO.puts("\\nDone!")
        _ -> :ok
      end)
  """
  @spec stream(GenServer.server(), String.t()) :: Enumerable.t()
  def stream(agent, text) do
    Stream.resource(
      fn ->
        sid = Agent.get_state(agent).session_id
        Events.subscribe(sid)
        Agent.prompt(agent, text)
        sid
      end,
      &next_event/1,
      fn
        {:done, sid} -> Events.unsubscribe(sid)
        sid -> Events.unsubscribe(sid)
      end
    )
  end

  # -- Configuration ----------------------------------------------------------

  @doc """
  Changes the model on a running session. Takes effect on the next prompt.

      Opal.set_model(agent, "claude-sonnet-4-5", thinking_level: :high)
  """
  @spec set_model(pid(), model_spec(), keyword()) :: :ok
  def set_model(agent, spec, opts \\ []) do
    Agent.set_model(agent, Model.coerce(spec, opts))
  end

  @doc """
  Sets the thinking level, preserving the current model.

      Opal.set_thinking_level(agent, :high)
  """
  @spec set_thinking_level(pid(), atom()) :: :ok
  def set_thinking_level(agent, level) do
    model = %{Agent.get_state(agent).model | thinking_level: level}
    Agent.set_model(agent, model)
  end

  @doc "Updates runtime configuration for a running session."
  @spec configure_session(pid(), map()) :: :ok
  def configure_session(agent, attrs) when is_map(attrs), do: Agent.configure(agent, attrs)

  # -- Introspection ----------------------------------------------------------

  @doc "Returns the full message context window for a session."
  @spec get_context(pid()) :: [Opal.Message.t()]
  def get_context(agent), do: Agent.get_context(agent)

  @doc """
  Returns an introspection snapshot of the agent. See `t:info/0`.
  """
  @spec get_info(pid()) :: info()
  def get_info(agent) do
    state = Agent.get_state(agent)

    state
    |> Map.take(@info_keys)
    |> Map.merge(%{
      session_dir: Path.join(Config.sessions_dir(state.config), state.session_id),
      message_count: length(state.messages)
    })
  end

  @doc "Replaces the agent's messages (typically after compaction)."
  @spec sync_messages(pid(), [Opal.Message.t()]) :: :ok
  def sync_messages(agent, messages), do: Agent.sync_messages(agent, messages)

  # -- Private ----------------------------------------------------------------

  @spec build_child_opts(session_opts()) :: keyword()
  defp build_child_opts(opts) do
    cfg = Config.new(opts)
    tools = opts[:tools] || cfg.default_tools

    [
      session_id: opts[:session_id] || Id.session(),
      system_prompt: Map.get(opts, :system_prompt, ""),
      model: resolve_model(opts, cfg),
      tools: tools,
      disabled_tools: resolve_disabled_tools(opts, tools),
      working_dir: Map.get(opts, :working_dir, File.cwd!()),
      config: cfg,
      provider: resolve_provider(opts, cfg),
      session: Map.get(opts, :session, false)
    ]
  end

  @spec resolve_model(session_opts(), Config.t()) :: Model.t()
  defp resolve_model(opts, cfg) do
    base = opts[:model] || saved_model() || cfg.default_model
    Model.coerce(base)
  end

  @spec saved_model() :: String.t() | nil
  defp saved_model do
    case Settings.get("default_model") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  @spec resolve_provider(session_opts(), Config.t()) :: module()
  defp resolve_provider(%{provider: mod}, _cfg) when is_atom(mod), do: mod
  defp resolve_provider(_opts, cfg), do: cfg.provider

  @spec resolve_disabled_tools(session_opts(), [module()]) :: [String.t()]
  defp resolve_disabled_tools(%{disabled_tools: names}, _tools) when is_list(names), do: names
  defp resolve_disabled_tools(_opts, _tools), do: []

  @spec find_session_server(pid()) :: {:ok, pid()} | {:error, :not_found}
  defp find_session_server(agent) do
    with {:dictionary, dict} <- Process.info(agent, :dictionary),
         [parent | _] when is_pid(parent) <- dict[:"$ancestors"] do
      {:ok, parent}
    else
      _ -> {:error, :not_found}
    end
  end

  # Stream.resource continuation — receives events until a terminal one.
  @spec next_event(String.t() | {:done, String.t()}) ::
          {[term()], String.t() | {:done, String.t()}} | {:halt, {:done, String.t()}}
  defp next_event({:done, _sid} = acc), do: {:halt, acc}

  defp next_event(sid) do
    receive do
      {:opal_event, ^sid, event} ->
        if terminal?(event),
          do: {[event], {:done, sid}},
          else: {[event], sid}
    after
      120_000 -> {[{:error, :timeout}], {:done, sid}}
    end
  end

  @spec terminal?(term()) :: boolean()
  defp terminal?({:agent_end, _}), do: true
  defp terminal?({:agent_end, _, _}), do: true
  defp terminal?({:error, _}), do: true
  defp terminal?(_), do: false
end
