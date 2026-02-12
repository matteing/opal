defmodule Opal.MCP.Client do
  @moduledoc """
  Anubis MCP client for connecting to external MCP servers.

  Each configured MCP server gets its own `Opal.MCP.Client` process,
  managed by Anubis internally. The client handles transport management,
  protocol negotiation, and provides a clean API for tool/resource operations.

  ## Naming

  Each server gets a unique client process name via `client_name/1`:

      Opal.MCP.Client.client_name(:weather)
      #=> :opal_mcp_client_weather

  All API functions (`server_list_tools/1`, `server_call_tool/3`, etc.) accept
  the server name atom and resolve the process name internally.

  ## Usage

  Typically started via `Opal.MCP.Supervisor`, not directly:

      child_spec = Opal.MCP.Client.child_spec(%{
        name: :filesystem,
        transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"]}
      })

  ## Supported transports

    * `{:stdio, command: "cmd", args: ["arg1"]}` — local process via stdin/stdout
    * `{:streamable_http, url: "http://..."}` — HTTP Stream transport
    * `{:sse, url: "http://..."}` — Server-Sent Events (legacy)
  """

  use Anubis.Client,
    name: "Opal",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: [:roots]

  alias Anubis.Client.Base

  @doc """
  Returns the registered process name for an MCP server's client GenServer.

  Uses a `{:via, Registry, ...}` tuple to avoid dynamic atom generation.
  """
  @spec client_name(atom() | String.t()) :: {:via, module(), {module(), term()}}
  def client_name(server_name), do: {:via, Registry, {Opal.Registry, {:mcp_client, server_name}}}

  @doc """
  Returns the registered process name for an MCP server's transport process.
  """
  @spec transport_name(atom() | String.t()) :: {:via, module(), {module(), term()}}
  def transport_name(server_name), do: {:via, Registry, {Opal.Registry, {:mcp_transport, server_name}}}

  @doc false
  @spec supervisor_name(atom() | String.t()) :: {:via, module(), {module(), term()}}
  def supervisor_name(server_name), do: {:via, Registry, {Opal.Registry, {:mcp_supervisor, server_name}}}

  @doc """
  Builds a child spec for a named MCP server connection.

  ## Parameters

    * `server_config` — a map with `:name` (atom) and `:transport` (tuple) keys

  The child spec uses `{:mcp, server_name}` as its id for supervisor
  deduplication and introspection. Each server's client GenServer is
  registered under `{:opal_mcp, server_name}` for unique addressing.
  """
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(%{name: server_name, transport: transport_config}) do
    opts = [
      transport: transport_config,
      name: supervisor_name(server_name),
      client_name: client_name(server_name),
      transport_name: transport_name(server_name)
    ]

    spec = super(opts)
    %{spec | id: {:mcp, server_name}}
  end

  @doc """
  Waits for the named MCP server to complete initialization.

  Polls `get_server_capabilities` until non-nil or the timeout expires.
  Returns `:ok` when ready, `{:error, :timeout}` if the server doesn't
  initialize in time.
  """
  @spec await_ready(atom() | String.t(), pos_integer()) :: :ok | {:error, :timeout}
  def await_ready(server_name, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready(server_name, deadline)
  end

  defp poll_ready(server_name, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case Base.get_server_capabilities(client_name(server_name), timeout: 1_000) do
        nil ->
          Process.sleep(100)
          poll_ready(server_name, deadline)

        _capabilities ->
          :ok
      end
    end
  catch
    _, _ ->
      Process.sleep(100)

      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout}
      else
        poll_ready(server_name, deadline)
      end
  end

  @doc "Lists tools on the named MCP server."
  @spec server_list_tools(atom() | String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def server_list_tools(server_name, opts \\ []) do
    Base.list_tools(client_name(server_name), opts)
  end

  @doc "Calls a tool on the named MCP server."
  @spec server_call_tool(atom() | String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def server_call_tool(server_name, tool_name, args \\ nil, opts \\ []) do
    Base.call_tool(client_name(server_name), tool_name, args, opts)
  end

  @doc "Lists resources on the named MCP server."
  @spec server_list_resources(atom() | String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def server_list_resources(server_name, opts \\ []) do
    Base.list_resources(client_name(server_name), opts)
  end

  @doc "Reads a resource from the named MCP server."
  @spec server_read_resource(atom() | String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def server_read_resource(server_name, uri, opts \\ []) do
    Base.read_resource(client_name(server_name), uri, opts)
  end
end
