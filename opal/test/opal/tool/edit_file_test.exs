defmodule Opal.Tool.EditFileTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.EditFile, as: Edit
  alias Opal.Hashline

  @working_dir System.tmp_dir!()

  setup do
    path = Path.join(@working_dir, "hashline_test_#{:erlang.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  defp write_and_anchors(path, content) do
    File.write!(path, content)
    lines = String.split(content, "\n")

    anchors =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} -> {num, Hashline.line_hash(line)} end)

    anchors
  end

  defp anchor_str({num, hash}), do: "#{num}:#{hash}"

  describe "single-line replace" do
    test "replaces one line by hash", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "BBB"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nBBB\nccc"
    end

    test "replaces first line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 0)),
                   "new_string" => "AAA"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "AAA\nbbb\nccc"
    end

    test "replaces last line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 2)),
                   "new_string" => "CCC"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nbbb\nCCC"
    end
  end

  describe "multi-line replace" do
    test "replaces a range of lines", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc\nddd\neee")

      assert {:ok, result} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "through" => anchor_str(Enum.at(anchors, 3)),
                   "new_string" => "REPLACED"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nREPLACED\neee"
      assert result =~ "Edit applied to:"
      assert result =~ "Replaced content:"
      assert result =~ "bbb"
      assert result =~ "ddd"
    end

    test "replaces with multi-line content", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "through" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "line1\nline2\nline3"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nline1\nline2\nline3\nccc"
    end
  end

  describe "backward compatibility" do
    test "accepts legacy 'end' parameter as fallback", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc\nddd\neee")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "end" => anchor_str(Enum.at(anchors, 3)),
                   "new_string" => "REPLACED"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nREPLACED\neee"
    end

    test "'through' takes precedence over 'end'", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc\nddd\neee")

      # 'through' points to line 2, 'end' points to line 4 — 'through' wins
      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "through" => anchor_str(Enum.at(anchors, 1)),
                   "end" => anchor_str(Enum.at(anchors, 3)),
                   "new_string" => "REPLACED"
                 },
                 %{working_dir: @working_dir}
               )

      # Only line 2 was replaced (through=line 2), not lines 2-4
      assert File.read!(path) == "aaa\nREPLACED\nccc\nddd\neee"
    end
  end

  describe "replaced content echo" do
    test "echoes replaced lines with hashline tags", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc\nddd")

      assert {:ok, result} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "through" => anchor_str(Enum.at(anchors, 2)),
                   "new_string" => "REPLACED"
                 },
                 %{working_dir: @working_dir}
               )

      assert result =~ "Replaced content:"
      # Should contain hashline-tagged versions of the replaced lines
      assert result =~ "2:"
      assert result =~ "|bbb"
      assert result =~ "3:"
      assert result =~ "|ccc"
    end

    test "echoes single replaced line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, result} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "BBB"
                 },
                 %{working_dir: @working_dir}
               )

      assert result =~ "Replaced content:"
      assert result =~ "|bbb"
    end

    test "echoes anchor line for insert operations", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, result} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "INSERTED",
                   "operation" => "insert_after"
                 },
                 %{working_dir: @working_dir}
               )

      assert result =~ "Replaced content:"
      assert result =~ "|bbb"
    end
  end

  describe "delete" do
    test "deletes lines when new_string is omitted", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc\nddd")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "through" => anchor_str(Enum.at(anchors, 2))
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nddd"
    end
  end

  describe "insert_after" do
    test "inserts content after a line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "INSERTED",
                   "operation" => "insert_after"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nbbb\nINSERTED\nccc"
    end

    test "inserts after last line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "ccc",
                   "operation" => "insert_after"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nbbb\nccc"
    end
  end

  describe "insert_before" do
    test "inserts content before a line", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "INSERTED",
                   "operation" => "insert_before"
                 },
                 %{working_dir: @working_dir}
               )

      assert File.read!(path) == "aaa\nINSERTED\nbbb\nccc"
    end
  end

  describe "hash validation" do
    test "rejects stale hash after file change", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      # Modify the file behind the model's back
      File.write!(path, "aaa\nXXX\nccc")

      assert {:error, msg} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "BBB"
                 },
                 %{working_dir: @working_dir}
               )

      assert msg =~ "Hash mismatch"
    end

    test "rejects invalid anchor format", %{path: path} do
      write_and_anchors(path, "aaa\nbbb")

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => path, "start" => "bad", "new_string" => "x"},
                 %{working_dir: @working_dir}
               )

      assert msg =~ "Invalid anchor"
    end

    test "rejects out-of-range line number", %{path: path} do
      write_and_anchors(path, "aaa\nbbb")

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => path, "start" => "99:aa", "new_string" => "x"},
                 %{working_dir: @working_dir}
               )

      assert msg =~ "out of range"
    end

    test "rejects start after end", %{path: path} do
      anchors = write_and_anchors(path, "aaa\nbbb\nccc")

      assert {:error, msg} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 2)),
                   "through" => anchor_str(Enum.at(anchors, 0)),
                   "new_string" => "x"
                 },
                 %{working_dir: @working_dir}
               )

      assert msg =~ "start line"
    end
  end

  describe "encoding preservation" do
    test "preserves CRLF line endings", %{path: path} do
      content = "aaa\r\nbbb\r\nccc"
      File.write!(path, content)
      # Compute anchors using normalized content
      normalized = String.replace(content, "\r\n", "\n")
      lines = String.split(normalized, "\n")

      anchors =
        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {line, num} -> {num, Hashline.line_hash(line)} end)

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "BBB"
                 },
                 %{working_dir: @working_dir}
               )

      result = File.read!(path)
      assert result == "aaa\r\nBBB\r\nccc"
    end

    test "preserves UTF-8 BOM", %{path: path} do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = bom <> "aaa\nbbb\nccc"
      File.write!(path, content)

      # Compute anchors without BOM
      clean = "aaa\nbbb\nccc"
      lines = String.split(clean, "\n")

      anchors =
        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {line, num} -> {num, Hashline.line_hash(line)} end)

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => path,
                   "start" => anchor_str(Enum.at(anchors, 1)),
                   "new_string" => "BBB"
                 },
                 %{working_dir: @working_dir}
               )

      result = File.read!(path)
      assert result == bom <> "aaa\nBBB\nccc"
    end
  end

  describe "path safety" do
    test "rejects path outside working directory", %{path: _path} do
      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "/etc/passwd", "start" => "1:aa", "new_string" => "x"},
                 %{working_dir: @working_dir}
               )

      assert msg =~ "escapes working directory"
    end

    test "rejects missing file", %{path: _path} do
      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "nonexistent.txt", "start" => "1:aa", "new_string" => "x"},
                 %{working_dir: @working_dir}
               )

      assert msg =~ "File not found"
    end
  end
end
