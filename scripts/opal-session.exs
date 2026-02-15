#!/usr/bin/env elixir
# scripts/opal-session.exs — Boot a session, send a prompt, stream events.
#
# Usage:
#   cd packages/core
#   mix run --no-start ../../scripts/opal-session.exs -- "<prompt>"
#   mix run --no-start ../../scripts/opal-session.exs -- "<prompt>" --timeout 30000
#   mix run --no-start ../../scripts/opal-session.exs -- "<prompt>" --model copilot:gpt-4.1
#   mix run --no-start ../../scripts/opal-session.exs -- "<prompt>" --working-dir /path/to/project
#   mix run --no-start ../../scripts/opal-session.exs -- "<prompt>" --json
#
# Examples:
#   # Simple prompt
#   mix run --no-start ../../scripts/opal-session.exs -- "What tools do you have?"
#
#   # With specific model and working directory
#   mix run --no-start ../../scripts/opal-session.exs -- "List files" --model copilot:claude-sonnet-4 --working-dir /tmp
#
#   # JSON output (for programmatic consumption)
#   mix run --no-start ../../scripts/opal-session.exs -- "Hello" --json --timeout 15000
#
# The script boots the Opal OTP application, starts a session, subscribes to
# events, sends the prompt, collects the full event stream, and prints results.

Application.put_env(:opal, :start_rpc, false)
Application.put_env(:opal, :start_distribution, false)
Application.ensure_all_started(:opal)

defmodule OpalSession.CLI do
  @default_timeout 60_000

  def run(argv) do
    # Strip leading "--" that mix run passes through.
    argv = Enum.drop_while(argv, &(&1 == "--"))
    {opts, args} = parse_args(argv)

    prompt =
      case args do
        [text | _] ->
          text

        [] ->
          IO.puts(:stderr, """
          Usage: elixir -S mix run scripts/opal-session.exs -- "<prompt>" [options]

          Options:
            --timeout <ms>       Max wait time (default: #{@default_timeout})
            --model <provider:id>  Model to use (e.g. copilot:gpt-4.1)
            --working-dir <path> Working directory for the session
            --json               Output events as JSON (one per line)
          """)

          System.halt(1)
      end

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    json_output = Keyword.get(opts, :json, false)

    session_config =
      %{}
      |> maybe_put_model(Keyword.get(opts, :model))
      |> maybe_put_working_dir(Keyword.get(opts, :working_dir))

    # Start session
    {:ok, agent} = Opal.start_session(session_config)
    state = Opal.Agent.get_state(agent)
    sid = state.session_id

    log(:stderr, "Session started: #{sid}")
    log(:stderr, "Model: #{inspect(state.model)}")
    log(:stderr, "Sending prompt: #{String.slice(prompt, 0, 80)}...")

    # Subscribe to events before sending prompt
    Opal.Events.subscribe(sid)
    Opal.Agent.prompt(agent, prompt)

    # Collect events
    events = collect_events(sid, [], timeout)

    Opal.Events.unsubscribe(sid)

    if json_output do
      print_json_events(events)
    else
      print_human_events(events)
    end

    # Print final response
    response =
      events
      |> Enum.filter(&match?({:message_delta, _}, &1))
      |> Enum.map_join(fn {:message_delta, %{delta: d}} -> d end)

    unless json_output do
      IO.puts(:stderr, "\n--- Final Response ---")
      IO.puts(response)
    end
  end

  defp collect_events(sid, acc, timeout) do
    receive do
      {:opal_event, ^sid, {:agent_end, _msgs}} ->
        Enum.reverse([{:agent_end, %{}} | acc])

      {:opal_event, ^sid, {:agent_end, _msgs, usage}} ->
        Enum.reverse([{:agent_end, %{usage: usage}} | acc])

      {:opal_event, ^sid, event} ->
        collect_events(sid, [event | acc], timeout)
    after
      timeout ->
        IO.puts(:stderr, "Timeout after #{timeout}ms — returning partial results")
        Enum.reverse(acc)
    end
  end

  defp print_json_events(events) do
    for event <- events do
      {type, data} = format_event(event)
      IO.puts(Jason.encode!(%{type: type, data: data}))
    end
  end

  defp print_human_events(events) do
    for event <- events do
      {type, data} = format_event(event)

      case type do
        "message_delta" -> :ok
        "thinking_delta" -> :ok
        _ -> IO.puts(:stderr, "  #{type} #{preview(data)}")
      end
    end
  end

  defp format_event({:agent_start}), do: {"agent_start", %{}}
  defp format_event({:agent_end, data}), do: {"agent_end", data}
  defp format_event({:agent_abort}), do: {"agent_abort", %{}}
  defp format_event({:message_start}), do: {"message_start", %{}}
  defp format_event({:message_delta, %{delta: d}}), do: {"message_delta", %{delta: d}}
  defp format_event({:thinking_start}), do: {"thinking_start", %{}}
  defp format_event({:thinking_delta, %{delta: d}}), do: {"thinking_delta", %{delta: d}}
  defp format_event({:error, reason}), do: {"error", %{reason: inspect(reason)}}
  defp format_event({:usage_update, u}), do: {"usage_update", u}
  defp format_event({:status_update, msg}), do: {"status_update", %{message: msg}}

  defp format_event({:tool_execution_start, tool, _call_id, args, _meta}),
    do: {"tool_start", %{tool: tool, args: args}}

  defp format_event({:tool_execution_start, tool, args, _meta}),
    do: {"tool_start", %{tool: tool, args: args}}

  defp format_event({:tool_execution_start, tool, args}),
    do: {"tool_start", %{tool: tool, args: args}}

  defp format_event({:tool_execution_end, tool, _call_id, result}),
    do: {"tool_end", %{tool: tool, result: serialize_result(result)}}

  defp format_event({:tool_execution_end, tool, result}),
    do: {"tool_end", %{tool: tool, result: serialize_result(result)}}

  defp format_event({:turn_end, _msg, _results}), do: {"turn_end", %{}}
  defp format_event({:request_start, info}), do: {"request_start", info}
  defp format_event({:request_end}), do: {"request_end", %{}}
  defp format_event({:context_discovered, files}), do: {"context_discovered", %{files: files}}
  defp format_event({:skill_loaded, name, _desc}), do: {"skill_loaded", %{name: name}}
  defp format_event({:agent_recovered}), do: {"agent_recovered", %{}}

  defp format_event({:sub_agent_event, call_id, sub_sid, inner}) do
    {inner_type, inner_data} = format_event(inner)

    {"sub_agent_event",
     %{call_id: call_id, sub_session_id: sub_sid, inner: Map.put(inner_data, :type, inner_type)}}
  end

  defp format_event(other), do: {"unknown", %{raw: inspect(other)}}

  defp serialize_result({:ok, out}) when is_binary(out), do: %{ok: true, output: out}
  defp serialize_result({:ok, out}), do: %{ok: true, output: inspect(out)}
  defp serialize_result({:error, e}), do: %{ok: false, error: inspect(e)}
  defp serialize_result(other), do: %{raw: inspect(other)}

  defp preview(data) when data == %{}, do: ""
  defp preview(%{delta: _}), do: ""
  defp preview(data), do: inspect(data, limit: 3, printable_limit: 100)

  defp log(:stderr, msg), do: IO.puts(:stderr, msg)

  defp parse_args(argv) do
    parse_args(argv, [], [])
  end

  defp parse_args([], opts, args), do: {Enum.reverse(opts), Enum.reverse(args)}

  defp parse_args(["--timeout", val | rest], opts, args),
    do: parse_args(rest, [{:timeout, String.to_integer(val)} | opts], args)

  defp parse_args(["--model", val | rest], opts, args),
    do: parse_args(rest, [{:model, val} | opts], args)

  defp parse_args(["--working-dir", val | rest], opts, args),
    do: parse_args(rest, [{:working_dir, val} | opts], args)

  defp parse_args(["--json" | rest], opts, args),
    do: parse_args(rest, [{:json, true} | opts], args)

  defp parse_args([arg | rest], opts, args),
    do: parse_args(rest, opts, [arg | args])

  defp maybe_put_model(config, nil), do: config

  defp maybe_put_model(config, model_str) do
    case String.split(model_str, ":", parts: 2) do
      [provider, id] -> Map.put(config, :model, {String.to_atom(provider), id})
      [id] -> Map.put(config, :model, id)
    end
  end

  defp maybe_put_working_dir(config, nil), do: config
  defp maybe_put_working_dir(config, dir), do: Map.put(config, :working_dir, dir)
end

OpalSession.CLI.run(System.argv())
