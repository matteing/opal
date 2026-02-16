defmodule Opal.Agent.ToolRunnerHelpersTest do
  @moduledoc """
  Tests for pure helper functions in Opal.Agent.ToolRunner.
  """
  use ExUnit.Case, async: true

  alias Opal.Agent.ToolRunner

  describe "make_relative/2" do
    test "converts absolute path under working_dir to relative" do
      assert ToolRunner.make_relative("/home/user/project/src/foo.ex", "/home/user/project") ==
               "src/foo.ex"
    end

    test "returns path unchanged if already relative" do
      assert ToolRunner.make_relative("src/foo.ex", "/home/user/project") == "src/foo.ex"
    end

    test "returns path unchanged if outside working_dir" do
      result = ToolRunner.make_relative("/other/path/foo.ex", "/home/user/project")
      # Should not be relative to working_dir
      assert result == "/other/path/foo.ex"
    end

    test "handles same directory" do
      assert ToolRunner.make_relative("/home/user/project/file.ex", "/home/user/project") ==
               "file.ex"
    end
  end
end
