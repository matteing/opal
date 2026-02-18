defmodule Opal.Provider.Copilot do
  @moduledoc """
  GitHub Copilot provider.

  Supports two OpenAI API variants based on the model:

    * **Chat Completions** (`/v1/chat/completions`) — most models
      (Claude, GPT-4o, Gemini, o3/o4, etc.)
    * **Responses API** (`/v1/responses`) — GPT-5 family models

  Streams SSE into the calling process's mailbox via `Req.post/2`
  with `into: :self`.
  """

  @behaviour Opal.Provider

  import Opal.Provider, only: [compact_map: 1, decode_json_args: 1]

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def stream(model, messages, tools, opts \\ []) do
    with {:ok, token_data} <- Opal.Auth.Copilot.get_token() do
      copilot_token = token_data["copilot_token"]
      base = token_data["base_url"] || Opal.Auth.Copilot.base_url(token_data)

      req =
        Req.new(
          base_url: base,
          auth: {:bearer, copilot_token},
          headers: build_headers(messages, opts)
        )

      ctx = Keyword.get(opts, :tool_context, %{})

      if responses_api?(model.id),
        do: do_stream_responses(req, model, messages, tools, ctx),
        else: do_stream_completions(req, model, messages, tools, ctx)
    end
  end

  @impl true
  def parse_stream_event(data) do
    case Jason.decode(data) do
      {:ok, %{"choices" => _} = event} -> Opal.Provider.parse_chat_event(event)
      {:ok, parsed} -> parse_responses_event(parsed)
      {:error, _} -> []
    end
  end

  @impl true
  def convert_messages(model, messages) do
    if responses_api?(model.id),
      do: messages_to_responses(model, messages),
      else: Opal.Provider.convert_messages_openai(messages, include_thinking: true)
  end

  @impl true
  defdelegate convert_tools(tools), to: Opal.Provider

  @doc false
  defdelegate convert_tools(tools, ctx), to: Opal.Provider

  # ── Chat Completions (/v1/chat/completions) ────────────────────────

  defp do_stream_completions(req, model, messages, tools, ctx) do
    body =
      %{model: model.id, stream: true, stream_options: %{include_usage: true}}
      |> put_unless_empty(:tools, Opal.Provider.convert_tools(tools, ctx))
      |> put_unless_empty(
        :messages,
        Opal.Provider.convert_messages_openai(messages, include_thinking: true)
      )
      |> maybe_add_reasoning(model, :completions)

    Req.post(req, url: "/chat/completions", json: body, into: :self, receive_timeout: 120_000)
  end

  # ── Responses API (/v1/responses) ──────────────────────────────────

  defp do_stream_responses(req, model, messages, tools, ctx) do
    body =
      %{model: model.id, stream: true, store: false}
      |> put_unless_empty(:tools, tools_to_responses(tools, ctx))
      |> put_unless_empty(:input, messages_to_responses(model, messages))
      |> maybe_add_reasoning(model, :responses)

    Req.post(req, url: "/responses", json: body, into: :self, receive_timeout: 120_000)
  end

  # Responses API uses a flat tool format (no nested "function" key)
  defp tools_to_responses(tools, ctx) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name(),
        description: Opal.Tool.description(tool, ctx),
        parameters: tool.parameters(),
        strict: false
      }
    end)
  end

  # ── Responses API SSE Parsing ──────────────────────────────────────

  defp parse_responses_event(%{"type" => "response.output_item.added", "item" => item}) do
    case item["type"] do
      "reasoning" ->
        [{:thinking_start, %{item_id: item["id"]}}]

      "message" ->
        [{:text_start, %{item_id: item["id"]}}]

      "function_call" ->
        [
          {:tool_call_start,
           compact_map(%{item_id: item["id"], call_id: item["call_id"], name: item["name"]})}
        ]

      _ ->
        []
    end
  end

  defp parse_responses_event(%{"type" => "response.reasoning_summary_text.delta", "delta" => d}),
    do: [{:thinking_delta, d}]

  defp parse_responses_event(%{"type" => "response.output_text.delta", "delta" => d}),
    do: [{:text_delta, d}]

  defp parse_responses_event(%{"type" => "response.output_text.done", "text" => t}),
    do: [{:text_done, t}]

  defp parse_responses_event(%{"type" => "response.function_call_arguments.delta"} = e) do
    case e["delta"] do
      d when is_binary(d) ->
        [
          {:tool_call_delta,
           compact_map(%{
             delta: d,
             item_id: e["item_id"],
             call_id: e["call_id"],
             call_index: e["output_index"],
             name: e["name"]
           })}
        ]

      _ ->
        []
    end
  end

  defp parse_responses_event(%{"type" => "response.function_call_arguments.done"} = e) do
    info =
      compact_map(%{
        item_id: e["item_id"],
        call_id: e["call_id"],
        call_index: e["output_index"],
        name: e["name"]
      })

    case decode_json_args(e["arguments"]) do
      {:ok, args} -> [{:tool_call_done, Map.put(info, :arguments, args)}]
      {:error, raw} -> [{:tool_call_done, Map.put(info, :arguments_raw, raw)}]
    end
  end

  defp parse_responses_event(%{
         "type" => "response.output_item.done",
         "item" => %{"type" => "function_call"} = item
       }) do
    info = compact_map(%{item_id: item["id"], call_id: item["call_id"], name: item["name"]})

    args =
      case decode_json_args(item["arguments"]),
        do: (
          {:ok, a} -> a
          {:error, _} -> %{}
        )

    [{:tool_call_done, Map.put(info, :arguments, args)}]
  end

  defp parse_responses_event(%{"type" => "response.completed", "response" => r}),
    do: [{:response_done, %{usage: Map.get(r, "usage", %{}), status: r["status"], id: r["id"]}}]

  defp parse_responses_event(%{"type" => "error"} = e),
    do: [{:error, Map.get(e, "error", e)}]

  defp parse_responses_event(%{"type" => "response.failed", "response" => r}),
    do: [{:error, r["error"] || r}]

  defp parse_responses_event(%{"error" => error}),
    do: [{:error, error}]

  defp parse_responses_event(_), do: []

  # ── Responses API Message Conversion ───────────────────────────────

  defp messages_to_responses(model, messages) do
    Enum.flat_map(messages, &msg_to_responses(model, &1))
  end

  defp msg_to_responses(model, %Opal.Message{role: :system, content: c}) do
    role = if model.thinking_level != :off, do: "developer", else: "system"
    [%{role: role, content: c}]
  end

  defp msg_to_responses(_, %Opal.Message{role: :user, content: c}),
    do: [%{role: "user", content: [%{type: "input_text", text: c}]}]

  defp msg_to_responses(_, %Opal.Message{
         role: :assistant,
         content: c,
         thinking: t,
         tool_calls: calls
       })
       when is_list(calls) and calls != [] do
    reasoning_items(t) ++
      text_items(c) ++
      Enum.map(calls, fn tc ->
        %{
          type: "function_call",
          call_id: tc.call_id,
          name: tc.name,
          arguments: Jason.encode!(tc.arguments)
        }
      end)
  end

  defp msg_to_responses(_, %Opal.Message{role: :assistant, content: c, thinking: t}) do
    reasoning_items(t) ++
      [
        %{
          type: "message",
          role: "assistant",
          content: [%{type: "output_text", text: c || ""}],
          status: "completed"
        }
      ]
  end

  defp msg_to_responses(_, %Opal.Message{role: :tool_call, call_id: id, name: name, content: c}) do
    args =
      case Jason.decode(c || "{}"),
        do: (
          {:ok, p} -> Jason.encode!(p)
          {:error, _} -> c || "{}"
        )

    [%{type: "function_call", call_id: id, name: name, arguments: args}]
  end

  defp msg_to_responses(_, %Opal.Message{role: :tool_result, call_id: id, content: c}),
    do: [%{type: "function_call_output", call_id: id, output: c || ""}]

  defp msg_to_responses(_, _), do: []

  defp reasoning_items(nil), do: []
  defp reasoning_items(""), do: []

  defp reasoning_items(t),
    do: [%{type: "reasoning", id: "rs_roundtrip", summary: [%{type: "summary_text", text: t}]}]

  defp text_items(nil), do: []
  defp text_items(""), do: []

  defp text_items(c),
    do: [
      %{
        type: "message",
        role: "assistant",
        content: [%{type: "output_text", text: c}],
        status: "completed"
      }
    ]

  # ── Reasoning ──────────────────────────────────────────────────────

  defp maybe_add_reasoning(body, %{thinking_level: :off}, _api), do: body

  defp maybe_add_reasoning(body, %{thinking_level: level, id: id}, :completions) do
    if thinking_capable?(id),
      do: Map.put(body, :reasoning_effort, Opal.Provider.reasoning_effort(level)),
      else: body
  end

  defp maybe_add_reasoning(body, %{thinking_level: level}, :responses),
    do:
      Map.put(body, :reasoning, %{effort: Opal.Provider.reasoning_effort(level), summary: "auto"})

  defp thinking_capable?(id) do
    Enum.any?(
      ~w(gpt-5 claude-sonnet-4 claude-opus-4 claude-haiku-4.5 o3 o4),
      &String.starts_with?(id, &1)
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp responses_api?(id),
    do: String.starts_with?(id, "gpt-5") or String.starts_with?(id, "oswe")

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, val), do: Map.put(map, key, val)

  defp build_headers(messages, opts) do
    last_role =
      case List.last(messages) do
        %{role: role} -> to_string(role)
        _ -> "user"
      end

    base = %{
      "user-agent" => "GitHubCopilotChat/0.35.0",
      "editor-version" => "vscode/1.107.0",
      "editor-plugin-version" => "copilot-chat/0.35.0",
      "copilot-integration-id" => "vscode-chat",
      "openai-intent" => "conversation-edits",
      "x-initiator" => if(last_role != "user", do: "agent", else: "user")
    }

    override =
      case Keyword.get(opts, :headers, %{}) do
        h when is_map(h) -> h
        h when is_list(h) -> Map.new(h)
        _ -> %{}
      end

    Map.merge(base, override)
  end
end
