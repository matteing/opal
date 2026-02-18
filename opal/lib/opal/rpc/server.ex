defmodule Opal.RPC.Server do
  @moduledoc """
  JSON-RPC 2.0 server over stdio.

  Reads newline-delimited JSON from stdin, dispatches to Opal API functions,
  and writes responses to stdout. Subscribes to `Opal.Events` and emits
  streaming notifications.

  ## Server → Client Requests

  The server can issue requests to the client (e.g. user confirmations)
  via `request_client/3`. The caller blocks until the client replies
  with a matching response `id`.
  """

  use GenServer
  require Logger

  alias Opal.RPC

  # -- Error codes (JSON-RPC 2.0) --

  @errors %{
    parse_error: -32_700,
    invalid_request: -32_600,
    method_not_found: -32_601,
    invalid_params: -32_602,
    internal_error: -32_603
  }

  # -- State --

  defstruct [
    :reader,
    :stdout_port,
    pending_requests: %{},
    next_id: 1,
    subscriptions: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  # ── Public API ─────────────────────────────────────────────────────

  @doc "Starts the stdio transport GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends a request to the client and blocks until a response arrives."
  @spec request_client(String.t(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def request_client(method, params, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:request_client, method, params}, timeout)
  end

  @doc "Sends a fire-and-forget notification to the client."
  @spec notify(String.t(), map()) :: :ok
  def notify(method, params), do: GenServer.cast(__MODULE__, {:notify, method, params})

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def init(_opts) do
    stdout = :erlang.open_port({:fd, 1, 1}, [:binary, :out])
    parent = self()
    {:ok, reader} = Task.start_link(fn -> stdin_loop(parent) end)
    {:ok, %__MODULE__{reader: reader, stdout_port: stdout}}
  end

  @impl true
  def handle_info(:stdin_eof, state) do
    Logger.info("stdin closed, shutting down")
    System.stop(0)
    {:noreply, state}
  end

  def handle_info({:stdin_line, line}, state), do: {:noreply, process_line(line, state)}

  def handle_info({:opal_event, session_id, event}, state) do
    {type, data} = serialize_event(event)
    params = Map.merge(%{session_id: session_id, type: type}, data)
    write(state, RPC.encode_notification("agent/event", params))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:request_client, method, params}, from, state) do
    id = "s2c-#{state.next_id}"
    write(state, RPC.encode_request(id, method, params))
    pending = Map.put(state.pending_requests, id, from)
    {:noreply, %{state | pending_requests: pending, next_id: state.next_id + 1}}
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    write(state, RPC.encode_notification(method, params))
    {:noreply, state}
  end

  # ── Line processing ────────────────────────────────────────────────

  defp process_line(line, state) do
    case RPC.decode(line) do
      {:request, id, method, params} -> handle_request(id, method, params, state)
      {:response, id, result} -> resolve_pending(id, {:ok, result}, state)
      {:error_response, id, error} -> resolve_pending(id, {:error, error}, state)
      {:notification, _, _} -> state
      {:error, :parse_error} -> send_error(state, nil, :parse_error, "Parse error")
      {:error, :invalid_request} -> send_error(state, nil, :invalid_request, "Invalid request")
    end
  end

  defp handle_request(id, method, params, state) do
    try do
      case dispatch(method, params) do
        {:ok, result} ->
          write(state, RPC.encode_response(id, result))
          maybe_subscribe(method, result, state)

        {:error, code, message, data} ->
          write(state, RPC.encode_error(id, code, message, data))
          state
      end
    rescue
      e ->
        Logger.error("RPC dispatch crashed: #{Exception.message(e)}")
        send_error(state, id, :internal_error, "Internal error", Exception.message(e))
    end
  end

  defp resolve_pending(id, reply, state) do
    case Map.pop(state.pending_requests, id) do
      {from, pending} when from != nil ->
        GenServer.reply(from, reply)
        %{state | pending_requests: pending}

      {nil, _} ->
        Logger.warning("Response for unknown request id: #{inspect(id)}")
        state
    end
  end

  defp maybe_subscribe("session/start", %{session_id: sid}, state) do
    unless MapSet.member?(state.subscriptions, sid) do
      Opal.Events.subscribe(sid)
      %{state | subscriptions: MapSet.put(state.subscriptions, sid)}
    else
      state
    end
  end

  defp maybe_subscribe(_, _, state), do: state

  # ── Dispatch ───────────────────────────────────────────────────────

  @doc false
  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, integer(), String.t(), term()}

  # -- Session lifecycle --

  def dispatch("session/start", params) do
    with {:ok, opts} <- decode_session_opts(params),
         :ok <-
           validate_tool_names(opts[:tool_names], fn -> Opal.Config.new(opts).default_tools end),
         {:ok, agent} <- start_session(opts) do
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
    end
  end

  def dispatch("session/list", _params) do
    config = Opal.Config.new()
    sessions = Opal.Session.list_sessions(Opal.Config.sessions_dir(config))

    {:ok,
     %{
       sessions:
         Enum.map(sessions, fn s ->
           %{id: s.id, title: s[:title], modified: NaiveDateTime.to_iso8601(s.modified)}
         end)
     }}
  end

  def dispatch("session/branch", %{"session_id" => sid, "entry_id" => eid}) do
    with_session(sid, fn session ->
      case Opal.Session.branch(session, eid) do
        :ok -> {:ok, %{}}
        {:error, reason} -> error(:internal_error, "Branch failed", inspect(reason))
      end
    end)
  end

  def dispatch("session/branch", _),
    do: error(:invalid_params, "Missing required params: session_id, entry_id")

  def dispatch("session/compact", %{"session_id" => sid} = params) do
    with_agent(sid, fn agent ->
      info = Opal.get_info(agent)

      case info.session do
        nil ->
          error(:internal_error, "Session persistence not enabled — cannot compact")

        session when is_pid(session) ->
          keep =
            if is_integer(params["keep_recent"]) and params["keep_recent"] > 0,
              do: params["keep_recent"]

          compact_opts =
            [provider: info.provider, model: info.model] ++
              if(keep, do: [keep_recent_tokens: keep], else: [])

          :ok = Opal.Session.Compaction.compact(session, compact_opts)
          Opal.sync_messages(agent, Opal.Session.get_path(session))
          {:ok, %{}}
      end
    end)
  end

  def dispatch("session/compact", _),
    do: error(:invalid_params, "Missing required param: session_id")

  def dispatch("session/history", %{"session_id" => sid}) do
    case find_session(sid) do
      {:ok, session} ->
        messages = Opal.Session.get_path(session)
        {:ok, %{messages: Enum.map(messages, &Opal.Message.to_map/1)}}

      {:error, _} ->
        case find_agent(sid) do
          {:ok, agent} ->
            path = Opal.Agent.get_state(agent).messages |> Enum.reverse()
            {:ok, %{messages: Enum.map(path, &Opal.Message.to_map/1)}}

          {:error, reason} ->
            error(:invalid_params, "Session not found", reason)
        end
    end
  end

  def dispatch("session/history", _),
    do: error(:invalid_params, "Missing required param: session_id")

  def dispatch("session/delete", %{"session_id" => sid}) do
    path = Path.join(Opal.Config.sessions_dir(Opal.Config.new()), "#{sid}.jsonl")

    case File.rm(path) do
      :ok -> {:ok, %{ok: true}}
      {:error, :enoent} -> error(:invalid_params, "Session not found", sid)
      {:error, reason} -> error(:internal_error, "Delete failed", inspect(reason))
    end
  end

  def dispatch("session/delete", _),
    do: error(:invalid_params, "Missing required param: session_id")

  # -- Agent operations --

  def dispatch("agent/prompt", %{"session_id" => sid, "text" => text}) do
    with_agent(sid, fn agent -> {:ok, Opal.prompt(agent, text)} end)
  end

  def dispatch("agent/prompt", _),
    do: error(:invalid_params, "Missing required params: session_id, text")

  def dispatch("agent/abort", %{"session_id" => sid}) do
    with_agent(sid, fn agent ->
      Opal.abort(agent)
      {:ok, %{}}
    end)
  end

  def dispatch("agent/abort", _),
    do: error(:invalid_params, "Missing required param: session_id")

  def dispatch("agent/state", %{"session_id" => sid}) do
    with_agent(sid, fn agent ->
      info = Opal.get_info(agent)

      {:ok,
       %{
         session_id: info.session_id,
         status: info.status,
         model: %{
           provider: info.model.provider,
           id: info.model.id,
           thinking_level: info.model.thinking_level
         },
         message_count: info.message_count,
         tools: Enum.map(info.tools, & &1.name()),
         token_usage: info.token_usage
       }}
    end)
  end

  def dispatch("agent/state", _),
    do: error(:invalid_params, "Missing required param: session_id")

  # -- Models & thinking --

  def dispatch("models/list", params) do
    copilot = Opal.Auth.Copilot.list_models() |> Enum.map(&Map.put(&1, :provider, "copilot"))

    case list_provider_models(params["providers"]) do
      {:ok, extra} ->
        {:ok, %{models: copilot ++ extra}}

      {:error, p} ->
        error(
          :invalid_params,
          "Unknown provider in providers list",
          "unknown provider: #{inspect(p)}"
        )
    end
  end

  def dispatch("model/set", %{"session_id" => sid, "model_id" => model_id} = params) do
    with_agent(sid, fn agent ->
      level = parse_thinking_level(params["thinking_level"])
      model = Opal.Provider.Model.coerce(model_id, thinking_level: level)
      Opal.set_model(agent, model)

      {:ok,
       %{model: %{provider: model.provider, id: model.id, thinking_level: model.thinking_level}}}
    end)
  end

  def dispatch("model/set", _),
    do: error(:invalid_params, "Missing required params: session_id, model_id")

  def dispatch("thinking/set", %{"session_id" => sid, "level" => level_str}) do
    with_agent(sid, fn agent ->
      level = parse_thinking_level(level_str)
      Opal.set_thinking_level(agent, level)
      {:ok, %{thinking_level: level}}
    end)
  end

  def dispatch("thinking/set", _),
    do: error(:invalid_params, "Missing required params: session_id, level")

  # -- Auth --

  def dispatch("auth/status", _params) do
    result = Opal.Auth.probe()
    {:ok, %{authenticated: result.status == "ready", auth: result}}
  end

  def dispatch("auth/login", _params) do
    case Opal.Auth.Copilot.start_device_flow() do
      {:ok, flow} ->
        {:ok, Map.take(flow, ["user_code", "verification_uri", "device_code", "interval"])}

      {:error, reason} ->
        error(:internal_error, "Login flow failed", inspect(reason))
    end
  end

  def dispatch("auth/poll", %{"device_code" => code, "interval" => interval}) do
    domain = Opal.Config.new().copilot_domain

    with {:ok, github_token} <- Opal.Auth.Copilot.poll_for_token(domain, code, interval * 1_000),
         {:ok, copilot} <- Opal.Auth.Copilot.exchange_copilot_token(github_token) do
      Opal.Auth.Copilot.save_token(%{
        "github_token" => github_token,
        "copilot_token" => copilot["token"],
        "expires_at" => copilot["expires_at"],
        "base_url" => Opal.Auth.Copilot.base_url(copilot)
      })

      {:ok, %{authenticated: true}}
    else
      {:error, reason} -> error(:internal_error, "Auth polling failed", inspect(reason))
    end
  end

  def dispatch("auth/poll", _),
    do: error(:invalid_params, "Missing required params: device_code, interval")

  def dispatch("auth/set_key", %{"provider" => p, "api_key" => key})
      when is_binary(p) and is_binary(key) and key != "" do
    Opal.Settings.save(%{"#{p}_api_key" => key})
    System.put_env("#{String.upcase(p)}_API_KEY", key)
    {:ok, %{ok: true}}
  end

  def dispatch("auth/set_key", _),
    do: error(:invalid_params, "Missing required params: provider, api_key")

  # -- Tasks --

  def dispatch("tasks/list", %{"session_id" => sid}) do
    with_agent(sid, fn _agent ->
      case Opal.Tool.Tasks.query_raw(%{session_id: sid}, nil) do
        {:ok, tasks} -> {:ok, %{tasks: tasks}}
        {:error, reason} -> error(:internal_error, "Tasks query failed", reason)
      end
    end)
  end

  def dispatch("tasks/list", _),
    do: error(:invalid_params, "Missing required param: session_id")

  # -- Settings --

  def dispatch("settings/get", _params), do: {:ok, %{settings: Opal.Settings.get_all()}}

  def dispatch("settings/save", %{"settings" => settings}) when is_map(settings) do
    case Opal.Settings.save(settings) do
      :ok -> {:ok, %{settings: Opal.Settings.get_all()}}
      {:error, reason} -> error(:internal_error, "Failed to save settings", inspect(reason))
    end
  end

  def dispatch("settings/save", _),
    do: error(:invalid_params, "Missing required param: settings")

  # -- Runtime config --

  def dispatch("opal/config/get", %{"session_id" => sid}) do
    with_agent(sid, fn agent ->
      {:ok, serialize_runtime_config(Opal.Agent.get_state(agent))}
    end)
  end

  def dispatch("opal/config/get", _),
    do: error(:invalid_params, "Missing required param: session_id")

  def dispatch("opal/config/set", %{"session_id" => sid} = params) do
    with {:ok, agent} <- find_agent(sid),
         {:ok, features} <- parse_features(Map.get(params, "features")),
         {:ok, tools} <- parse_string_list(Map.get(params, "tools"), "tools"),
         :ok <- validate_tool_names(tools, fn -> Opal.Agent.get_state(agent).tools end),
         {:ok, _} <- handle_distribution(Map.get(params, "distribution", :skip)) do
      :ok = Opal.configure_session(agent, %{features: features, enabled_tools: tools})
      {:ok, serialize_runtime_config(Opal.Agent.get_state(agent))}
    else
      {:error, reason} when is_binary(reason) ->
        error(:invalid_params, "Session not found", reason)

      {:error, msg, data} ->
        error(:invalid_params, msg, data)
    end
  end

  def dispatch("opal/config/set", _),
    do: error(:invalid_params, "Missing required param: session_id")

  # -- Meta --

  def dispatch("opal/ping", _), do: {:ok, %{}}

  def dispatch("opal/version", _) do
    {:ok,
     %{
       server_version: Application.spec(:opal, :vsn) |> to_string(),
       protocol_version: Opal.RPC.Protocol.spec().version
     }}
  end

  # -- Catch-all --

  def dispatch(method, _), do: error(:method_not_found, "Method not found: #{method}")

  # ── Lookup helpers ─────────────────────────────────────────────────

  defp with_agent(sid, fun) do
    case find_agent(sid) do
      {:ok, agent} -> fun.(agent)
      {:error, reason} -> error(:invalid_params, "Session not found", reason)
    end
  end

  defp with_session(sid, fun) do
    case find_session(sid) do
      {:ok, session} -> fun.(session)
      {:error, reason} -> error(:invalid_params, "Session not found", reason)
    end
  end

  defp find_agent(sid), do: Opal.Util.Registry.lookup({:agent, sid})
  defp find_session(sid), do: Opal.Util.Registry.lookup({:session, sid})

  # ── Error helper ───────────────────────────────────────────────────

  defp error(code_name, message, data \\ nil) do
    {:error, @errors[code_name], message, data}
  end

  defp send_error(state, id, code_name, message, data \\ nil) do
    write(state, RPC.encode_error(id, @errors[code_name], message, data))
    state
  end

  # ── Session opts decoding ──────────────────────────────────────────

  defp decode_session_opts(params) when is_map(params) do
    with {:ok, model} <- parse_model(params["model"]),
         {:ok, features} <- parse_features(params["features"]),
         {:ok, tools} <- parse_string_list(params["tools"], "tools") do
      opts =
        %{working_dir: params["working_dir"] || File.cwd!()}
        |> put_if_present(:model, model)
        |> put_if_present(:features, normalize_features(features))
        |> put_if_present(:tool_names, tools)
        |> put_string(params, "system_prompt", :system_prompt)
        |> put_flag(params, "session", :session)
        |> put_string(params, "session_id", :session_id)

      # Resuming a session implies persistence
      opts = if Map.has_key?(opts, :session_id), do: Map.put(opts, :session, true), else: opts

      {:ok, opts}
    end
  end

  defp decode_session_opts(_), do: error(:invalid_params, "params must be an object")

  defp parse_model(nil), do: {:ok, nil}

  defp parse_model(%{"provider" => p, "id" => id})
       when is_binary(p) and p != "" and is_binary(id) and id != "" do
    {:ok, "#{p}:#{id}"}
  end

  defp parse_model(_),
    do: error(:invalid_params, "model must be {provider, id} with non-empty strings")

  defp normalize_features(nil), do: nil
  defp normalize_features(f) when map_size(f) == 0, do: nil
  defp normalize_features(f), do: Enum.into(f, %{}, fn {k, v} -> {k, %{enabled: v}} end)

  @feature_keys %{
    "sub_agents" => :sub_agents,
    "skills" => :skills,
    "mcp" => :mcp,
    "debug" => :debug
  }

  defp parse_features(nil), do: {:ok, nil}

  defp parse_features(features) when is_map(features) do
    unknown = Map.keys(features) -- Map.keys(@feature_keys)

    cond do
      unknown != [] ->
        error(
          :invalid_params,
          "Unknown feature keys",
          "unknown features: #{Enum.join(unknown, ", ")}"
        )

      true ->
        Enum.reduce_while(features, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          if is_boolean(value) do
            {:cont, {:ok, Map.put(acc, Map.fetch!(@feature_keys, key), value)}}
          else
            {:halt, error(:invalid_params, "Invalid feature value", "#{key} must be a boolean")}
          end
        end)
    end
  end

  defp parse_features(_), do: error(:invalid_params, "features must be an object")

  defp parse_string_list(nil, _label), do: {:ok, nil}

  defp parse_string_list(list, _label) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: error(:invalid_params, "tools must be an array of strings")
  end

  defp parse_string_list(_, label),
    do: error(:invalid_params, "#{label} must be an array of strings")

  defp validate_tool_names(nil, _tools_fn), do: :ok

  defp validate_tool_names(names, tools_fn) when is_list(names) do
    available = Enum.map(tools_fn.(), & &1.name())
    unknown = names -- available

    if unknown == [],
      do: :ok,
      else: {:error, "Unknown tools in tools list", "unknown tools: #{Enum.join(unknown, ", ")}"}
  end

  defp start_session(opts) do
    case Opal.start_session(opts) do
      {:ok, agent} -> {:ok, agent}
      {:error, reason} -> error(:internal_error, "Failed to start session", inspect(reason))
    end
  end

  @valid_thinking ~w(off low medium high max)
  defp parse_thinking_level(l) when l in @valid_thinking, do: String.to_atom(l)
  defp parse_thinking_level(_), do: :off

  defp list_provider_models(nil), do: {:ok, []}

  defp list_provider_models(providers) when is_list(providers) do
    Enum.reduce_while(providers, {:ok, []}, fn p, {:ok, acc} ->
      try do
        provider = String.to_existing_atom(p)

        models =
          Opal.Provider.Registry.list_provider(provider) |> Enum.map(&Map.put(&1, :provider, p))

        {:cont, {:ok, acc ++ models}}
      rescue
        ArgumentError -> {:halt, {:error, p}}
      end
    end)
  end

  # ── Runtime config ─────────────────────────────────────────────────

  defp serialize_runtime_config(%Opal.Agent.State{} = state) do
    enabled = Opal.Agent.ToolRunner.active_tools(state) |> Enum.map(& &1.name())

    %{
      features: %{
        sub_agents: state.config.features.sub_agents.enabled,
        skills: state.config.features.skills.enabled,
        mcp: state.config.features.mcp.enabled,
        debug: state.config.features.debug.enabled
      },
      tools: %{
        all: Enum.map(state.tools, & &1.name()),
        enabled: enabled,
        disabled: state.disabled_tools
      },
      distribution: distribution_info()
    }
  end

  defp distribution_info do
    if Node.alive?(),
      do: %{node: Atom.to_string(Node.self()), cookie: Atom.to_string(Node.get_cookie())},
      else: nil
  end

  defp handle_distribution(:skip), do: {:ok, :noop}

  defp handle_distribution(nil) do
    if Node.alive?(), do: Node.stop()
    {:ok, nil}
  end

  defp handle_distribution(%{"name" => name} = params) when is_binary(name) do
    cookie =
      case params["cookie"] do
        c when is_binary(c) and c != "" -> String.to_atom(c)
        _ -> Opal.Application.generate_cookie()
      end

    if Node.alive?() do
      {:ok, distribution_info()}
    else
      case Node.start(String.to_atom(name), name_domain: :shortnames) do
        {:ok, _} ->
          Node.set_cookie(cookie)
          Opal.Application.write_node_file(Node.self(), cookie)
          {:ok, distribution_info()}

        {:error, reason} ->
          {:error, "Failed to start distribution: #{inspect(reason)}", nil}
      end
    end
  end

  defp handle_distribution(_),
    do: {:error, "Invalid distribution config: expected {name, cookie?} or null", nil}

  # ── Map helpers ────────────────────────────────────────────────────

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, val), do: Map.put(map, key, val)

  defp put_string(map, params, from, to) do
    case params[from] do
      v when is_binary(v) -> Map.put(map, to, v)
      _ -> map
    end
  end

  defp put_flag(map, params, from, to) do
    if params[from] == true, do: Map.put(map, to, true), else: map
  end

  # ── Event serialization ────────────────────────────────────────────

  defp serialize_event({:agent_start}), do: {"agent_start", %{}}
  defp serialize_event({:agent_abort}), do: {"agent_abort", %{}}
  defp serialize_event({:agent_recovered}), do: {"agent_recovered", %{}}
  defp serialize_event({:message_start}), do: {"message_start", %{}}
  defp serialize_event({:thinking_start}), do: {"thinking_start", %{}}

  defp serialize_event({:message_delta, %{delta: d}}), do: {"message_delta", %{delta: d}}
  defp serialize_event({:thinking_delta, %{delta: d}}), do: {"thinking_delta", %{delta: d}}
  defp serialize_event({:message_queued, text}), do: {"message_queued", %{text: text}}
  defp serialize_event({:message_applied, text}), do: {"message_applied", %{text: text}}
  defp serialize_event({:status_update, msg}), do: {"status_update", %{message: msg}}
  defp serialize_event({:error, reason}), do: {"error", %{reason: inspect(reason)}}
  defp serialize_event({:context_discovered, files}), do: {"context_discovered", %{files: files}}

  defp serialize_event({:skill_loaded, name, desc}),
    do: {"skill_loaded", %{name: name, description: desc}}

  defp serialize_event({:usage_update, usage}), do: {"usage_update", %{usage: usage}}

  defp serialize_event({:agent_end, _messages}), do: {"agent_end", %{}}
  defp serialize_event({:agent_end, _messages, usage}), do: {"agent_end", %{usage: usage}}

  defp serialize_event({:turn_end, message, _results}) do
    content =
      case message do
        %Opal.Message{content: c} -> c
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    {"turn_end", %{message: content}}
  end

  defp serialize_event({:sub_agent_start, %{model: m, label: l, tools: t}}),
    do: {"sub_agent_start", %{model: m, label: l, tools: t}}

  defp serialize_event({:sub_agent_event, call_id, sub_sid, inner}) do
    {inner_type, inner_data} = serialize_event(inner)

    {"sub_agent_event",
     %{
       parent_call_id: call_id,
       sub_session_id: sub_sid,
       inner: Map.put(inner_data, :type, inner_type)
     }}
  end

  # tool_execution_start has 3 arities in the wild
  defp serialize_event({:tool_execution_start, tool, call_id, args, meta}),
    do: {"tool_execution_start", %{tool: tool, call_id: call_id, args: args, meta: meta}}

  defp serialize_event({:tool_execution_start, tool, args, meta}),
    do: {"tool_execution_start", %{tool: tool, call_id: "", args: args, meta: meta}}

  defp serialize_event({:tool_execution_start, tool, args}),
    do: {"tool_execution_start", %{tool: tool, call_id: "", args: args, meta: tool}}

  defp serialize_event({:tool_execution_end, tool, call_id, result}),
    do:
      {"tool_execution_end", %{tool: tool, call_id: call_id, result: format_tool_result(result)}}

  defp serialize_event({:tool_execution_end, tool, result}),
    do: {"tool_execution_end", %{tool: tool, call_id: "", result: format_tool_result(result)}}

  defp serialize_event(other), do: {"unknown", %{raw: inspect(other)}}

  defp format_tool_result({:ok, output}), do: %{ok: true, output: output}
  defp format_tool_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp format_tool_result(other), do: %{ok: true, output: inspect(other)}

  # ── Stdin reader ───────────────────────────────────────────────────

  defp stdin_loop(parent) do
    port = :erlang.open_port({:fd, 0, 0}, [:binary, :stream, :eof])
    read_loop(port, parent, "")
  end

  defp read_loop(port, parent, buf) do
    receive do
      {^port, {:data, data}} ->
        buf = buf <> data
        {lines, rest} = split_lines(buf)

        for line <- lines,
            line = String.trim(line),
            line != "",
            do: send(parent, {:stdin_line, line})

        read_loop(port, parent, rest)

      {^port, :eof} ->
        send(parent, :stdin_eof)
    end
  end

  defp split_lines(buf) do
    case String.split(buf, "\n", parts: 2) do
      [line, rest] ->
        {more, final} = split_lines(rest)
        {[line | more], final}

      [incomplete] ->
        {[], incomplete}
    end
  end

  # ── Stdout ─────────────────────────────────────────────────────────

  defp write(%__MODULE__{stdout_port: port}, json), do: Port.command(port, json <> "\n")
end
