defmodule Opal.Provider.OpenAI do
  @moduledoc """
  Shared utilities for OpenAI Chat Completions API format.

  Provides reusable SSE event parsing, message conversion, and reasoning
  effort mapping for any provider using the OpenAI Chat Completions wire
  format (`/v1/chat/completions`).

  Used by `Opal.Provider.Copilot`'s Chat Completions path. Available for
  any future OpenAI-compatible providers (direct OpenAI, Azure, etc.).
  """

  # ── SSE Parsing ──────────────────────────────────────────────────────

  @doc """
  Parse a Chat Completions SSE JSON object into Opal stream events.

  Handles the standard `choices[0].delta` format including:
  - Text content (`delta.content`)
  - Reasoning content (`delta.reasoning_content`)
  - Tool calls (`delta.tool_calls`)
  - Role start (`delta.role`)
  - Finish reason (`choice.finish_reason`)
  - Usage stats (top-level `usage` object)
  """
  @spec parse_chat_event(map()) :: [Opal.Provider.stream_event()]
  def parse_chat_event(%{"choices" => [%{"delta" => delta} = choice | _]} = event) do
    events = []

    # Text content
    events =
      case delta do
        %{"content" => content} when is_binary(content) and content != "" ->
          events ++ [{:text_delta, content}]

        _ ->
          events
      end

    # Reasoning / thinking content
    events =
      case delta do
        %{"reasoning_content" => rc} when is_binary(rc) and rc != "" ->
          events ++ [{:thinking_delta, rc}]

        _ ->
          events
      end

    # Tool calls
    events =
      case delta do
        %{"tool_calls" => tool_calls} when is_list(tool_calls) ->
          Enum.reduce(tool_calls, events, fn tc, acc ->
            cond do
              tc["id"] ->
                acc ++
                  [
                    {:tool_call_start,
                     %{
                       call_id: tc["id"],
                       name: get_in(tc, ["function", "name"]) || ""
                     }}
                  ]

              get_in(tc, ["function", "arguments"]) ->
                acc ++ [{:tool_call_delta, get_in(tc, ["function", "arguments"])}]

              true ->
                acc
            end
          end)

        _ ->
          events
      end

    # Role start — only on the first chunk (role present, no content yet)
    events =
      case delta do
        %{"role" => "assistant", "content" => c} when c in [nil, ""] ->
          [{:text_start, %{}} | events]

        %{"role" => "assistant"} when not is_map_key(delta, "content") ->
          [{:text_start, %{}} | events]

        _ ->
          events
      end

    # Finish reason → finalize tool calls or mark done
    events =
      case choice do
        %{"finish_reason" => "tool_calls"} ->
          events ++ [{:response_done, %{usage: %{}, stop_reason: :tool_calls}}]

        %{"finish_reason" => reason} when is_binary(reason) ->
          events ++ [{:response_done, %{usage: %{}, stop_reason: :stop}}]

        _ ->
          events
      end

    # Usage stats (comes in a separate chunk with empty choices)
    events =
      case event do
        %{"usage" => usage} when is_map(usage) and usage != %{} ->
          events ++ [{:usage, usage}]

        _ ->
          events
      end

    events
  end

  # Usage-only chunk (choices is empty list)
  def parse_chat_event(%{"choices" => [], "usage" => usage})
      when is_map(usage) and usage != %{} do
    [{:usage, usage}]
  end

  def parse_chat_event(%{"choices" => []}), do: []

  def parse_chat_event(_), do: []

  # ── Message Conversion ───────────────────────────────────────────────

  @doc """
  Convert Opal messages to OpenAI Chat Completions format.

  ## Options

    * `:include_thinking` — include `reasoning_content` field on assistant
      messages that have thinking content (default: `true`)

  """
  @spec convert_messages([Opal.Message.t()], keyword()) :: [map()]
  def convert_messages(messages, opts \\ []) do
    include_thinking = Keyword.get(opts, :include_thinking, true)
    Enum.flat_map(messages, fn msg -> convert_msg(msg, include_thinking) end)
  end

  defp convert_msg(%Opal.Message{role: :system, content: content}, _include_thinking) do
    [%{role: "system", content: content}]
  end

  defp convert_msg(%Opal.Message{role: :user, content: content}, _include_thinking) do
    [%{role: "user", content: content}]
  end

  defp convert_msg(
         %Opal.Message{
           role: :assistant,
           content: content,
           thinking: thinking,
           tool_calls: tool_calls
         },
         include_thinking
       )
       when is_list(tool_calls) and tool_calls != [] do
    calls =
      Enum.map(tool_calls, fn tc ->
        %{
          id: tc.call_id,
          type: "function",
          function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}
        }
      end)

    msg = %{role: "assistant", content: content || "", tool_calls: calls}
    [maybe_add_thinking(msg, thinking, include_thinking)]
  end

  defp convert_msg(
         %Opal.Message{role: :assistant, content: content, thinking: thinking},
         include_thinking
       ) do
    msg = %{role: "assistant", content: content || ""}
    [maybe_add_thinking(msg, thinking, include_thinking)]
  end

  defp convert_msg(
         %Opal.Message{role: :tool_result, call_id: call_id, content: content},
         _include_thinking
       ) do
    [%{role: "tool", tool_call_id: call_id, content: content || ""}]
  end

  defp convert_msg(_msg, _include_thinking), do: []

  defp maybe_add_thinking(msg, thinking, true) when is_binary(thinking) and thinking != "" do
    Map.put(msg, :reasoning_content, thinking)
  end

  defp maybe_add_thinking(msg, _thinking, _include_thinking), do: msg

  # ── Reasoning Effort ─────────────────────────────────────────────────

  @doc """
  Map Opal thinking level to OpenAI `reasoning_effort` string.

  Returns `nil` for `:off`. Clamps `:max` to `"high"` since OpenAI
  models don't support a "max" effort level.
  """
  @spec reasoning_effort(Opal.Model.thinking_level()) :: String.t() | nil
  def reasoning_effort(:off), do: nil
  def reasoning_effort(:max), do: "high"
  def reasoning_effort(level), do: to_string(level)
end
