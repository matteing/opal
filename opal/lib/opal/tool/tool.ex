defmodule Opal.Tool do
  @moduledoc """
  Behaviour defining the interface for agent tools.

  Any module implementing this behaviour can be registered as a tool
  available to the agent during a session. Tools are invoked by the
  assistant via tool calls and must return their output as a string.

  ## Using the macro

  The simplest way to define a tool is with `use Opal.Tool`:

      defmodule MyApp.SearchTool do
        use Opal.Tool,
          name: "search",
          description: "Search the codebase"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Search query"}
            },
            "required" => ["query"]
          }
        end

        @impl true
        def execute(%{"query" => query}, _context) do
          {:ok, "Results for: \#{query}"}
        end
      end

  The `:name` option is optional — if omitted, it is auto-derived from the
  module name (e.g. `MyApp.SearchTool` → `"search_tool"`).

  ## Implementing the behaviour directly

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

  @typedoc """
  Lightweight context passed to tools during schema generation.

  Lets tools enrich their descriptions with runtime information (e.g. the
  shell tool embeds the current working directory so the LLM stops
  prepending `cd` to every command).

  Distinct from the heavier execution context passed to `execute/2`.
  """
  @type tool_context :: %{
          optional(:working_dir) => String.t(),
          optional(:shell) => atom()
        }

  @doc "Returns the tool name used in tool call messages."
  @callback name() :: String.t()

  @doc "Returns a human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc """
  Returns a context-aware description of the tool.

  Optional callback that receives a `t:tool_context/0` with runtime
  information and can enrich the description accordingly.

  Falls back to `description/0` when not implemented.
  """
  @callback description(context :: tool_context()) :: String.t()

  @doc "Returns a JSON Schema map describing the tool's accepted parameters."
  @callback parameters() :: map()

  @doc """
  Returns a short, human-readable summary of a specific tool invocation.

  Used by UIs to show what a tool call is doing, e.g. `"Reading lib/opal.ex"`.
  Receives the parsed arguments map. Falls back to the tool name if not implemented.
  """
  @callback meta(args :: map()) :: String.t()

  @doc "Executes the tool with the given arguments and session context."
  @callback execute(args :: map(), context :: map()) ::
              {:ok, String.t()} | {:error, String.t()} | {:effect, term()}

  @optional_callbacks [meta: 1, description: 1]

  @doc """
  Returns the tool description, enriched with context when supported.

  Calls `tool_module.description(context)` if the tool implements the
  optional `description/1` callback, otherwise falls back to the
  zero-arity `description/0`.
  """
  @spec description(module(), tool_context()) :: String.t()
  def description(tool_module, context) do
    if function_exported?(tool_module, :description, 1) do
      tool_module.description(context)
    else
      tool_module.description()
    end
  end

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

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Opal.Tool

      @opal_tool_name Keyword.get(opts, :name)
      @opal_tool_description Keyword.get(opts, :description)

      @before_compile Opal.Tool

      @impl true
      def name do
        @opal_tool_name ||
          __MODULE__
          |> Module.split()
          |> List.last()
          |> Macro.underscore()
      end

      @impl true
      def description do
        @opal_tool_description ||
          raise "#{inspect(__MODULE__)}: :description is required when using `use Opal.Tool`"
      end

      defoverridable name: 0, description: 0
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:parameters, 0}) do
      raise CompileError,
        file: env.file,
        line: 0,
        description:
          "#{inspect(env.module)} must implement parameters/0 when using `use Opal.Tool`"
    end

    unless Module.defines?(env.module, {:execute, 2}) do
      raise CompileError,
        file: env.file,
        line: 0,
        description: "#{inspect(env.module)} must implement execute/2 when using `use Opal.Tool`"
    end

    :ok
  end
end
