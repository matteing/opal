defmodule Opal.RPC.Handler do
  @moduledoc """
  Dispatches JSON-RPC methods to Opal library functions.

  Pure dispatch layer — receives a method name and params map, calls into
  the Opal public API, and returns a result tuple. Has no transport awareness
  and no side effects beyond the Opal calls themselves.

  The set of supported methods, their params, and result shapes are
  declared in `Opal.RPC.Protocol` — the single source of truth for
  the Opal RPC specification.

  ## Return Values

    * `{:ok, result}` — success, `result` is serialized as `"result"` in the response
    * `{:error, code, message, data}` — failure, serialized as a JSON-RPC error
  """

  require Logger

  @type result :: {:ok, map()} | {:error, integer(), String.t(), term()}

  @doc """
  Dispatches a JSON-RPC method call to the appropriate Opal API function.

  Only methods declared in `Opal.RPC.Protocol.methods/0` are handled.
  See `Opal.RPC.Protocol` for the full protocol specification.
  """
  @spec handle(String.t(), map()) :: result()
  def handle(method, params)

  def handle("session/start", params) do
    opts = decode_session_opts(params)

    case Opal.start_session(opts) do
      {:ok, agent} ->
        state = Opal.Agent.get_state(agent)
        session_dir = Path.join(Opal.Config.sessions_dir(state.config), state.session_id)
        {:ok, %{
          session_id: state.session_id,
          session_dir: session_dir,
          context_files: state.context_files,
          available_skills: Enum.map(state.available_skills, & &1.name),
          mcp_servers: Enum.map(state.mcp_servers, & &1.name),
          node_name: Atom.to_string(Node.self())
        }}

      {:error, reason} ->
        {:error, Opal.RPC.internal_error(), "Failed to start session", inspect(reason)}
    end
  end

  def handle("agent/prompt", %{"session_id" => sid, "text" => text}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        Opal.prompt(agent, text)
        {:ok, %{}}

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("agent/prompt", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, text", nil}
  end

  def handle("agent/steer", %{"session_id" => sid, "text" => text}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        Opal.steer(agent, text)
        {:ok, %{}}

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("agent/steer", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, text", nil}
  end

  def handle("agent/abort", %{"session_id" => sid}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        Opal.abort(agent)
        {:ok, %{}}

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("agent/abort", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("agent/state", %{"session_id" => sid}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        state = Opal.Agent.get_state(agent)
        {:ok, serialize_state(state)}

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("agent/state", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("session/list", _params) do
    config = Opal.Config.new()
    dir = Opal.Config.sessions_dir(config)
    sessions = Opal.Session.list_sessions(dir)

    {:ok, %{sessions: Enum.map(sessions, &serialize_session_info/1)}}
  end

  def handle("session/branch", %{"session_id" => sid, "entry_id" => eid}) do
    case lookup_session(sid) do
      {:ok, session} ->
        case Opal.Session.branch(session, eid) do
          :ok -> {:ok, %{}}
          {:error, reason} -> {:error, Opal.RPC.internal_error(), "Branch failed", inspect(reason)}
        end

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("session/branch", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, entry_id", nil}
  end

  def handle("session/compact", %{"session_id" => sid} = params) do
    with {:ok, agent} <- find_agent_by_session_id(sid) do
      state = Opal.Agent.get_state(agent)

      case state.session do
        nil ->
          {:error, Opal.RPC.internal_error(), "Session persistence not enabled — cannot compact", nil}

        session when is_pid(session) ->
          keep_tokens = case params do
            %{"keep_recent" => n} when is_integer(n) and n > 0 -> n
            _ -> nil
          end

          compact_opts = [
            provider: state.provider,
            model: state.model
          ] ++ if(keep_tokens, do: [keep_recent_tokens: keep_tokens], else: [])

          case Opal.Session.Compaction.compact(session, compact_opts) do
            :ok ->
              # Sync the agent's message list with the compacted session path
              new_path = Opal.Session.get_path(session)
              GenServer.call(agent, {:sync_messages, new_path})
              {:ok, %{}}

            {:error, reason} ->
              {:error, Opal.RPC.internal_error(), "Compaction failed", inspect(reason)}
          end
      end
    else
      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("session/compact", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("models/list", params) do
    copilot_models =
      Opal.Auth.list_models()
      |> Enum.map(fn m -> Map.put(m, :provider, "copilot") end)

    # Include models from direct providers if requested
    provider_models =
      case params do
        %{"providers" => providers} when is_list(providers) ->
          Enum.flat_map(providers, fn p ->
            provider = String.to_atom(p)
            Opal.Models.list_provider(provider)
            |> Enum.map(fn m -> Map.put(m, :provider, p) end)
          end)

        _ ->
          []
      end

    {:ok, %{models: copilot_models ++ provider_models}}
  end

  def handle("model/set", %{"session_id" => sid, "model_id" => model_id} = params) do
    with {:ok, agent} <- find_agent_by_session_id(sid) do
      thinking_level = parse_thinking_level(params["thinking_level"])
      model = Opal.Model.coerce(model_id, thinking_level: thinking_level)
      provider = Opal.Model.provider_module(model)

      GenServer.call(agent, {:set_model, model})
      GenServer.call(agent, {:set_provider, provider})
      {:ok, %{model: %{provider: model.provider, id: model.id, thinking_level: model.thinking_level}}}
    end
  end

  def handle("model/set", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, model_id", nil}
  end

  def handle("thinking/set", %{"session_id" => sid, "level" => level_str}) do
    with {:ok, agent} <- find_agent_by_session_id(sid) do
      level = parse_thinking_level(level_str)
      state = Opal.Agent.get_state(agent)
      model = %{state.model | thinking_level: level}
      GenServer.call(agent, {:set_model, model})
      {:ok, %{thinking_level: level}}
    end
  end

  def handle("thinking/set", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, level", nil}
  end

  def handle("auth/status", _params) do
    case Opal.Auth.get_token() do
      {:ok, _token_data} ->
        {:ok, %{authenticated: true}}

      {:error, _} ->
        {:ok, %{authenticated: false}}
    end
  end

  def handle("auth/login", _params) do
    case Opal.Auth.start_device_flow() do
      {:ok, flow} ->
        {:ok, %{
          user_code: flow["user_code"],
          verification_uri: flow["verification_uri"],
          device_code: flow["device_code"],
          interval: flow["interval"]
        }}

      {:error, reason} ->
        {:error, Opal.RPC.internal_error(), "Login flow failed", inspect(reason)}
    end
  end

  def handle("tasks/list", %{"session_id" => sid}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        state = Opal.Agent.get_state(agent)

        case Opal.Tool.Tasks.query_raw(state.working_dir, nil) do
          {:ok, tasks} -> {:ok, %{tasks: tasks}}
          {:error, reason} -> {:error, Opal.RPC.internal_error(), "Tasks query failed", reason}
        end

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("tasks/list", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("settings/get", _params) do
    {:ok, %{settings: Opal.Settings.get_all()}}
  end

  def handle("settings/save", %{"settings" => settings}) when is_map(settings) do
    case Opal.Settings.save(settings) do
      :ok -> {:ok, %{settings: Opal.Settings.get_all()}}
      {:error, reason} -> {:error, Opal.RPC.internal_error(), "Failed to save settings", inspect(reason)}
    end
  end

  def handle("settings/save", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: settings", nil}
  end

  # Catch-all for unknown methods
  def handle(method, _params) do
    {:error, Opal.RPC.method_not_found(), "Method not found: #{method}", nil}
  end

  # -- Private Helpers --

  defp decode_session_opts(params) do
    opts = %{}

    opts =
      case params do
        %{"model" => %{"provider" => p, "id" => id}} ->
          Map.put(opts, :model, {String.to_existing_atom(p), id})

        _ ->
          opts
      end

    opts =
      case params do
        %{"system_prompt" => sp} -> Map.put(opts, :system_prompt, sp)
        _ -> opts
      end

    opts =
      case params do
        %{"working_dir" => wd} -> Map.put(opts, :working_dir, wd)
        _ -> Map.put(opts, :working_dir, File.cwd!())
      end

    case params do
      %{"session" => true} -> Map.put(opts, :session, true)
      _ -> opts
    end
  end

  defp lookup_agent(session_id) do
    case Registry.lookup(Opal.Registry, {:tool_sup, session_id}) do
      [{_pid, _}] ->
        # The agent is a sibling in the same SessionServer supervisor.
        # We find it by walking the supervision tree from the tool supervisor.
        find_agent_by_session_id(session_id)

      [] ->
        {:error, "No session with id: #{session_id}"}
    end
  end

  defp find_agent_by_session_id(session_id) do
    # Walk DynamicSupervisor children to find the SessionServer for this session
    children = DynamicSupervisor.which_children(Opal.SessionSupervisor)

    result =
      Enum.find_value(children, fn
        {_, pid, :supervisor, _} when is_pid(pid) ->
          agent = Opal.SessionServer.agent(pid)

          if agent && Process.alive?(agent) do
            state = Opal.Agent.get_state(agent)

            if state.session_id == session_id do
              {:ok, agent}
            end
          end

        _ ->
          nil
      end)

    result || {:error, "No session with id: #{session_id}"}
  end

  defp lookup_session(session_id) do
    case Registry.lookup(Opal.Registry, {:session, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, "No session process for id: #{session_id}"}
    end
  end

  defp serialize_state(%Opal.Agent.State{} = state) do
    %{
      session_id: state.session_id,
      status: state.status,
      model: %{
        provider: state.model.provider,
        id: state.model.id,
        thinking_level: state.model.thinking_level
      },
      message_count: length(state.messages),
      tools: Enum.map(state.tools, fn t -> t.name() end),
      token_usage: state.token_usage
    }
  end

  defp serialize_session_info(info) do
    %{
      id: info.id,
      title: info[:title],
      modified: NaiveDateTime.to_iso8601(info.modified)
    }
  end

  @valid_thinking_levels ~w(off low medium high)
  defp parse_thinking_level(nil), do: :off
  defp parse_thinking_level(level) when level in @valid_thinking_levels, do: String.to_atom(level)
  defp parse_thinking_level(_), do: :off
end
