defmodule Opal.Provider do
  @moduledoc """
  Behaviour and shared utilities for LLM providers.

  ## Implementing a provider

      defmodule MyProvider do
        use Opal.Provider, name: :my_provider

        @impl true
        def stream(model, messages, tools, opts), do: ...

        @impl true
        def parse_stream_event(data), do: ...

        @impl true
        def convert_messages(model, messages), do: ...
      end

  The `use` macro injects `@behaviour Opal.Provider` and a default
  `convert_tools/1` in OpenAI function-calling format. Override it
  for provider-specific tool formats.

  ## Shared Helpers

  Reusable utilities for providers using the OpenAI Chat Completions
  wire format:

    * `parse_chat_event/1` — SSE JSON → stream events
    * `convert_messages_openai/2` — `Opal.Message` → Chat Completions format
    * `reasoning_effort/1` — thinking level → effort string
    * `compact_map/1` — strip nil/empty values from maps
    * `decode_json_args/1` — safe JSON argument decoding
    * `collect_text/3` — consume an SSE stream into a text string
  """

  # ── Types ──────────────────────────────────────────────────────────

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

  # ── Callbacks ──────────────────────────────────────────────────────

  @doc "Initiates a streaming request. Returns `{:ok, %Req.Response{}}` for SSE streams."
  @callback stream(
              model :: Opal.Provider.Model.t(),
              messages :: [Opal.Message.t()],
              tools :: [module()],
              opts :: keyword()
            ) :: {:ok, Req.Response.t()} | {:error, term()}

  @doc "Parses a raw SSE JSON line into stream events. Returns `[]` for ignored events."
  @callback parse_stream_event(data :: String.t()) :: [stream_event()]

  @doc "Converts `Opal.Message` structs to the provider's wire format."
  @callback convert_messages(model :: Opal.Provider.Model.t(), messages :: [Opal.Message.t()]) ::
              [map()]

  @doc "Converts `Opal.Tool` modules to the provider's wire format."
  @callback convert_tools(tools :: [module()]) :: [map()]

  # ── use Opal.Provider ──────────────────────────────────────────────

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

      def convert_tools(tools, ctx), do: Opal.Provider.convert_tools(tools, ctx)

      defoverridable convert_tools: 1
    end
  end

  # ── Tool Conversion (OpenAI function format) ───────────────────────

  @doc """
  Converts tool modules to OpenAI function-calling format.

  Accepts an optional `tool_context` forwarded to tools implementing
  the `description/1` callback for context-aware descriptions.
  """
  @spec convert_tools([module()], Opal.Tool.tool_context()) :: [map()]
  def convert_tools(tools, tool_context \\ %{}) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name(),
          description: Opal.Tool.description(tool, tool_context),
          parameters: tool.parameters(),
          strict: false
        }
      }
    end)
  end

  # ── Chat Completions SSE Parsing ───────────────────────────────────

  @doc """
  Parses an OpenAI Chat Completions SSE event into stream events.

  Handles `choices[0].delta` format: text, reasoning, tool calls,
  role start, finish reason, and usage.
  """
  @spec parse_chat_event(map()) :: [stream_event()]
  def parse_chat_event(%{"choices" => [%{"delta" => delta} = choice | _]} = event) do
    List.flatten([
      role_start(delta),
      text_content(delta),
      thinking_content(delta),
      tool_calls(delta),
      finish(choice),
      usage(event)
    ])
  end

  def parse_chat_event(%{"choices" => [], "usage" => u}) when is_map(u) and u != %{},
    do: [{:usage, u}]

  def parse_chat_event(_), do: []

  defp role_start(%{"reasoning_text" => _}), do: []
  defp role_start(%{"reasoning_content" => _}), do: []
  defp role_start(%{"reasoning_opaque" => _}), do: []

  defp role_start(%{"role" => "assistant", "content" => c}) when c in [nil, ""],
    do: {:text_start, %{}}

  defp role_start(%{"role" => "assistant"} = d) when not is_map_key(d, "content"),
    do: {:text_start, %{}}

  defp role_start(_), do: []

  defp text_content(%{"content" => c}) when is_binary(c) and c != "", do: {:text_delta, c}
  defp text_content(_), do: []

  defp thinking_content(%{"reasoning_content" => r}) when is_binary(r) and r != "",
    do: {:thinking_delta, r}

  defp thinking_content(%{"reasoning_text" => r}) when is_binary(r) and r != "",
    do: {:thinking_delta, r}

  defp thinking_content(_), do: []

  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.flat_map(calls, fn tc ->
      id = tc["id"]
      index = tc["index"]
      name = get_in(tc, ["function", "name"])
      args = get_in(tc, ["function", "arguments"])

      start =
        if is_binary(id) or is_binary(name),
          do: [{:tool_call_start, compact_map(%{call_id: id, call_index: index, name: name})}],
          else: []

      delta =
        if is_binary(args) and args != "",
          do: [
            {:tool_call_delta,
             compact_map(%{call_id: id, call_index: index, name: name, delta: args})}
          ],
          else: []

      start ++ delta
    end)
  end

  defp tool_calls(_), do: []

  defp finish(%{"finish_reason" => "tool_calls"}),
    do: {:response_done, %{usage: %{}, stop_reason: :tool_calls}}

  defp finish(%{"finish_reason" => r}) when is_binary(r),
    do: {:response_done, %{usage: %{}, stop_reason: :stop}}

  defp finish(_), do: []

  defp usage(%{"usage" => u}) when is_map(u) and u != %{}, do: {:usage, u}
  defp usage(_), do: []

  # ── Message Conversion (Chat Completions format) ───────────────────

  @doc """
  Converts `Opal.Message` structs to OpenAI Chat Completions format.

  ## Options

    * `:include_thinking` — include `reasoning_content` on assistant
      messages with thinking content (default: `true`)
  """
  @spec convert_messages_openai([Opal.Message.t()], keyword()) :: [map()]
  def convert_messages_openai(messages, opts \\ []) do
    include_thinking = Keyword.get(opts, :include_thinking, true)
    Enum.flat_map(messages, &msg_to_openai(&1, include_thinking))
  end

  defp msg_to_openai(%Opal.Message{role: :system, content: c}, _),
    do: [%{role: "system", content: c}]

  defp msg_to_openai(%Opal.Message{role: :user, content: c}, _),
    do: [%{role: "user", content: c}]

  defp msg_to_openai(
         %Opal.Message{role: :assistant, content: c, thinking: t, tool_calls: calls},
         include_thinking
       )
       when is_list(calls) and calls != [] do
    wire_calls =
      Enum.map(calls, fn tc ->
        %{
          id: tc.call_id,
          type: "function",
          function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}
        }
      end)

    [
      %{role: "assistant", content: c || "", tool_calls: wire_calls}
      |> put_thinking(t, include_thinking)
    ]
  end

  defp msg_to_openai(%Opal.Message{role: :assistant, content: c, thinking: t}, include_thinking),
    do: [%{role: "assistant", content: c || ""} |> put_thinking(t, include_thinking)]

  defp msg_to_openai(%Opal.Message{role: :tool_result, call_id: id, content: c}, _),
    do: [%{role: "tool", tool_call_id: id, content: c || ""}]

  defp msg_to_openai(_, _), do: []

  defp put_thinking(msg, t, true) when is_binary(t) and t != "",
    do: Map.put(msg, :reasoning_content, t)

  defp put_thinking(msg, _, _), do: msg

  # ── Reasoning Effort ───────────────────────────────────────────────

  @doc """
  Maps thinking level to OpenAI `reasoning_effort` string.

  Returns `nil` for `:off`, clamps `:max` to `"high"`.
  """
  @spec reasoning_effort(Opal.Provider.Model.thinking_level()) :: String.t() | nil
  def reasoning_effort(:off), do: nil
  def reasoning_effort(:max), do: "high"
  def reasoning_effort(level), do: to_string(level)

  # ── Shared Helpers ─────────────────────────────────────────────────

  @doc "Strips nil and empty string values from a map. Delegates to `Opal.Util.Map.compact/1`."
  @spec compact_map(map()) :: map()
  defdelegate compact_map(map), to: Opal.Util.Map, as: :compact

  @doc "Safely decodes JSON tool arguments. Returns `{:ok, map}` or `{:error, raw}`."
  @spec decode_json_args(term()) :: {:ok, map()} | {:error, String.t()}
  def decode_json_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, args}
    end
  end

  def decode_json_args(_), do: {:ok, %{}}

  # ── Text Collection ────────────────────────────────────────────────

  @doc """
  Consumes an SSE stream and returns the concatenated text content.

  Used by subsystems (e.g. compaction) that need the full LLM response
  as a string rather than processing events incrementally.
  """
  @spec collect_text(Req.Response.t(), module(), pos_integer()) :: String.t()
  def collect_text(resp, provider, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_text(resp, provider, "", deadline)
  end

  defp do_collect_text(resp, provider, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message when is_tuple(message) ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            case reduce_sse_chunks(chunks, provider, acc) do
              {:done, text} -> text
              {:cont, text} -> do_collect_text(resp, provider, text, deadline)
            end

          :unknown ->
            do_collect_text(resp, provider, acc, deadline)
        end
    after
      remaining -> acc
    end
  end

  defp reduce_sse_chunks(chunks, provider, acc) do
    Enum.reduce(chunks, {:cont, acc}, fn
      {:data, data}, {_, text} -> {:cont, text <> extract_text(data, provider)}
      :done, {_, text} -> {:done, text}
      _, pair -> pair
    end)
  end

  defp extract_text(data, provider) do
    data
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.reduce("", fn
      "data: [DONE]", acc -> acc
      "data: " <> json, acc -> acc <> text_from_events(provider.parse_stream_event(json))
      "{" <> _ = json, acc -> acc <> text_from_events(provider.parse_stream_event(json))
      _, acc -> acc
    end)
  end

  defp text_from_events(events) do
    Enum.reduce(events, "", fn
      {:text_delta, d}, acc when is_binary(d) -> acc <> d
      {:text_done, t}, "" when is_binary(t) -> t
      _, acc -> acc
    end)
  end
end
