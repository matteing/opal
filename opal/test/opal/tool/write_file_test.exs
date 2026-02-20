defmodule Opal.Tool.WriteFileTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Opal.Config
  alias Opal.Tool.WriteFile, as: Write

  describe "behaviour" do
    test "implements Opal.Tool behaviour" do
      Code.ensure_loaded!(Write)
      assert function_exported?(Write, :name, 0)
      assert function_exported?(Write, :description, 0)
      assert function_exported?(Write, :parameters, 0)
      assert function_exported?(Write, :execute, 2)
    end

    test "name/0 returns \"write_file\"" do
      assert Write.name() == "write_file"
    end

    test "parameters/0 returns valid JSON Schema map" do
      params = Write.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "path" in params["required"]
      assert "content" in params["required"]
    end
  end

  describe "execute/2 success" do
    test "writes content to a new file", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:ok, msg, %{diff: _}} =
               Write.execute(%{"path" => "new.txt", "content" => "hello"}, ctx)

      assert msg =~ "File written"
      assert File.read!(Path.join(tmp_dir, "new.txt")) == "hello"
    end

    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "a/b/c/deep.txt", "content" => "deep"}, ctx)

      assert File.read!(Path.join(tmp_dir, "a/b/c/deep.txt")) == "deep"
    end

    test "overwrites existing file content", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      File.write!(Path.join(tmp_dir, "exist.txt"), "old")

      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "exist.txt", "content" => "new"}, ctx)

      assert File.read!(Path.join(tmp_dir, "exist.txt")) == "new"
    end

    test "returns success message with file path", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      {:ok, msg, %{diff: _}} = Write.execute(%{"path" => "out.txt", "content" => "data"}, ctx)
      assert msg =~ "File written"
      assert msg =~ "out.txt"
    end

    test "handles empty content", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      assert {:ok, _, %{diff: _}} = Write.execute(%{"path" => "empty.txt", "content" => ""}, ctx)
      assert File.read!(Path.join(tmp_dir, "empty.txt")) == ""
    end

    test "allows writing absolute path in Opal data_dir", %{tmp_dir: tmp_dir} do
      working_dir = Path.join(tmp_dir, "project")
      data_dir = Path.join(tmp_dir, ".opal")
      path = Path.join(data_dir, "plans/plan.md")
      File.mkdir_p!(working_dir)

      ctx = %{working_dir: working_dir, config: Config.new(%{data_dir: data_dir})}

      assert {:ok, _msg, %{diff: _}} = Write.execute(%{"path" => path, "content" => "plan"}, ctx)
      assert File.read!(path) == "plan"
    end
  end

  describe "execute/2 errors" do
    test "rejects path traversal", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:error, msg} =
               Write.execute(%{"path" => "../../../tmp/evil.txt", "content" => "x"}, ctx)

      assert msg =~ "escapes working directory"
    end

    test "returns error when working_dir missing from context" do
      assert {:error, "Missing working_dir in context"} =
               Write.execute(%{"path" => "f.txt", "content" => "x"}, %{})
    end

    test "returns error when required params missing", %{tmp_dir: tmp_dir} do
      assert {:error, msg} = Write.execute(%{}, %{working_dir: tmp_dir})
      assert msg =~ "Missing required parameters"
    end

    test "rejects path outside both working_dir and Opal data_dir", %{tmp_dir: tmp_dir} do
      working_dir = Path.join(tmp_dir, "project")
      data_dir = Path.join(tmp_dir, ".opal")
      path = Path.join(tmp_dir, "outside/evil.txt")
      File.mkdir_p!(working_dir)

      ctx = %{working_dir: working_dir, config: Config.new(%{data_dir: data_dir})}

      assert {:error, msg} = Write.execute(%{"path" => path, "content" => "x"}, ctx)
      assert msg =~ "escapes working directory"
    end
  end

  # -- Plan 10: Encoding preservation -----------------------------------------

  describe "BOM preservation" do
    test "preserves BOM when overwriting a file that has one", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      bom = <<0xEF, 0xBB, 0xBF>>
      path = Path.join(tmp_dir, "bom.txt")
      File.write!(path, bom <> "old content")

      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "bom.txt", "content" => "new content"}, ctx)

      result = File.read!(path)
      assert <<0xEF, 0xBB, 0xBF, rest::binary>> = result
      assert rest == "new content"
    end

    test "does not add BOM to new files", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "fresh.txt", "content" => "hello"}, ctx)

      result = File.read!(Path.join(tmp_dir, "fresh.txt"))
      refute match?(<<0xEF, 0xBB, 0xBF, _::binary>>, result)
      assert result == "hello"
    end
  end

  describe "CRLF preservation" do
    test "preserves CRLF when overwriting a file that uses it", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "old\r\nlines\r\nhere")

      # LLM sends LF-only content (always)
      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "crlf.txt", "content" => "new\nlines\nhere"}, ctx)

      result = File.read!(path)
      assert result == "new\r\nlines\r\nhere"
    end

    test "does not add CRLF to new files", %{tmp_dir: tmp_dir} do
      ctx = %{working_dir: tmp_dir}

      assert {:ok, _, %{diff: _}} =
               Write.execute(%{"path" => "lf.txt", "content" => "line1\nline2"}, ctx)

      result = File.read!(Path.join(tmp_dir, "lf.txt"))
      assert result == "line1\nline2"
      refute result =~ "\r\n"
    end
  end
end
