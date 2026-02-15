defmodule Opal.Agent.Stream do
  @moduledoc """
  SSE stream parsing and event dispatch for the Agent loop.

  Handles parsing raw server-sent events from LLM providers and dispatches
  the parsed events to update agent state. This includes text deltas, tool
  calls, thinking streams, usage reports, and error handling.
  """

  require Logger
  alias Opal.Agent.State

  @doc """
  Parses raw SSE data, dispatching events for each line.

  Takes binary SSE data from the provider response and processes it line by line.
  Each valid data line is parsed and events are dispatched to update state.

  Returns updated state after processing all events in the data.
  """
  @spec parse_sse_data(binary(), State.t()) :: State.t()
  def parse_sse_data(data, state) do
    binary = IO.iodata_to_binary(data)

    Logger.debug(
      "SSE raw data (#{byte_size(binary)} bytes): #{inspect(String.slice(binary, 0, 300))}"
    )

    binary
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, fn line, acc ->
      case line do
        "data: [DONE]" ->
          acc

        "data: " <> json_data ->
          dispatch_sse_events(json_data, acc)

        # Handle raw JSON error responses (no SSE prefix)
        "{" <> _ = json_data ->
          dispatch_sse_events(json_data, acc)

        _ ->
          acc
      end
    end)
  end

  @doc """
  Decodes a single SSE JSON line and dispatches all parsed events.

  Parses the JSON data using the provider's stream event parser and applies
  each parsed event to the state via handle_stream_event/2.

  Returns updated state after processing all events from this JSON line.
  """
  @spec dispatch_sse_events(String.t(), State.t()) :: State.t()
  def dispatch_sse_events(json_data, state) do
    events = state.provider.parse_stream_event(json_data)
    Logger.debug("Parsed SSE events: #{inspect(events, limit: 5, printable_limit: 200)}")

    Enum.reduce(events, state, fn event, acc ->
      handle_stream_event(event, acc)
    end)
  end

  @doc """
  Handles a single parsed stream event, updating state accordingly.

  Processes various event types from LLM provider streams:
  - Text events (:text_start, :text_delta, :text_done)
  - Thinking events (:thinking_start, :thinking_delta, :thinking_done)
  - Tool call events (:tool_call_start, :tool_call_delta, :tool_call_done)
  - Usage reports (:usage)
  - Response completion (:response_done)
  - Errors (:error)

  Returns updated state.
  """
  @spec handle_stream_event({atom(), term()}, State.t()) :: State.t()
  def handle_stream_event({:text_start, _info}, state) do
    broadcast(state, {:message_start})
    state
  end

  def handle_stream_event({:text_delta, delta}, state) do
    {clean_delta, state} = extract_status_tags(delta, state)

    unless clean_delta == "" do
      broadcast(state, {:message_delta, %{delta: clean_delta}})
    end

    %{state | current_text: state.current_text <> clean_delta}
  end

  def handle_stream_event({:text_done, text}, state) do
    %{state | current_text: text}
  end

  def handle_stream_event({:thinking_start, _info}, state) do
    broadcast(state, {:thinking_start})
    %{state | current_thinking: ""}
  end

  def handle_stream_event({:thinking_delta, delta}, state) do
    # Auto-emit thinking_start if the provider didn't (e.g. Chat Completions)
    state =
      if is_nil(state.current_thinking) do
        broadcast(state, {:thinking_start})
        %{state | current_thinking: ""}
      else
        state
      end

    broadcast(state, {:thinking_delta, %{delta: delta}})
    %{state | current_thinking: state.current_thinking <> delta}
  end

  def handle_stream_event({:tool_call_start, info}, state) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: tool_call_index(info),
      name: info[:name],
      arguments_json: ""
    }

    %{state | current_tool_calls: upsert_tool_call(state.current_tool_calls, tool_call)}
  end

  # Backward-compatible delta payload (legacy providers emit just a string).
  def handle_stream_event({:tool_call_delta, delta}, state) when is_binary(delta) do
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _} ->
          state.current_tool_calls

        {last_tc, rest} ->
          rest ++ [%{last_tc | arguments_json: last_tc.arguments_json <> delta}]
      end

    %{state | current_tool_calls: updated}
  end

  # Identifier-aware delta payload for interleaved multi-tool streams.
  def handle_stream_event({:tool_call_delta, %{delta: delta} = info}, state)
      when is_binary(delta) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: tool_call_index(info),
      name: info[:name],
      arguments_json: delta
    }

    %{state | current_tool_calls: append_tool_call_delta(state.current_tool_calls, tool_call)}
  end

  def handle_stream_event({:tool_call_delta, _}, state), do: state

  def handle_stream_event({:tool_call_done, info}, state) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: tool_call_index(info),
      name: info[:name],
      arguments: info[:arguments]
    }

    %{state | current_tool_calls: finalize_tool_call(state.current_tool_calls, tool_call)}
  end

  def handle_stream_event({:usage, usage}, state) do
    Opal.Agent.Compaction.update_usage(usage, state)
  end

  def handle_stream_event({:response_done, info}, state) do
    # Responses API includes usage inline; Chat Completions sends it separately via {:usage, ...}
    case Map.get(info, :usage, %{}) do
      usage when usage != %{} -> handle_stream_event({:usage, usage}, state)
      _ -> state
    end
  end

  def handle_stream_event({:error, reason}, state) do
    Logger.error("Stream error: #{inspect(reason)}")
    broadcast(state, {:error, reason})
    %{state | status: :idle, streaming_resp: nil}
  end

  def handle_stream_event(_unknown, state), do: state

  @doc """
  Extracts <status>...</status> tags from streaming text deltas.

  Tags may span multiple deltas, so we buffer partial matches.
  Returns {clean_text, updated_state} with tags stripped and broadcast.
  """
  @spec extract_status_tags(String.t(), State.t()) :: {String.t(), State.t()}
  def extract_status_tags(delta, %State{status_tag_buffer: buf} = state) do
    text = buf <> delta

    case Regex.run(~r/<status>(.*?)<\/status>/s, text) do
      [full_match, status_text] ->
        broadcast(state, {:status_update, String.trim(status_text)})
        clean = String.replace(text, full_match, "", global: false)
        # Recurse in case there are multiple tags in one chunk
        {more_clean, state} = extract_status_tags("", %{state | status_tag_buffer: ""})
        {clean <> more_clean, state}

      nil ->
        # Check if we might be in the middle of a tag
        cond do
          String.contains?(text, "<status>") and not String.contains?(text, "</status>") ->
            # Partial open tag — buffer everything from <status> onward
            [before | _] = String.split(text, "<status>", parts: 2)
            rest = String.slice(text, String.length(before)..-1//1)
            {before, %{state | status_tag_buffer: rest}}

          String.ends_with?(text, "<") or
            String.ends_with?(text, "<s") or
            String.ends_with?(text, "<st") or
            String.ends_with?(text, "<sta") or
            String.ends_with?(text, "<stat") or
            String.ends_with?(text, "<statu") or
              String.ends_with?(text, "<status") ->
            # Might be start of a tag — buffer the trailing potential match
            idx = String.length(text) - partial_tag_length(text)

            {String.slice(text, 0, idx),
             %{state | status_tag_buffer: String.slice(text, idx..-1//1)}}

          true ->
            {text, %{state | status_tag_buffer: ""}}
        end
    end
  end

  @doc """
  Computes the length of a partial status tag suffix.
  """
  @spec partial_tag_length(String.t()) :: non_neg_integer()
  def partial_tag_length(text) do
    suffixes = ["<status", "<statu", "<stat", "<sta", "<st", "<s", "<"]

    Enum.find_value(suffixes, 0, fn s ->
      if String.ends_with?(text, s), do: String.length(s)
    end)
  end

  # Helper functions

  defp upsert_tool_call(tool_calls, tool_call) do
    case find_tool_call_index(tool_calls, tool_call) do
      nil ->
        tool_calls ++ [tool_call]

      idx ->
        List.update_at(tool_calls, idx, &merge_tool_call_metadata(&1, tool_call))
    end
  end

  defp append_tool_call_delta(tool_calls, tool_call) do
    idx = find_tool_call_index(tool_calls, tool_call) || find_fallback_tool_call_index(tool_calls)

    case idx do
      nil ->
        tool_calls ++ [tool_call]

      idx ->
        List.update_at(tool_calls, idx, fn existing ->
          existing
          |> merge_tool_call_metadata(tool_call)
          |> Map.put(
            :arguments_json,
            (existing[:arguments_json] || "") <> (tool_call[:arguments_json] || "")
          )
        end)
    end
  end

  defp finalize_tool_call(tool_calls, tool_call) do
    idx = find_tool_call_index(tool_calls, tool_call) || find_fallback_tool_call_index(tool_calls)

    case idx do
      nil ->
        tool_calls ++
          [
            Map.put(
              tool_call,
              :arguments,
              tool_call[:arguments] || decode_tool_arguments(tool_call[:arguments_json])
            )
          ]

      idx ->
        List.update_at(tool_calls, idx, fn existing ->
          existing
          |> merge_tool_call_metadata(tool_call)
          |> Map.put(
            :arguments,
            tool_call[:arguments] || decode_tool_arguments(existing[:arguments_json])
          )
        end)
    end
  end

  defp find_tool_call_index(tool_calls, tool_call) do
    call_id = normalize_tool_id(tool_call[:call_id])
    item_id = normalize_tool_id(tool_call[:item_id])
    call_index = tool_call[:call_index]

    cond do
      call_id != nil ->
        find_last_index(tool_calls, &(normalize_tool_id(&1[:call_id]) == call_id))

      item_id != nil ->
        find_last_index(tool_calls, &(normalize_tool_id(&1[:item_id]) == item_id))

      is_integer(call_index) ->
        find_last_index(tool_calls, &(&1[:call_index] == call_index))

      true ->
        nil
    end
  end

  defp find_fallback_tool_call_index(tool_calls) do
    find_last_index(tool_calls, &is_nil(&1[:arguments]))
  end

  defp find_last_index(list, predicate) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {item, idx}, acc ->
      if predicate.(item), do: idx, else: acc
    end)
  end

  defp merge_tool_call_metadata(existing, incoming) do
    existing
    |> maybe_put_metadata(:call_id, incoming[:call_id])
    |> maybe_put_metadata(:item_id, incoming[:item_id])
    |> maybe_put_metadata(:call_index, incoming[:call_index])
    |> maybe_put_metadata(:name, incoming[:name])
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp normalize_tool_id(id) when is_binary(id) and id != "", do: id
  defp normalize_tool_id(_), do: nil

  defp tool_call_index(info) do
    case info[:call_index] || info[:output_index] do
      idx when is_integer(idx) -> idx
      _ -> nil
    end
  end

  defp decode_tool_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp decode_tool_arguments(_), do: %{}

  defp broadcast(%State{} = state, event), do: Opal.Agent.EventLog.broadcast(state, event)
end
