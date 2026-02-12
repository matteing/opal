defmodule Opal.Tool.ReadTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Read

  # Strips hashline tags from output for content comparison
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
      assert function_exported?(Read, :name, 0)
      assert function_exported?(Read, :description, 0)
      assert function_exported?(Read, :parameters, 0)
      assert function_exported?(Read, :execute, 2)
    end

    test "name/0 returns \"read_file\"" do
      assert Read.name() == "read_file"
    end

    test "parameters/0 returns valid JSON Schema map" do
      params = Read.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "path" in params["required"]
    end
  end

  describe "execute/2 success" do
    test "reads an existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "hello.txt")
      File.write!(path, "hello world")

      {:ok, result} = Read.execute(%{"path" => "hello.txt"}, %{working_dir: tmp_dir})
      assert strip_tags(result) == "hello world"
    end

    test "respects working_dir from context", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "sub")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "file.txt"), "in subdir")

      {:ok, result} = Read.execute(%{"path" => "file.txt"}, %{working_dir: subdir})
      assert strip_tags(result) == "in subdir"
    end

    test "output uses hashline format N:hash|content", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tagged.txt"), "aaa\nbbb")

      {:ok, result} = Read.execute(%{"path" => "tagged.txt"}, %{working_dir: tmp_dir})
      lines = String.split(result, "\n")

      Enum.each(lines, fn line ->
        assert String.match?(line, ~r/^\d+:[0-9a-f]{2}\|/)
      end)

      assert String.starts_with?(Enum.at(lines, 0), "1:")
      assert String.starts_with?(Enum.at(lines, 1), "2:")
    end
  end

  describe "execute/2 errors" do
    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      assert {:error, msg} = Read.execute(%{"path" => "nope.txt"}, %{working_dir: tmp_dir})
      assert msg =~ "File not found"
    end

    test "rejects path traversal", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               Read.execute(%{"path" => "../../../etc/passwd"}, %{working_dir: tmp_dir})

      assert msg =~ "escapes working directory"
    end

    test "returns error when working_dir missing from context" do
      assert {:error, "Missing working_dir in context"} =
               Read.execute(%{"path" => "foo.txt"}, %{})
    end

    test "returns error when path param missing", %{tmp_dir: tmp_dir} do
      assert {:error, "Missing required parameter: path"} =
               Read.execute(%{}, %{working_dir: tmp_dir})
    end
  end

  describe "offset and limit" do
    # File with 5 lines: "line1\nline2\nline3\nline4\nline5"
    setup %{tmp_dir: tmp_dir} do
      content = Enum.map_join(1..5, "\n", &"line#{&1}")
      path = Path.join(tmp_dir, "lines.txt")
      File.write!(path, content)
      %{ctx: %{working_dir: tmp_dir}}
    end

    test "offset returns lines starting from given 1-indexed line", %{ctx: ctx} do
      {:ok, result} = Read.execute(%{"path" => "lines.txt", "offset" => 3}, ctx)
      assert result =~ "3:"
      assert strip_tags(result) =~ "line3"
      assert strip_tags(result) =~ "line4"
      assert strip_tags(result) =~ "line5"
      refute strip_tags(result) =~ "line1"
    end

    test "limit returns at most N lines", %{ctx: ctx} do
      {:ok, result} = Read.execute(%{"path" => "lines.txt", "limit" => 2}, ctx)
      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert String.starts_with?(hd(lines), "1:")
    end

    test "offset + limit together", %{ctx: ctx} do
      {:ok, result} = Read.execute(%{"path" => "lines.txt", "offset" => 2, "limit" => 2}, ctx)
      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ "2:"
      assert Enum.at(lines, 1) =~ "3:"
    end

    test "output includes hashline tags when offset/limit used", %{ctx: ctx} do
      {:ok, result} = Read.execute(%{"path" => "lines.txt", "offset" => 1, "limit" => 3}, ctx)
      lines = String.split(result, "\n")

      Enum.each(lines, fn line ->
        assert String.match?(line, ~r/^\d+:[0-9a-f]{2}\|/)
      end)
    end
  end

  # -- Plan 08: Output truncation ---------------------------------------------

  describe "truncation" do
    test "truncates files exceeding line limit with continuation hint", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # Generate a file with 3000 lines (over the 2000 limit)
      content = Enum.map_join(1..3000, "\n", &"line #{&1}")
      File.write!(Path.join(tmp_dir, "big.txt"), content)

      {:ok, result} = Read.execute(%{"path" => "big.txt"}, ctx)

      # Should show truncation hint with offset instruction
      assert result =~ "Showing lines"
      assert result =~ "of 3000"
      assert result =~ "Use offset="
      # Should NOT contain the last line
      refute strip_tags(result) =~ "line 3000"
    end

    test "truncates files exceeding byte limit at line boundary", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # Generate content over 50KB with many short lines
      line = String.duplicate("x", 100)
      # ~600 lines × 101 bytes = ~60KB
      content = Enum.map_join(1..600, "\n", fn _ -> line end)
      File.write!(Path.join(tmp_dir, "bytes.txt"), content)

      {:ok, result} = Read.execute(%{"path" => "bytes.txt"}, ctx)

      # Should be truncated with hint
      assert result =~ "truncated at"
      assert result =~ "Use offset="
    end

    test "shows special hint for giant single-line files", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      # Generate a single line over 50KB (like minified JS)
      content = String.duplicate("x", 60 * 1024)
      File.write!(Path.join(tmp_dir, "minified.js"), content)

      {:ok, result} = Read.execute(%{"path" => "minified.js"}, ctx)

      assert result =~ "KB limit"
      assert result =~ "head -c"
    end

    test "passes through small files with hashline tags", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "small.txt"), "just a small file")

      {:ok, result} = Read.execute(%{"path" => "small.txt"}, ctx)
      assert strip_tags(result) == "just a small file"
      assert String.match?(result, ~r/^1:[0-9a-f]{2}\|/)
    end
  end

  # -- Plan 10: BOM stripping -------------------------------------------------

  describe "BOM handling" do
    test "strips UTF-8 BOM from file content", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(Path.join(tmp_dir, "bom.txt"), bom <> "hello world")

      {:ok, result} = Read.execute(%{"path" => "bom.txt"}, ctx)

      # BOM should be stripped — content visible after tag
      assert strip_tags(result) == "hello world"
      refute String.contains?(result, bom)
    end

    test "returns clean content for files without BOM", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "nobom.txt"), "hello world")

      {:ok, result} = Read.execute(%{"path" => "nobom.txt"}, ctx)
      assert strip_tags(result) == "hello world"
    end
  end
end
