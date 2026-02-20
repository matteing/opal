defmodule Opal.Agent.Stream do
  @moduledoc """
  SSE stream parsing and event dispatch for the Agent loop.

  This module sits between the raw HTTP/SSE transport and the agent state
  machine.  It has three layers:

  1. **SSE parsing** — `parse_sse_data/2` splits a raw binary chunk into
     individual `data:` lines (the SSE wire format).
  2. **Event dispatch** — `dispatch_sse_events/2` hands each JSON line to
     the current provider's `parse_stream_event/1` callback, which returns
     a list of normalised `{event_type, payload}` tuples.
  3. **State updates** — `handle_stream_event/2` pattern-matches every
     event type and folds it into `%State{}`.

  ## Inline XML tag extraction

  LLM responses may contain inline XML tags such as `<status>…</status>`
  and `<title>…</title>` that should be stripped from user-visible text
  and dispatched as separate events.  Because tags can be split across
  multiple streaming deltas, we buffer partial matches in
  `state.tag_buffers` (a `%{atom() => String.t()}` map keyed by tag name).

  The generic `extract_xml_tag/4` function handles any tag name; the
  public wrappers `extract_status_tags/2` and `extract_title_tag/2`
  supply the tag-specific side-effects (broadcasting, session persistence).

  ## Event types handled

  | Event                | Effect                                          |
  |----------------------|-------------------------------------------------|
  | `:text_start`        | Broadcasts `{:message_start}`                   |
  | `:text_delta`        | Strips XML tags, appends to `current_text`       |
  | `:text_done`         | Finalises `current_text`                         |
  | `:thinking_start`    | Broadcasts `{:thinking_start}`                   |
  | `:thinking_delta`    | Appends to `current_thinking`                    |
  | `:tool_call_start`   | Inserts/upserts tool call in `current_tool_calls`|
  | `:tool_call_delta`   | Appends JSON fragment to matching tool call       |
  | `:tool_call_done`    | Finalises arguments on matching tool call          |
  | `:usage`             | Delegates to `UsageTracker.update_usage/2`        |
  | `:response_done`     | Extracts inline usage if present                  |
  | `:error`             | Sets `stream_errored`, resets to `:idle`           |
  """

  require Logger
  alias Opal.Agent.{Emitter, State}

  # ── SSE Parsing ──────────────────────────────────────────────────────

  @doc """
  Parses raw SSE data and folds every event into `state`.

  A single `data` chunk from the HTTP transport may contain multiple
  newline-separated SSE lines.  Each line is classified as:

  - `"data: [DONE]"` — end-of-stream sentinel, ignored
  - `"data: <json>"` — standard SSE data line
  - `"{…"` — raw JSON (some error responses omit the SSE prefix)
  - anything else — SSE comments / event-type lines, ignored

  ## Example

      iex> raw = "data: {\\"type\\":\\"text_delta\\",\\"delta\\":\\"hi\\"}\\ndata: [DONE]\\n"
      iex> state = Stream.parse_sse_data(raw, state)
      %State{current_text: "hi", …}

  """
  @spec parse_sse_data(binary(), State.t()) :: State.t()
  def parse_sse_data(data, state) do
    binary = IO.iodata_to_binary(data)

    Logger.debug(
      "SSE raw data (#{byte_size(binary)} bytes): #{inspect(String.slice(binary, 0, 300))}"
    )

    binary
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, fn
      "data: [DONE]", acc ->
        acc

      "data: " <> json, acc ->
        dispatch_sse_events(json, acc)

      # Raw JSON without SSE prefix (e.g. error responses from the gateway).
      "{" <> _ = json, acc ->
        dispatch_sse_events(json, acc)

      _comment_or_event_line, acc ->
        acc
    end)
  end

  @doc """
  Decodes a single JSON line into provider events and folds them into state.

  The provider's `parse_stream_event/1` callback returns a list of
  `{event_type, payload}` tuples; each is applied via `handle_stream_event/2`.

  ## Example

      iex> json = ~s({"type":"response.output_text.delta","delta":"ok"})
      iex> state = Stream.dispatch_sse_events(json, state)
      %State{current_text: "ok", …}

  """
  @spec dispatch_sse_events(String.t(), State.t()) :: State.t()
  def dispatch_sse_events(json_data, state) do
    events = state.provider.parse_stream_event(json_data)
    Logger.debug("Parsed SSE events: #{inspect(events, limit: 5, printable_limit: 200)}")

    Enum.reduce(events, state, &handle_stream_event/2)
  end

  # ── Stream Event Handlers ───────────────────────────────────────────

  @doc """
  Handles a single parsed stream event, updating state accordingly.

  Each clause matches one event type from the provider's normalised stream.
  Unknown events are silently ignored (forward-compatibility).

  ## Examples

      # Text delta accumulates into current_text
      iex> Stream.handle_stream_event({:text_delta, "hello"}, state)
      %State{current_text: "hello", …}

      # Errors mark the stream as failed
      iex> Stream.handle_stream_event({:error, "rate_limited"}, state)
      %State{stream_errored: true, status: :idle, …}

  """
  @spec handle_stream_event({atom(), term()}, State.t()) :: State.t()

  # ── Text ──

  def handle_stream_event({:text_start, _info}, %{message_started: true} = state), do: state

  def handle_stream_event({:text_start, _info}, state) do
    Emitter.broadcast(state, {:message_start})
    %{state | message_started: true}
  end

  def handle_stream_event({:text_delta, delta}, state) do
    # Strip inline XML tags (<status>, <title>) from the visible text stream.
    # Each extractor may buffer partial tags across chunks in state.tag_buffers.
    {clean, state} = extract_status_tags(delta, state)
    {clean, state} = extract_title_tag(clean, state)

    if clean != "", do: Emitter.broadcast(state, {:message_delta, %{delta: clean}})

    %{state | current_text: state.current_text <> clean}
  end

  def handle_stream_event({:text_done, text}, state) do
    %{state | current_text: text}
  end

  # ── Thinking / Chain-of-Thought ──

  def handle_stream_event({:thinking_start, _info}, state) do
    Emitter.broadcast(state, {:thinking_start})
    %{state | current_thinking: ""}
  end

  def handle_stream_event({:thinking_delta, delta}, state) do
    # Some providers (e.g. Chat Completions) send thinking deltas without
    # a preceding :thinking_start.  Auto-emit start so the UI is consistent.
    state =
      if is_nil(state.current_thinking) do
        Emitter.broadcast(state, {:thinking_start})
        %{state | current_thinking: ""}
      else
        state
      end

    Emitter.broadcast(state, {:thinking_delta, %{delta: delta}})
    %{state | current_thinking: state.current_thinking <> delta}
  end

  # ── Tool Calls ──
  #
  # Tool calls arrive in three phases:
  #   1. :tool_call_start  — creates the slot with name & ids
  #   2. :tool_call_delta  — appends JSON argument fragments
  #   3. :tool_call_done   — finalises with parsed arguments
  #
  # Multiple tool calls can be in-flight simultaneously (e.g. parallel
  # function calls in Chat Completions).  We match them by call_id,
  # item_id, or call_index — whichever the provider supplies.

  def handle_stream_event({:tool_call_start, info}, state) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: resolve_call_index(info),
      name: info[:name],
      arguments_json: ""
    }

    %{state | current_tool_calls: upsert_tool_call(state.current_tool_calls, tool_call)}
  end

  # Legacy string delta — older providers emit a bare string instead of a map.
  # We append it to the *last* tool call since there's no identifier to match on.
  def handle_stream_event({:tool_call_delta, delta}, state) when is_binary(delta) do
    updated =
      case List.pop_at(state.current_tool_calls, -1) do
        {nil, _list} ->
          # No tool call in progress — silently drop the orphaned delta.
          state.current_tool_calls

        {last, rest} ->
          rest ++ [%{last | arguments_json: last.arguments_json <> delta}]
      end

    %{state | current_tool_calls: updated}
  end

  # Identifier-aware delta — modern providers emit `%{delta: "…", call_id: …}`.
  # This supports interleaved multi-tool streams where deltas for different
  # tool calls arrive mixed together.
  def handle_stream_event({:tool_call_delta, %{delta: delta} = info}, state)
      when is_binary(delta) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: resolve_call_index(info),
      name: info[:name],
      arguments_json: delta
    }

    %{state | current_tool_calls: append_tool_call_delta(state.current_tool_calls, tool_call)}
  end

  # Catch-all for unrecognised delta payloads (e.g. integer, nil).
  def handle_stream_event({:tool_call_delta, _unrecognised}, state), do: state

  def handle_stream_event({:tool_call_done, info}, state) do
    tool_call = %{
      call_id: info[:call_id],
      item_id: info[:item_id],
      call_index: resolve_call_index(info),
      name: info[:name],
      arguments: info[:arguments]
    }

    %{state | current_tool_calls: finalize_tool_call(state.current_tool_calls, tool_call)}
  end

  # ── Usage & Completion ──

  def handle_stream_event({:usage, usage}, state) do
    Opal.Agent.UsageTracker.update_usage(usage, state)
  end

  def handle_stream_event({:response_done, info}, state) do
    # The Responses API bundles usage inside response.completed;
    # Chat Completions sends a separate {:usage, …} event instead.
    case Map.get(info, :usage, %{}) do
      usage when usage != %{} -> handle_stream_event({:usage, usage}, state)
      _empty -> state
    end
  end

  # ── Errors ──

  def handle_stream_event({:error, reason}, state) do
    Logger.error("Stream error: #{inspect(reason)}")
    Emitter.broadcast(state, {:error, reason})
    %{state | status: :idle, streaming_resp: nil, stream_errored: reason}
  end

  # Forward-compatibility: ignore unknown event types from newer provider versions.
  def handle_stream_event(_unknown, state), do: state

  # ── XML Tag Extraction ──────────────────────────────────────────────
  #
  # LLM responses embed inline XML tags (e.g. <status>, <title>) that
  # should be stripped from visible text and routed as separate events.
  #
  # Because SSE deltas can split a tag across chunks, we maintain a
  # per-tag buffer in `state.tag_buffers[tag_name]`.  The generic
  # `extract_xml_tag/4` handles the buffering logic; thin wrappers
  # supply the tag-specific side-effects.

  @doc """
  Generic XML tag extractor for streaming deltas.

  Strips `<tag_name>…</tag_name>` from `delta`, calling `on_match`
  when a complete tag is found.  Partial tags are buffered in
  `state.tag_buffers[tag_name]` for the next chunk.

  ## Parameters

  - `delta`    — the new text chunk to process
  - `tag_name` — atom identifying the tag (e.g. `:status`, `:title`)
  - `state`    — current agent state (tag buffers live here)
  - `on_match` — `fn inner_text, state -> state` called with the tag body

  ## Returns

  `{clean_text, updated_state}` — text with the tag stripped out.

  ## Examples

      # Complete tag in a single chunk:
      iex> cb = fn text, st -> IO.puts(text); st end
      iex> {clean, _st} = Stream.extract_xml_tag("<foo>bar</foo>rest", :foo, state, cb)
      # prints "bar"
      {clean, _st}
      #=> {"rest", %State{…}}

      # Tag split across two chunks:
      iex> {text1, st} = Stream.extract_xml_tag("Hello<foo>par", :foo, state, cb)
      #=> {"Hello", %State{tag_buffers: %{foo: "<foo>par"}}}
      iex> {text2, st} = Stream.extract_xml_tag("tial</foo>end", :foo, st, cb)
      # prints "partial"
      #=> {"end", %State{tag_buffers: %{foo: ""}}}

  """
  @spec extract_xml_tag(String.t(), atom(), State.t(), (String.t(), State.t() -> State.t())) ::
          {String.t(), State.t()}
  def extract_xml_tag(delta, tag_name, state, on_match) do
    buf = state.tag_buffers[tag_name] || ""
    text = buf <> delta
    open_tag = "<#{tag_name}>"
    close_tag = "</#{tag_name}>"
    tag_regex = ~r/<#{tag_name}>(.*?)<\/#{tag_name}>/s

    case Regex.run(tag_regex, text) do
      [full_match, inner_text] ->
        # Complete tag found — invoke callback, strip from output, and
        # recurse in case the same chunk contains multiple tags.
        state = on_match.(String.trim(inner_text), state)
        clean = String.replace(text, full_match, "", global: false)

        {more_clean, state} =
          extract_xml_tag("", tag_name, clear_tag_buffer(state, tag_name), on_match)

        {clean <> more_clean, state}

      nil ->
        cond do
          # The opening tag is present but the closing tag hasn't arrived yet.
          # Buffer everything from the opening tag onward for the next chunk.
          String.contains?(text, open_tag) and not String.contains?(text, close_tag) ->
            [before | _] = String.split(text, open_tag, parts: 2)
            rest = String.slice(text, String.length(before)..-1//1)
            {before, put_tag_buffer(state, tag_name, rest)}

          # We might be in the middle of typing the opening tag (e.g. "<sta"
          # could become "<status>").  Buffer the partial suffix so the next
          # chunk can complete it.
          (len = partial_tag_suffix_length(text, open_tag)) > 0 ->
            split_at = String.length(text) - len

            {String.slice(text, 0, split_at),
             put_tag_buffer(state, tag_name, String.slice(text, split_at..-1//1))}

          # No tag activity — flush any stale buffer.
          true ->
            {text, clear_tag_buffer(state, tag_name)}
        end
    end
  end

  @doc """
  Extracts `<status>…</status>` tags from a streaming text delta.

  When a complete status tag is found, broadcasts `{:status_update, text}`
  so the UI can display a progress indicator.

  Tags may span multiple deltas — partial matches are buffered in
  `state.tag_buffers[:status]`.

  ## Examples

      iex> {clean, _st} = Stream.extract_status_tags("<status>Reading files...</status>ok", state)
      # broadcasts {:status_update, "Reading files..."}
      #=> {"ok", %State{…}}

      # Partial tag buffered for next chunk:
      iex> {clean, st} = Stream.extract_status_tags("Hello<stat", state)
      #=> {"Hello", %State{tag_buffers: %{status: "<stat"}}}

  """
  @spec extract_status_tags(String.t(), State.t()) :: {String.t(), State.t()}
  def extract_status_tags(delta, state) do
    extract_xml_tag(delta, :status, state, fn text, st ->
      Emitter.broadcast(st, {:status_update, text})
      st
    end)
  end

  @doc """
  Extracts `<title>…</title>` tags from a streaming text delta.

  When a complete title tag is found, broadcasts `{:title_generated, title}`
  and persists the title to the session (if one is attached).  The title is
  trimmed and capped at 60 characters.

  ## Examples

      iex> {clean, _st} = Stream.extract_title_tag("<title>Fix auth bug</title>rest", state)
      # broadcasts {:title_generated, "Fix auth bug"}
      #=> {"rest", %State{…}}

  """
  @spec extract_title_tag(String.t(), State.t()) :: {String.t(), State.t()}
  def extract_title_tag(delta, state) do
    extract_xml_tag(delta, :title, state, fn text, st ->
      title = String.slice(text, 0, 60)

      if title != "" do
        Emitter.broadcast(st, {:title_generated, title})

        if st.session do
          Opal.Session.set_metadata(st.session, :title, title)
        end
      end

      st
    end)
  end

  @doc """
  Returns the length of a partial `<status` tag suffix at the end of `text`.

  Used to detect when a streaming chunk ends mid-tag-name so we can buffer
  the ambiguous suffix for the next chunk.

  ## Examples

      iex> Stream.partial_tag_length("some text<st")
      3

      iex> Stream.partial_tag_length("no tag here")
      0

  """
  @spec partial_tag_length(String.t()) :: non_neg_integer()
  def partial_tag_length(text) do
    partial_tag_suffix_length(text, "<status>")
  end

  @doc """
  Returns the length of a partial `<title` tag suffix at the end of `text`.

  ## Examples

      iex> Stream.partial_title_tag_length("text<ti")
      3

      iex> Stream.partial_title_tag_length("hello")
      0

  """
  @spec partial_title_tag_length(String.t()) :: non_neg_integer()
  def partial_title_tag_length(text) do
    partial_tag_suffix_length(text, "<title>")
  end

  # ── Tag Buffer Helpers ──────────────────────────────────────────────

  # Checks if `text` ends with a prefix of `open_tag` (e.g. "<", "<s",
  # "<st", … for "<status>").  Returns the length of the matching suffix,
  # or 0 if none matches.
  #
  # ## Example
  #
  #     partial_tag_suffix_length("hello<st", "<status>")
  #     #=> 3  (matches "<st")
  #
  @spec partial_tag_suffix_length(String.t(), String.t()) :: non_neg_integer()
  defp partial_tag_suffix_length(text, open_tag) do
    # Build candidate suffixes from longest to shortest:
    #   "<status" -> "<statu" -> "<stat" -> … -> "<"
    tag_without_close = String.trim_trailing(open_tag, ">")
    len = String.length(tag_without_close)

    # Check longest suffix first so we return the maximal match.
    Enum.find_value(len..1//-1, 0, fn n ->
      suffix = String.slice(tag_without_close, 0, n)
      if String.ends_with?(text, suffix), do: n
    end)
  end

  defp put_tag_buffer(state, tag_name, value) do
    %{state | tag_buffers: Map.put(state.tag_buffers, tag_name, value)}
  end

  defp clear_tag_buffer(state, tag_name) do
    %{state | tag_buffers: Map.put(state.tag_buffers, tag_name, "")}
  end

  # ── Tool Call Helpers ───────────────────────────────────────────────
  #
  # Tool calls are assembled incrementally from start/delta/done events.
  # Each tool call is a map with:
  #   - :call_id        — provider-assigned call identifier (string)
  #   - :item_id        — response item identifier (Responses API)
  #   - :call_index     — integer index for multi-call ordering
  #   - :name           — tool function name
  #   - :arguments_json — raw JSON string being assembled from deltas
  #   - :arguments      — parsed map (only set after :tool_call_done)
  #
  # The matching strategy tries call_id first, then item_id, then
  # call_index.  If nothing matches, a fallback finds the last tool
  # call without finalised arguments (for legacy single-call providers).

  # Inserts a new tool call or merges metadata into an existing one
  # (matched by identifier).
  defp upsert_tool_call(tool_calls, tool_call) do
    case find_tool_call_index(tool_calls, tool_call) do
      nil -> tool_calls ++ [tool_call]
      idx -> List.update_at(tool_calls, idx, &merge_tool_call_metadata(&1, tool_call))
    end
  end

  # Appends an argument JSON fragment to the matching tool call, or
  # creates a new slot if no match is found.
  defp append_tool_call_delta(tool_calls, tool_call) do
    idx = find_tool_call_index(tool_calls, tool_call) || find_fallback_index(tool_calls)

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

  # Marks a tool call as complete by parsing its accumulated JSON arguments.
  # If the :tool_call_done event carries pre-parsed arguments, those take
  # precedence over re-parsing the JSON buffer.
  defp finalize_tool_call(tool_calls, tool_call) do
    idx = find_tool_call_index(tool_calls, tool_call) || find_fallback_index(tool_calls)

    case idx do
      nil ->
        # No matching slot — append with arguments resolved.
        resolved_args = tool_call[:arguments] || decode_arguments_json(tool_call[:arguments_json])
        tool_calls ++ [Map.put(tool_call, :arguments, resolved_args)]

      idx ->
        List.update_at(tool_calls, idx, fn existing ->
          existing
          |> merge_tool_call_metadata(tool_call)
          |> Map.put(
            :arguments,
            tool_call[:arguments] || decode_arguments_json(existing[:arguments_json])
          )
        end)
    end
  end

  # ── Tool Call Index Resolution ──────────────────────────────────────

  # Finds the index of a matching tool call using the best available
  # identifier: call_id > item_id > call_index.
  defp find_tool_call_index(tool_calls, tool_call) do
    call_id = normalize_id(tool_call[:call_id])
    item_id = normalize_id(tool_call[:item_id])
    call_index = tool_call[:call_index]

    cond do
      call_id != nil ->
        find_last_index(tool_calls, &(normalize_id(&1[:call_id]) == call_id))

      item_id != nil ->
        find_last_index(tool_calls, &(normalize_id(&1[:item_id]) == item_id))

      is_integer(call_index) ->
        find_last_index(tool_calls, &(&1[:call_index] == call_index))

      true ->
        nil
    end
  end

  # Fallback: find the last tool call that hasn't been finalised yet
  # (no :arguments key set).  Used by legacy single-tool providers.
  defp find_fallback_index(tool_calls) do
    find_last_index(tool_calls, &is_nil(&1[:arguments]))
  end

  # Returns the index of the last element matching `predicate`, or nil.
  defp find_last_index(list, predicate) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {item, idx}, acc ->
      if predicate.(item), do: idx, else: acc
    end)
  end

  # ── Tool Call Metadata Helpers ──────────────────────────────────────

  # Merges non-nil, non-empty identifier fields from `incoming` into
  # `existing`.  Later events often carry identifiers that weren't
  # available at :tool_call_start time.
  defp merge_tool_call_metadata(existing, incoming) do
    Enum.reduce([:call_id, :item_id, :call_index, :name], existing, fn key, acc ->
      put_if_present(acc, key, incoming[key])
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # Normalises a tool identifier: non-empty strings pass through, everything
  # else becomes nil (so we can use `!= nil` checks consistently).
  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_), do: nil

  # Extracts a 0-based call index from event info.  Providers may use
  # either :call_index or :output_index depending on the API flavour.
  defp resolve_call_index(info) do
    case info[:call_index] || info[:output_index] do
      idx when is_integer(idx) -> idx
      _ -> nil
    end
  end

  # Safely decodes a JSON arguments string into a map.
  # Returns `%{}` on invalid / incomplete JSON rather than crashing.
  defp decode_arguments_json(json), do: Opal.Util.Json.safe_decode(json)
end
