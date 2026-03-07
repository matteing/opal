defmodule Opal.Tool.DebugState do
  @moduledoc """
  Returns a debug snapshot of the current agent runtime state.

  Intended for self-diagnosis: compact state summary plus recent session
  events captured by `Opal.Agent.Emitter`.
  """

  @behaviour Opal.Tool

  alias Opal.FileIO

  @max_event_limit 500
  @max_message_limit 200

  @impl true
  @spec name() :: String.t()
  def name, do: "debug_state"

  @impl true
  @spec description() :: String.t()
  def description,
    do: "Inspect current Opal runtime state and recent session events for debugging."

  @impl true
  @spec parameters() :: map()
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
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
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
        pending_messages: length(state.pending_messages),
        pending_tool_tasks: map_size(state.pending_tool_tasks),
        in_flight_tools:
          state.pending_tool_tasks |> Map.values() |> Enum.map(fn {_task, tc} -> tc.name end)
      },
      tools: %{
        all: Enum.map(state.tools, & &1.name()),
        enabled: Opal.Agent.ToolRunner.active_tools(state) |> Enum.map(& &1.name()),
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
    Opal.Agent.Emitter.recent(session_id, limit)
    |> Enum.map(fn %{timestamp_ms: ts, event: event} ->
      %{
        timestamp_ms: ts,
        type: event_type(event),
        data: FileIO.truncate(inspect(event, limit: 5, printable_limit: 500), 500)
      }
    end)
  end

  defp recent_messages(messages, limit) do
    messages
    |> Enum.take(-limit)
    |> Enum.map(fn msg ->
      %{
        id: msg.id,
        role: msg.role,
        call_id: msg.call_id,
        name: msg.name,
        is_error: msg.is_error,
        content: truncate_content(msg.content, 400)
      }
    end)
  end

  defp truncate_content(nil, _limit), do: nil

  defp truncate_content(value, limit) when is_binary(value),
    do: Opal.Util.Text.truncate(value, limit, "...")

  defp truncate_content(value, limit),
    do: value |> inspect(limit: 3, printable_limit: limit) |> truncate_content(limit)

  defp clamp_int(value, _default, max_limit) when is_integer(value),
    do: Opal.Util.Number.clamp(value, 1, max_limit)

  defp clamp_int(_value, default, _max_limit), do: default

  defp event_type({type, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type({type, _, _, _, _, _}) when is_atom(type), do: Atom.to_string(type)
  defp event_type(_), do: "unknown"
end
