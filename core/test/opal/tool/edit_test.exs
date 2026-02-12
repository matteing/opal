defmodule Opal.Tool.EditTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Tool.Edit

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      assert function_exported?(Edit, :name, 0)
      assert function_exported?(Edit, :description, 0)
      assert function_exported?(Edit, :parameters, 0)
      assert function_exported?(Edit, :execute, 2)
    end

    test "name/0 returns \"edit_file\"" do
      assert Edit.name() == "edit_file"
    end

    test "parameters/0 returns valid JSON Schema map" do
      params = Edit.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "path" in params["required"]
      assert "old_string" in params["required"]
      assert "new_string" in params["required"]
    end
  end

  describe "execute/2 success" do
    test "replaces old_string with new_string in file", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "code.ex")
      File.write!(path, "hello world")

      assert {:ok, msg} =
               Edit.execute(
                 %{"path" => "code.ex", "old_string" => "hello", "new_string" => "goodbye"},
                 ctx
               )

      assert msg =~ "Edit applied"
      assert File.read!(path) == "goodbye world"
    end

    test "handles multi-line old_string", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "multi.txt")
      File.write!(path, "aaa\nbbb\nccc\nddd")

      assert {:ok, _} =
               Edit.execute(
                 %{"path" => "multi.txt", "old_string" => "bbb\nccc", "new_string" => "XXX"},
                 ctx
               )

      assert File.read!(path) == "aaa\nXXX\nddd"
    end

    test "handles empty new_string (deletion)", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "del.txt")
      File.write!(path, "keep_remove_keep")

      assert {:ok, _} =
               Edit.execute(
                 %{"path" => "del.txt", "old_string" => "_remove_", "new_string" => ""},
                 ctx
               )

      assert File.read!(path) == "keepkeep"
    end

    test "preserves file content outside the edit", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "preserve.txt")
      File.write!(path, "alpha\nbeta\ngamma\ndelta")

      Edit.execute(
        %{"path" => "preserve.txt", "old_string" => "beta", "new_string" => "BETA"},
        ctx
      )

      content = File.read!(path)
      assert content =~ "alpha"
      assert content =~ "BETA"
      assert content =~ "gamma"
      assert content =~ "delta"
    end
  end

  describe "execute/2 errors" do
    test "returns error if old_string not found (0 matches)", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "nope.txt"), "some content")

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "nope.txt", "old_string" => "missing", "new_string" => "x"},
                 ctx
               )

      assert msg =~ "not found"
    end

    test "returns error if old_string found multiple times (>1 matches)", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "dup.txt"), "foo bar foo baz foo")

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "dup.txt", "old_string" => "foo", "new_string" => "x"},
                 ctx
               )

      assert msg =~ "3 times"
    end

    test "returns error for empty old_string", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "empty_old.txt"), "content")

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "empty_old.txt", "old_string" => "", "new_string" => "x"},
                 ctx
               )

      assert msg =~ "must not be empty"
    end

    test "rejects path traversal", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:error, msg} =
               Edit.execute(
                 %{
                   "path" => "../../../etc/passwd",
                   "old_string" => "root",
                   "new_string" => "hacked"
                 },
                 ctx
               )

      assert msg =~ "escapes working directory"
    end

    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:error, msg} =
               Edit.execute(
                 %{"path" => "ghost.txt", "old_string" => "a", "new_string" => "b"},
                 ctx
               )

      assert msg =~ "File not found"
    end

    test "returns error when working_dir missing from context" do
      assert {:error, "Missing working_dir in context"} =
               Edit.execute(
                 %{"path" => "f.txt", "old_string" => "a", "new_string" => "b"},
                 %{}
               )
    end

    test "returns error when required params missing", %{tmp_dir: tmp_dir} do
      assert {:error, msg} = Edit.execute(%{}, %{working_dir: tmp_dir})
      assert msg =~ "Missing required parameters"
    end
  end

  # -- Plan 09: Fuzzy edit matching -------------------------------------------

  describe "fuzzy matching" do
    test "matches when LLM sends curly quotes but file has straight quotes", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "quotes.txt")
      File.write!(path, "puts 'hello world'")

      # LLM sends curly quotes (\u2018 / \u2019)
      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => "quotes.txt",
                   "old_string" => "puts \u2018hello world\u2019",
                   "new_string" => "puts 'goodbye world'"
                 },
                 ctx
               )

      assert File.read!(path) == "puts 'goodbye world'"
    end

    test "matches when LLM sends em-dash but file has hyphen", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "dash.txt")
      File.write!(path, "foo - bar")

      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => "dash.txt",
                   "old_string" => "foo \u2014 bar",
                   "new_string" => "foo + bar"
                 },
                 ctx
               )

      assert File.read!(path) == "foo + bar"
    end

    test "prefers exact match over fuzzy when both would work", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "exact.txt")
      File.write!(path, "hello world")

      # Exact match available — should not trigger fuzzy path
      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => "exact.txt",
                   "old_string" => "hello",
                   "new_string" => "goodbye"
                 },
                 ctx
               )

      assert File.read!(path) == "goodbye world"
    end

    test "returns error when fuzzy match is ambiguous", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "ambiguous.txt")
      File.write!(path, "'hello' and 'hello'")

      # Both occurrences would match after normalization
      assert {:error, msg} =
               Edit.execute(
                 %{
                   "path" => "ambiguous.txt",
                   "old_string" => "\u2018hello\u2019",
                   "new_string" => "x"
                 },
                 ctx
               )

      assert msg =~ "not found"
    end
  end

  # -- Plan 10: BOM & CRLF handling ------------------------------------------

  describe "BOM handling" do
    test "edits file with BOM and preserves it", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      bom = <<0xEF, 0xBB, 0xBF>>
      path = Path.join(tmp_dir, "bom.txt")
      File.write!(path, bom <> "hello world")

      assert {:ok, _} =
               Edit.execute(
                 %{"path" => "bom.txt", "old_string" => "hello", "new_string" => "goodbye"},
                 ctx
               )

      result = File.read!(path)
      # BOM should be preserved
      assert <<0xEF, 0xBB, 0xBF, rest::binary>> = result
      assert rest == "goodbye world"
    end

    test "edits file without BOM and does not add one", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "nobom.txt")
      File.write!(path, "hello world")

      assert {:ok, _} =
               Edit.execute(
                 %{"path" => "nobom.txt", "old_string" => "hello", "new_string" => "goodbye"},
                 ctx
               )

      result = File.read!(path)
      refute match?(<<0xEF, 0xBB, 0xBF, _::binary>>, result)
      assert result == "goodbye world"
    end
  end

  describe "CRLF handling" do
    test "edits file with CRLF and preserves line endings", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "aaa\r\nbbb\r\nccc")

      # LLM sends LF-only old_string (always the case)
      assert {:ok, _} =
               Edit.execute(
                 %{"path" => "crlf.txt", "old_string" => "bbb", "new_string" => "XXX"},
                 ctx
               )

      result = File.read!(path)
      assert result == "aaa\r\nXXX\r\nccc"
    end

    test "multi-line old_string matches across CRLF boundaries", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "crlf_multi.txt")
      File.write!(path, "aaa\r\nbbb\r\nccc\r\nddd")

      # LLM sends "bbb\nccc" (no \r), which should match "bbb\r\nccc" in file
      assert {:ok, _} =
               Edit.execute(
                 %{
                   "path" => "crlf_multi.txt",
                   "old_string" => "bbb\nccc",
                   "new_string" => "XXX"
                 },
                 ctx
               )

      result = File.read!(path)
      assert result == "aaa\r\nXXX\r\nddd"
    end
  end
end
