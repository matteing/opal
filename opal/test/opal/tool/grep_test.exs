defmodule Opal.Tool.GrepTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Grep

  # Strips hashline tags (N:hash|) from output for content comparison
  defp strip_tags(output) do
    output
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case String.split(line, "|", parts: 2) do
        [_tag, content] -> content
        [content] -> content
      end
    end)
  end

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      Code.ensure_loaded!(Grep)
      assert function_exported?(Grep, :name, 0)
      assert function_exported?(Grep, :description, 0)
      assert function_exported?(Grep, :parameters, 0)
      assert function_exported?(Grep, :execute, 2)
    end

    test "name/0 returns \"grep\"" do
      assert Grep.name() == "grep"
    end

    test "parameters/0 returns valid JSON Schema map" do
      params = Grep.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "pattern" in params["required"]
    end

    test "meta/1 includes pattern" do
      assert Grep.meta(%{"pattern" => "defmodule"}) == "Grep defmodule"
    end
  end

  describe "execute/2 — single file" do
    test "finds matching lines in a file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.ex"), "defmodule Hello do\n  def greet, do: :ok\nend")

      {:ok, result} = Grep.execute(%{"pattern" => "greet"}, %{working_dir: tmp_dir})

      assert result =~ "hello.ex"
      assert strip_tags(result) =~ "greet"
    end

    test "returns hashline-tagged output", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tagged.ex"), "aaa\nbbb\nccc")

      {:ok, result} =
        Grep.execute(
          %{"pattern" => "bbb", "path" => "tagged.ex", "context_lines" => 0},
          %{working_dir: tmp_dir}
        )

      # Match line should be tagged
      lines =
        result
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.reject(&(&1 == ""))
        |> Enum.reject(&String.starts_with?(&1, "["))
        |> Enum.reject(&String.contains?(&1, "match"))

      Enum.each(lines, fn line ->
        assert String.match?(line, ~r/^\d+:[0-9a-f]{2}\|/),
               "Expected hashline format, got: #{line}"
      end)
    end

    test "searching a single file via path param", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "target.txt"), "line one\nline two\nline three")

      {:ok, result} =
        Grep.execute(
          %{"pattern" => "two", "path" => "target.txt"},
          %{working_dir: tmp_dir}
        )

      assert strip_tags(result) =~ "two"
    end
  end

  describe "execute/2 — directory search" do
    setup %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "src"))

      File.write!(
        Path.join(tmp_dir, "src/foo.ex"),
        "defmodule Foo do\n  def hello, do: :world\nend"
      )

      File.write!(
        Path.join(tmp_dir, "src/bar.ex"),
        "defmodule Bar do\n  def goodbye, do: :bye\nend"
      )

      File.write!(Path.join(tmp_dir, "readme.md"), "# Hello World\nThis is a project.")
      %{ctx: %{working_dir: tmp_dir}}
    end

    test "searches all files in directory", %{ctx: ctx} do
      {:ok, result} = Grep.execute(%{"pattern" => "defmodule"}, ctx)

      assert result =~ "foo.ex"
      assert result =~ "bar.ex"
    end

    test "include glob filters by filename", %{ctx: ctx} do
      {:ok, result} = Grep.execute(%{"pattern" => "Hello", "include" => "*.md"}, ctx)

      assert result =~ "readme.md"
      refute result =~ "foo.ex"
    end

    test "include glob supports brace expansion", %{ctx: ctx} do
      {:ok, result} = Grep.execute(%{"pattern" => "def", "include" => "*.{ex,exs}"}, ctx)

      assert result =~ "foo.ex"
      assert result =~ "bar.ex"
      refute result =~ "readme.md"
    end

    test "searches subdirectory when path is given", %{ctx: ctx} do
      {:ok, result} = Grep.execute(%{"pattern" => "defmodule", "path" => "src"}, ctx)

      assert result =~ "foo.ex"
      assert result =~ "bar.ex"
    end
  end

  describe "execute/2 — context lines" do
    test "includes surrounding context lines", %{tmp_dir: tmp_dir} do
      content = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(Path.join(tmp_dir, "ctx.txt"), content)

      {:ok, result} =
        Grep.execute(
          %{"pattern" => "line 5", "path" => "ctx.txt", "context_lines" => 2},
          %{working_dir: tmp_dir}
        )

      stripped = strip_tags(result)
      assert stripped =~ "line 3"
      assert stripped =~ "line 4"
      assert stripped =~ "line 5"
      assert stripped =~ "line 6"
      assert stripped =~ "line 7"
      refute stripped =~ "line 1\n"
    end

    test "context_lines 0 returns only matching lines", %{tmp_dir: tmp_dir} do
      content = "aaa\nbbb\nccc\nddd"
      File.write!(Path.join(tmp_dir, "noctx.txt"), content)

      {:ok, result} =
        Grep.execute(
          %{"pattern" => "bbb", "path" => "noctx.txt", "context_lines" => 0},
          %{working_dir: tmp_dir}
        )

      stripped = strip_tags(result)
      assert stripped =~ "bbb"
      refute stripped =~ "aaa"
      refute stripped =~ "ccc"
    end
  end

  describe "execute/2 — max_results" do
    test "caps output at max_results", %{tmp_dir: tmp_dir} do
      # File with many matching lines
      content = Enum.map_join(1..100, "\n", &"match_#{&1}")
      File.write!(Path.join(tmp_dir, "many.txt"), content)

      {:ok, result} =
        Grep.execute(
          %{
            "pattern" => "match_",
            "path" => "many.txt",
            "max_results" => 5,
            "context_lines" => 0
          },
          %{working_dir: tmp_dir}
        )

      assert result =~ "capped"
    end
  end

  describe "execute/2 — no matches" do
    test "returns 'No matches found' when nothing matches", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "empty_match.txt"), "hello world")

      {:ok, result} =
        Grep.execute(
          %{"pattern" => "zzzzz", "path" => "empty_match.txt"},
          %{working_dir: tmp_dir}
        )

      assert result == "No matches found."
    end
  end

  describe "execute/2 — directory skipping" do
    test "skips .git directory", %{tmp_dir: tmp_dir} do
      git_dir = Path.join(tmp_dir, ".git")
      File.mkdir_p!(git_dir)
      File.write!(Path.join(git_dir, "HEAD"), "ref: refs/heads/main")

      File.write!(Path.join(tmp_dir, "real.txt"), "ref: refs/heads/main")

      {:ok, result} =
        Grep.execute(%{"pattern" => "ref:"}, %{working_dir: tmp_dir})

      assert result =~ "real.txt"
      refute result =~ ".git"
    end

    test "skips node_modules", %{tmp_dir: tmp_dir} do
      nm = Path.join(tmp_dir, "node_modules")
      File.mkdir_p!(nm)
      File.write!(Path.join(nm, "dep.js"), "function hello() {}")

      File.write!(Path.join(tmp_dir, "app.js"), "function hello() {}")

      {:ok, result} =
        Grep.execute(%{"pattern" => "hello"}, %{working_dir: tmp_dir})

      assert result =~ "app.js"
      refute result =~ "node_modules"
    end

    test "skips _build and deps", %{tmp_dir: tmp_dir} do
      for dir <- ["_build", "deps"] do
        d = Path.join(tmp_dir, dir)
        File.mkdir_p!(d)
        File.write!(Path.join(d, "compiled.ex"), "defmodule X do end")
      end

      File.write!(Path.join(tmp_dir, "lib.ex"), "defmodule X do end")

      {:ok, result} =
        Grep.execute(%{"pattern" => "defmodule"}, %{working_dir: tmp_dir})

      assert result =~ "lib.ex"
      refute result =~ "_build"
      refute result =~ "deps"
    end
  end

  describe "execute/2 — binary files" do
    test "skips files with null bytes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "binary.dat"), <<0, 1, 2, 104, 101, 108, 108, 111>>)
      File.write!(Path.join(tmp_dir, "text.txt"), "hello")

      {:ok, result} =
        Grep.execute(%{"pattern" => "hello"}, %{working_dir: tmp_dir})

      assert result =~ "text.txt"
      refute result =~ "binary.dat"
    end
  end

  describe "execute/2 — error handling" do
    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      {:error, msg} =
        Grep.execute(%{"pattern" => "[invalid("}, %{working_dir: tmp_dir})

      assert msg =~ "Invalid regex"
    end

    test "returns error when path escapes working dir", %{tmp_dir: tmp_dir} do
      {:error, msg} =
        Grep.execute(
          %{"pattern" => "test", "path" => "../../../etc"},
          %{working_dir: tmp_dir}
        )

      assert msg =~ "escapes working directory"
    end

    test "returns error when working_dir is missing" do
      {:error, msg} = Grep.execute(%{"pattern" => "x"}, %{})
      assert msg =~ "Missing working_dir"
    end

    test "returns error when pattern is missing", %{tmp_dir: tmp_dir} do
      {:error, msg} = Grep.execute(%{}, %{working_dir: tmp_dir})
      assert msg =~ "Missing required parameter"
    end
  end

  describe "execute/2 — encoding" do
    test "handles UTF-8 BOM files", %{tmp_dir: tmp_dir} do
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(Path.join(tmp_dir, "bom.txt"), bom <> "hello world")

      {:ok, result} =
        Grep.execute(%{"pattern" => "hello", "path" => "bom.txt"}, %{working_dir: tmp_dir})

      assert strip_tags(result) =~ "hello world"
      refute String.contains?(result, bom)
    end

    test "handles CRLF line endings", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "crlf.txt"), "line one\r\nline two\r\nline three")

      {:ok, result} =
        Grep.execute(%{"pattern" => "two", "path" => "crlf.txt"}, %{working_dir: tmp_dir})

      assert strip_tags(result) =~ "line two"
    end
  end

  describe "execute/2 — cross-platform" do
    test "output uses forward slashes in file paths", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "deep/nested/dir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "file.ex"), "defmodule Nested do end")

      {:ok, result} =
        Grep.execute(%{"pattern" => "defmodule"}, %{working_dir: tmp_dir})

      # File header should use forward slashes regardless of OS
      assert result =~ "deep/nested/dir/file.ex"
      refute result =~ "\\"
    end

    test "symlink loops do not cause infinite recursion", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "real")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "a.txt"), "target content")

      link_path = Path.join(subdir, "loop")

      case File.ln_s(subdir, link_path) do
        :ok ->
          # Should complete without hanging — the symlink cycle is broken
          {:ok, result} =
            Grep.execute(%{"pattern" => "target"}, %{working_dir: tmp_dir})

          assert result =~ "a.txt"

        {:error, _} ->
          # Symlinks not supported (some Windows configs) — skip
          :ok
      end
    end

    test "deeply nested directories are depth-limited", %{tmp_dir: tmp_dir} do
      # Create a directory 30 levels deep (exceeds @max_depth of 25)
      deep =
        Enum.reduce(1..30, tmp_dir, fn n, acc ->
          p = Path.join(acc, "d#{n}")
          File.mkdir_p!(p)
          p
        end)

      File.write!(Path.join(deep, "deep.txt"), "needle")
      File.write!(Path.join(tmp_dir, "shallow.txt"), "needle")

      {:ok, result} =
        Grep.execute(%{"pattern" => "needle"}, %{working_dir: tmp_dir})

      # Shallow file is found, but the 30-deep one is skipped
      assert result =~ "shallow.txt"
      refute result =~ "deep.txt"
    end
  end
end
