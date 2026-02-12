defmodule Opal.PathTest do
  use ExUnit.Case, async: true

  alias Opal.Path, as: OpalPath

  # Validates path normalization (backslash replacement and expansion)
  describe "normalize/1" do
    test "replaces backslashes with forward slashes" do
      result = OpalPath.normalize("foo\\bar\\baz")
      assert not String.contains?(result, "\\")
    end

    test "expands relative paths to absolute" do
      result = OpalPath.normalize("foo/bar")
      assert String.starts_with?(result, "/")
    end

    test "expands tilde paths" do
      result = OpalPath.normalize("~/something")
      home = System.user_home!()
      assert String.starts_with?(result, home)
      assert String.ends_with?(result, "/something")
    end

    test "handles mixed separators" do
      result = OpalPath.normalize("foo\\bar/baz")
      assert not String.contains?(result, "\\")
      assert String.ends_with?(result, "foo/bar/baz")
    end
  end

  # Validates native path conversion
  describe "to_native/1" do
    test "returns path unchanged on Unix (forward slashes preserved)" do
      # On macOS/Linux, forward slashes should remain
      assert OpalPath.to_native("foo/bar/baz") == "foo/bar/baz"
    end

    test "preserves absolute paths" do
      assert OpalPath.to_native("/usr/local/bin") == "/usr/local/bin"
    end
  end

  # Validates safe_relative path security checks
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
end
