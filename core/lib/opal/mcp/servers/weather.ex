defmodule Opal.MCP.Servers.Weather do
  @moduledoc """
  Example MCP server that provides weather information via stdio JSON-RPC.

  Implements the MCP protocol directly over stdin/stdout without depending
  on Anubis server (which has a bug in its stdio transport message parsing).

  Uses the free wttr.in API to fetch current weather for a given location.
  Defaults to Seattle if no location is specified.

  ## Usage

  Started as a stdio MCP server via `mix opal.mcp.weather`:

      mix opal.mcp.weather

  Or reference it in `.mcp.json`:

      {
        "servers": {
          "weather": {
            "command": "mix",
            "args": ["opal.mcp.weather"]
          }
        }
      }
  """

  require Logger

  @server_info %{"name" => "opal-weather", "version" => "0.1.0"}

  @tool_definition %{
    "name" => "get_weather",
    "description" =>
      "Get current weather for a location. Uses wttr.in. " <>
        "Returns temperature, conditions, humidity, and wind.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "location" => %{
          "type" => "string",
          "description" => "City name (e.g. 'Seattle', 'London'). Defaults to Seattle."
        }
      }
    }
  }

  @doc "Starts the stdio MCP server loop."
  def run do
    # Read lines from stdin, process as JSON-RPC, write responses to stdout
    IO.stream(:stdio, :line)
    |> Stream.each(&handle_line/1)
    |> Stream.run()
  end

  defp handle_line(line) do
    line = String.trim(line)
    if line == "", do: :ok, else: process_message(line)
  end

  defp process_message(data) do
    case Jason.decode(data) do
      {:ok, msg} ->
        dispatch(msg)

      {:error, reason} ->
        Logger.warning("Failed to decode MCP message: #{inspect(reason)}")
    end
  end

  defp dispatch(%{"method" => "initialize", "id" => id}) do
    reply(id, %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => @server_info
    })
  end

  defp dispatch(%{"method" => "notifications/initialized"}) do
    # Client acknowledgement — no response needed
    :ok
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}) do
    reply(id, %{"tools" => [@tool_definition]})
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}) do
    tool_name = params["name"]
    args = params["arguments"] || %{}

    case tool_name do
      "get_weather" ->
        result = call_weather(args)
        reply(id, result)

      _ ->
        error(id, -32601, "Unknown tool: #{tool_name}")
    end
  end

  defp dispatch(%{"method" => "ping", "id" => id}) do
    reply(id, %{})
  end

  defp dispatch(%{"method" => _method}) do
    # Ignore unknown notifications
    :ok
  end

  defp dispatch(%{"id" => id}) do
    error(id, -32601, "Method not found")
  end

  defp call_weather(args) do
    location = Map.get(args, "location", "Seattle") |> URI.encode()
    url = "https://wttr.in/#{location}?format=j1"

    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        %{"content" => [%{"type" => "text", "text" => format_weather(body, location)}]}

      {:ok, %{status: status}} ->
        %{"content" => [%{"type" => "text", "text" => "Weather API returned status #{status}"}],
          "isError" => true}

      {:error, reason} ->
        %{"content" => [%{"type" => "text", "text" => "Failed to fetch weather: #{inspect(reason)}"}],
          "isError" => true}
    end
  end

  defp reply(id, result) do
    msg = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    IO.puts(msg)
  end

  defp error(id, code, message) do
    msg = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
    IO.puts(msg)
  end

  defp format_weather(data, location) do
    current = get_in(data, ["current_condition", Access.at(0)]) || %{}

    temp_c = current["temp_C"] || "?"
    temp_f = current["temp_F"] || "?"
    desc = get_in(current, ["weatherDesc", Access.at(0), "value"]) || "Unknown"
    humidity = current["humidity"] || "?"
    wind_mph = current["windspeedMiles"] || "?"
    wind_dir = current["winddir16Point"] || "?"
    feels_c = current["FeelsLikeC"] || "?"
    feels_f = current["FeelsLikeF"] || "?"

    area =
      get_in(data, ["nearest_area", Access.at(0), "areaName", Access.at(0), "value"]) ||
        URI.decode(location)

    """
    Weather for #{area}:
    #{desc}
    Temperature: #{temp_c}°C (#{temp_f}°F)
    Feels like: #{feels_c}°C (#{feels_f}°F)
    Humidity: #{humidity}%
    Wind: #{wind_mph} mph #{wind_dir}\
    """
  end
end
