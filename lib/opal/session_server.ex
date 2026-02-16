defmodule Opal.SessionServer do
  @moduledoc """
  Per-session supervisor that owns the full session process tree.

  Each session gets its own supervision subtree:

      Opal.SessionServer (Supervisor, :rest_for_one)
      ├── Task.Supervisor        — per-session tool execution
      ├── DynamicSupervisor      — per-session sub-agents
      ├── Opal.MCP.Supervisor    — MCP client connections (optional)
      ├── Opal.Session           — conversation persistence (optional)
      └── Opal.Agent             — the agent loop

  Terminating the SessionServer cleans up everything: the agent, all
  running tools, all sub-agents, MCP connections, and the session store.

  The `:rest_for_one` strategy means if the Task.Supervisor,
  DynamicSupervisor, or MCP.Supervisor crashes, the Agent (which depends
  on them) restarts too.
  """

  use Supervisor

  @doc """
  Starts a session supervisor with the given options.

  ## Required Options

    * `:session_id` — unique session identifier
    * `:model` — `Opal.Model.t()` struct
    * `:working_dir` — base directory for tool execution

  ## Optional Options

    * `:system_prompt` — system prompt string
    * `:tools` — list of `Opal.Tool` modules
    * `:config` — `Opal.Config.t()` struct
    * `:provider` — `Opal.Provider` module
    * `:session` — if `true`, starts an `Opal.Session` process
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.get(opts, :config, Opal.Config.new())
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    # Name the per-session supervisors using Registry for discoverability
    # (avoids dynamic atom generation which leaks memory on the BEAM)
    tool_sup_name = {:via, Registry, {Opal.Registry, {:tool_sup, session_id}}}
    sub_agent_sup_name = {:via, Registry, {Opal.Registry, {:sub_agent_sup, session_id}}}
    mcp_sup_name = {:via, Registry, {Opal.Registry, {:mcp_sup, session_id}}}

    # Discover MCP servers from config files + explicit config (if MCP enabled)
    mcp_servers =
      if config.features.mcp.enabled do
        discover_mcp_servers(config, working_dir)
      else
        []
      end

    # Build child list dynamically
    children =
      [
        {Task.Supervisor, name: tool_sup_name},
        {DynamicSupervisor, name: sub_agent_sup_name, strategy: :one_for_one}
      ] ++
        maybe_mcp_child(mcp_servers, mcp_sup_name) ++
        maybe_session_child(opts) ++
        [
          {Opal.Agent,
           opts ++
             [
               tool_supervisor: tool_sup_name,
               sub_agent_supervisor: sub_agent_sup_name,
               mcp_supervisor: if(mcp_servers != [], do: mcp_sup_name),
               mcp_servers: mcp_servers
             ]}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Optionally includes an Opal.Session child if session: true.
  defp maybe_session_child(opts) do
    if Keyword.get(opts, :session) == true do
      session_id = Keyword.fetch!(opts, :session_id)
      config = Keyword.get(opts, :config, Opal.Config.new())
      sessions_dir = Opal.Config.sessions_dir(config)
      session_file = Path.join(sessions_dir, "#{session_id}.jsonl")

      session_opts = [
        session_id: session_id,
        sessions_dir: sessions_dir,
        name: {:via, Registry, {Opal.Registry, {:session, session_id}}}
      ]

      # If a saved session file exists on disk, load it during init
      session_opts =
        if File.exists?(session_file),
          do: Keyword.put(session_opts, :load_from, session_file),
          else: session_opts

      [{Opal.Session, session_opts}]
    else
      []
    end
  end

  # Includes MCP.Supervisor child if there are MCP servers configured.
  defp maybe_mcp_child([], _name), do: []

  defp maybe_mcp_child(servers, name) do
    [{Opal.MCP.Supervisor, servers: servers, name: name}]
  end

  # Discovers MCP servers from config files and merges with explicit config.
  defp discover_mcp_servers(config, working_dir) do
    discovered =
      Opal.MCP.Config.discover(working_dir, extra_files: config.features.mcp.config_files)

    explicit = config.features.mcp.servers

    # Explicit config takes priority, then discovered (dedup by name)
    (explicit ++ discovered)
    |> Enum.uniq_by(&to_string(&1.name))
  end

  @doc """
  Returns the Agent pid from a SessionServer supervisor.
  """
  @spec agent(pid()) :: pid() | nil
  def agent(session_server) do
    session_server
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Opal.Agent, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  @doc """
  Returns the Session pid from a SessionServer supervisor, or nil.
  """
  @spec session(pid()) :: pid() | nil
  def session(session_server) do
    session_server
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Opal.Session, pid, :worker, _} -> pid
      _ -> nil
    end)
  end
end
