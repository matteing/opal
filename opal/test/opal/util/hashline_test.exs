defmodule Opal.HashlineTest do
  use ExUnit.Case, async: true

  alias Opal.Hashline

  describe "line_hash/1" do
    test "returns a 2-character hex string" do
      hash = Hashline.line_hash("hello world")
      assert String.length(hash) == 2
      assert String.match?(hash, ~r/^[0-9a-f]{2}$/)
    end

    test "is deterministic" do
      assert Hashline.line_hash("foo") == Hashline.line_hash("foo")
    end

    test "trims whitespace before hashing" do
      assert Hashline.line_hash("  hello  ") == Hashline.line_hash("hello")
    end

    test "empty lines hash consistently" do
      assert Hashline.line_hash("") == Hashline.line_hash("   ")
    end

    test "different content produces different hashes (usually)" do
      h1 = Hashline.line_hash("function foo() {")
      h2 = Hashline.line_hash("return 42;")
      assert h1 != h2
    end
  end

  describe "tag_lines/2" do
    test "tags each line with N:hash|content format" do
      content = "line one\nline two\nline three"
      tagged = Hashline.tag_lines(content)

      lines = String.split(tagged, "\n")
      assert length(lines) == 3

      Enum.each(lines, fn line ->
        assert String.match?(line, ~r/^\d+:[0-9a-f]{2}\|/)
      end)

      assert String.starts_with?(Enum.at(lines, 0), "1:")
      assert String.starts_with?(Enum.at(lines, 1), "2:")
      assert String.starts_with?(Enum.at(lines, 2), "3:")
    end

    test "preserves original content after the pipe" do
      content = "  indented\nnormal"
      tagged = Hashline.tag_lines(content)
      lines = String.split(tagged, "\n")

      [_, after_pipe] = String.split(Enum.at(lines, 0), "|", parts: 2)
      assert after_pipe == "  indented"
    end

    test "respects start_line offset" do
      content = "a\nb\nc"
      tagged = Hashline.tag_lines(content, 10)
      lines = String.split(tagged, "\n")

      assert String.starts_with?(Enum.at(lines, 0), "10:")
      assert String.starts_with?(Enum.at(lines, 1), "11:")
    end
  end

  describe "parse_anchor/1" do
    test "parses valid anchor" do
      assert {:ok, {5, "a3"}} = Hashline.parse_anchor("5:a3")
    end

    test "normalizes hash to lowercase" do
      assert {:ok, {1, "ff"}} = Hashline.parse_anchor("1:FF")
    end

    test "rejects invalid format" do
      assert {:error, _} = Hashline.parse_anchor("bad")
      assert {:error, _} = Hashline.parse_anchor("5:")
      assert {:error, _} = Hashline.parse_anchor(":a3")
      assert {:error, _} = Hashline.parse_anchor("0:a3")
      assert {:error, _} = Hashline.parse_anchor("-1:a3")
    end
  end

  describe "validate_hash/3" do
    test "accepts correct hash" do
      lines = ["hello", "world"]
      hash = Hashline.line_hash("hello")
      assert :ok = Hashline.validate_hash(lines, 1, hash)
    end

    test "rejects wrong hash" do
      lines = ["hello", "world"]
      assert {:error, msg} = Hashline.validate_hash(lines, 1, "zz")
      assert msg =~ "Hash mismatch"
    end

    test "rejects out-of-range line" do
      lines = ["hello"]
      assert {:error, msg} = Hashline.validate_hash(lines, 5, "aa")
      assert msg =~ "out of range"
    end
  end
end
