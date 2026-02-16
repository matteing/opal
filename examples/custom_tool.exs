# examples/custom_tool.exs
#
# Define a custom tool with `use Opal.Tool` and register it in a session.
#
# Usage:
#   mix run examples/custom_tool.exs
#

defmodule Examples.WeatherTool do
  use Opal.Tool,
    name: "get_weather",
    description: "Get the current weather for a city (mock data)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string", "description" => "City name"}
      },
      "required" => ["city"]
    }
  end

  @impl true
  def execute(%{"city" => city}, _context) do
    {:ok, "The weather in #{city} is 72°F and sunny."}
  end
end

{:ok, agent} =
  Opal.start_session(%{
    system_prompt: "You have access to a weather tool. Use it when asked about weather.",
    working_dir: File.cwd!(),
    tools: [Examples.WeatherTool]
  })

{:ok, response} = Opal.prompt_sync(agent, "What's the weather in San Francisco?", 30_000)
IO.puts(response)

Opal.stop_session(agent)
