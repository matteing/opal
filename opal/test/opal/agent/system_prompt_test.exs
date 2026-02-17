defmodule Opal.Agent.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.SystemPrompt

  # -- Stub tool modules ------------------------------------------------------
  #
  # Minimal modules that implement name/0 so we can test guideline generation
  # without loading the real tool modules and their dependencies.

  defmodule ReadStub do
    def name, do: "read_file"
  end

  defmodule EditStub do
    def name, do: "edit_file"
  end

  defmodule WriteStub do
    def name, do: "write_file"
  end

  defmodule ShellStub do
    def name, do: "shell"
  end

  defmodule BashStub do
    def name, do: "bash"
  end

  defmodule PowerShellStub do
    def name, do: "powershell"
  end

  defmodule SubAgentStub do
    def name, do: "sub_agent"
  end

  defmodule TasksStub do
    def name, do: "tasks"
  end

  defmodule CustomStub do
    def name, do: "custom_tool"
  end

  # -- Tests ------------------------------------------------------------------

  describe "build_guidelines/1" do
    test "produces all rules when all standard tools are active" do
      tools = [ReadStub, EditStub, WriteStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "<tool-guidelines>"
      assert result =~ "read_file"
      assert result =~ "edit_file"
      assert result =~ "write_file"
      assert result =~ "Do NOT use `cat`"
      assert result =~ "Do NOT use `sed`"
    end

    test "returns empty string when no tools are active" do
      assert SystemPrompt.build_guidelines([]) == ""
    end

    test "emits only status tags when only custom tools are active" do
      result = SystemPrompt.build_guidelines([CustomStub])
      assert result =~ "<status>"
      refute result =~ "read_file"
      refute result =~ "shell"
    end

    test "produces shell-only rules when only shell is active" do
      result = SystemPrompt.build_guidelines([ShellStub])

      assert result =~ "<tool-guidelines>"
      # Should suggest using shell for file exploration
      assert result =~ "grep"
      # Should NOT mention read_file or edit_file
      refute result =~ "read_file"
      refute result =~ "edit_file"
    end

    test "no read-vs-shell rule when read_file is active but no shell" do
      result = SystemPrompt.build_guidelines([ReadStub])

      # Should not produce the "don't use cat" rule when no shell exists
      refute result =~ "Do NOT use `cat`"
    end

    test "no edit-vs-shell rule when edit_file is active but no shell" do
      result = SystemPrompt.build_guidelines([EditStub])

      refute result =~ "Do NOT use `sed`"
    end

    test "recognizes alternative shell names (bash, powershell)" do
      result = SystemPrompt.build_guidelines([ReadStub, BashStub])
      assert result =~ "Do NOT use `cat`"

      result2 = SystemPrompt.build_guidelines([ReadStub, PowerShellStub])
      assert result2 =~ "Do NOT use `cat`"
    end

    test "produces write guidelines even without shell" do
      result = SystemPrompt.build_guidelines([WriteStub])
      assert result =~ "write_file"
    end

    test "shell display warning is present when shell is active" do
      result = SystemPrompt.build_guidelines([ShellStub])
      assert result =~ "output plain text directly"
    end

    test "returns rules as a bulleted list" do
      result = SystemPrompt.build_guidelines([ReadStub, ShellStub])
      # Each rule should be prefixed with "- "
      lines = result |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- "))
      assert length(lines) >= 2
    end
  end

  describe "parallel tool calls" do
    test "emits parallel call guidance when 3+ tools are active" do
      tools = [ReadStub, WriteStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "no dependencies between the calls"
      assert result =~ "independent calls in the same response"
    end

    test "does not emit parallel call guidance with only 2 tools" do
      tools = [ReadStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      refute result =~ "no dependencies between the calls"
    end

    test "includes parameter validation guidance with 3+ tools" do
      tools = [ReadStub, WriteStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "required parameters"
      assert result =~ "DO NOT make up values"
    end

    test "warns against using placeholders for dependent values" do
      tools = [ReadStub, EditStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "do NOT use placeholders"
    end
  end

  describe "sub-agent parallelism" do
    test "emits sub-agent guidance when sub_agent tool is active" do
      tools = [ReadStub, ShellStub, SubAgentStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "sub_agent"
      assert result =~ "independent workstreams"
    end

    test "does not emit sub-agent guidance when sub_agent is absent" do
      tools = [ReadStub, WriteStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      refute result =~ "sub_agent"
      refute result =~ "independent workstreams"
    end

    test "warns against overuse on simple tasks" do
      tools = [SubAgentStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "Avoid sub-agents for simple tasks"
    end

    test "lists available models from same provider when state is provided" do
      tools = [SubAgentStub, ShellStub]

      state = %Opal.Agent.State{
        session_id: "test-123",
        model: %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4"},
        working_dir: "/tmp",
        config: Opal.Config.new()
      }

      result = SystemPrompt.build_guidelines(tools, state)

      assert result =~ "Available models for sub-agents"
      assert result =~ "claude-sonnet-4 (current)"
      assert result =~ "claude-haiku"
      assert result =~ "smaller/faster models"
    end

    test "omits model list when state is nil" do
      tools = [SubAgentStub, ShellStub]
      result = SystemPrompt.build_guidelines(tools)

      assert result =~ "sub_agent"
      refute result =~ "Available models"
    end
  end

  # -- Identity ---------------------------------------------------------------

  describe "build_identity/0" do
    test "returns identity wrapped in XML tags" do
      result = SystemPrompt.build_identity()
      assert result =~ "<identity>"
      assert result =~ "</identity>"
    end

    test "contains the agent name" do
      assert SystemPrompt.build_identity() =~ "Opal"
    end

    test "contains core principles" do
      result = SystemPrompt.build_identity()
      assert result =~ "Be direct"
      assert result =~ "Act, don't ask"
      assert result =~ "Verify your work"
      assert result =~ "Be honest"
    end
  end

  # -- Context formatting -----------------------------------------------------

  describe "format_context_entries/1" do
    test "returns empty string for empty list" do
      assert SystemPrompt.format_context_entries([]) == ""
    end

    test "wraps each file in project-context tags" do
      entries = [
        %{path: "/project/AGENTS.md", content: "Be helpful."}
      ]

      result = SystemPrompt.format_context_entries(entries)
      assert result =~ ~s(<project-context source="/project/AGENTS.md">)
      assert result =~ "Be helpful."
      assert result =~ "</project-context>"
    end

    test "includes multiple files separated by blank lines" do
      entries = [
        %{path: "/root/AGENTS.md", content: "Root context."},
        %{path: "/root/project/AGENTS.md", content: "Project context."}
      ]

      result = SystemPrompt.format_context_entries(entries)
      assert result =~ "Root context."
      assert result =~ "Project context."
      # Two separate blocks
      assert length(String.split(result, "</project-context>")) == 3
    end
  end

  # -- Skills formatting ------------------------------------------------------

  describe "format_skills/2" do
    test "returns empty string when no skills" do
      config = %{features: %{skills: %{enabled: true}}}
      assert SystemPrompt.format_skills([], config) == ""
    end

    test "returns empty string when skills are disabled" do
      config = %{features: %{skills: %{enabled: false}}}

      skills = [
        %{name: "test-skill", description: "A test skill."}
      ]

      assert SystemPrompt.format_skills(skills, config) == ""
    end

    test "wraps skills in XML tags when enabled" do
      config = %{features: %{skills: %{enabled: true}}}

      skills = [
        %{name: "lint", description: "Run linter."},
        %{name: "test", description: "Run tests."}
      ]

      result = SystemPrompt.format_skills(skills, config)
      assert result =~ "<skills>"
      assert result =~ "</skills>"
      assert result =~ "use_skill"
      assert result =~ "**lint**"
      assert result =~ "**test**"
    end
  end

  # -- Environment formatting -------------------------------------------------

  describe "format_environment/1" do
    test "returns empty string for nil" do
      assert SystemPrompt.format_environment(nil) == ""
    end

    test "returns empty string for empty string" do
      assert SystemPrompt.format_environment("") == ""
    end

    test "wraps working directory in environment tags" do
      result = SystemPrompt.format_environment("/home/user/project")
      assert result =~ "<environment>"
      assert result =~ "</environment>"
      assert result =~ "/home/user/project"
    end
  end

  # -- Planning formatting ----------------------------------------------------

  describe "format_planning/1" do
    test "returns empty string for sub-agents (no session)" do
      state = %Opal.Agent.State{
        session: nil,
        session_id: "test-123",
        model: %Opal.Provider.Model{provider: :test, id: "test"},
        working_dir: "/tmp",
        config: Opal.Config.new()
      }

      assert SystemPrompt.format_planning(state) == ""
    end

    test "returns planning section for interactive sessions" do
      state = %Opal.Agent.State{
        session: self(),
        session_id: "test-123",
        model: %Opal.Provider.Model{provider: :test, id: "test"},
        working_dir: "/tmp",
        config: Opal.Config.new()
      }

      result = SystemPrompt.format_planning(state)
      assert result =~ "<planning>"
      assert result =~ "</planning>"
      assert result =~ "plan.md"
    end
  end
end
