defmodule Opal.FileIOTest do
  use ExUnit.Case, async: true

  alias Opal.FileIO

  # ── Encoding ──────────────────────────────────────────────────────────

  describe "normalize_encoding/1 + restore_encoding/2" do
    test "round-trips BOM content" do
      bom = <<0xEF, 0xBB, 0xBF>>
      original = bom <> "hello world"

      {info, clean} = FileIO.normalize_encoding(original)
      assert clean == "hello world"
      assert info.bom == true
      assert FileIO.restore_encoding(clean, info) == original
    end

    test "round-trips CRLF content" do
      original = "aaa\r\nbbb\r\nccc"

      {info, clean} = FileIO.normalize_encoding(original)
      assert clean == "aaa\nbbb\nccc"
      assert info.crlf == true
      assert FileIO.restore_encoding(clean, info) == original
    end

    test "round-trips BOM + CRLF together" do
      bom = <<0xEF, 0xBB, 0xBF>>
      original = bom <> "line1\r\nline2\r\n"

      {info, clean} = FileIO.normalize_encoding(original)
      assert info == %{bom: true, crlf: true}
      assert clean == "line1\nline2\n"
      assert FileIO.restore_encoding(clean, info) == original
    end

    test "no-ops on clean content" do
      {info, clean} = FileIO.normalize_encoding("plain text\n")
      assert info == %{bom: false, crlf: false}
      assert clean == "plain text\n"
    end

    test "handles empty content" do
      {info, clean} = FileIO.normalize_encoding("")
      assert info == %{bom: false, crlf: false}
      assert clean == ""
    end

    test "handles content that is only a BOM" do
      bom = <<0xEF, 0xBB, 0xBF>>
      {info, clean} = FileIO.normalize_encoding(bom)
      assert info.bom == true
      assert clean == ""
    end

    test "does not strip BOM-like bytes mid-content" do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = "prefix" <> bom <> "suffix"
      {info, _clean} = FileIO.normalize_encoding(content)
      assert info.bom == false
    end
  end

  # ── Truncation ────────────────────────────────────────────────────────

  describe "truncate/2" do
    test "returns short strings unchanged" do
      assert FileIO.truncate("hello", 100) == "hello"
    end

    test "truncates long strings with marker" do
      result = FileIO.truncate(String.duplicate("x", 200), 10)
      assert String.starts_with?(result, "xxxxxxxxxx")
      assert result =~ "truncated"
    end
  end

  describe "truncate_at_line/2" do
    test "truncates at last newline before limit" do
      content = "line1\nline2\nline3\nline4"
      result = FileIO.truncate_at_line(content, 12)
      assert result == "line1\nline2"
    end

    test "returns full content if under limit" do
      content = "short"
      assert FileIO.truncate_at_line(content, 100) == "short"
    end
  end
end
