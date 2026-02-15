defmodule Opal.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Each provider must implement streaming, SSE event parsing, and conversion
  of internal message/tool representations to the provider's wire format.

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
              model :: Opal.Model.t(),
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
  @callback convert_messages(model :: Opal.Model.t(), messages :: [Opal.Message.t()]) :: [map()]

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
          strict: false
        }
      }
    end)
  end
end
