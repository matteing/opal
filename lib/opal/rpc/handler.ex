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
    case decode_session_opts(params) do
      {:ok, opts} ->
        case validate_boot_tool_names(opts) do
          :ok ->
            case Opal.start_session(opts) do
              {:ok, agent} ->
                info = Opal.get_info(agent)

                auth =
                  try do
                    Opal.Auth.probe()
                  rescue
                    e ->
                      Logger.error("Auth probe failed: #{Exception.message(e)}")
                      %{status: "setup_required", provider: nil, providers: []}
                  end

                {:ok,
                 %{
                   session_id: info.session_id,
                   session_dir: info.session_dir,
                   context_files: info.context_files,
                   available_skills: Enum.map(info.available_skills, & &1.name),
                   mcp_servers: Enum.map(info.mcp_servers, & &1.name),
                   node_name: Atom.to_string(Node.self()),
                   auth: auth
                 }}

              {:error, reason} ->
                {:error, Opal.RPC.internal_error(), "Failed to start session", inspect(reason)}
            end

          {:error, msg, data} ->
            {:error, Opal.RPC.invalid_params(), msg, data}
        end

      {:error, msg, data} ->
        {:error, Opal.RPC.invalid_params(), msg, data}
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
        info = Opal.get_info(agent)
        {:ok, serialize_info(info)}

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
          :ok ->
            {:ok, %{}}

          {:error, reason} ->
            {:error, Opal.RPC.internal_error(), "Branch failed", inspect(reason)}
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
      info = Opal.get_info(agent)

      case info.session do
        nil ->
          {:error, Opal.RPC.internal_error(), "Session persistence not enabled — cannot compact",
           nil}

        session when is_pid(session) ->
          keep_tokens =
            case params do
              %{"keep_recent" => n} when is_integer(n) and n > 0 -> n
              _ -> nil
            end

          compact_opts =
            [
              provider: info.provider,
              model: info.model
            ] ++ if(keep_tokens, do: [keep_recent_tokens: keep_tokens], else: [])

          case Opal.Session.Compaction.compact(session, compact_opts) do
            :ok ->
              new_path = Opal.Session.get_path(session)
              Opal.sync_messages(agent, new_path)
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
      Opal.Auth.Copilot.list_models()
      |> Enum.map(fn m -> Map.put(m, :provider, "copilot") end)

    # Include models from direct providers if requested
    provider_models_result =
      case params do
        %{"providers" => providers} when is_list(providers) ->
          Enum.reduce_while(providers, {:ok, []}, fn p, {:ok, acc} ->
            case parse_provider_name(p) do
              {:ok, provider} ->
                models =
                  Opal.Models.list_provider(provider)
                  |> Enum.map(fn m -> Map.put(m, :provider, p) end)

                {:cont, {:ok, acc ++ models}}

              :error ->
                {:halt, {:error, p}}
            end
          end)

        _ ->
          {:ok, []}
      end

    case provider_models_result do
      {:ok, provider_models} ->
        {:ok, %{models: copilot_models ++ provider_models}}

      {:error, invalid_provider} ->
        {:error, Opal.RPC.invalid_params(), "Unknown provider in providers list",
         "unknown provider: #{inspect(invalid_provider)}"}
    end
  end

  def handle("model/set", %{"session_id" => sid, "model_id" => model_id} = params) do
    with {:ok, agent} <- find_agent_by_session_id(sid) do
      thinking_level = parse_thinking_level(params["thinking_level"])
      model = Opal.Model.coerce(model_id, thinking_level: thinking_level)

      Opal.set_model(agent, model)

      {:ok,
       %{model: %{provider: model.provider, id: model.id, thinking_level: model.thinking_level}}}
    else
      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("model/set", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, model_id", nil}
  end

  def handle("thinking/set", %{"session_id" => sid, "level" => level_str}) do
    with {:ok, agent} <- find_agent_by_session_id(sid) do
      level = parse_thinking_level(level_str)
      Opal.set_thinking_level(agent, level)
      {:ok, %{thinking_level: level}}
    else
      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("thinking/set", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: session_id, level", nil}
  end

  def handle("auth/status", _params) do
    result = Opal.Auth.probe()
    {:ok, %{authenticated: result.status == "ready", auth: result}}
  end

  def handle("auth/login", _params) do
    case Opal.Auth.Copilot.start_device_flow() do
      {:ok, flow} ->
        {:ok,
         %{
           user_code: flow["user_code"],
           verification_uri: flow["verification_uri"],
           device_code: flow["device_code"],
           interval: flow["interval"]
         }}

      {:error, reason} ->
        {:error, Opal.RPC.internal_error(), "Login flow failed", inspect(reason)}
    end
  end

  def handle("auth/poll", %{"device_code" => device_code, "interval" => interval}) do
    domain = Opal.Config.new().copilot.domain

    case Opal.Auth.Copilot.poll_for_token(domain, device_code, interval * 1_000) do
      {:ok, github_token} ->
        case Opal.Auth.Copilot.exchange_copilot_token(github_token) do
          {:ok, copilot_response} ->
            token_data = %{
              "github_token" => github_token,
              "copilot_token" => copilot_response["token"],
              "expires_at" => copilot_response["expires_at"],
              "base_url" => Opal.Auth.Copilot.base_url(copilot_response)
            }

            Opal.Auth.Copilot.save_token(token_data)
            {:ok, %{authenticated: true}}

          {:error, reason} ->
            {:error, Opal.RPC.internal_error(), "Token exchange failed", inspect(reason)}
        end

      {:error, reason} ->
        {:error, Opal.RPC.internal_error(), "Polling failed", inspect(reason)}
    end
  end

  def handle("auth/poll", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: device_code, interval", nil}
  end

  def handle("auth/set_key", %{"provider" => provider, "api_key" => api_key})
      when is_binary(provider) and is_binary(api_key) and api_key != "" do
    # Derive the env var name (e.g. "anthropic" → "ANTHROPIC_API_KEY")
    env_var = "#{String.upcase(provider)}_API_KEY"

    # Save to persistent settings so it survives restarts
    Opal.Settings.save(%{"#{provider}_api_key" => api_key})

    # Set in process env so ReqLLM picks it up immediately
    System.put_env(env_var, api_key)

    {:ok, %{ok: true}}
  end

  def handle("auth/set_key", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required params: provider, api_key", nil}
  end

  def handle("tasks/list", %{"session_id" => sid}) do
    case lookup_agent(sid) do
      {:ok, _agent} ->
        case Opal.Tool.Tasks.query_raw(%{session_id: sid}, nil) do
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
      :ok ->
        {:ok, %{settings: Opal.Settings.get_all()}}

      {:error, reason} ->
        {:error, Opal.RPC.internal_error(), "Failed to save settings", inspect(reason)}
    end
  end

  def handle("settings/save", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: settings", nil}
  end

  def handle("opal/config/get", %{"session_id" => sid}) do
    case lookup_agent(sid) do
      {:ok, agent} ->
        state = Opal.Agent.get_state(agent)
        {:ok, serialize_runtime_config(state)}

      {:error, reason} ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}
    end
  end

  def handle("opal/config/get", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("opal/config/set", %{"session_id" => sid} = params) do
    with {:ok, agent} <- lookup_agent(sid),
         {:ok, features} <- parse_feature_overrides(Map.get(params, "features")),
         {:ok, enabled_tools} <- parse_enabled_tools(Map.get(params, "tools")),
         :ok <- validate_session_tool_names(agent, enabled_tools) do
      config = %{
        features: features,
        enabled_tools: enabled_tools
      }

      :ok = Opal.configure_session(agent, config)
      state = Opal.Agent.get_state(agent)
      {:ok, serialize_runtime_config(state)}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, Opal.RPC.invalid_params(), "Session not found", reason}

      {:error, msg, data} ->
        {:error, Opal.RPC.invalid_params(), msg, data}
    end
  end

  def handle("opal/config/set", _params) do
    {:error, Opal.RPC.invalid_params(), "Missing required param: session_id", nil}
  end

  def handle("opal/ping", _params) do
    {:ok, %{}}
  end

  # Catch-all for unknown methods
  def handle(method, _params) do
    {:error, Opal.RPC.method_not_found(), "Method not found: #{method}", nil}
  end

  # -- Private Helpers --

  defp decode_session_opts(params) when is_map(params) do
    with {:ok, opts} <- decode_model_opt(params, %{}),
         {:ok, opts} <- decode_feature_opts(params, opts),
         {:ok, opts} <- decode_tool_opt(params, opts) do
      opts =
        opts
        |> maybe_put_string(params, "system_prompt", :system_prompt)
        |> Map.put(:working_dir, Map.get(params, "working_dir", File.cwd!()))
        |> maybe_put_true(params, "session", :session)
        |> maybe_put_string(params, "session_id", :session_id)

      # Resuming a session implies persistence
      opts =
        if Map.has_key?(opts, :session_id),
          do: Map.put(opts, :session, true),
          else: opts

      {:ok, opts}
    end
  end

  defp decode_session_opts(_), do: {:error, "Invalid params", "params must be an object"}

  defp decode_model_opt(%{"model" => %{"provider" => p, "id" => id}}, opts)
       when is_binary(p) and is_binary(id) and p != "" and id != "" do
    {:ok, Map.put(opts, :model, "#{p}:#{id}")}
  end

  defp decode_model_opt(%{"model" => _}, _opts) do
    {:error, "Invalid model param", "model must be {provider, id} with non-empty strings"}
  end

  defp decode_model_opt(_params, opts), do: {:ok, opts}

  defp decode_feature_opts(%{"features" => features}, opts) when is_map(features) do
    case parse_feature_overrides(features) do
      {:ok, feature_overrides} when map_size(feature_overrides) == 0 ->
        {:ok, opts}

      {:ok, feature_overrides} ->
        normalized =
          Enum.into(feature_overrides, %{}, fn {key, enabled} ->
            {key, %{enabled: enabled}}
          end)

        {:ok, Map.put(opts, :features, normalized)}

      {:error, _, _} = error ->
        error
    end
  end

  defp decode_feature_opts(%{"features" => _}, _opts) do
    {:error, "Invalid features param", "features must be an object"}
  end

  defp decode_feature_opts(_params, opts), do: {:ok, opts}

  defp decode_tool_opt(%{"tools" => tools}, opts) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1) do
      {:ok, Map.put(opts, :tool_names, tools)}
    else
      {:error, "Invalid tools param", "tools must be an array of strings"}
    end
  end

  defp decode_tool_opt(%{"tools" => _}, _opts) do
    {:error, "Invalid tools param", "tools must be an array of strings"}
  end

  defp decode_tool_opt(_params, opts), do: {:ok, opts}

  defp maybe_put_string(opts, params, from_key, to_key) do
    case Map.get(params, from_key) do
      value when is_binary(value) -> Map.put(opts, to_key, value)
      _ -> opts
    end
  end

  defp maybe_put_true(opts, params, from_key, to_key) do
    case Map.get(params, from_key) do
      true -> Map.put(opts, to_key, true)
      _ -> opts
    end
  end

  defp validate_boot_tool_names(%{tool_names: names} = opts) when is_list(names) do
    cfg = Opal.Config.new(opts)
    available = Enum.map(cfg.default_tools, & &1.name())
    unknown = names -- available

    if unknown == [] do
      :ok
    else
      {:error, "Unknown tools in tools list", "unknown tools: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp validate_boot_tool_names(_opts), do: :ok

  defp parse_feature_overrides(nil), do: {:ok, %{}}

  defp parse_feature_overrides(features) when is_map(features) do
    key_map = %{
      "sub_agents" => :sub_agents,
      "skills" => :skills,
      "mcp" => :mcp,
      "debug" => :debug
    }

    unknown_keys =
      features
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(key_map, &1))

    cond do
      unknown_keys != [] ->
        {:error, "Unknown feature keys", "unknown features: #{Enum.join(unknown_keys, ", ")}"}

      true ->
        Enum.reduce_while(features, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          if is_boolean(value) do
            feature_key = Map.fetch!(key_map, key)
            {:cont, {:ok, Map.put(acc, feature_key, value)}}
          else
            {:halt, {:error, "Invalid feature value", "#{key} must be a boolean"}}
          end
        end)
    end
  end

  defp parse_feature_overrides(_),
    do: {:error, "Invalid features param", "features must be an object"}

  defp parse_enabled_tools(nil), do: {:ok, nil}

  defp parse_enabled_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1) do
      {:ok, tools}
    else
      {:error, "Invalid tools param", "tools must be an array of strings"}
    end
  end

  defp parse_enabled_tools(_),
    do: {:error, "Invalid tools param", "tools must be an array of strings"}

  defp validate_session_tool_names(_agent, nil), do: :ok

  defp validate_session_tool_names(agent, enabled_tools) when is_list(enabled_tools) do
    state = Opal.Agent.get_state(agent)
    available = Enum.map(state.tools, & &1.name())
    unknown = enabled_tools -- available

    if unknown == [] do
      :ok
    else
      {:error, "Unknown tools in tools list", "unknown tools: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp lookup_agent(session_id) do
    find_agent_by_session_id(session_id)
  end

  defp find_agent_by_session_id(session_id) do
    case Registry.lookup(Opal.Registry, {:agent, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, "No session with id: #{session_id}"}
    end
  end

  defp lookup_session(session_id) do
    case Registry.lookup(Opal.Registry, {:session, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, "No session process for id: #{session_id}"}
    end
  end

  defp serialize_info(info) do
    %{
      session_id: info.session_id,
      status: info.status,
      model: %{
        provider: info.model.provider,
        id: info.model.id,
        thinking_level: info.model.thinking_level
      },
      message_count: info.message_count,
      tools: Enum.map(info.tools, fn t -> t.name() end),
      token_usage: info.token_usage
    }
  end

  defp serialize_runtime_config(%Opal.Agent.State{} = state) do
    all_tools = Enum.map(state.tools, & &1.name())
    enabled_tools = Opal.Agent.Tools.active_tools(state) |> Enum.map(& &1.name())

    %{
      features: %{
        sub_agents: state.config.features.sub_agents.enabled,
        skills: state.config.features.skills.enabled,
        mcp: state.config.features.mcp.enabled,
        debug: state.config.features.debug.enabled
      },
      tools: %{
        all: all_tools,
        enabled: enabled_tools,
        disabled: state.disabled_tools
      }
    }
  end

  defp serialize_session_info(info) do
    %{
      id: info.id,
      title: info[:title],
      modified: NaiveDateTime.to_iso8601(info.modified)
    }
  end

  @valid_thinking_levels ~w(off low medium high max)
  defp parse_thinking_level(nil), do: :off
  defp parse_thinking_level(level) when level in @valid_thinking_levels, do: String.to_atom(level)
  defp parse_thinking_level(_), do: :off

  defp parse_provider_name(provider) when is_binary(provider) do
    try do
      {:ok, String.to_existing_atom(provider)}
    rescue
      ArgumentError -> :error
    end
  end

  defp parse_provider_name(_), do: :error
end
