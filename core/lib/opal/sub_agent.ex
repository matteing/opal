defmodule Opal.SubAgent do
  @moduledoc """
  Spawns and manages child agents that work in parallel.

  A sub-agent is another `Opal.Agent` started under `Opal.SessionSupervisor`.
  It gets its own process, message history, and tool set. The supervision tree
  ensures cleanup — if the parent session is torn down, sub-agents started by
  tools within that session are cleaned up when those tool tasks terminate.

  ## Usage

      # From within a tool or the parent agent:
      {:ok, sub} = Opal.SubAgent.spawn(parent_agent, %{
        system_prompt: "You are a test-writing specialist.",
        tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Shell],
        model: {:copilot, "claude-haiku-3-5"}
      })

      {:ok, result} = Opal.SubAgent.run(sub, "Write tests for lib/opal/agent.ex")

  Multiple sub-agents can be spawned in parallel, each working on different
  files or tasks. If a sub-agent crashes, only that sub-agent is affected.
  """

  require Logger

  @doc """
  Spawns a new sub-agent inheriting defaults from the parent agent.

  The parent agent's config, working directory, model, provider, and tools
  are used as defaults. Any key in `overrides` replaces the parent's value.

  ## Overrides

    * `:system_prompt` — system prompt for the sub-agent (default: parent's)
    * `:tools` — tool modules (default: parent's tools)
    * `:model` — `{provider, model_id}` tuple (default: parent's model)
    * `:working_dir` — working directory (default: parent's)
    * `:provider` — provider module (default: parent's)

  Returns `{:ok, sub_agent_pid}` or `{:error, reason}`.
  """
  @spec spawn(GenServer.server(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn(parent_agent, overrides \\ %{}) do
    parent_state = Opal.Agent.get_state(parent_agent)
    spawn_from_state(parent_state, overrides)
  end

  @doc """
  Like `spawn/2`, but takes an already-captured `Opal.Agent.State` struct
  instead of a pid. Use this from within tool execution to avoid calling
  back into the blocked Agent GenServer (which would deadlock).
  """
  @spec spawn_from_state(Opal.Agent.State.t(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn_from_state(parent_state, overrides \\ %{}) do
    if not parent_state.config.features.sub_agents.enabled do
      {:error, :sub_agents_disabled}
    else
      do_spawn(parent_state, overrides)
    end
  end

  defp do_spawn(parent_state, overrides) do
    model =
      case Map.get(overrides, :model) do
        nil -> parent_state.model
        spec -> Opal.Model.coerce(spec)
      end

    # Auto-select provider: use explicit override, or inherit from parent.
    # Only switch provider when the model is explicitly changed to a provider
    # that differs from the parent's model provider.
    provider =
      case Map.get(overrides, :provider) do
        nil ->
          # Inherit parent's provider by default
          parent_state.provider

        mod ->
          mod
      end

    session_id = generate_session_id()

    Logger.debug("SubAgent spawn parent=#{parent_state.session_id} child=#{session_id} model=#{model.id}")

    # Filter out tools that shouldn't be available to sub-agents;
    # inject AskParent so sub-agents can ask questions back to the parent.
    parent_tools = Map.get(overrides, :tools, parent_state.tools)

    tools =
      parent_tools
      |> Enum.reject(&(&1 == Opal.Tool.AskUser))
      |> then(fn ts ->
        if Opal.Tool.AskParent in ts, do: ts, else: ts ++ [Opal.Tool.AskParent]
      end)

    opts = [
      session_id: session_id,
      system_prompt: Map.get(overrides, :system_prompt, parent_state.system_prompt),
      model: model,
      tools: tools,
      working_dir: Map.get(overrides, :working_dir, parent_state.working_dir),
      config: parent_state.config,
      provider: provider,
      tool_supervisor: parent_state.tool_supervisor,
      question_handler: Map.get(overrides, :question_handler)
    ]

    DynamicSupervisor.start_child(parent_state.sub_agent_supervisor, {Opal.Agent, opts})
  end

  @doc """
  Sends a prompt to a sub-agent and synchronously collects the response.

  Subscribes to the sub-agent's events, sends the prompt, and waits for
  `:agent_end`. Returns the accumulated text response.

  ## Options

    * `timeout` — maximum wait time in milliseconds (default: `120_000`)
  """
  @spec run(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def run(sub_agent, prompt, timeout \\ 120_000) do
    state = Opal.Agent.get_state(sub_agent)
    session_id = state.session_id
    Logger.debug("SubAgent run session=#{session_id} prompt=\"#{String.slice(prompt, 0, 80)}\"")
    Opal.Events.subscribe(session_id)

    try do
      Opal.Agent.prompt(sub_agent, prompt)
      Opal.Agent.Collector.collect_response(session_id, "", timeout)
    after
      Opal.Events.unsubscribe(session_id)
    end
  end

  @doc """
  Stops a sub-agent and cleans up its process.

  Accepts either just the sub-agent pid (looks up the parent supervisor
  from process ancestry) or the sub-agent pid and the supervisor to
  terminate it from.
  """
  @spec stop(pid()) :: :ok | {:error, :not_found}
  def stop(sub_agent) when is_pid(sub_agent) do
    case Process.info(sub_agent, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$ancestors") do
          [parent | _] when is_pid(parent) ->
            DynamicSupervisor.terminate_child(parent, sub_agent)

          _ ->
            {:error, :not_found}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp generate_session_id do
    "sub-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
