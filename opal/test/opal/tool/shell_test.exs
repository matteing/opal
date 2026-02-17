defmodule Opal.Tool.ShellTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Shell

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      Code.ensure_loaded!(Shell)
      assert function_exported?(Shell, :name, 0)
      assert function_exported?(Shell, :description, 0)
      assert function_exported?(Shell, :parameters, 0)
      assert function_exported?(Shell, :execute, 2)
    end

    test "name/0 returns \"shell\"" do
      assert Shell.name() == "shell"
    end

    test "parameters/0 returns valid JSON Schema map" do
      params = Shell.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "command" in params["required"]
    end
  end

  describe "execute/2 success" do
    test "executes a simple command and captures stdout", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      assert {:ok, output} = Shell.execute(%{"command" => "echo hello"}, ctx)
      assert String.trim(output) == "hello"
    end

    test "respects working_dir from context", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # pwd should return the tmp_dir
      {:ok, output} = Shell.execute(%{"command" => "pwd"}, ctx)
      assert String.trim(output) == tmp_dir
    end
  end

  describe "execute/2 errors" do
    test "returns exit code info on failure", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      assert {:error, msg} = Shell.execute(%{"command" => "false"}, ctx)
      assert msg =~ "exited with status"
    end

    test "captures stderr via stderr_to_stdout", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # Write to stderr — should appear in output since stderr_to_stdout is set
      {:error, msg} = Shell.execute(%{"command" => "echo err_msg >&2; exit 1"}, ctx)
      assert msg =~ "err_msg"
    end

    test "returns error when working_dir missing from context" do
      assert {:error, "Missing working_dir in context"} =
               Shell.execute(%{"command" => "echo hi"}, %{})
    end

    test "returns error when command param missing", %{tmp_dir: tmp_dir} do
      assert {:error, "Missing required parameter: command"} =
               Shell.execute(%{}, %{working_dir: tmp_dir})
    end
  end

  describe "name/1 and description/1" do
    test "returns correct name per shell type" do
      assert Shell.name(:sh) == "shell"
      assert Shell.name(:bash) == "bash"
      assert Shell.name(:zsh) == "zsh"
      assert Shell.name(:cmd) == "cmd"
      assert Shell.name(:powershell) == "powershell"
    end

    test "returns non-empty description per shell type" do
      for shell <- [:sh, :bash, :zsh, :cmd, :powershell] do
        desc = Shell.shell_description(shell)
        assert is_binary(desc) and String.length(desc) > 0
      end
    end

    test "description/1 includes working directory when provided" do
      desc = Shell.description(%{working_dir: "/tmp/project"})
      assert desc =~ "/tmp/project"
      assert desc =~ "Do NOT prepend cd"
    end

    test "description/1 falls back to base description without working_dir" do
      desc = Shell.description(%{})
      assert desc == Shell.description()
    end
  end

  describe "meta/1" do
    test "truncates long commands" do
      long_cmd = String.duplicate("x", 100)
      meta = Shell.meta(%{"command" => long_cmd})
      assert meta =~ "Run `"
      assert meta =~ "..."
      assert String.length(meta) < 100
    end

    test "keeps short commands intact" do
      assert Shell.meta(%{"command" => "ls"}) == "Run `ls`"
    end

    test "returns fallback for missing command" do
      assert Shell.meta(%{}) == "Run command"
    end
  end

  describe "default_shell/0" do
    test "returns :sh or :cmd based on platform" do
      shell = Shell.default_shell()
      assert shell in [:sh, :cmd]
    end
  end

  describe "execute/2 with shell config" do
    test "uses shell from context config", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir, config: %{shell: :sh}}
      assert {:ok, output} = Shell.execute(%{"command" => "echo configured"}, ctx)
      assert String.trim(output) == "configured"
    end

    test "uses default shell when config.shell is nil", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir, config: %{shell: nil}}
      assert {:ok, output} = Shell.execute(%{"command" => "echo default"}, ctx)
      assert String.trim(output) == "default"
    end
  end

  describe "execute/2 with timeout" do
    test "returns timeout error for long-running command", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # sleep for 10 seconds with a 100ms timeout
      assert {:error, msg} = Shell.execute(%{"command" => "sleep 10", "timeout" => 100}, ctx)
      assert msg =~ "timed out"
    end
  end

  describe "execute/2 with streaming" do
    test "emits chunks via emit function", %{tmp_dir: tmp_dir} do
      parent = self()
      emit = fn chunk -> send(parent, {:chunk, chunk}) end
      ctx = %{working_dir: tmp_dir, emit: emit}

      assert {:ok, output} = Shell.execute(%{"command" => "echo streamed"}, ctx)
      assert String.trim(output) =~ "streamed"
      assert_receive {:chunk, _}, 1_000
    end
  end

  # -- Plan 08: Output truncation ---------------------------------------------

  describe "truncation" do
    test "truncates output exceeding line limit (keeps tail)", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # Generate 3000 lines of output via seq
      {:ok, result} = Shell.execute(%{"command" => "seq 1 3000"}, ctx)

      # Should show truncation hint
      assert result =~ "Showing lines"
      assert result =~ "Full output:"
      # Should keep the LAST lines (tail truncation), not the first
      assert result =~ "3000"
    end

    test "passes through small output unchanged", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      {:ok, result} = Shell.execute(%{"command" => "echo hello"}, ctx)

      assert String.trim(result) == "hello"
      refute result =~ "Showing lines"
    end

    test "saves full output to temp file on truncation", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      {:ok, result} = Shell.execute(%{"command" => "seq 1 3000"}, ctx)

      # Extract the temp file path from the hint
      [_, tmp_path] = Regex.run(~r/Full output: (.+?)\]/, result)
      assert File.exists?(tmp_path)

      # Full output should have all 3000 lines
      full = File.read!(tmp_path)
      assert full =~ "1\n"
      assert full =~ "3000\n"

      # Clean up
      File.rm!(tmp_path)
    end
  end
end
