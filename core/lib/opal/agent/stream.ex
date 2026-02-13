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
    state
  end

  def handle_stream_event({:thinking_delta, delta}, state) do
    broadcast(state, {:thinking_delta, %{delta: delta}})
    state
  end

  def handle_stream_event({:tool_call_start, info}, state) do
    # Start a new tool call accumulator
    tool_call = %{
      call_id: info[:call_id],
      name: info[:name],
      arguments_json: ""
    }

    %{state | current_tool_calls: state.current_tool_calls ++ [tool_call]}
  end

  def handle_stream_event({:tool_call_delta, delta}, state) do
    # Append to the last tool call's arguments JSON
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _} ->
          state.current_tool_calls

        {last_tc, rest} ->
          rest ++ [%{last_tc | arguments_json: last_tc.arguments_json <> delta}]
      end

    %{state | current_tool_calls: updated}
  end

  def handle_stream_event({:tool_call_done, info}, state) do
    # Finalize the tool call with parsed arguments
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _} ->
          # No in-progress tool call — create one from the done event
          [
            %{
              call_id: info[:call_id],
              name: info[:name],
              arguments: info[:arguments] || %{}
            }
          ]

        {last_tc, rest} ->
          # Merge final info into the accumulated tool call
          arguments =
            info[:arguments] ||
              case Jason.decode(last_tc[:arguments_json] || "{}") do
                {:ok, parsed} -> parsed
                {:error, _} -> %{}
              end

          finalized = %{
            call_id: info[:call_id] || last_tc[:call_id],
            name: info[:name] || last_tc[:name],
            arguments: arguments
          }

          rest ++ [finalized]
      end

    %{state | current_tool_calls: updated}
  end

  def handle_stream_event({:usage, usage}, state) do
    Opal.Agent.UsageTracker.update_usage(usage, state)
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

  defp broadcast(%State{session_id: session_id}, event) do
    Opal.Events.broadcast(session_id, event)
  end
end
