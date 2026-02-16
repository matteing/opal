defmodule Opal.Provider.LLM do
  @moduledoc """
  Generic LLM provider powered by ReqLLM.

  Supports any provider that ReqLLM supports (Anthropic, OpenAI, Google, Groq,
  OpenRouter, xAI, AWS Bedrock, and more) through a unified interface.

  This provider bridges ReqLLM's `StreamResponse` into Opal's event-based
  streaming model by iterating chunks in a spawned process and sending
  pre-parsed event tuples via `Opal.Provider.EventStream`.

  ## Model Specification

  Models are specified as `"provider:model_id"` strings via `Opal.Model`:

      Opal.Model.new(:anthropic, "claude-sonnet-4-5")
      Opal.Model.new(:openai, "gpt-4o")

  ## API Key Management

  API keys are managed through ReqLLM's key system:

      # Via environment variables (recommended)
      # ANTHROPIC_API_KEY=sk-ant-...
      # OPENAI_API_KEY=sk-...

      # Or programmatically
      ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
  """

  @behaviour Opal.Provider

  require Logger

  # ── stream/4 ──────────────────────────────────────────────────────────

  @impl true
  def stream(model, messages, tools, _opts \\ []) do
    model_spec = Opal.Model.to_req_llm_spec(model)
    context = to_req_llm_context(model, messages)
    req_tools = to_req_llm_tools(tools)

    stream_opts =
      [tools: req_tools]
      |> maybe_add_thinking(model)

    Logger.debug(
      "ReqLLM stream start model=#{model_spec} messages=#{length(messages)} tools=#{length(tools)}"
    )

    case ReqLLM.stream_text(model_spec, context, stream_opts) do
      {:ok, stream_response} ->
        bridge_to_events(stream_response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Bridge ReqLLM's StreamResponse into an EventStream that sends
  # pre-parsed event tuples directly to the agent — no JSON round-trip.
  defp bridge_to_events(stream_response) do
    caller = self()
    ref = make_ref()
    ready_ref = make_ref()

    spawn(fn ->
      # Signal that the spawned process is running before streaming begins
      send(caller, {ready_ref, :go})

      text_started = false

      {_text_started, _tc_state} =
        Enum.reduce(stream_response.stream, {text_started, %{}}, fn chunk, {started, tc_state} ->
          {events, new_started, new_tc_state} = chunk_to_events(chunk, started, tc_state)

          if events != [] do
            send(caller, {ref, {:events, events}})
          end

          {new_started, new_tc_state}
        end)

      # Collect metadata (usage, finish_reason) after stream ends
      metadata = ReqLLM.StreamResponse.MetadataHandle.await(stream_response.metadata_handle)

      if is_map(metadata) do
        if usage = Map.get(metadata, :usage) do
          send(caller, {ref, {:events, [{:usage, normalize_usage(usage)}]}})
        end
      end

      send(caller, {ref, :done})
    end)

    cancel_fn = fn ->
      stream_response.cancel.()
      :ok
    end

    # Wait for the spawned process to be running before returning
    receive do
      {^ready_ref, :go} -> :ok
    after
      5_000 -> :ok
    end

    {:ok, %Opal.Provider.EventStream{ref: ref, cancel_fun: cancel_fn}}
  end

  # Convert ReqLLM StreamChunks to Opal stream events.
  # Returns {events, text_started?, tool_call_state}
  defp chunk_to_events(%{type: :content, text: text}, started, tc_state) do
    events =
      if started do
        [{:text_delta, text}]
      else
        [{:text_start, %{}}, {:text_delta, text}]
      end

    {events, true, tc_state}
  end

  defp chunk_to_events(%{type: :thinking, text: text}, started, tc_state) do
    events =
      if Map.get(tc_state, :thinking_started) do
        [{:thinking_delta, text}]
      else
        [{:thinking_start, %{}}, {:thinking_delta, text}]
      end

    {events, started, Map.put(tc_state, :thinking_started, true)}
  end

  defp chunk_to_events(
         %{type: :tool_call, name: name, arguments: args, metadata: meta},
         started,
         tc_state
       ) do
    call_id = Map.get(meta, :id) || Map.get(meta, :call_id) || generate_call_id()

    events = [
      {:tool_call_start, %{call_id: call_id, name: name}},
      {:tool_call_delta, Jason.encode!(args)},
      {:tool_call_done, %{call_id: call_id, name: name, arguments: args}}
    ]

    {events, started, tc_state}
  end

  defp chunk_to_events(%{type: :meta, metadata: meta}, started, tc_state) do
    events = []

    events =
      case Map.get(meta, :finish_reason) do
        nil ->
          events

        reason ->
          stop_reason =
            case to_string(reason) do
              "tool_use" -> :tool_calls
              "tool_calls" -> :tool_calls
              _ -> :stop
            end

          events ++ [{:response_done, %{usage: %{}, stop_reason: stop_reason}}]
      end

    events =
      case Map.get(meta, :usage) do
        nil -> events
        usage when is_map(usage) -> events ++ [{:usage, normalize_usage(usage)}]
      end

    {events, started, tc_state}
  end

  defp chunk_to_events(_chunk, started, tc_state) do
    {[], started, tc_state}
  end

  defp normalize_usage(usage) when is_map(usage) do
    # Normalize ReqLLM usage to the format Opal expects
    input = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0
    output = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp normalize_usage(_), do: %{}

  # ── parse_stream_event/1 ──────────────────────────────────────────────
  # This provider uses EventStream (native event tuples), so SSE parsing
  # is never called. Stub satisfies the @behaviour callback.

  @impl true
  def parse_stream_event(_data), do: []

  # ── convert_messages/2 ──────────────────────────────────────────────

  @impl true
  def convert_messages(_model, messages) do
    # Conversion is handled internally by stream/4 via ReqLLM.
    # This callback exists for compaction/summary subsystems that
    # need the wire format. Return a passthrough representation.
    Enum.flat_map(messages, fn msg ->
      case msg do
        %Opal.Message{role: :system, content: c} ->
          [%{role: "system", content: c}]

        %Opal.Message{role: :user, content: c} ->
          [%{role: "user", content: c}]

        %Opal.Message{role: :assistant, content: c} ->
          [%{role: "assistant", content: c || ""}]

        %Opal.Message{role: :tool_result, call_id: id, content: c} ->
          [%{role: "tool", tool_call_id: id, content: c || ""}]

        %Opal.Message{
          role: :tool_call,
          content: content,
          tool_calls: tool_calls
        }
        when is_list(tool_calls) and tool_calls != [] ->
          calls =
            Enum.map(tool_calls, fn tc ->
              %{
                id: tc.call_id || tc.id,
                type: "function",
                function: %{name: tc.name, arguments: Jason.encode!(tc.arguments || %{})}
              }
            end)

          [%{role: "assistant", content: content || "", tool_calls: calls}]

        %Opal.Message{role: :tool_call, content: content} ->
          [%{role: "assistant", content: content || ""}]

        _ ->
          []
      end
    end)
  end

  # ── convert_tools/1 ──────────────────────────────────────────────────

  @impl true
  defdelegate convert_tools(tools), to: Opal.Provider

  # ── Internal Conversion Helpers ──────────────────────────────────────

  # Convert Opal messages to ReqLLM Context
  defp to_req_llm_context(model, messages) do
    req_messages =
      Enum.flat_map(messages, fn msg ->
        to_req_llm_message(model, msg)
      end)

    ReqLLM.Context.new(req_messages)
  end

  defp to_req_llm_message(_model, %Opal.Message{role: :system, content: content}) do
    [ReqLLM.Context.system(content)]
  end

  defp to_req_llm_message(_model, %Opal.Message{role: :user, content: content}) do
    [ReqLLM.Context.user(content)]
  end

  defp to_req_llm_message(_model, %Opal.Message{
         role: :assistant,
         content: content,
         thinking: thinking,
         tool_calls: tool_calls
       })
       when is_list(tool_calls) and tool_calls != [] do
    req_tool_calls =
      Enum.map(tool_calls, fn tc ->
        ReqLLM.ToolCall.new(tc.call_id, tc.name, Jason.encode!(tc.arguments))
      end)

    meta = if thinking, do: %{thinking: thinking}, else: %{}
    [ReqLLM.Context.assistant(content || "", tool_calls: req_tool_calls, metadata: meta)]
  end

  defp to_req_llm_message(_model, %Opal.Message{
         role: :assistant,
         content: content,
         thinking: thinking
       }) do
    meta = if thinking, do: %{thinking: thinking}, else: %{}
    [ReqLLM.Context.assistant(content || "", metadata: meta)]
  end

  defp to_req_llm_message(_model, %Opal.Message{
         role: :tool_result,
         call_id: call_id,
         content: content
       }) do
    [ReqLLM.Context.tool_result(call_id, content || "")]
  end

  defp to_req_llm_message(_model, _msg), do: []

  # Convert Opal tool modules to ReqLLM tool structs
  defp to_req_llm_tools(tools) do
    Enum.map(tools, fn tool ->
      ReqLLM.tool(
        name: tool.name(),
        description: tool.description(),
        parameter_schema: tool.parameters(),
        callback: fn _args -> {:ok, ""} end
      )
    end)
  end

  defp maybe_add_thinking(opts, %{thinking_level: :off}), do: opts

  defp maybe_add_thinking(opts, %{thinking_level: level}) do
    # ReqLLM accepts :low, :medium, :high for reasoning_effort.
    # :max maps to Anthropic's adaptive "max" — pass through to ReqLLM.
    Keyword.put(opts, :reasoning_effort, level)
  end

  defp generate_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
