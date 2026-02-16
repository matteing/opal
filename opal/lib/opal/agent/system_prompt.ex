defmodule Opal.Agent.SystemPrompt do
  @moduledoc """
  Generates dynamic system prompt guidelines based on active tools.

  Inspects the set of available tools and produces instructions that
  prevent common LLM mistakes: using shell commands for operations
  that have dedicated tools, displaying file contents via shell instead
  of directly, or using `sed`/`awk` when `edit_file` is available.

  The rule system is composable — new rules can be added as simple
  functions without touching the rest of the codebase.
  """

  @doc """
  Builds tool-specific usage guidelines from the list of active tool modules.

  Returns a markdown string to append to the system prompt, or an empty
  string if no guidelines apply.

  ## Example

      iex> modules = [Opal.Tool.Read, Opal.Tool.Edit, Opal.Tool.Shell]
      iex> guidelines = Opal.Agent.SystemPrompt.build_guidelines(modules)
      iex> guidelines =~ "read_file"
      true
  """
  @spec build_guidelines([module()]) :: String.t()
  def build_guidelines(tools) do
    # Collect tool names into a set for O(1) membership checks
    names = tools |> Enum.map(& &1.name()) |> MapSet.new()
    rules = collect_rules(names)

    case rules do
      [] ->
        ""

      list ->
        header = "\n\n## Tool Usage Guidelines\n\n"
        body = Enum.map_join(list, "\n", &("- " <> &1))
        header <> body
    end
  end

  # -- Rule collection --------------------------------------------------------
  #
  # Each rule function returns nil (not applicable), a string, or a list of
  # strings. New rules are added by defining a new function and adding it
  # to the pipeline below.

  defp collect_rules(names) do
    [
      &read_vs_shell/1,
      &edit_vs_shell/1,
      &write_guidelines/1,
      &shell_display_warning/1,
      &search_guidelines/1,
      &parallel_tool_calls/1,
      &sub_agent_parallelism/1,
      &status_tags/1
    ]
    |> Enum.flat_map(fn rule_fn ->
      case rule_fn.(names) do
        nil -> []
        rules when is_list(rules) -> rules
        rule when is_binary(rule) -> [rule]
      end
    end)
  end

  # -- Individual rules -------------------------------------------------------

  # When read_file and a shell are both available, prefer the dedicated tool.
  defp read_vs_shell(names) do
    if "read_file" in names and has_shell?(names) do
      [
        "Use the `read_file` tool to read files. Do NOT use `cat`, `head`, `tail`, or `less` via shell.",
        "Use `read_file` with `offset` and `limit` to read specific line ranges."
      ]
    end
  end

  # When edit_file and a shell are both available, prevent sed/awk/perl usage.
  defp edit_vs_shell(names) do
    if "edit_file" in names and has_shell?(names) do
      "Use the `edit_file` tool for all file modifications. Do NOT use `sed`, `awk`, `perl -i`, or shell redirects (`>`, `>>`)."
    end
  end

  # When write_file is available, prevent shell-based file creation.
  defp write_guidelines(names) do
    if "write_file" in names do
      "Use the `write_file` tool to create new files. Do NOT use shell redirects or `tee`."
    end
  end

  # When any shell tool is available, prevent using it to "show" files.
  defp shell_display_warning(names) do
    if has_shell?(names) do
      "When summarizing your actions, output plain text directly in your response. Do NOT use `cat`, `echo`, or shell to display files you just wrote."
    end
  end

  # When shell is the only file tool (no read/edit), suggest shell file commands.
  defp search_guidelines(names) do
    if has_shell?(names) and "read_file" not in names do
      "Use shell commands like `cat`, `grep`, `find`, and `ls` for file exploration."
    end
  end

  # -- Parallelism rules ------------------------------------------------------

  # When multiple tools are available, encourage batching independent calls
  # into a single response so the runtime can execute them concurrently.
  # The threshold of 3+ tools filters out degenerate cases (e.g. only
  # read_file + shell) where parallelism opportunities are rare.
  defp parallel_tool_calls(names) do
    if MapSet.size(names) >= 3 do
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
      ]
    end
  end

  # When sub_agent is available, encourage using it for independent parallel
  # workstreams while warning against overuse on simple sequential tasks.
  defp sub_agent_parallelism(names) do
    if "sub_agent" in names do
      "Use `sub_agent` to delegate independent workstreams that can run in parallel. " <>
        "Avoid sub-agents for simple tasks a single tool call can handle."
    end
  end

  # -- Helpers ----------------------------------------------------------------

  # Checks if any shell-type tool is in the active set.
  defp has_shell?(names) do
    Enum.any?(["shell", "bash", "zsh", "cmd", "powershell"], &(&1 in names))
  end

  # Instructs the model to emit short status tags during complex tasks.
  @known_tools MapSet.new([
                 "read_file",
                 "edit_file",
                 "write_file",
                 "shell",
                 "bash",
                 "zsh",
                 "cmd",
                 "powershell",
                 "sub_agent",
                 "tasks",
                 "use_skill"
               ])

  defp status_tags(names) do
    if MapSet.size(MapSet.intersection(names, @known_tools)) > 0 do
      "Before starting each major step in a multi-step task, emit a short status tag: `<status>Analyzing test failures</status>`. Keep it under 6 words. This is displayed as a progress indicator and stripped from your output. Only emit when the task involves multiple steps — skip for simple questions."
    end
  end
end
