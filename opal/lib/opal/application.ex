defmodule Opal.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Opal.Registry},
      {Registry, keys: :duplicate, name: Opal.Events.Registry},
      {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one}
    ]

    # Only start stdio transport when enabled (default true for backward compat;
    # set `config :opal, start_rpc: false` for embedded SDK use).
    children =
      if Application.get_env(:opal, :start_rpc, true) do
        children ++ [Opal.RPC.Stdio]
      else
        children
      end

    opts = [strategy: :rest_for_one, name: Opal.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if Application.get_env(:opal, :start_distribution, false) do
        start_distribution()
      end

      {:ok, pid}
    end
  end

  @doc """
  Starts Erlang distribution so remote nodes can connect.

  Writes the node name to `~/.opal/node` for discovery by `pnpm inspect`.
  No-op if distribution is already started. Returns `{:ok, node_name}` or `{:error, reason}`.

  The distribution cookie is read from `config :opal, :distribution_cookie`.
  When set to `:random` (the default), a cryptographically random cookie is
  generated each time. Set an explicit atom to use a fixed cookie.
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
      cookie = distribution_cookie()

      case Node.start(node_name, name_domain: :shortnames) do
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
  Generates a cryptographically random cookie for Erlang distribution.
  """
  @spec generate_cookie() :: atom()
  def generate_cookie do
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
    |> String.to_atom()
  end

  defp distribution_cookie do
    case Application.get_env(:opal, :distribution_cookie, :random) do
      :random -> generate_cookie()
      cookie when is_atom(cookie) -> cookie
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
          [name, cookie] when name != "" and cookie != "" ->
            # Validate node name format (e.g. "opal_12345@hostname")
            if Regex.match?(~r/^[\w@.\-]+$/, name) do
              {:ok, String.to_atom(name), String.to_atom(cookie)}
            else
              Logger.warning("Invalid node name in #{path}: #{inspect(name)}")
              :error
            end

          _ ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  @doc """
  Writes node name and cookie to the node file for discovery.
  """
  @spec write_node_file(node(), atom()) :: :ok
  def write_node_file(node_name, cookie) do
    path = node_file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{node_name}\n#{cookie}\n")
    # Best-effort permission restriction — chmod is unsupported on Windows
    _ = File.chmod(path, 0o600)
    :ok
  end

  defp node_file_path do
    Path.join([System.user_home!(), ".opal", "node"])
  end
end
