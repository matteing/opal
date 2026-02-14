defmodule Opal.Inspect do
  @moduledoc """
  Helpers for the `pnpm inspect` IEx session.

  Call `Opal.Inspect.watch()` to stream all agent events to the console.
  """

  @doc """
  Subscribe to all session events and print them to the console.

  Returns the subscriber PID. Call `Process.exit(pid, :normal)` to stop.

  ## Examples

      iex> Opal.Inspect.watch()
      Watching all opal events... (Ctrl+C to stop)
      {:ok, #PID<0.123.0>}
  """
  @spec watch() :: {:ok, pid()}
  def watch do
    pid =
      spawn_link(fn ->
        Opal.Events.subscribe_all()
        IO.puts(IO.ANSI.magenta() <> "✦ Watching all opal events..." <> IO.ANSI.reset())
        loop()
      end)

    {:ok, pid}
  end

  defp loop do
    receive do
      {:opal_event, session_id, event} ->
        short_sid = String.slice(session_id, 0, 8)
        ts = Time.utc_now() |> Time.truncate(:millisecond) |> Time.to_string()
        {type, data} = format_event(event)

        color = event_color(type)

        IO.puts(
          "#{IO.ANSI.faint()}#{ts}#{IO.ANSI.reset()} " <>
            "#{IO.ANSI.faint()}[#{short_sid}]#{IO.ANSI.reset()} " <>
            "#{color}#{type}#{IO.ANSI.reset()}" <>
            if(data != "", do: " #{data}", else: "")
        )

        loop()

      _ ->
        loop()
    end
  end

  defp format_event({:agent_start}), do: {"agent_start", ""}
  defp format_event({:agent_abort}), do: {"agent_abort", ""}
  defp format_event({:agent_end, _msgs}), do: {"agent_end", ""}
  defp format_event({:agent_end, _msgs, usage}), do: {"agent_end", "tokens=#{inspect(usage)}"}

  defp format_event({:usage_update, usage}),
    do:
      {"usage_update",
       "prompt=#{usage.prompt_tokens} total=#{usage.total_tokens} ctx=#{usage.context_window}"}

  defp format_event({:status_update, msg}), do: {"status_update", "\"#{msg}\""}
  defp format_event({:message_start}), do: {"message_start", ""}

  defp format_event({:message_delta, %{delta: d}}),
    do: {"message_delta", "\"#{String.slice(d, 0, 60)}\""}

  defp format_event({:thinking_start}), do: {"thinking_start", ""}

  defp format_event({:thinking_delta, %{delta: d}}),
    do: {"thinking_delta", "\"#{String.slice(d, 0, 60)}\""}

  defp format_event({:tool_execution_start, tool, _call_id, _args, meta}),
    do: {"tool_start", "#{tool} #{meta}"}

  defp format_event({:tool_execution_start, tool, _args, meta}),
    do: {"tool_start", "#{tool} #{meta}"}

  defp format_event({:tool_execution_start, tool, _args}), do: {"tool_start", "#{tool}"}

  defp format_event({:tool_execution_end, tool, _call_id, {:ok, out}}),
    do: {"tool_end", "#{tool} ok #{out |> to_preview() |> String.slice(0, 60)}"}

  defp format_event({:tool_execution_end, tool, _call_id, {:error, e}}),
    do: {"tool_end", "#{tool} error #{inspect(e) |> String.slice(0, 60)}"}

  defp format_event({:tool_execution_end, tool, {:ok, out}}),
    do: {"tool_end", "#{tool} ok #{out |> to_preview() |> String.slice(0, 60)}"}

  defp format_event({:tool_execution_end, tool, {:error, e}}),
    do: {"tool_end", "#{tool} error #{inspect(e) |> String.slice(0, 60)}"}

  defp format_event({:sub_agent_event, _call_id, sub_sid, inner}) do
    {inner_type, inner_data} = format_event(inner)
    {"sub_agent", "[#{String.slice(sub_sid, 0, 12)}] #{inner_type} #{inner_data}"}
  end

  defp format_event({:skill_loaded, name, _desc}), do: {"skill_loaded", name}
  defp format_event({:turn_end, _msg, _results}), do: {"turn_end", ""}
  defp format_event({:error, reason}), do: {"error", inspect(reason)}
  defp format_event({:request_start, info}), do: {"request_start", inspect(info)}
  defp format_event({:request_end}), do: {"request_end", ""}
  defp format_event(other), do: {"unknown", inspect(other, limit: 3, printable_limit: 80)}

  defp event_color("agent_start"), do: IO.ANSI.green()
  defp event_color("agent_end"), do: IO.ANSI.green()
  defp event_color("agent_abort"), do: IO.ANSI.yellow()
  defp event_color("message_start"), do: IO.ANSI.cyan()
  defp event_color("message_delta"), do: IO.ANSI.cyan()
  defp event_color("thinking" <> _), do: IO.ANSI.magenta()
  defp event_color("tool_start"), do: IO.ANSI.yellow()
  defp event_color("tool_end"), do: IO.ANSI.yellow()
  defp event_color("sub_agent"), do: IO.ANSI.blue()
  defp event_color("error"), do: IO.ANSI.red()
  defp event_color("request" <> _), do: IO.ANSI.faint()
  defp event_color(_), do: IO.ANSI.faint()

  defp to_preview(val) when is_binary(val), do: val
  defp to_preview(nil), do: ""
  defp to_preview(val), do: inspect(val, limit: 3, printable_limit: 80)
end
