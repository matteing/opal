defmodule Opal.MCP.Resources do
  @moduledoc """
  Discovers and reads resources from connected MCP servers.

  MCP servers can expose resources (file contents, database schemas, etc.)
  that can be injected into the agent's context. This module provides a
  thin wrapper around Anubis client resource operations.
  """

  require Logger

  @doc """
  Lists available resources from a named MCP client.

  Returns a list of resource maps, or `[]` if discovery fails.
  """
  @spec list(atom() | String.t()) :: [map()]
  def list(client_name) do
    case Opal.MCP.Client.server_list_resources(client_name) do
      {:ok, %{result: %{"resources" => resources}}} ->
        resources

      {:ok, %{result: result}} when is_list(result) ->
        result

      {:error, reason} ->
        Logger.warning(
          "Failed to list resources from MCP server #{client_name}: #{inspect(reason)}"
        )

        []
    end
  end

  @doc """
  Reads a specific resource by URI from a named MCP client.

  Returns `{:ok, contents}` or `{:error, reason}`.
  """
  @spec read(atom() | String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(client_name, uri) do
    case Opal.MCP.Client.server_read_resource(client_name, uri) do
      {:ok, %{result: %{"contents" => contents}}} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists resources from all configured MCP servers.

  Returns a flat list of `{server_name, resource}` tuples.
  """
  @spec list_all([map()]) :: [{atom() | String.t(), map()}]
  def list_all(mcp_servers) do
    mcp_servers
    |> Enum.flat_map(fn %{name: name} ->
      name
      |> list()
      |> Enum.map(&{name, &1})
    end)
  end
end
