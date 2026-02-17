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
  Returns `{session_id, pid}` for the first active session found.

  Shorthand for quickly grabbing a session in IEx without caring
  which one:

      {sid, pid} = Opal.Inspect.first()
      Opal.Inspect.state(sid)

  ## Examples

      iex> Opal.Inspect.first()
      {"abc123def456", #PID<0.456.0>}
  """
  @spec first() :: {String.t(), pid()}
  def first do
    case sessions() do
      [{_id, _pid} = entry | _] -> entry
      [] -> raise "No active sessions. Start an Opal session first."
    end
  end

  @doc """
  Returns the agent pid for the given session ID, or auto-selects
  the first session when no ID is given.

  When multiple sessions exist, picks the first one found and prints
  which session was chosen. Use `sessions/0` to list all and pass an
  explicit ID if needed.

  ## Examples

      iex> Opal.Inspect.agent()
      #PID<0.456.0>

      iex> Opal.Inspect.agent("abc123def456")
      #PID<0.456.0>
  """
  @spec agent() :: pid()
  def agent do
    case sessions() do
      [{_id, pid}] ->
        pid

      [] ->
        raise "No active sessions. Start an Opal session first."

      [{id, pid} | _rest] ->
        short = String.slice(id, 0, 12)
        IO.puts(IO.ANSI.faint() <> "» Auto-selected session #{short}…" <> IO.ANSI.reset())
        pid
    end
  end

  @spec agent(String.t()) :: pid()
  def agent(session_id) when is_binary(session_id) do
    case Registry.lookup(Opal.Registry, {:agent, session_id}) do
      [{pid, _}] -> pid
      [] -> raise "No agent for session: #{session_id}"
    end
  end

  # ── State Inspection ───────────────────────────────────────────────

  @doc """
  Returns the full `Opal.Agent.State` struct for a session.

  Auto-selects the session if only one is active.

  ## Examples

      iex> state = Opal.Inspect.state()
      %Opal.Agent.State{session_id: "abc123", status: :idle, ...}
  """
  @spec state() :: State.t()
  def state, do: Opal.Agent.get_state(agent())

  @spec state(String.t()) :: State.t()
  def state(session_id), do: Opal.Agent.get_state(agent(session_id))

  @doc """
  Returns the current system prompt (including discovered context,
  skill menu, tool guidelines, and runtime instructions).

  This is the *assembled* prompt sent to the LLM, not just the raw
  `system_prompt` field — it includes everything `build_messages/1`
  prepends.

  ## Options

    * `:file` — write to a file path and open it (defaults to a temp `.md` file
      when set to `true`)

  ## Examples

      iex> Opal.Inspect.system_prompt() |> IO.puts()
      You are a coding assistant...

      iex> Opal.Inspect.system_prompt(file: true)
      Wrote system prompt to /tmp/opal-system-prompt.md

      iex> Opal.Inspect.system_prompt("session-id", file: true)
  """
  @spec system_prompt(keyword()) :: String.t() | :ok
  def system_prompt(opts \\ []) when is_list(opts) do
    fetch_and_format_prompt(agent(), opts)
  end

  @spec system_prompt(String.t(), keyword()) :: String.t() | :ok
  def system_prompt(session_id, opts) when is_binary(session_id) do
    fetch_and_format_prompt(agent(session_id), opts)
  end

  defp fetch_and_format_prompt(pid, opts) do
    messages = Opal.Agent.get_context(pid)

    prompt =
      case messages do
        [%{role: :system, content: p} | _] -> p
        _ -> Opal.Agent.get_state(pid).system_prompt
      end

    case Keyword.get(opts, :file) do
      nil -> prompt
      true -> write_and_open(prompt, Path.join(System.tmp_dir!(), "opal-system-prompt.md"))
      path -> write_and_open(prompt, Path.expand(path))
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
    sid = Keyword.get(opts, :session_id)
    s = if sid, do: state(sid), else: state()
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
  @spec tools() :: [{String.t(), module()}]
  def tools, do: Enum.map(state().tools, fn mod -> {mod.name(), mod} end)

  @spec tools(String.t()) :: [{String.t(), module()}]
  def tools(session_id), do: Enum.map(state(session_id).tools, fn mod -> {mod.name(), mod} end)

  @doc """
  Returns the current model.

  ## Examples

      iex> Opal.Inspect.model()
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4"}
  """
  @spec model() :: Opal.Provider.Model.t()
  def model, do: state().model

  @spec model(String.t()) :: Opal.Provider.Model.t()
  def model(session_id), do: state(session_id).model

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
  @spec summary() :: map()
  def summary, do: build_summary(state())

  @spec summary(String.t()) :: map()
  def summary(session_id), do: build_summary(state(session_id))

  defp build_summary(s) do
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

  # ── Agent Actions ──────────────────────────────────────────────────

  @doc """
  Sends a prompt to the agent from IEx.

  ## Examples

      iex> prompt("List all files")
      %{queued: false}
  """
  @spec prompt(String.t()) :: %{queued: boolean()}
  def prompt(text), do: Opal.Agent.prompt(agent(), text)

  @spec prompt(String.t(), String.t()) :: %{queued: boolean()}
  def prompt(session_id, text), do: Opal.Agent.prompt(agent(session_id), text)

  @doc """
  Aborts the currently running agent turn.

  ## Examples

      iex> abort()
      :ok
  """
  @spec abort() :: :ok
  def abort, do: Opal.Agent.abort(agent())

  @spec abort(String.t()) :: :ok
  def abort(session_id), do: Opal.Agent.abort(agent(session_id))

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

  # ── State Dump ──────────────────────────────────────────────────────

  @doc """
  Dumps the full agent state to a temporary file and opens it.

  The state is pretty-printed as an Elixir term and written to
  `/tmp/opal-state-<session_id>.exs`. Returns the file path.

  ## Options

    * `:path` — custom file path (default: auto-generated temp path)
    * `:open` — whether to open the file after writing (default: `true`)

  ## Examples

      iex> Opal.Inspect.dump_state()
      "/tmp/opal-state-abc123def456.exs"

      iex> Opal.Inspect.dump_state(open: false)
      "/tmp/opal-state-abc123def456.exs"

      iex> Opal.Inspect.dump_state("session-id", path: "/tmp/my-dump.exs")
      "/tmp/my-dump.exs"
  """
  @spec dump_state(keyword()) :: String.t()
  def dump_state(opts \\ []) when is_list(opts) do
    s = state()
    do_dump_state(s, opts)
  end

  @spec dump_state(String.t(), keyword()) :: String.t()
  def dump_state(session_id, opts) when is_binary(session_id) do
    s = state(session_id)
    do_dump_state(s, opts)
  end

  defp do_dump_state(%State{} = s, opts) do
    short_id = String.slice(s.session_id, 0, 12)
    default_path = Path.join(System.tmp_dir!(), "opal-state-#{short_id}.exs")
    path = Keyword.get(opts, :path, default_path)
    open? = Keyword.get(opts, :open, true)

    content =
      inspect(s,
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity,
        width: 120
      )

    File.write!(path, content)
    IO.puts(IO.ANSI.green() <> "Wrote agent state to #{path}" <> IO.ANSI.reset())

    if open?, do: open_file(path)

    path
  end

  defp open_file(path) do
    editor = System.get_env("VISUAL") || System.get_env("EDITOR")

    if editor do
      System.cmd(editor, [path], stderr_to_stdout: true)
    else
      case Opal.Platform.os() do
        :macos -> System.cmd("open", [path])
        :linux -> System.cmd("xdg-open", [path])
        :windows -> System.cmd("cmd", ["/c", "start", "", path])
      end
    end
  end

  # ── Conversation Dump ─────────────────────────────────────────────

  @doc """
  Dumps the entire conversation to a folder of linked Markdown files.

  Creates a directory containing:

    * `index.md` — debug info + main conversation thread
    * `system-prompt.md` — the full assembled system prompt
    * `sub-agent-<N>.md` — one file per sub-agent invocation, linked
      from `index.md` at the point where the sub-agent was called

  Returns the folder path and prints it to the console. The `index.md`
  file is opened automatically unless `:open` is `false`.

  ## Options

    * `:path` — custom folder path (default: auto-generated in tmp)
    * `:open` — whether to open `index.md` after writing (default: `true`)

  ## Examples

      iex> Opal.Inspect.dump_conversation()
      "/tmp/opal-conversation-abc123def456/"

      iex> Opal.Inspect.dump_conversation(open: false)
      "/tmp/opal-conversation-abc123def456/"

      iex> Opal.Inspect.dump_conversation("session-id")
      "/tmp/opal-conversation-session-id/"
  """
  @spec dump_conversation(keyword()) :: String.t()
  def dump_conversation(opts \\ []) when is_list(opts) do
    pid = agent()
    do_dump_conversation(pid, Opal.Agent.get_state(pid), opts)
  end

  @spec dump_conversation(String.t(), keyword()) :: String.t()
  def dump_conversation(session_id, opts) when is_binary(session_id) do
    pid = agent(session_id)
    do_dump_conversation(pid, Opal.Agent.get_state(pid), opts)
  end

  defp do_dump_conversation(pid, %State{} = s, opts) do
    short_id = String.slice(s.session_id, 0, 12)
    default_dir = Path.join(System.tmp_dir!(), "opal-conversation-#{short_id}")
    dir = Keyword.get(opts, :path, default_dir)
    open? = Keyword.get(opts, :open, true)

    # Ensure a clean output directory
    if File.exists?(dir), do: File.rm_rf!(dir)
    File.mkdir_p!(dir)

    context_messages = Opal.Agent.get_context(pid)
    active = Opal.Agent.Tools.active_tools(s)

    # Extract system prompt into its own file
    {system_prompt, conversation_messages} = split_system_prompt(context_messages)
    File.write!(Path.join(dir, "system-prompt.md"), render_system_prompt_file(system_prompt))

    # Identify sub-agent calls and write each to a separate file.
    # Returns a map of call_id → filename for linking from the index.
    sub_agent_files = write_sub_agent_files(dir, conversation_messages)

    # Write the main index
    index_md = render_index(s, active, conversation_messages, sub_agent_files)
    index_path = Path.join(dir, "index.md")
    File.write!(index_path, index_md)

    IO.puts(IO.ANSI.green() <> "Wrote conversation dump to #{dir}/" <> IO.ANSI.reset())

    if open?, do: open_file(index_path)

    dir
  end

  # ── System prompt ──────────────────────────────────────────────────

  defp split_system_prompt([%Opal.Message{role: :system, content: content} | rest]),
    do: {content, rest}

  defp split_system_prompt(messages), do: {nil, messages}

  defp render_system_prompt_file(nil), do: "# System Prompt\n\n_No system prompt._\n"

  defp render_system_prompt_file(content) do
    "# System Prompt\n\n" <>
      "[← Back to conversation](index.md)\n\n" <>
      "#{String.length(content)} characters\n\n---\n\n" <>
      content <> "\n"
  end

  # ── Sub-agent extraction ───────────────────────────────────────────

  # Scans messages for sub_agent tool calls and their corresponding
  # tool results. Writes each pair to `sub-agent-<N>.md` and returns
  # a map of %{call_id => filename} for linking.
  defp write_sub_agent_files(dir, messages) do
    # Build a lookup of call_id → tool_result content
    result_by_call_id =
      messages
      |> Enum.filter(&(&1.role == :tool_result))
      |> Map.new(&{&1.call_id, &1})

    # Find all sub_agent tool calls (both in assistant.tool_calls and
    # standalone :tool_call messages)
    sub_agent_calls = collect_sub_agent_calls(messages)

    sub_agent_calls
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {{call_id, prompt, args_json}, idx}, acc ->
      filename = "sub-agent-#{idx}.md"
      result_msg = Map.get(result_by_call_id, call_id)

      md = render_sub_agent_file(idx, call_id, prompt, args_json, result_msg)
      File.write!(Path.join(dir, filename), md)

      Map.put(acc, call_id, filename)
    end)
  end

  # Collects {call_id, prompt, args_json} tuples for every sub_agent invocation.
  defp collect_sub_agent_calls(messages) do
    Enum.flat_map(messages, fn
      %Opal.Message{role: :assistant, tool_calls: tcs} when is_list(tcs) ->
        tcs
        |> Enum.filter(fn tc -> (tc[:name] || tc["name"]) == "sub_agent" end)
        |> Enum.map(fn tc ->
          cid = tc[:call_id] || tc["call_id"]
          args = tc[:arguments] || tc["arguments"] || %{}
          prompt = args["prompt"] || Map.get(args, :prompt, "")
          {cid, prompt, args}
        end)

      %Opal.Message{role: :tool_call, name: "sub_agent", call_id: cid, content: content} ->
        args = decode_json(content)
        prompt = args["prompt"] || ""
        [{cid, prompt, args}]

      _ ->
        []
    end)
  end

  defp render_sub_agent_file(idx, call_id, prompt, args, result_msg) do
    header =
      "# Sub-Agent ##{idx}\n\n" <>
        "[← Back to conversation](index.md)\n\n" <>
        "| Key | Value |\n" <>
        "|-----|-------|\n" <>
        "| Call ID | `#{call_id}` |\n"

    # Show extra args (model, system_prompt, tools) if provided
    extra_args =
      args
      |> Map.drop(["prompt", :prompt])
      |> Enum.map_join("", fn {k, v} ->
        "| #{k} | `#{inspect(v, limit: 200)}` |\n"
      end)

    prompt_section = "\n## Prompt\n\n#{prompt}\n"

    result_section =
      case result_msg do
        %Opal.Message{content: content, is_error: is_error} ->
          status = if is_error, do: " [ERROR]", else: ""

          "\n## Result#{status}\n\n" <>
            fence_content(content || "_empty_")

        nil ->
          "\n## Result\n\n_No result found._\n"
      end

    header <> extra_args <> prompt_section <> result_section
  end

  # ── Index rendering ────────────────────────────────────────────────

  defp render_index(%State{} = s, active_tools, messages, sub_agent_files) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    sections = [
      "# Opal Conversation Dump\n",
      "_Generated at #{ts}_\n",
      render_debug_info(s, active_tools),
      render_messages(messages, sub_agent_files)
    ]

    Enum.join(sections, "\n")
  end

  defp render_debug_info(%State{} = s, active_tools) do
    tool_names = Enum.map(active_tools, & &1.name()) |> Enum.sort()
    all_tool_names = Enum.map(s.tools, & &1.name()) |> Enum.sort()
    disabled = s.disabled_tools |> Enum.sort()
    skills_available = Enum.map(s.available_skills, & &1.name) |> Enum.sort()

    usage = s.token_usage

    lines = [
      "## Debug Info\n",
      "| Key | Value |",
      "|-----|-------|",
      "| Session ID | `#{s.session_id}` |",
      "| Status | `#{s.status}` |",
      "| Model | `#{s.model.provider}:#{s.model.id}` |",
      "| Provider | `#{inspect(s.provider)}` |",
      "| Working Dir | `#{s.working_dir}` |",
      "| Messages | #{length(s.messages)} |",
      "| Retry Count | #{s.retry_count} / #{s.max_retries} |",
      "| Overflow | #{s.overflow_detected} |",
      "",
      "### Token Usage\n",
      "| Metric | Value |",
      "|--------|-------|",
      "| Prompt Tokens | #{Map.get(usage, :prompt_tokens, 0)} |",
      "| Completion Tokens | #{Map.get(usage, :completion_tokens, 0)} |",
      "| Total Tokens | #{Map.get(usage, :total_tokens, 0)} |",
      "| Context Window | #{Map.get(usage, :context_window, 0)} |",
      "| Current Context | #{Map.get(usage, :current_context_tokens, 0)} |",
      "",
      "### Active Tools (#{length(tool_names)})\n",
      format_list(tool_names),
      "",
      "### All Registered Tools (#{length(all_tool_names)})\n",
      format_list(all_tool_names),
      "",
      if(disabled != [], do: "### Disabled Tools\n\n#{format_list(disabled)}\n", else: ""),
      "### Context Files\n",
      if(s.context_files == [], do: "_none_", else: format_list(s.context_files)),
      "",
      "### Skills\n",
      "**Available:** #{if(skills_available == [], do: "_none_", else: Enum.join(skills_available, ", "))}",
      "**Active:** #{if(s.active_skills == [], do: "_none_", else: Enum.join(s.active_skills, ", "))}",
      "",
      "### MCP Servers\n",
      if(s.mcp_servers == [],
        do: "_none_",
        else: fence_content(Jason.encode!(s.mcp_servers, pretty: true), "json")
      ),
      "",
      "**System Prompt →** [system-prompt.md](system-prompt.md)\n",
      "---\n"
    ]

    Enum.join(lines, "\n")
  end

  # ── Message rendering ─────────────────────────────────────────────

  defp render_messages(messages, sub_agent_files) do
    header = "## Conversation\n\n"

    body =
      messages
      |> Enum.map_join("\n---\n\n", &render_message(&1, sub_agent_files))

    header <> body
  end

  defp render_message(%Opal.Message{role: :user, content: content, id: id}, _sa) do
    "### 👤 User `#{short_id(id)}`\n\n#{content}\n"
  end

  defp render_message(
         %Opal.Message{
           role: :assistant,
           content: content,
           thinking: thinking,
           tool_calls: tool_calls,
           id: id
         },
         sub_agent_files
       ) do
    parts = ["### 🤖 Assistant `#{short_id(id)}`\n"]

    parts =
      if thinking && thinking != "" do
        parts ++ ["\n**Thinking:**\n\n#{fence_content(thinking)}\n"]
      else
        parts
      end

    parts =
      if content && content != "" do
        parts ++ ["\n#{content}\n"]
      else
        parts ++ ["\n_no text content_\n"]
      end

    parts =
      if tool_calls && tool_calls != [] do
        tc_section =
          Enum.map_join(tool_calls, "\n", fn tc ->
            name = tc[:name] || tc["name"]
            cid = tc[:call_id] || tc["call_id"]
            args = format_json(tc[:arguments] || tc["arguments"] || %{})

            sub_link =
              case Map.get(sub_agent_files, cid) do
                nil -> ""
                file -> "\n\n🔗 **Sub-agent thread →** [#{file}](#{file})\n"
              end

            "**Tool Call:** `#{name}` (call_id: `#{cid}`)\n\n" <>
              fence_content(args, "json") <>
              sub_link
          end)

        parts ++ ["\n#{tc_section}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp render_message(
         %Opal.Message{
           role: :tool_call,
           name: name,
           call_id: call_id,
           content: content,
           id: id
         },
         sub_agent_files
       ) do
    args = format_json_string(content)

    sub_link =
      case Map.get(sub_agent_files, call_id) do
        nil -> ""
        file -> "\n🔗 **Sub-agent thread →** [#{file}](#{file})\n"
      end

    "### 🔧 Tool Call `#{short_id(id)}` — `#{name}`\n\n" <>
      "Call ID: `#{call_id}`\n\n" <>
      fence_content(args, "json") <>
      sub_link
  end

  defp render_message(
         %Opal.Message{
           role: :tool_result,
           call_id: call_id,
           content: content,
           is_error: is_error,
           id: id
         },
         sub_agent_files
       ) do
    status = if is_error, do: "ERROR", else: "OK"

    # If this is a sub-agent result, show a short summary with link
    case Map.get(sub_agent_files, call_id) do
      nil ->
        preview = truncate_content(content, 5_000)

        "### 📤 Tool Result `#{short_id(id)}` [#{status}]\n\n" <>
          "Call ID: `#{call_id}`\n\n" <>
          fence_content(preview)

      file ->
        "### 📤 Tool Result `#{short_id(id)}` [#{status}] — Sub-Agent\n\n" <>
          "Call ID: `#{call_id}`\n\n" <>
          "🔗 **Full sub-agent conversation →** [#{file}](#{file})\n"
    end
  end

  defp render_message(%Opal.Message{role: role, content: content, id: id}, _sa) do
    "### #{to_string(role) |> String.capitalize()} `#{short_id(id)}`\n\n" <>
      fence_content(content || "_empty_")
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp short_id(nil), do: "?"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp format_list([]), do: "_none_"
  defp format_list(items), do: Enum.map_join(items, "\n", &"- `#{&1}`")

  defp format_json(data) when is_map(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true, limit: :infinity)
    end
  end

  defp format_json(data), do: inspect(data, pretty: true, limit: :infinity)

  defp format_json_string(nil), do: "{}"

  defp format_json_string(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end

  defp decode_json(nil), do: %{}

  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  # Wraps content in a fenced code block, choosing a fence marker that
  # doesn't collide with the content itself (avoids the backtick-in-
  # system-prompt rendering bug).
  defp fence_content(content, lang \\ "") do
    fence = pick_fence(content)
    "#{fence}#{lang}\n#{content}\n#{fence}\n"
  end

  defp pick_fence(content) when is_binary(content) do
    if String.contains?(content, "```") do
      if String.contains?(content, "````") do
        "`````"
      else
        "````"
      end
    else
      "```"
    end
  end

  defp pick_fence(_), do: "```"

  defp truncate_content(nil, _max), do: "_empty_"

  defp truncate_content(content, max) when is_binary(content) do
    if String.length(content) > max do
      String.slice(content, 0, max) <>
        "\n\n… (truncated, #{String.length(content)} chars total)"
    else
      content
    end
  end

  defp write_and_open(content, path) do
    File.write!(path, content)
    IO.puts(IO.ANSI.green() <> "Wrote system prompt to #{path}" <> IO.ANSI.reset())
    open_file(path)
    :ok
  end
end
