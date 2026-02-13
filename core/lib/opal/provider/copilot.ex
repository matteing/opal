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

  require Logger

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
    converted_tools = convert_tools(tools)

    body = %{
      model: model.id,
      input: converted_messages,
      stream: true,
      store: false
    }

    body = if converted_tools != [], do: Map.put(body, :tools, converted_tools), else: body

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
  # Shape: {"choices": [{"delta": {"content": "..."}, "finish_reason": null}]}

  defp do_parse_event(%{"choices" => [%{"delta" => delta} = choice | _]} = event) do
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
              # New tool call (has id)
              tc["id"] ->
                acc ++
                  [
                    {:tool_call_start,
                     %{
                       call_id: tc["id"],
                       name: get_in(tc, ["function", "name"]) || ""
                     }}
                  ]

              # Argument delta
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
  defp do_parse_event(%{"choices" => [], "usage" => usage}) when is_map(usage) and usage != %{} do
    [{:usage, usage}]
  end

  defp do_parse_event(%{"choices" => []}), do: []

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

  # ── Chat Completions message format ──────────────────────────────────

  defp convert_messages_completions(model, messages) do
    Enum.flat_map(messages, fn msg -> convert_msg_completions(model, msg) end)
  end

  defp convert_msg_completions(_model, %Opal.Message{role: :system, content: content}) do
    [%{role: "system", content: content}]
  end

  defp convert_msg_completions(_model, %Opal.Message{role: :user, content: content}) do
    [%{role: "user", content: content}]
  end

  defp convert_msg_completions(_model, %Opal.Message{
         role: :assistant,
         content: content,
         tool_calls: tool_calls
       })
       when is_list(tool_calls) and tool_calls != [] do
    calls =
      Enum.map(tool_calls, fn tc ->
        %{
          id: tc.call_id,
          type: "function",
          function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}
        }
      end)

    [%{role: "assistant", content: content || "", tool_calls: calls}]
  end

  defp convert_msg_completions(_model, %Opal.Message{role: :assistant, content: content}) do
    [%{role: "assistant", content: content || ""}]
  end

  defp convert_msg_completions(_model, %Opal.Message{
         role: :tool_result,
         call_id: call_id,
         content: content
       }) do
    [%{role: "tool", tool_call_id: call_id, content: content || ""}]
  end

  defp convert_msg_completions(_model, _msg), do: []

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
         tool_calls: tool_calls
       })
       when is_list(tool_calls) and tool_calls != [] do
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

    text_item ++ call_items
  end

  defp convert_msg_responses(_model, %Opal.Message{role: :assistant, content: content}) do
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
end
