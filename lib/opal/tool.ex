defmodule Opal.Tool do
  @moduledoc """
  Behaviour defining the interface for agent tools.

  Any module implementing this behaviour can be registered as a tool
  available to the agent during a session. Tools are invoked by the
  assistant via tool calls and must return their output as a string.

  ## Implementing a tool

      defmodule MyTool do
        @behaviour Opal.Tool

        @impl true
        def name, do: "my_tool"

        @impl true
        def description, do: "Does something useful"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "input" => %{"type" => "string", "description" => "The input value"}
            },
            "required" => ["input"]
          }
        end

        @impl true
        def execute(%{"input" => input}, _context) do
          {:ok, "Processed: \#{input}"}
        end
      end
  """

  @doc "Returns the tool name used in tool call messages."
  @callback name() :: String.t()

  @doc "Returns a human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc "Returns a JSON Schema map describing the tool's accepted parameters."
  @callback parameters() :: map()

  @doc """
  Returns a short, human-readable summary of a specific tool invocation.

  Used by UIs to show what a tool call is doing, e.g. `"Reading lib/opal.ex"`.
  Receives the parsed arguments map. Falls back to the tool name if not implemented.
  """
  @callback meta(args :: map()) :: String.t()

  @doc "Executes the tool with the given arguments and session context."
  @callback execute(args :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks [meta: 1]

  @doc """
  Returns the meta description for a tool invocation.

  Calls `tool_module.meta(args)` if defined, otherwise returns `tool_module.name()`.
  """
  @spec meta(module(), map()) :: String.t()
  def meta(tool_module, args) do
    if function_exported?(tool_module, :meta, 1) do
      tool_module.meta(args)
    else
      tool_module.name()
    end
  end
end
