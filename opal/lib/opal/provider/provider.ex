defmodule Opal.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Each provider must implement streaming, SSE event parsing, and conversion
  of internal message/tool representations to the provider's wire format.

  ## Using the macro

  The simplest way to define a provider is with `use Opal.Provider`:

      defmodule MyProvider.Anthropic do
        use Opal.Provider,
          name: :anthropic,
          models: ["claude-sonnet-4", "claude-opus-4"]

        @impl true
        def stream(model, messages, tools, opts) do
          # Provider-specific streaming implementation
        end

        @impl true
        def parse_stream_event(data) do
          # Parse SSE data into stream events
        end

        @impl true
        def convert_messages(model, messages) do
          # Convert to provider wire format
        end
      end

  The macro injects `@behaviour Opal.Provider` and provides a default
  `convert_tools/1` that delegates to the shared OpenAI format. Override
  it for provider-specific tool formats.

  ## Built-in Providers

    * `Opal.Provider.Copilot` — GitHub Copilot via its proprietary API
    * `Opal.Provider.LLM` — Any provider supported by ReqLLM (Anthropic,
      OpenAI, Google, Groq, OpenRouter, xAI, AWS Bedrock, and more)

  The provider is auto-selected based on the model's provider atom:
  `:copilot` → `Opal.Provider.Copilot`, anything else → `Opal.Provider.LLM`.
  """

  @type stream_event ::
          {:text_start, map()}
          | {:text_delta, String.t()}
          | {:text_done, String.t()}
          | {:thinking_start, map()}
          | {:thinking_delta, String.t()}
          | {:tool_call_start, map()}
          | {:tool_call_delta, String.t() | map()}
          | {:tool_call_done, map()}
          | {:response_done, map()}
          | {:usage, map()}
          | {:error, term()}

  @doc """
  Initiates a streaming request to the LLM provider.

  Returns either:

    * `{:ok, %Req.Response{}}` — raw SSE stream; the agent uses
      `Req.parse_message/2` and `parse_stream_event/1` to decode chunks.
    * `{:ok, %Opal.Provider.EventStream{}}` — pre-parsed event stream;
      the provider sends `{ref, {:events, [stream_event()]}}` messages
      directly, bypassing SSE parsing.
  """
  @callback stream(
              model :: Opal.Provider.Model.t(),
              messages :: [Opal.Message.t()],
              tools :: [module()],
              opts :: keyword()
            ) :: {:ok, Req.Response.t() | Opal.Provider.EventStream.t()} | {:error, term()}

  @doc """
  Parses a raw SSE data line into a list of stream events.

  Returns an empty list for events that should be ignored.
  """
  @callback parse_stream_event(data :: String.t()) :: [stream_event()]

  @doc """
  Converts internal `Opal.Message` structs to the provider's wire format.
  """
  @callback convert_messages(model :: Opal.Provider.Model.t(), messages :: [Opal.Message.t()]) ::
              [map()]

  @doc """
  Converts tool modules implementing `Opal.Tool` to the provider's wire format.
  """
  @callback convert_tools(tools :: [module()]) :: [map()]

  @doc """
  Converts tool modules to the OpenAI function-calling format.

  This is the shared default implementation used by all built-in providers.
  """
  @spec convert_tools(tools :: [module()]) :: [map()]
  def convert_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name(),
          description: tool.description(),
          parameters: tool.parameters(),
          # Strict mode requires all properties to be required and no
          # additionalProperties — our tool schemas don't guarantee that.
          strict: false
        }
      }
    end)
  end

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Opal.Provider

      @opal_provider_name Keyword.get(opts, :name)
      @opal_provider_models Keyword.get(opts, :models, [])

      @doc false
      def __opal_provider_name__, do: @opal_provider_name

      @doc false
      def __opal_provider_models__, do: @opal_provider_models

      @impl true
      def convert_tools(tools), do: Opal.Provider.convert_tools(tools)

      defoverridable convert_tools: 1
    end
  end
end
