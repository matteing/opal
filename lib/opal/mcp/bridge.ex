defmodule Opal.MCP.Bridge do
  @moduledoc """
  Bridges MCP tools into the Opal tool system.

  After Anubis clients connect and negotiate, `Bridge` queries each client
  for its available tools and wraps them as anonymous modules that implement
  the `Opal.Tool` behaviour interface. This lets the agent call MCP tools
  exactly like native tools — no special dispatch needed.

  ## Tool naming

  MCP tools keep their original names (e.g. `get_weather`, `search_issues`).
  When two servers expose tools with the same name, the tool is prefixed
  with the server name: `weather_get_weather`, `backup_get_weather`.
  """

  require Logger

  @doc """
  Discovers tools from a single named MCP client and returns them as
  Opal-compatible tool maps.

  Each returned map has:
    * `:name` — tool name (original, or `<server>_<tool>` on collision)
    * `:description` — tool description from the MCP server
    * `:parameters` — JSON Schema input schema
    * `:server` — the MCP server name (atom)
    * `:original_name` — the tool's original name on the MCP server

  Returns `[]` if the client is not connected or tool discovery fails.
  """
  @spec discover_tools(atom() | String.t()) :: [map()]
  def discover_tools(client_name) do
    # Wait for the MCP server to complete its initialization handshake
    case Opal.MCP.Client.await_ready(client_name, 5_000) do
      {:error, :timeout} ->
        Logger.warning("MCP server #{client_name} did not initialize in time")
        []

      :ok ->
        do_discover_tools(client_name)
    end
  catch
    kind, reason ->
      Logger.warning(
        "MCP tool discovery for #{client_name} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      []
  end

  defp do_discover_tools(client_name) do
    case Opal.MCP.Client.server_list_tools(client_name, timeout: 5_000) do
      {:ok, %{result: %{"tools" => tools}}} ->
        Enum.map(tools, fn tool ->
          wrap_tool(client_name, tool)
        end)

      {:ok, %{result: result}} when is_list(result) ->
        Enum.map(result, fn tool ->
          wrap_tool(client_name, tool)
        end)

      {:error, reason} ->
        Logger.warning(
          "Failed to discover tools from MCP server #{client_name}: #{inspect(reason)}"
        )

        []
    end
  catch
    kind, reason ->
      Logger.warning(
        "MCP tool discovery for #{client_name} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      []
  end

  @doc """
  Discovers tools from all configured MCP servers.

  Takes a list of server config maps (each with a `:name` key) and returns
  a flat list of all discovered tools across all servers.
  """
  @spec discover_all_tools([map()]) :: [map()]
  def discover_all_tools(mcp_servers) do
    mcp_servers
    |> Enum.flat_map(fn %{name: name} -> discover_tools(name) end)
  end

  @doc """
  Creates an Opal.Tool-compatible module for an MCP tool at runtime.

  The generated module implements the `Opal.Tool` behaviour callbacks
  (`name/0`, `description/0`, `parameters/0`, `execute/2`) and routes
  execution through the Anubis client.
  """
  @spec create_tool_module(atom() | String.t(), map(), String.t()) :: module()
  def create_tool_module(client_name, tool, resolved_name) do
    mod_name = Module.concat(Opal.MCP.Tool, Macro.camelize("#{client_name}_#{tool["name"]}"))

    tool_desc = tool["description"] || ""
    tool_params = tool["inputSchema"] || %{}
    original_name = tool["name"]

    # Purge any previous version of this module so reconnections with
    # changed tool definitions get a fresh module.
    if :erlang.module_loaded(mod_name) do
      :code.purge(mod_name)
      :code.delete(mod_name)
    end

    contents =
      quote do
        @behaviour Opal.Tool

        @impl true
        def name, do: unquote(resolved_name)

        @impl true
        def description, do: unquote(tool_desc)

        @impl true
        def parameters, do: unquote(Macro.escape(tool_params))

        @impl true
        def execute(args, _context) do
          case Opal.MCP.Client.server_call_tool(
                 unquote(client_name),
                 unquote(original_name),
                 args
               ) do
            {:ok, %{result: %{"content" => content}}} ->
              text = extract_text_content(content)
              {:ok, text}

            {:ok, %{result: result}} ->
              {:ok, inspect(result)}

            {:error, reason} ->
              {:error, "MCP tool error: #{inspect(reason)}"}
          end
        end

        defp extract_text_content(content) when is_list(content) do
          content
          |> Enum.map(fn
            %{"type" => "text", "text" => text} -> text
            other -> inspect(other)
          end)
          |> Enum.join("\n")
        end

        defp extract_text_content(content) when is_binary(content), do: content
        defp extract_text_content(content), do: inspect(content)
      end

    Module.create(mod_name, contents, Macro.Env.location(__ENV__))

    mod_name
  end

  @doc """
  Discovers tools from all MCP servers and returns them as runtime modules
  implementing `Opal.Tool`.

  Uses original tool names by default. When two servers expose tools with
  the same name, both get prefixed with their server name to disambiguate.

  The `existing_names` parameter is a `MapSet` of tool names already
  registered (e.g. native tools), which also trigger prefixing.
  """
  @spec discover_tool_modules([map()], MapSet.t()) :: [module()]
  def discover_tool_modules(mcp_servers, existing_names \\ MapSet.new()) do
    # Gather all raw tools from all servers
    all_tools =
      mcp_servers
      |> Enum.flat_map(fn %{name: server_name} ->
        discover_tools(server_name)
        |> Enum.map(&Map.put(&1, :server, server_name))
      end)

    # Count how many times each original_name appears across all servers + existing
    name_counts =
      all_tools
      |> Enum.frequencies_by(& &1.original_name)

    # Resolve final names: prefix with server name only on collision
    all_tools
    |> Enum.map(fn tool ->
      needs_prefix =
        Map.get(name_counts, tool.original_name, 0) > 1 or
          MapSet.member?(existing_names, tool.original_name)

      resolved_name =
        if needs_prefix,
          do: "#{tool.server}_#{tool.original_name}",
          else: tool.original_name

      create_tool_module(
        tool.server,
        %{
          "name" => tool.original_name,
          "description" => tool.description,
          "inputSchema" => tool.parameters
        },
        resolved_name
      )
    end)
  end

  # Wraps a raw MCP tool map into an Opal-friendly map.
  defp wrap_tool(client_name, tool) do
    %{
      name: tool["name"],
      description: tool["description"] || "",
      parameters: tool["inputSchema"] || %{},
      server: client_name,
      original_name: tool["name"]
    }
  end
end
