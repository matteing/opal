defmodule Opal.PathTest do
  use ExUnit.Case, async: true

  alias Opal.Path, as: OpalPath

  describe "safe_relative/2" do
    @tag :tmp_dir
    test "accepts a path within the base directory", %{tmp_dir: tmp_dir} do
      assert {:ok, expanded} = OpalPath.safe_relative("src/main.ex", tmp_dir)
      assert expanded == Path.join(tmp_dir, "src/main.ex")
    end

    @tag :tmp_dir
    test "rejects path traversal with ../ sequences", %{tmp_dir: tmp_dir} do
      assert {:error, :outside_base_dir} =
               OpalPath.safe_relative("../../../etc/passwd", tmp_dir)
    end

    @tag :tmp_dir
    test "accepts absolute path that is within base dir", %{tmp_dir: tmp_dir} do
      inner_path = Path.join(tmp_dir, "subdir/file.txt")
      assert {:ok, ^inner_path} = OpalPath.safe_relative(inner_path, tmp_dir)
    end

    @tag :tmp_dir
    test "rejects absolute path outside base dir", %{tmp_dir: tmp_dir} do
      assert {:error, :outside_base_dir} =
               OpalPath.safe_relative("/etc/passwd", tmp_dir)
    end

    @tag :tmp_dir
    test "accepts base dir itself as the path", %{tmp_dir: tmp_dir} do
      assert {:ok, expanded} = OpalPath.safe_relative(".", tmp_dir)
      assert expanded == Path.expand(tmp_dir)
    end

    @tag :tmp_dir
    test "rejects sneaky traversal like 'subdir/../../..'", %{tmp_dir: tmp_dir} do
      assert {:error, :outside_base_dir} =
               OpalPath.safe_relative("subdir/../../..", tmp_dir)
    end

    @tag :tmp_dir
    test "handles nested subdirectories correctly", %{tmp_dir: tmp_dir} do
      assert {:ok, expanded} = OpalPath.safe_relative("a/b/c/d.txt", tmp_dir)
      assert expanded == Path.join(tmp_dir, "a/b/c/d.txt")
    end
  end

  describe "posix_relative/2" do
    test "returns path relative to base with forward slashes" do
      assert OpalPath.posix_relative("/project/src/main.ex", "/project") == "src/main.ex"
    end

    test "returns full path when not relative to base" do
      result = OpalPath.posix_relative("/other/file.ex", "/project")
      assert result == "/other/file.ex"
    end
  end
end
