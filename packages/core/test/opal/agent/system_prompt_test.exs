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

      assert result =~ "## Tool Usage Guidelines"
      assert result =~ "read_file"
      assert result =~ "edit_file"
      assert result =~ "write_file"
      assert result =~ "Do NOT use `cat`"
      assert result =~ "Do NOT use `sed`"
    end

    test "returns empty string when no tools are active" do
      assert SystemPrompt.build_guidelines([]) == ""
    end

    test "returns empty string when only custom tools are active" do
      assert SystemPrompt.build_guidelines([CustomStub]) == ""
    end

    test "produces shell-only rules when only shell is active" do
      result = SystemPrompt.build_guidelines([ShellStub])

      assert result =~ "Tool Usage Guidelines"
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
  end
end
