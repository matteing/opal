defmodule Opal.MCP.Config do
  @moduledoc """
  Discovers and parses MCP server configuration files.

  Searches multiple standard locations for `mcp.json` files following the
  [VS Code MCP configuration format](https://code.visualstudio.com/docs/copilot/customization/mcp-servers#_configuration-format),
  and converts them into the internal `%{name, transport}` maps that
  `Opal.MCP.Supervisor` expects.

  ## Discovery paths (in order)

  Project-local (relative to `working_dir`):
    1. `.vscode/mcp.json`
    2. `.github/mcp.json`
    3. `.opal/mcp.json`
    4. `.mcp.json`

  User global:
    5. `~/.opal/mcp.json`

  First definition wins per server name — project-local overrides global.

  ## VS Code format

  ```json
  {
    "servers": {
      "memory": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-memory"]
      },
      "github": {
        "type": "http",
        "url": "https://api.githubcopilot.com/mcp"
      }
    }
  }
  ```

  Stdio servers use `command` + `args` + optional `env`/`envFile`.
  HTTP/SSE servers use `type` ("http" or "sse") + `url` + optional `headers`.
  """

  @default_config_files [
    ".vscode/mcp.json",
    ".github/mcp.json",
    ".opal/mcp.json",
    ".mcp.json"
  ]

  @doc """
  Discovers MCP server configurations from standard file locations.

  ## Options

    * `:extra_files` — additional file paths to search (absolute or relative to working_dir)

  Returns a list of `%{name: atom, transport: tuple}` maps, deduplicated
  by server name (first found wins).
  """
  @spec discover(String.t(), keyword()) :: [map()]
  def discover(working_dir, opts \\ []) do
    extra_files = Keyword.get(opts, :extra_files, [])

    # Project-local paths
    project_files =
      @default_config_files
      |> Enum.map(&Path.join(working_dir, &1))

    # User global
    global_files = [
      Path.join(System.user_home!(), ".opal/mcp.json")
    ]

    all_files =
      project_files ++
        Enum.map(extra_files, fn f ->
          if Path.type(f) == :absolute, do: f, else: Path.join(working_dir, f)
        end) ++ global_files

    all_files
    |> Enum.flat_map(&parse_file/1)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Parses a single mcp.json file and returns a list of server configs.

  Returns `[]` if the file doesn't exist or is invalid.
  """
  @spec parse_file(String.t()) :: [map()]
  def parse_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content),
         %{"servers" => servers} when is_map(servers) <- json do
      servers
      |> Enum.map(fn {name, config} -> parse_server(name, config) end)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @doc """
  Parses a single server entry from VS Code format into internal format.

  Returns `%{name: String.t(), transport: tuple}` or `nil` if invalid.
  """
  @spec parse_server(String.t(), map()) :: map() | nil
  def parse_server(name, config) when is_binary(name) and is_map(config) do
    case detect_transport(config) do
      {:ok, transport} ->
        %{name: name, transport: transport}

      :error ->
        nil
    end
  end

  def parse_server(_name, _config), do: nil

  # --- Private ---

  # Detects transport type from VS Code config format.
  defp detect_transport(%{"type" => type, "url" => url} = config) when type in ["http", "sse"] do
    transport_type = if type == "sse", do: :sse, else: :streamable_http
    headers = parse_headers(config["headers"])

    opts =
      [{:url, url}]
      |> maybe_add(:headers, headers)

    {:ok, {transport_type, opts}}
  end

  # Stdio: has "command" key (type may be "stdio" or absent)
  defp detect_transport(%{"command" => command} = config) do
    args = config["args"] || []
    env = parse_env(config["env"])

    # On Windows, .cmd/.bat files can't be executed directly via open_port;
    # wrap with cmd.exe /C so Erlang's spawn_executable works.
    {command, args} =
      if Opal.Platform.windows?() do
        {"cmd", ["/C", command | args]}
      else
        {command, args}
      end

    opts =
      [{:command, command}, {:args, args}]
      |> maybe_add(:env, env)

    {:ok, {:stdio, opts}}
  end

  defp detect_transport(_), do: :error

  defp parse_headers(nil), do: []

  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {k, resolve_value(v)} end)
  end

  defp parse_headers(_), do: []

  defp parse_env(nil), do: %{}

  defp parse_env(env) when is_map(env) do
    Map.new(env, fn {k, v} -> {k, resolve_value(v)} end)
  end

  defp parse_env(_), do: %{}

  # Resolves ${input:...} placeholders — for now, checks env vars.
  # Full VS Code input variable support would require interactive prompting.
  defp resolve_value(value) when is_binary(value) do
    Regex.replace(~r/\$\{input:([^}]+)\}/, value, fn _match, var_name ->
      System.get_env(String.upcase(var_name)) || "${input:#{var_name}}"
    end)
  end

  defp resolve_value(value), do: value

  defp maybe_add(opts, _key, val) when val == [] or val == %{}, do: opts
  defp maybe_add(opts, key, val), do: opts ++ [{key, val}]
end
