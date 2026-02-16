defmodule Opal.Inspect do
  @moduledoc """
  Helpers for inspecting a running Opal agent from IEx.

  Connect to a running instance with `mise run inspect` and use these
  helpers to explore agent state, messages, and configuration.

  ## Quick Start

      # List all running sessions
      Opal.Inspect.sessions()

      # Get the agent pid (auto-selects if only one session)
      agent = Opal.Inspect.agent()

      # Inspect state
      Opal.Inspect.state()
      Opal.Inspect.system_prompt()
      Opal.Inspect.messages()
      Opal.Inspect.tools()
      Opal.Inspect.model()

      # Stream live events
      Opal.Inspect.watch()
  """

  alias Opal.Agent.State

  # ── Session Discovery ──────────────────────────────────────────────

  @doc """
  Lists all active agent sessions.

  Returns a list of `{session_id, pid}` tuples.

  ## Examples

      iex> Opal.Inspect.sessions()
      [{"abc123def456", #PID<0.456.0>}]
  """
  @spec sessions() :: [{String.t(), pid()}]
  def sessions do
    Registry.select(Opal.Registry, [
      {{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Returns the agent pid for the given session ID, or auto-selects
  the best candidate when no ID is given.

  Heuristic (when multiple sessions exist): prefers a session that is
  currently busy (running/streaming/executing_tools), then falls back
  to the session with the most messages (likely the most recent).

  ## Examples

      iex> Opal.Inspect.agent()
      #PID<0.456.0>

      iex> Opal.Inspect.agent("abc123def456")
      #PID<0.456.0>
  """
  @spec agent(String.t() | nil) :: pid()
  def agent(session_id \\ nil)

  def agent(nil) do
    case sessions() do
      [{_id, pid}] ->
        pid

      [] ->
        raise "No active sessions. Start an Opal session first."

      many ->
        pick_best_session(many)
    end
  end

  def agent(session_id) when is_binary(session_id) do
    case Registry.lookup(Opal.Registry, {:agent, session_id}) do
      [{pid, _}] -> pid
      [] -> raise "No agent for session: #{session_id}"
    end
  end

  # Picks the best session from multiple candidates.
  # Prefers busy sessions (running > streaming > executing_tools),
  # then falls back to most messages (proxy for "most recent").
  defp pick_best_session(candidates) do
    scored =
      Enum.map(candidates, fn {id, pid} ->
        state = Opal.Agent.get_state(pid)
        busy_score = if state.status != :idle, do: 1000, else: 0
        msg_count = length(state.messages)
        {busy_score + msg_count, id, pid}
      end)

    {_score, chosen_id, pid} = Enum.max_by(scored, &elem(&1, 0))
    short = String.slice(chosen_id, 0, 12)
    IO.puts(IO.ANSI.faint() <> "» Auto-selected session #{short}…" <> IO.ANSI.reset())
    pid
  end

  # ── State Inspection ───────────────────────────────────────────────

  @doc """
  Returns the full `Opal.Agent.State` struct for a session.

  Auto-selects the session if only one is active.

  ## Examples

      iex> state = Opal.Inspect.state()
      %Opal.Agent.State{session_id: "abc123", status: :idle, ...}
  """
  @spec state(String.t() | nil) :: State.t()
  def state(session_id \\ nil) do
    Opal.Agent.get_state(agent(session_id))
  end

  @doc """
  Returns the current system prompt (including discovered context,
  skill menu, tool guidelines, and runtime instructions).

  This is the *assembled* prompt sent to the LLM, not just the raw
  `system_prompt` field — it includes everything `build_messages/1`
  prepends.

  ## Examples

      iex> Opal.Inspect.system_prompt() |> IO.puts()
      You are a coding assistant...
      ## Runtime Context
      ...
  """
  @spec system_prompt(String.t() | nil) :: String.t()
  def system_prompt(session_id \\ nil) do
    pid = agent(session_id)
    messages = Opal.Agent.get_context(pid)

    case messages do
      [%{role: :system, content: prompt} | _] -> prompt
      _ -> state(session_id).system_prompt
    end
  end

  @doc """
  Returns the conversation messages (newest first, as stored in state).

  ## Options

    * `:limit` — max messages to return (default: all)
    * `:role` — filter by role (`:user`, `:assistant`, `:tool_result`, `:system`)

  ## Examples

      iex> Opal.Inspect.messages(limit: 5)
      [%Opal.Message{role: :assistant, ...}, ...]

      iex> Opal.Inspect.messages(role: :user)
      [%Opal.Message{role: :user, content: "List files", ...}]
  """
  @spec messages(keyword()) :: [Opal.Message.t()]
  def messages(opts \\ []) do
    s = state(Keyword.get(opts, :session_id))
    msgs = s.messages

    msgs =
      case Keyword.get(opts, :role) do
        nil -> msgs
        role -> Enum.filter(msgs, &(&1.role == role))
      end

    case Keyword.get(opts, :limit) do
      nil -> msgs
      n -> Enum.take(msgs, n)
    end
  end

  @doc """
  Returns the active tool modules and their names.

  ## Examples

      iex> Opal.Inspect.tools()
      [{"read_file", Opal.Tool.Read}, {"shell", Opal.Tool.Shell}, ...]
  """
  @spec tools(String.t() | nil) :: [{String.t(), module()}]
  def tools(session_id \\ nil) do
    s = state(session_id)
    Enum.map(s.tools, fn mod -> {mod.name(), mod} end)
  end

  @doc """
  Returns the current model.

  ## Examples

      iex> Opal.Inspect.model()
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4"}
  """
  @spec model(String.t() | nil) :: Opal.Provider.Model.t()
  def model(session_id \\ nil) do
    state(session_id).model
  end

  @doc """
  Returns a summary map of the current session state.

  Useful for a quick overview without printing the full struct.

  ## Examples

      iex> Opal.Inspect.summary()
      %{
        session_id: "abc123",
        status: :idle,
        model: "copilot:claude-sonnet-4",
        messages: 12,
        tools: 8,
        active_skills: [],
        token_usage: %{prompt_tokens: 4200, ...}
      }
  """
  @spec summary(String.t() | nil) :: map()
  def summary(session_id \\ nil) do
    s = state(session_id)

    %{
      session_id: s.session_id,
      status: s.status,
      model: "#{s.model.provider}:#{s.model.id}",
      provider: s.provider,
      messages: length(s.messages),
      tools: length(s.tools),
      active_skills: s.active_skills,
      available_skills: Enum.map(s.available_skills, & &1.name),
      context_files: s.context_files,
      working_dir: s.working_dir,
      token_usage: s.token_usage,
      retry_count: s.retry_count
    }
  end

  # ── Live Event Watching ────────────────────────────────────────────

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
        watch_loop()
      end)

    {:ok, pid}
  end

  defp watch_loop do
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

        watch_loop()

      _ ->
        watch_loop()
    end
  end

  # ── Event Formatting (private) ─────────────────────────────────────

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

  defp format_event({:context_discovered, files}),
    do: {"context_discovered", Enum.join(files, ", ")}

  defp format_event({:skill_loaded, name, _desc}), do: {"skill_loaded", name}
  defp format_event({:turn_end, _msg, _results}), do: {"turn_end", ""}
  defp format_event({:error, reason}), do: {"error", inspect(reason)}
  defp format_event({:request_start, info}), do: {"request_start", inspect(info)}
  defp format_event({:request_end}), do: {"request_end", ""}
  defp format_event({:agent_recovered}), do: {"agent_recovered", "session reloaded"}
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
