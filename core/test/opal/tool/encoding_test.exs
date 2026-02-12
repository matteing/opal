defmodule Opal.Tool.EncodingTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.Encoding

  # -- BOM handling -----------------------------------------------------------

  describe "strip_bom/1" do
    test "strips UTF-8 BOM from content" do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = bom <> "hello world"

      assert {true, "hello world"} = Encoding.strip_bom(content)
    end

    test "returns false when no BOM present" do
      assert {false, "hello world"} = Encoding.strip_bom("hello world")
    end

    test "handles empty content" do
      assert {false, ""} = Encoding.strip_bom("")
    end

    test "handles content that is only a BOM" do
      bom = <<0xEF, 0xBB, 0xBF>>
      assert {true, ""} = Encoding.strip_bom(bom)
    end

    test "does not strip BOM-like bytes mid-content" do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = "prefix" <> bom <> "suffix"
      assert {false, ^content} = Encoding.strip_bom(content)
    end
  end

  describe "restore_bom/2" do
    test "prepends BOM when had_bom is true" do
      bom = <<0xEF, 0xBB, 0xBF>>
      result = Encoding.restore_bom("hello", true)
      assert result == bom <> "hello"
    end

    test "returns content unchanged when had_bom is false" do
      assert "hello" = Encoding.restore_bom("hello", false)
    end

    test "round-trips correctly" do
      bom = <<0xEF, 0xBB, 0xBF>>
      original = bom <> "some content\nwith lines"

      {had_bom, stripped} = Encoding.strip_bom(original)
      restored = Encoding.restore_bom(stripped, had_bom)

      assert restored == original
    end
  end

  # -- Line-ending handling ---------------------------------------------------

  describe "normalize_line_endings/1" do
    test "converts CRLF to LF" do
      content = "line1\r\nline2\r\nline3"
      assert {true, "line1\nline2\nline3"} = Encoding.normalize_line_endings(content)
    end

    test "returns false when no CRLF present" do
      content = "line1\nline2\nline3"
      assert {false, ^content} = Encoding.normalize_line_endings(content)
    end

    test "handles empty content" do
      assert {false, ""} = Encoding.normalize_line_endings("")
    end

    test "handles content with only CRLF" do
      assert {true, "\n\n"} = Encoding.normalize_line_endings("\r\n\r\n")
    end
  end

  describe "restore_line_endings/2" do
    test "converts LF back to CRLF when had_crlf is true" do
      assert "line1\r\nline2" = Encoding.restore_line_endings("line1\nline2", true)
    end

    test "returns content unchanged when had_crlf is false" do
      assert "line1\nline2" = Encoding.restore_line_endings("line1\nline2", false)
    end

    test "round-trips correctly" do
      original = "aaa\r\nbbb\r\nccc"

      {had_crlf, normalized} = Encoding.normalize_line_endings(original)
      restored = Encoding.restore_line_endings(normalized, had_crlf)

      assert restored == original
    end
  end
end
