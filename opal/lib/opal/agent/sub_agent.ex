defmodule Opal.SubAgent do
  @moduledoc """
  Spawns and manages child agents that run in parallel.

  Each sub-agent is a full `Opal.Agent` process started under the parent's
  `DynamicSupervisor`. It inherits the parent's configuration by default —
  model, provider, tools, working directory — but any field can be overridden.

  ## Example

      {:ok, sub} = Opal.SubAgent.spawn(parent_pid, %{
        system_prompt: "You are a test-writing specialist.",
        model: {:copilot, "claude-haiku-3-5"}
      })

      {:ok, response} = Opal.SubAgent.run(sub, "Write tests for lib/opal/agent.ex")
  """

  require Logger

  alias Opal.Agent
  alias Opal.Agent.State
  alias Opal.Provider.Model

  @type overrides :: %{
          optional(:system_prompt) => String.t(),
          optional(:tools) => [module()],
          optional(:model) => Model.t() | {atom(), String.t()} | String.t(),
          optional(:working_dir) => String.t(),
          optional(:provider) => module()
        }

  # ── Spawn ──────────────────────────────────────────────────────────

  @doc """
  Spawns a sub-agent, inheriting defaults from the parent agent process.

  Calls `Opal.Agent.get_state/1` on `parent` — do **not** call this from
  inside a tool callback (it will deadlock). Use `spawn_from_state/2` instead.
  """
  @spec spawn(GenServer.server(), overrides()) :: {:ok, pid()} | {:error, term()}
  def spawn(parent, overrides \\ %{}) do
    parent |> Agent.get_state() |> spawn_from_state(overrides)
  end

  @doc """
  Spawns a sub-agent from an already-captured `State` struct.

  Use this inside tool execution where the agent GenServer is blocked.
  """
  @spec spawn_from_state(State.t(), overrides()) :: {:ok, pid()} | {:error, term()}
  def spawn_from_state(%State{config: %{features: %{sub_agents: %{enabled: false}}}} = _state, _),
    do: {:error, :sub_agents_disabled}

  def spawn_from_state(%State{} = parent, overrides),
    do: start_child(parent, overrides)

  # ── Run ────────────────────────────────────────────────────────────

  @doc """
  Sends a prompt to a sub-agent and blocks until the response is complete.

  Returns the full accumulated text. Subscribes to the sub-agent's event
  stream for the duration of the call.
  """
  @spec run(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def run(sub_agent, prompt, timeout \\ 120_000) do
    %{session_id: session_id} = Agent.get_state(sub_agent)

    Logger.debug(
      "SubAgent run session=#{session_id} prompt=#{inspect(String.slice(prompt, 0, 80))}"
    )

    Opal.Events.subscribe(session_id)

    try do
      Agent.prompt(sub_agent, prompt)
      Agent.Collector.collect_response(session_id, "", timeout)
    after
      Opal.Events.unsubscribe(session_id)
    end
  end

  # ── Stop ───────────────────────────────────────────────────────────

  @doc """
  Terminates a sub-agent by locating its supervisor from process ancestry.
  """
  @spec stop(pid()) :: :ok | {:error, :not_found}
  def stop(sub_agent) when is_pid(sub_agent) do
    with {:dictionary, dict} <- Process.info(sub_agent, :dictionary),
         [sup | _] when is_pid(sup) <- Keyword.get(dict, :"$ancestors", []) do
      DynamicSupervisor.terminate_child(sup, sub_agent)
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp start_child(parent, overrides) do
    model = resolve_model(parent, overrides)
    provider = resolve_provider(parent, model, overrides)
    session_id = generate_session_id()

    Logger.debug(
      "SubAgent spawn parent=#{parent.session_id} child=#{session_id} model=#{model.id}"
    )

    opts = [
      session_id: session_id,
      system_prompt: Map.get(overrides, :system_prompt, parent.system_prompt),
      model: model,
      tools: resolve_tools(parent, overrides),
      working_dir: Map.get(overrides, :working_dir, parent.working_dir),
      config: parent.config,
      provider: provider,
      tool_supervisor: parent.tool_supervisor
    ]

    DynamicSupervisor.start_child(parent.sub_agent_supervisor, {Agent, opts})
  end

  @spec resolve_model(State.t(), overrides()) :: Model.t()
  defp resolve_model(parent, overrides) do
    case Map.get(overrides, :model) do
      nil -> parent.model
      spec -> Model.coerce(spec)
    end
  end

  # Explicit provider override always wins.
  # When only the model changes and the provider atom differs, derive the
  # provider module from the new model. Otherwise inherit the parent's.
  @spec resolve_provider(State.t(), Model.t(), overrides()) :: module()
  defp resolve_provider(_parent, _model, %{provider: mod}), do: mod
  defp resolve_provider(parent, _model, _overrides), do: parent.provider

  # Sub-agents never get AskUser — only top-level agents may prompt the user.
  @spec resolve_tools(State.t(), overrides()) :: [module()]
  defp resolve_tools(parent, overrides) do
    overrides
    |> Map.get(:tools, parent.tools)
    |> Enum.reject(&(&1 == Opal.Tool.AskUser))
  end

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "sub-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end
