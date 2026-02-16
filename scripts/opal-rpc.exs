#!/usr/bin/env elixir
# scripts/opal-rpc.exs — Send a one-off JSON-RPC call to opal-server in-process.
#
# Usage:
#   mix run --no-start scripts/opal-rpc.exs -- <method> [params_json]
#
# Examples:
#   # Liveness check
#   mix run --no-start scripts/opal-rpc.exs -- opal/ping
#
#   # Start a session
#   mix run --no-start ../../scripts/opal-rpc.exs -- session/start '{"working_dir": "/tmp"}'
#
#   # List models
#   mix run --no-start ../../scripts/opal-rpc.exs -- models/list
#
#   # Check auth status
#   mix run --no-start ../../scripts/opal-rpc.exs -- auth/status
#
#   # Get agent state
#   mix run --no-start ../../scripts/opal-rpc.exs -- agent/state '{"session_id": "..."}'
#
# The script boots the Opal OTP application (without the stdio transport),
# calls Opal.RPC.Handler.handle/2 directly, and prints the JSON result.

# Disable stdio RPC transport and distribution — not needed for direct calls.
Application.put_env(:opal, :start_rpc, false)
Application.put_env(:opal, :start_distribution, false)

# Ensure the app is started (deps, supervision tree, registries).
Application.ensure_all_started(:opal)

# Strip leading "--" that mix run passes through when used with `--` separator.
argv = Enum.drop_while(System.argv(), &(&1 == "--"))

{method, params} =
  case argv do
    [method] ->
      {method, %{}}

    [method, params_json] ->
      case Jason.decode(params_json) do
        {:ok, params} when is_map(params) ->
          {method, params}

        {:ok, _} ->
          IO.puts(:stderr, "Error: params must be a JSON object")
          System.halt(1)

        {:error, err} ->
          IO.puts(:stderr, "Error: invalid JSON — #{inspect(err)}")
          System.halt(1)
      end

    [] ->
      IO.puts(:stderr, """
      Usage: elixir -S mix run scripts/opal-rpc.exs -- <method> [params_json]

      Methods:
        opal/ping              Liveness check
        session/start          Start a new session
        session/list           List saved sessions
        models/list            List available models
        auth/status            Check auth credentials
        agent/state            Get agent state (needs session_id)
        agent/prompt           Send a prompt (needs session_id + text)
        opal/config/get        Get runtime config (needs session_id)
      """)

      System.halt(1)

    _ ->
      IO.puts(:stderr, "Error: too many arguments (expected: method [params_json])")
      System.halt(1)
  end

result =
  case Opal.RPC.Handler.handle(method, params) do
    {:ok, data} ->
      %{ok: true, result: data}

    {:error, code, message, data} ->
      %{ok: false, error: %{code: code, message: message, data: data}}
  end

IO.puts(Jason.encode!(result, pretty: true))
