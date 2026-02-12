# `Opal.Tool`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/tool.ex#L1)

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
        {:ok, "Processed: #{input}"}
      end
    end

# `description`

```elixir
@callback description() :: String.t()
```

Returns a human-readable description of what the tool does.

# `execute`

```elixir
@callback execute(args :: map(), context :: map()) ::
  {:ok, String.t()} | {:error, String.t()}
```

Executes the tool with the given arguments and session context.

# `meta`
*optional* 

```elixir
@callback meta(args :: map()) :: String.t()
```

Returns a short, human-readable summary of a specific tool invocation.

Used by UIs to show what a tool call is doing, e.g. `"Reading lib/opal.ex"`.
Receives the parsed arguments map. Falls back to the tool name if not implemented.

# `name`

```elixir
@callback name() :: String.t()
```

Returns the tool name used in tool call messages.

# `parameters`

```elixir
@callback parameters() :: map()
```

Returns a JSON Schema map describing the tool's accepted parameters.

# `meta`

```elixir
@spec meta(module(), map()) :: String.t()
```

Returns the meta description for a tool invocation.

Calls `tool_module.meta(args)` if defined, otherwise returns `tool_module.name()`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
