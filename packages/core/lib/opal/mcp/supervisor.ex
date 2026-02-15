defmodule Opal.MCP.Supervisor do
  @moduledoc """
  Supervisor for MCP client processes within a session.

  Starts one `Opal.MCP.Client` child per configured MCP server using
  a `:one_for_one` strategy — each server connection is independent,
  so a crash in one doesn't affect others.

  ## Supervision tree placement

      SessionSupervisor (:rest_for_one)
      ├── Task.Supervisor      — tool execution
      ├── DynamicSupervisor    — sub-agents
      ├── Opal.MCP.Supervisor  — MCP clients
      │   ├── Client :server_a
      │   ├── Client :server_b
      │   └── ...
      ├── Opal.Session         — persistence (optional)
      └── Opal.Agent           — the agent loop

  When the session shuts down, this supervisor cascades termination to
  all Anubis client processes, which cleanly close their connections.
  """

  use Supervisor

  @doc """
  Starts the MCP supervisor with the given server configurations.

  ## Parameters

    * `opts` — keyword list with:
      * `:servers` — list of `%{name: atom | String.t(), transport: tuple}` maps
      * `:name` — optional process name (atom or via-tuple)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, opts, start_opts)
  end

  @impl true
  def init(opts) do
    servers = Keyword.get(opts, :servers, [])

    children =
      Enum.map(servers, fn server_config ->
        Opal.MCP.Client.child_spec(server_config)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the list of running MCP client names from this supervisor.
  """
  @spec running_clients(pid()) :: [atom() | String.t()]
  def running_clients(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> Enum.map(fn {{:mcp, name}, _pid, _type, _modules} -> name end)
  end
end
