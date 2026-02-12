# `Opal.MCP.Client`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/mcp/client.ex#L1)

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

# `add_root`

Adds a root directory or resource.

## Examples
    :ok = MyClient.add_root("file:///project", "My Project")

# `await_ready`

```elixir
@spec await_ready(atom() | String.t(), pos_integer()) :: :ok | {:error, :timeout}
```

Waits for the named MCP server to complete initialization.

Polls `get_server_capabilities` until non-nil or the timeout expires.
Returns `:ok` when ready, `{:error, :timeout}` if the server doesn't
initialize in time.

# `call_tool`

Calls a specific tool by name with optional arguments.

## Examples
    {:ok, result} = MyClient.call_tool("search", %{query: "elixir"})

# `cancel_all_requests`

Cancels all pending requests.

## Examples
    :ok = MyClient.cancel_all_requests("shutting_down")

# `cancel_request`

Cancels a specific request by ID.

## Examples
    :ok = MyClient.cancel_request("req-123")

# `child_spec`

```elixir
@spec child_spec(map()) :: Supervisor.child_spec()
```

Builds a child spec for a named MCP server connection.

## Parameters

  * `server_config` — a map with `:name` (atom) and `:transport` (tuple) keys

The child spec uses `{:mcp, server_name}` as its id for supervisor
deduplication and introspection. Each server's client GenServer is
registered under `{:opal_mcp, server_name}` for unique addressing.

# `clear_roots`

Clears all registered roots.

## Examples
    :ok = MyClient.clear_roots()

# `client_name`

```elixir
@spec client_name(atom() | String.t()) :: {:via, module(), {module(), term()}}
```

Returns the registered process name for an MCP server's client GenServer.

Uses a `{:via, Registry, ...}` tuple to avoid dynamic atom generation.

# `close`

Closes the client connection gracefully.

## Examples
    :ok = MyClient.close()

# `complete`

Completes a partial result reference.

## Examples
    {:ok, result} = MyClient.complete(ref, "completed")

# `get_prompt`

Gets a specific prompt by name with optional arguments.

## Examples
    {:ok, prompt} = MyClient.get_prompt("greeting", %{name: "Alice"})

# `get_server_capabilities`

Gets the server's declared capabilities.

## Examples
    {:ok, capabilities} = MyClient.get_server_capabilities()

# `get_server_info`

Gets the server information including name and version.

## Examples
    {:ok, info} = MyClient.get_server_info()

# `list_prompts`

Lists all available prompts from the server.

## Options
  * `:cursor` - Pagination cursor
  * `:timeout` - Request timeout in milliseconds

## Examples
    {:ok, prompts} = MyClient.list_prompts()

# `list_resource_templates`

Lists all available resource templates from the server.

## Options
  * `:cursor` - Pagination cursor
  * `:timeout` - Request timeout in milliseconds

## Examples
    {:ok, resources} = MyClient.list_resources_templates()

# `list_resources`

Lists all available resources from the server.

## Options
  * `:cursor` - Pagination cursor
  * `:timeout` - Request timeout in milliseconds

## Examples
    {:ok, resources} = MyClient.list_resources()

# `list_roots`

Lists all registered roots.

## Examples
    {:ok, roots} = MyClient.list_roots()

# `list_tools`

Lists all available tools from the server.

## Options
  * `:cursor` - Pagination cursor
  * `:timeout` - Request timeout in milliseconds

## Examples
    {:ok, tools} = MyClient.list_tools()

# `merge_capabilities`

Merges additional capabilities into the client.

## Examples
    :ok = MyClient.merge_capabilities(%{"experimental" => %{}})

# `ping`

Sends a ping request to the MCP server.

## Options
  * `:timeout` - Request timeout in milliseconds (default: 5000)

## Examples
    {:ok, :pong} = MyClient.ping()

# `read_resource`

Reads a specific resource by URI.

## Examples
    {:ok, content} = MyClient.read_resource("file:///path/to/file")

# `register_log_callback`

Registers a callback for log messages.

## Examples
    :ok = MyClient.register_log_callback(fn log -> IO.puts(log) end)

# `register_progress_callback`

Registers a callback for progress updates.

## Examples
    :ok = MyClient.register_progress_callback("task-1", fn progress -> 
      IO.puts("Progress: #{progress}")
    end)

# `remove_root`

Removes a root directory or resource.

## Examples
    :ok = MyClient.remove_root("file:///project")

# `send_progress`

Sends a progress update for a token.

## Examples
    :ok = MyClient.send_progress("task-1", 50, 100)

# `server_call_tool`

```elixir
@spec server_call_tool(atom() | String.t(), String.t(), map() | nil, keyword()) ::
  {:ok, term()} | {:error, term()}
```

Calls a tool on the named MCP server.

# `server_list_resources`

```elixir
@spec server_list_resources(
  atom() | String.t(),
  keyword()
) :: {:ok, term()} | {:error, term()}
```

Lists resources on the named MCP server.

# `server_list_tools`

```elixir
@spec server_list_tools(
  atom() | String.t(),
  keyword()
) :: {:ok, term()} | {:error, term()}
```

Lists tools on the named MCP server.

# `server_read_resource`

```elixir
@spec server_read_resource(atom() | String.t(), String.t(), keyword()) ::
  {:ok, term()} | {:error, term()}
```

Reads a resource from the named MCP server.

# `set_log_level`

Sets the server's log level.

## Examples
    :ok = MyClient.set_log_level("debug")

# `start_link`

# `transport_name`

```elixir
@spec transport_name(atom() | String.t()) :: {:via, module(), {module(), term()}}
```

Returns the registered process name for an MCP server's transport process.

# `unregister_log_callback`

Unregisters the log callback.

# `unregister_progress_callback`

Unregisters a progress callback.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
