defmodule Opal do
  @moduledoc """
  Public API for the Opal coding agent SDK.

  Provides functions to start agent sessions, send prompts (async and sync),
  steer agents mid-run, and manage session lifecycle. All agent events are
  broadcast via `Opal.Events` for real-time observability.

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

  require Logger

  @doc """
  Starts a new agent session with the given configuration.

  All keys are optional — defaults come from `config :opal` via `Opal.Config`.

  ## Config Keys

    * `:model` — a `{provider_atom, model_id_string}` tuple
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

      # Override model for this session
      {:ok, agent} = Opal.start_session(%{
        model: {:copilot, "gpt-5"},
        working_dir: "/project"
      })
  """
  @spec start_session(map()) :: {:ok, pid()} | {:error, term()}
  def start_session(config) when is_map(config) do
    cfg = Opal.Config.new(config)

    {provider_raw, model_id} = Map.get(config, :model) || cfg.default_model
    provider_atom = if is_atom(provider_raw), do: provider_raw, else: String.to_existing_atom(provider_raw)
    model = Opal.Model.new(provider_atom, model_id)
    session_id = generate_session_id()

    opts = [
      session_id: session_id,
      system_prompt: Map.get(config, :system_prompt, ""),
      model: model,
      tools: Map.get(config, :tools) || cfg.default_tools,
      working_dir: Map.get(config, :working_dir, File.cwd!()),
      config: cfg,
      session: Map.get(config, :session, false)
    ]

    Opal.Config.ensure_dirs!(cfg)

    case DynamicSupervisor.start_child(Opal.SessionSupervisor, {Opal.SessionServer, opts}) do
      {:ok, session_server} ->
        agent = Opal.SessionServer.agent(session_server)
        {:ok, agent}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sends an asynchronous prompt to the agent.

  Subscribe to `Opal.Events` with the session ID to receive streaming output.
  Returns `:ok` immediately.
  """
  @spec prompt(GenServer.server(), String.t()) :: :ok
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
    collect_response(state.session_id, "", timeout)
  after
    state = Opal.Agent.get_state(agent)
    Opal.Events.unsubscribe(state.session_id)
  end

  @doc """
  Steers the agent mid-run.

  If idle, acts like `prompt/2`. If running, the message is picked up
  between tool executions.
  """
  @spec steer(GenServer.server(), String.t()) :: :ok
  def steer(agent, text) do
    Opal.Agent.steer(agent, text)
  end

  @doc """
  Sends a follow-up prompt to the agent. Convenience wrapper for `prompt/2`.
  """
  @spec follow_up(GenServer.server(), String.t()) :: :ok
  def follow_up(agent, text) do
    Opal.Agent.follow_up(agent, text)
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

      Opal.set_model(agent, :copilot, "gpt-5")
  """
  @spec set_model(pid(), atom(), String.t(), keyword()) :: :ok
  def set_model(agent, provider, model_id, opts \\ []) do
    model = Opal.Model.new(provider, model_id, opts)
    GenServer.call(agent, {:set_model, model})
  end

  @doc """
  Returns the full context window (system prompt + all messages) for a session.
  """
  @spec get_context(pid()) :: [Opal.Message.t()]
  def get_context(agent) do
    GenServer.call(agent, :get_context)
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

  # --- Private Helpers ---

  # Collects streamed text deltas until :agent_end is received.
  defp collect_response(session_id, acc, timeout) do
    receive do
      {:opal_event, ^session_id, {:message_delta, %{delta: delta}}} ->
        collect_response(session_id, acc <> delta, timeout)

      {:opal_event, ^session_id, {:agent_end, _messages}} ->
        {:ok, acc}

      {:opal_event, ^session_id, {:agent_end, _messages, _usage}} ->
        {:ok, acc}

      {:opal_event, ^session_id, {:error, reason}} ->
        {:error, reason}

      {:opal_event, ^session_id, _other} ->
        # Ignore other events (tool_execution_start, thinking, etc.)
        collect_response(session_id, acc, timeout)
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
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
