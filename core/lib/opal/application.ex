defmodule Opal.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Opal.Registry},
      {Registry, keys: :duplicate, name: Opal.Events.Registry},
      {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one},
      Opal.RPC.Stdio
    ]

    opts = [strategy: :one_for_one, name: Opal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Starts Erlang distribution so remote nodes can connect.

  Writes the node name to `~/.opal/node` for discovery by `--connect`.
  No-op if distribution is already started. Returns `{:ok, node_name}` or `{:error, reason}`.
  """
  @spec start_distribution() :: {:ok, node()} | {:error, term()}
  def start_distribution do
    if Node.alive?() do
      # Already distributed (e.g. started via --name/--sname by mix or release)
      write_node_file(Node.self(), Node.get_cookie())
      Logger.debug("Distribution already active: #{Node.self()}")
      {:ok, Node.self()}
    else
      node_name = :"opal_#{System.pid()}"
      cookie = :opal

      case Node.start(node_name, :shortnames) do
        {:ok, _pid} ->
          Node.set_cookie(cookie)
          write_node_file(Node.self(), cookie)
          Logger.debug("Distribution started: #{Node.self()}")
          {:ok, Node.self()}

        {:error, reason} ->
          Logger.warning("Could not start distribution: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Reads the node name and cookie from `~/.opal/node`.
  Returns `{:ok, node_name, cookie}` or `:error`.
  """
  @spec read_node_file() :: {:ok, node(), atom()} | :error
  def read_node_file do
    path = node_file_path()

    case File.read(path) do
      {:ok, contents} ->
        case String.split(String.trim(contents), "\n") do
          [name, cookie] ->
            {:ok, String.to_atom(name), String.to_atom(cookie)}

          _ ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp write_node_file(node_name, cookie) do
    path = node_file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{node_name}\n#{cookie}\n")
  end

  defp node_file_path do
    Path.join([System.user_home!(), ".opal", "node"])
  end
end
