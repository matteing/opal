defmodule Opal.Provider.Copilot do
  @moduledoc """
  GitHub Copilot provider implementation.

  Supports two OpenAI API variants based on the model:

  - **Chat Completions** (`/v1/chat/completions`) — used by most models
    (Claude, GPT-4o, Gemini, o3/o4, etc.)
  - **Responses API** (`/v1/responses`) — used by GPT-5 family models

  Streams responses via SSE into the calling process's mailbox using
  `Req.post/2` with `into: :self`. The caller (typically `Opal.Agent`)
  iterates chunks with `Req.parse_message/2`.
  """

  @behaviour Opal.Provider

  # Models that require the Responses API; all others use Chat Completions
  defp use_responses_api?(model_id) do
    String.starts_with?(model_id, "gpt-5") or String.starts_with?(model_id, "oswe")
  end

  # ── stream/4 ──────────────────────────────────────────────────────────

  @impl true
  def stream(model, messages, tools, opts \\ []) do
    with {:ok, token_data} <- Opal.Auth.Copilot.get_token() do
      copilot_token = token_data["copilot_token"]
      base = token_data["base_url"] || Opal.Auth.Copilot.base_url(token_data)

      req =
        Req.new(
          base_url: base,
          auth: {:bearer, copilot_token},
          headers: copilot_headers(messages, opts)
        )

      if use_responses_api?(model.id) do
        stream_responses_api(req, model, messages, tools)
      else
        stream_chat_completions(req, model, messages, tools)
      end
    end
  end

  # ── Chat Completions variant (/v1/chat/completions) ──

  defp stream_chat_completions(req, model, messages, tools) do
    converted_messages = convert_messages_completions(model, messages)
    converted_tools = convert_tools(tools)

    body = %{
      model: model.id,
      messages: converted_messages,
      stream: true,
      stream_options: %{include_usage: true}
    }

    body = if converted_tools != [], do: Map.put(body, :tools, converted_tools), else: body
    body = maybe_add_reasoning_effort(body, model)

    case Req.post(req,
           url: "/chat/completions",
           json: body,
           into: :self,
           receive_timeout: 120_000
         ) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Responses API variant (/v1/responses) ──

  defp stream_responses_api(req, model, messages, tools) do
    converted_messages = convert_messages_responses(model, messages)
    converted_tools = convert_tools_responses(tools)

    body = %{
      model: model.id,
      input: converted_messages,
      stream: true,
      store: false
    }

    body = if converted_tools != [], do: Map.put(body, :tools, converted_tools), else: body
    body = maybe_add_reasoning_config(body, model)

    case Req.post(req, url: "/responses", json: body, into: :self, receive_timeout: 120_000) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── parse_stream_event/1 ──────────────────────────────────────────────

  @doc """
  Parses a raw SSE JSON line into stream event tuples.

  Handles both Chat Completions format (`choices[0].delta`) and
  Responses API format (`response.output_text.delta`, etc.).
  """
  @impl true
  def parse_stream_event(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> do_parse_event(parsed)
      {:error, _} -> []
    end
  end

  # ── Chat Completions SSE format ──
  # Delegates to shared OpenAI module for standard choices[0].delta parsing.

  defp do_parse_event(%{"choices" => _} = event) do
    Opal.Provider.OpenAI.parse_chat_event(event)
  end

  # ── Responses API SSE format ──

  defp do_parse_event(%{"type" => "response.output_item.added", "item" => item}) do
    case item["type"] do
      "reasoning" ->
        [{:thinking_start, %{item_id: item["id"]}}]

      "message" ->
        [{:text_start, %{item_id: item["id"]}}]

      "function_call" ->
        [
          {:tool_call_start,
           %{
             item_id: item["id"],
             call_id: item["call_id"],
             name: item["name"]
           }}
        ]

      _ ->
        []
    end
  end

  defp do_parse_event(%{"type" => "response.reasoning_summary_text.delta", "delta" => delta}),
    do: [{:thinking_delta, delta}]

  defp do_parse_event(%{"type" => "response.output_text.delta", "delta" => delta}),
    do: [{:text_delta, delta}]

  defp do_parse_event(%{"type" => "response.output_text.done", "text" => text}),
    do: [{:text_done, text}]

  defp do_parse_event(%{"type" => "response.function_call_arguments.delta", "delta" => delta}),
    do: [{:tool_call_delta, delta}]

  defp do_parse_event(%{"type" => "response.function_call_arguments.done", "arguments" => args}) do
    case Jason.decode(args) do
      {:ok, parsed_args} -> [{:tool_call_done, %{arguments: parsed_args}}]
      {:error, _} -> [{:tool_call_done, %{arguments_raw: args}}]
    end
  end

  defp do_parse_event(%{
         "type" => "response.output_item.done",
         "item" => %{"type" => "function_call"} = item
       }) do
    args =
      case Jason.decode(item["arguments"] || "{}") do
        {:ok, parsed} -> parsed
        {:error, _} -> %{}
      end

    [
      {:tool_call_done,
       %{
         item_id: item["id"],
         call_id: item["call_id"],
         name: item["name"],
         arguments: args
       }}
    ]
  end

  defp do_parse_event(%{"type" => "response.completed", "response" => response}) do
    [
      {:response_done,
       %{
         usage: Map.get(response, "usage", %{}),
         status: Map.get(response, "status"),
         id: Map.get(response, "id")
       }}
    ]
  end

  # ── Error handling (both APIs) ──

  defp do_parse_event(%{"type" => "error"} = event),
    do: [{:error, Map.get(event, "error", event)}]

  defp do_parse_event(%{"type" => "response.failed", "response" => response}),
    do: [{:error, get_in(response, ["error"]) || response}]

  defp do_parse_event(%{"error" => error}),
    do: [{:error, error}]

  defp do_parse_event(_), do: []

  # ── convert_messages/2 (behaviour callback) ──────────────────────────

  @impl true
  def convert_messages(model, messages) do
    if use_responses_api?(model.id) do
      convert_messages_responses(model, messages)
    else
      convert_messages_completions(model, messages)
    end
  end

  # ── convert_tools/1 ──────────────────────────────────────────────────

  @impl true
  defdelegate convert_tools(tools), to: Opal.Provider

  # Responses API uses a flat tool format: {type, name, description, parameters}
  # Unlike Chat Completions which nests under "function".
  defp convert_tools_responses(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name(),
        description: tool.description(),
        parameters: tool.parameters(),
        strict: false
      }
    end)
  end

  # ── Chat Completions message format ──────────────────────────────────
  # Delegates to shared OpenAI module for standard message conversion.

  defp convert_messages_completions(_model, messages) do
    Opal.Provider.OpenAI.convert_messages(messages, include_thinking: true)
  end

  # ── Responses API message format ─────────────────────────────────────

  defp convert_messages_responses(model, messages) do
    Enum.flat_map(messages, fn msg -> convert_msg_responses(model, msg) end)
  end

  defp convert_msg_responses(model, %Opal.Message{role: :system, content: content}) do
    role = if model.thinking_level != :off, do: "developer", else: "system"
    [%{role: role, content: content}]
  end

  defp convert_msg_responses(_model, %Opal.Message{role: :user, content: content}) do
    [%{role: "user", content: [%{type: "input_text", text: content}]}]
  end

  defp convert_msg_responses(_model, %Opal.Message{
         role: :assistant,
         content: content,
         thinking: thinking,
         tool_calls: tool_calls
       })
       when is_list(tool_calls) and tool_calls != [] do
    # Reasoning item for roundtripping (OpenAI recommends passing back reasoning items)
    reasoning_item =
      if thinking do
        [
          %{
            type: "reasoning",
            id: "rs_roundtrip",
            summary: [%{type: "summary_text", text: thinking}]
          }
        ]
      else
        []
      end

    text_item =
      if content && content != "" do
        [
          %{
            type: "message",
            role: "assistant",
            content: [%{type: "output_text", text: content}],
            status: "completed"
          }
        ]
      else
        []
      end

    call_items =
      Enum.map(tool_calls, fn tc ->
        %{
          type: "function_call",
          call_id: tc.call_id,
          name: tc.name,
          arguments: Jason.encode!(tc.arguments)
        }
      end)

    reasoning_item ++ text_item ++ call_items
  end

  defp convert_msg_responses(_model, %Opal.Message{
         role: :assistant,
         content: content,
         thinking: thinking
       }) do
    reasoning_item =
      if thinking do
        [
          %{
            type: "reasoning",
            id: "rs_roundtrip",
            summary: [%{type: "summary_text", text: thinking}]
          }
        ]
      else
        []
      end

    reasoning_item ++
      [
        %{
          type: "message",
          role: "assistant",
          content: [%{type: "output_text", text: content || ""}],
          status: "completed"
        }
      ]
  end

  defp convert_msg_responses(_model, %Opal.Message{
         role: :tool_call,
         call_id: call_id,
         name: name,
         content: content
       }) do
    args =
      case Jason.decode(content || "{}") do
        {:ok, parsed} -> Jason.encode!(parsed)
        {:error, _} -> content || "{}"
      end

    [%{type: "function_call", call_id: call_id, name: name, arguments: args}]
  end

  defp convert_msg_responses(_model, %Opal.Message{
         role: :tool_result,
         call_id: call_id,
         content: content
       }) do
    [%{type: "function_call_output", call_id: call_id, output: content || ""}]
  end

  defp convert_msg_responses(_model, _msg), do: []

  # ── Copilot Headers ──────────────────────────────────────────────────

  defp copilot_headers(messages, _opts) do
    last_role =
      case List.last(messages) do
        %{role: role} -> to_string(role)
        _ -> "user"
      end

    %{
      "user-agent" => "GitHubCopilotChat/0.35.0",
      "editor-version" => "vscode/1.107.0",
      "editor-plugin-version" => "copilot-chat/0.35.0",
      "copilot-integration-id" => "vscode-chat",
      "openai-intent" => "conversation-edits",
      "x-initiator" => if(last_role != "user", do: "agent", else: "user")
    }
  end

  # ── Reasoning Effort ─────────────────────────────────────────────────

  # Chat Completions: add reasoning_effort string param
  defp maybe_add_reasoning_effort(body, %{thinking_level: :off}), do: body

  defp maybe_add_reasoning_effort(body, %{thinking_level: level, id: id}) do
    if supports_thinking?(id) do
      Map.put(body, :reasoning_effort, Opal.Provider.OpenAI.reasoning_effort(level))
    else
      body
    end
  end

  # Responses API: add reasoning object with effort + summary
  defp maybe_add_reasoning_config(body, %{thinking_level: :off}), do: body

  defp maybe_add_reasoning_config(body, %{thinking_level: level}) do
    Map.put(body, :reasoning, %{
      effort: Opal.Provider.OpenAI.reasoning_effort(level),
      summary: "auto"
    })
  end

  # Modern thinking-capable models served through Copilot proxy
  defp supports_thinking?(id) do
    String.starts_with?(id, "gpt-5") or
      String.starts_with?(id, "claude-sonnet-4") or
      String.starts_with?(id, "claude-opus-4") or
      String.starts_with?(id, "claude-haiku-4.5") or
      String.starts_with?(id, "o3") or
      String.starts_with?(id, "o4")
  end
end
