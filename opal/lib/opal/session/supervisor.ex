defmodule Opal.Session.Supervisor do
  @moduledoc """
  Per-session supervisor that owns the full session process tree.

  Each session gets its own supervision subtree:

      Opal.Session.Supervisor (Supervisor, :rest_for_one)
      ├── Task.Supervisor        — per-session tool execution
      ├── Opal.Session           — conversation persistence (optional)
      └── Opal.Agent             — the agent loop

  Terminating the Session.Supervisor cleans up everything: the agent, all
  running tools, and the session store.

  The `:rest_for_one` strategy means if the Task.Supervisor crashes,
  the Agent (which depends on it) restarts too.

  The agent registers itself in `Opal.Registry` under `{:agent, session_id}`,
  so callers can discover it without a reference to this supervisor:

      [{agent, _}] = Registry.lookup(Opal.Registry, {:agent, session_id})
  """

  use Supervisor

  @doc """
  Starts a session supervisor with the given options.

  ## Required Options

    * `:session_id` — unique session identifier
    * `:model` — `Opal.Provider.Model.t()` struct
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

    # Name the per-session supervisors using Registry for discoverability
    # (avoids dynamic atom generation which leaks memory on the BEAM)
    tool_sup_name = {:via, Registry, {Opal.Registry, {:tool_sup, session_id}}}

    children =
      [{Task.Supervisor, name: tool_sup_name}] ++
        maybe_session_child(opts) ++
        [{Opal.Agent, opts ++ [tool_supervisor: tool_sup_name]}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_session_child(opts) do
    if Keyword.get(opts, :session) == true do
      session_id = Keyword.fetch!(opts, :session_id)
      config = Keyword.get(opts, :config, Opal.Config.new())
      sessions_dir = Opal.Config.sessions_dir(config)
      session_file = Path.join(sessions_dir, "#{session_id}.dets")

      session_opts = [
        session_id: session_id,
        sessions_dir: sessions_dir,
        name: {:via, Registry, {Opal.Registry, {:session, session_id}}}
      ]

      session_opts =
        if File.exists?(session_file),
          do: Keyword.put(session_opts, :load_from, session_file),
          else: session_opts

      [{Opal.Session, session_opts}]
    else
      []
    end
  end
end
