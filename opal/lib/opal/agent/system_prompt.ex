defmodule Opal.Agent.SystemPrompt do
  @moduledoc """
  Builds the structured system prompt for Opal agents.

  This is the **single module** that owns all system prompt concerns:
  identity, project context formatting, skill menus, environment info,
  tool-usage guidelines, and planning — assembled into one coherent
  prompt via `build/1`.

  ## Prompt layout (top → bottom)

      1. <identity>         — core personality (or caller-provided override)
      2. <project-context>  — discovered AGENTS.md / OPAL.md files
      3. <skills>           — progressive-disclosure skill menu
      4. <environment>      — working directory, runtime info
      5. <tool-guidelines>  — conditional tool-usage rules
      6. <planning>         — plan.md location (interactive sessions only)

  Each section is wrapped in XML-style tags so the model can clearly
  distinguish boundaries.

  ## How tools reach the model

  Every tool — built-in, custom, and MCP — is exposed to the model via
  the provider's `convert_tools/1`, which serialises each module's
  `name()`, `description()`, and `parameters()` into the API's `tools`
  array. That is the primary mechanism; the model learns what each tool
  does from its own schema and description.

  ## Tool guidelines

  This module also produces *additional* natural-language steering via
  `build_guidelines/1`. It exists because LLMs have a strong tendency
  to reach for shell commands (`cat`, `sed`, `echo >`) even when
  dedicated tools (`read_file`, `edit_file`, `write_file`) are
  available.

  The guidelines are **conditional**: they only mention tools that are
  actually active, so the model never receives instructions about tools
  it can't call. They are rebuilt every turn because the active tool
  set can change mid-session (e.g. MCP servers connecting, feature
  flags toggling).

  ## Editing rules

  Rules are defined as a flat `{condition, text}` table inside
  `guidelines/1` — scan that single function to see every guideline
  the model can receive and the condition that activates it.
  To add or edit a rule, touch only that table.
  """

  alias Opal.Agent.State

  # ── Full prompt assembly ───────────────────────────────────────────────

  @doc """
  Assembles the complete system prompt from agent state.

  Combines identity, project context, skills, environment, tool
  guidelines, and planning into a single string. Called on every turn
  by `Opal.Agent` so the prompt reflects the latest tool set and
  active skills.

  Returns `nil` when there is nothing to include (no custom prompt,
  no context, no tools).
  """
  @spec build(State.t()) :: String.t() | nil
  def build(%State{} = state) do
    sections = [
      build_identity_section(state),
      format_context_entries(state.context_entries),
      format_skills(state.available_skills, state.config),
      format_environment(state.working_dir),
      build_guidelines(Opal.Agent.Tools.active_tools(state), state),
      format_planning(state)
    ]

    case Enum.reject(sections, &(&1 == "" or is_nil(&1))) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # ── Identity ───────────────────────────────────────────────────────────

  @doc """
  Returns the core identity and behavioural instructions for the agent.

  This is placed at the very top of the system prompt so the model has
  a clear sense of role, personality and ground rules before any
  project-specific context is injected.

  Callers can override the system prompt entirely via the `:system_prompt`
  option when starting a session — in that case this identity block is
  not used (the caller's prompt replaces it).
  """
  @spec build_identity() :: String.t()
  def build_identity do
    """
    <identity>
    You are Opal, an expert AI coding assistant.

    You help users understand, create, debug, and improve code. You have
    access to tools for reading and editing files, running shell commands,
    and delegating work to sub-agents.

    ## Principles

    - **Be direct** — answer concisely; expand only when the task is complex
      or the user asks for detail.
    - **Act, don't ask** — when intent is clear, use tools and make changes
      rather than describing what you would do. Infer missing details from
      context instead of asking.
    - **Verify your work** — after making changes, check for errors and run
      relevant tests when available.
    - **Be honest** — if you are unsure or lack context, say so. Never
      fabricate file contents, paths, or tool output.
    - **Respect boundaries** — do not modify files outside the working
      directory without explicit instruction. Never execute destructive
      commands (rm -rf /, DROP DATABASE, etc.) without confirmation.
    - **Stay on task** — focus on the user's request. Avoid unsolicited
      refactoring, style changes, or tangential suggestions.
    - **Be joyful** — we're serious, focused and creative, but with intelligence comes wit and warmth.
    </identity>
    """
    |> String.trim()
  end

  # Uses the caller's system_prompt if provided, otherwise the default identity.
  defp build_identity_section(%State{system_prompt: prompt}) do
    case prompt do
      p when p in ["", nil] -> build_identity()
      custom -> custom
    end
  end

  # ── Project context ────────────────────────────────────────────────────

  @doc """
  Formats discovered context file entries into XML-tagged blocks.

  Each file is wrapped in `<project-context source="...">` tags.
  Returns an empty string if no entries are present.
  """
  @spec format_context_entries([%{path: String.t(), content: String.t()}]) :: String.t()
  def format_context_entries([]), do: ""

  def format_context_entries(entries) do
    Enum.map_join(entries, "\n\n", fn %{path: path, content: content} ->
      "<project-context source=\"#{path}\">\n#{content}\n</project-context>"
    end)
  end

  # ── Skills ─────────────────────────────────────────────────────────────

  @doc """
  Formats available skills into an XML-tagged menu block.

  Returns an empty string if skills are disabled or none are available.
  """
  @spec format_skills([Opal.Skill.t()], Opal.Config.t()) :: String.t()
  def format_skills(skills, config)

  def format_skills([], _config), do: ""

  def format_skills(skills, config) do
    if config.features.skills.enabled do
      lines =
        Enum.map_join(skills, "\n", fn skill ->
          "- **#{skill.name}**: #{skill.description}"
        end)

      """
      <skills>
      Use the `use_skill` tool to load a skill's full instructions when relevant.

      #{lines}
      </skills>\
      """
    else
      ""
    end
  end

  # ── Environment ────────────────────────────────────────────────────────

  @doc """
  Formats environment/runtime context (working directory, etc.).
  """
  @spec format_environment(String.t() | nil) :: String.t()
  def format_environment(working_dir)
      when is_binary(working_dir) and working_dir != "" do
    """
    <environment>
    Current working directory: `#{working_dir}`

    Shell commands already run from this directory by default. Do not prepend `cd` to the same directory unless you intentionally need a different location.
    </environment>\
    """
  end

  def format_environment(_), do: ""

  # ── Planning ───────────────────────────────────────────────────────────

  @doc """
  Formats planning instructions for interactive sessions.

  Returns an empty string for sub-agents (no session).
  """
  @spec format_planning(State.t()) :: String.t()
  def format_planning(%State{session: nil}), do: ""

  def format_planning(%State{config: config, session_id: session_id}) do
    session_dir = Path.join(Opal.Config.sessions_dir(config), session_id)

    """
    <planning>
    For complex multi-step tasks, create a plan document at:
      #{session_dir}/plan.md

    Write your plan before starting implementation. Update it as you
    complete steps. The user can review the plan at any time with Ctrl+Y.
    </planning>\
    """
  end

  # ── Tool guidelines ────────────────────────────────────────────────────

  @doc """
  Builds tool-specific usage guidelines from the list of active tool modules.

  Returns a markdown string to append to the system prompt, or an empty
  string if no guidelines apply. The block is wrapped in `<tool-guidelines>`
  XML tags so the model can clearly distinguish it from other sections.

  ## Example

      iex> modules = [Opal.Tool.Read, Opal.Tool.Edit, Opal.Tool.Shell]
      iex> guidelines = Opal.Agent.SystemPrompt.build_guidelines(modules)
      iex> guidelines =~ "read_file"
      true
  """
  @spec build_guidelines([module()], State.t() | nil) :: String.t()
  def build_guidelines(tools, state \\ nil) do
    names = tools |> Enum.map(& &1.name()) |> MapSet.new()

    case guidelines(names, state) do
      [] ->
        ""

      items ->
        body = Enum.map_join(items, "\n", &("- " <> &1))

        """

        <tool-guidelines>
        #{body}
        </tool-guidelines>
        """
        |> String.trim_trailing()
    end
  end

  # ── Rule table ──────────────────────────────────────────────────────
  #
  # Each entry is  {boolean_condition, text | [text]}.
  #
  # • Conditions are evaluated when the list is built — only truthy
  #   entries survive the `for` comprehension at the bottom.
  # • To add a rule:  append a new {condition, "…"} tuple.
  # • To edit wording: change the string in-place.
  # • To reorder rules in the final prompt: move the tuple.

  # Builds a list of guideline strings based on which tools are active.
  #
  # LLMs tend to reach for shell commands even when dedicated tools exist —
  # e.g. `cat` instead of `read_file`, `sed` instead of `edit_file`. This
  # breaks the tool chain (read_file produces hash-anchored lines that
  # edit_file depends on, write_file emits events, etc.).
  #
  # Each rule is a {condition, text} tuple. The condition is a plain boolean
  # computed from `names` (the active tool name set). The `for` comprehension
  # at the end pattern-matches `{true, _}`, so false-guarded rules are
  # silently dropped and only matching guidelines make it into the prompt.
  defp guidelines(names, state) do
    # Is any shell-type tool active? (shell, bash, zsh, cmd, powershell)
    shell? = not MapSet.disjoint?(names, Opal.Tool.Shell.shell_names())
    # Shorthand: is a specific tool name present?
    has? = &MapSet.member?(names, &1)

    rules = [
      # When both read_file and a shell exist, stop the model from using
      # cat/head/tail — those bypass hash-tagged output that edit_file needs.
      {has?.("read_file") and shell?,
       [
         "Use the `read_file` tool to read files. " <>
           "Do NOT use `cat`, `head`, `tail`, or `less` via shell.",
         "Use `read_file` with `offset` and `limit` to read specific line ranges."
       ]},

      # When both edit_file and a shell exist, stop the model from using
      # sed/awk/perl — those bypass hash-anchored editing and event emission.
      {has?.("edit_file") and shell?,
       "Use the `edit_file` tool for all file modifications. " <>
         "Do NOT use `sed`, `awk`, `perl -i`, or shell redirects (`>`, `>>`)."},

      # write_file creates parent dirs and emits events; shell redirects don't.
      {has?.("write_file"),
       "Use the `write_file` tool to create new files. " <>
         "Do NOT use shell redirects or `tee`."},

      # Models like to `cat` a file they just created to "show" the user.
      # The TUI already displays tool results, so this wastes tokens.
      {shell?,
       "When summarizing your actions, output plain text directly in your response. " <>
         "Do NOT use `cat`, `echo`, or shell to display files you just wrote."},

      # Opposite case: if shell is the *only* file tool (no read_file),
      # then cat/grep/find *are* the right tools — encourage them.
      {shell? and not has?.("read_file"),
       "Use shell commands like `cat`, `grep`, `find`, and `ls` for file exploration."},

      # With 3+ tools, parallel independent calls save round-trips.
      # Skipped for ≤2 tools where parallelism opportunities are rare.
      {MapSet.size(names) >= 3,
       [
         "Check that all the required parameters for each tool call are provided " <>
           "or can reasonably be inferred from context. " <>
           "IF there are no relevant tools or there are missing values for required parameters, " <>
           "ask the user to supply these values; otherwise proceed with the tool calls. " <>
           "If the user provides a specific value for a parameter (for example provided in quotes), " <>
           "make sure to use that value EXACTLY. DO NOT make up values for or ask about optional parameters.",
         "If you intend to call multiple tools and there are no dependencies between the calls, " <>
           "make all of the independent calls in the same response rather than sequentially, " <>
           "otherwise you MUST wait for previous calls to finish first to determine the " <>
           "dependent values (do NOT use placeholders or guess missing parameters)."
       ]},

      # sub_agent spawns a child agent for independent workstreams.
      # Warn against overuse — simple sequential tasks don't need delegation.
      # Include available sibling models so the agent can pick cheaper ones.
      {has?.("sub_agent"),
       [
         "Use `sub_agent` to delegate independent workstreams that can run in parallel. " <>
           "Avoid sub-agents for simple tasks a single tool call can handle."
         | format_available_models(state)
       ]},

      # Status tags let the TUI show progress during multi-step work.
      # Active whenever the agent has any tools (i.e. can do real work).
      {MapSet.size(names) > 0,
       "Before starting each major step in a multi-step task, emit a short status tag: " <>
         "`<status>Analyzing test failures</status>`. Keep it under 6 words. " <>
         "This is displayed as a progress indicator and stripped from your output. " <>
         "Only emit when the task involves multiple steps — skip for simple questions."},

      # Title generation: on the first turn of a new session, ask the model
      # to emit a <title> tag so we can extract it without a separate LLM call.
      {needs_title?(state),
       "This is the start of a new conversation. Emit a concise 3-6 word title for it " <>
         "at the very beginning of your response: `<title>Refactor auth module</title>`. " <>
         "The tag is stripped from your visible output. Do not use quotes or punctuation in the title."}
    ]

    # Pattern-match {true, _} to keep only active rules; List.wrap
    # normalizes single strings and lists into a flat list of guideline texts.
    for {true, texts} <- rules, text <- List.wrap(texts), do: text
  end

  # Returns a list of guideline strings describing available models for
  # sub-agent delegation.  Queries LLMDB for all active, non-deprecated
  # models from the same provider, formats each as "id (Name) [tags]",
  # and wraps them in a single guideline line.
  #
  # Returns [] when state is nil, the provider is unknown, or no sibling
  # models are found — the caller prepends/appends to a list, so an empty
  # list simply contributes nothing.
  defp format_available_models(nil), do: []

  defp format_available_models(%State{model: model}) do
    provider = model.provider
    llmdb_provider = if provider == :copilot, do: :github_copilot, else: provider

    models =
      LLMDB.models()
      |> Enum.filter(fn m ->
        m.provider == llmdb_provider and not m.deprecated and not m.retired
      end)
      |> Enum.sort_by(& &1.id)

    case models do
      [] ->
        []

      models ->
        current_id = model.id

        entries =
          Enum.map_join(models, ", ", fn m ->
            label = format_model_entry(m)
            if m.id == current_id, do: label <> " (current)", else: label
          end)

        [
          "Available models for sub-agents: #{entries}. " <>
            "Use smaller/faster models for simple sub-tasks to save tokens."
        ]
    end
  rescue
    _ -> []
  end

  # Formats a single model entry: "id" or "id [tag1, tag2]" if tags exist.
  defp format_model_entry(%{id: id, tags: tags}) when is_list(tags) and tags != [] do
    "#{id} [#{Enum.join(tags, ", ")}]"
  end

  defp format_model_entry(%{id: id}), do: id

  # Returns true when the agent should ask the model to emit a <title> tag.
  # Conditions: auto_title enabled, session attached, first turn (≤ 1 message),
  # and no title already set on the session.
  defp needs_title?(nil), do: false

  defp needs_title?(%State{config: config, session: session, messages: messages}) do
    config.auto_title and session != nil and length(messages) <= 1 and
      Opal.Session.get_metadata(session, :title) == nil
  end
end
