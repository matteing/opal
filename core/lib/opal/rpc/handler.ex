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
      {:ok, agent} ->
        info = Opal.get_info(agent)

        case Opal.Tool.Tasks.query_raw(info.working_dir, nil) do
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
