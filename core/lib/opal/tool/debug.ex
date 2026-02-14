defmodule Opal.Tool.Debug do
  @moduledoc """
  Returns a debug snapshot of the current agent runtime state.

  This tool is intended for self-diagnosis and troubleshooting. It includes a
  compact state summary and, when enabled, recent session events captured by
  `Opal.Agent.EventLog`.
  """

  @behaviour Opal.Tool

  @max_event_limit 500
  @max_message_limit 200

  @impl true
  def name, do: "debug_state"

  @impl true
  def description do
    "Inspect current Opal runtime state and recent session events for debugging."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "event_limit" => %{
          "type" => "integer",
          "description" => "Max recent events to include (default: 50, max: 500)."
        },
        "include_messages" => %{
          "type" => "boolean",
          "description" =>
            "Include recent conversation messages in the snapshot (default: false)."
        },
        "message_limit" => %{
          "type" => "integer",
          "description" =>
            "Max messages to include when include_messages=true (default: 20, max: 200)."
        }
      }
    }
  end

  @impl true
  def meta(%{"event_limit" => limit}) when is_integer(limit),
    do: "Inspect runtime (events=#{limit})"

  def meta(_), do: "Inspect runtime state"

  @impl true
  def execute(args, %{agent_state: %Opal.Agent.State{} = state}) do
    event_limit = clamp_int(Map.get(args, "event_limit"), 50, @max_event_limit)
    include_messages = Map.get(args, "include_messages", false) == true
    message_limit = clamp_int(Map.get(args, "message_limit"), 20, @max_message_limit)

    payload = %{
      session_id: state.session_id,
      status: state.status,
      model: %{
        provider: state.model.provider,
        id: state.model.id,
        thinking_level: state.model.thinking_level
      },
      provider: inspect(state.provider),
      working_dir: state.working_dir,
      queues: %{
        pending_steers: length(state.pending_steers),
        remaining_tool_calls: length(state.remaining_tool_calls),
        has_pending_tool_task: not is_nil(state.pending_tool_task)
      },
      tools: %{
        all: Enum.map(state.tools, & &1.name()),
        enabled: Opal.Agent.Tools.active_tools(state) |> Enum.map(& &1.name()),
        disabled: state.disabled_tools
      },
      token_usage: state.token_usage,
      messages: %{
        count: length(state.messages),
        recent:
          if(include_messages,
            do: recent_messages(state.messages, message_limit),
            else: []
          )
      },
      recent_events: recent_events(state.session_id, event_limit)
    }

    {:ok, Jason.encode!(payload, pretty: true)}
  end

  def execute(_args, _context), do: {:error, "Missing agent_state in context"}

  defp recent_events(session_id, limit) do
    Opal.Agent.EventLog.recent(session_id, limit)
    |> Enum.map(fn %{timestamp_ms: ts, event: event} ->
      %{
        timestamp_ms: ts,
        type: event_type(event),
        data: String.slice(inspect(event, limit: 5, printable_limit: 500), 0, 500)
      }
    end)
  end

  defp recent_messages(messages, limit) do
    messages
    |> Enum.take(limit)
    |> Enum.map(fn msg ->
      %{
        id: msg.id,
        role: msg.role,
        call_id: msg.call_id,
        name: msg.name,
        is_error: msg.is_error,
        content: truncate(msg.content, 400)
      }
    end)
  end

  defp truncate(nil, _limit), do: nil

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "...", else: value
  end

  defp truncate(value, limit),
    do: value |> inspect(limit: 3, printable_limit: limit) |> truncate(limit)

  defp clamp_int(value, _default, max_limit) when is_integer(value),
    do: value |> max(1) |> min(max_limit)

  defp clamp_int(_value, default, _max_limit), do: default

  defp event_type({type, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type(_), do: "unknown"
end
