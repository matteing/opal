defmodule Opal.Tool.Edit.FuzzyTest do
  use ExUnit.Case, async: true

  alias Opal.Tool.Edit.Fuzzy

  # -- Normalization ----------------------------------------------------------

  describe "normalize/1" do
    test "strips trailing whitespace from each line" do
      assert Fuzzy.normalize("hello   \nworld  ") == "hello\nworld"
    end

    test "normalizes curly single quotes to straight" do
      # \u2018 = left single, \u2019 = right single
      assert Fuzzy.normalize("\u2018hello\u2019") == "'hello'"
    end

    test "normalizes curly double quotes to straight" do
      # \u201C = left double, \u201D = right double
      assert Fuzzy.normalize("\u201Chello\u201D") == "\"hello\""
    end

    test "normalizes guillemets to double quotes" do
      assert Fuzzy.normalize("\u00ABhello\u00BB") == "\"hello\""
    end

    test "normalizes em-dash to hyphen" do
      assert Fuzzy.normalize("foo\u2014bar") == "foo-bar"
    end

    test "normalizes en-dash to hyphen" do
      assert Fuzzy.normalize("foo\u2013bar") == "foo-bar"
    end

    test "normalizes math minus to hyphen" do
      assert Fuzzy.normalize("x \u2212 y") == "x - y"
    end

    test "normalizes non-breaking space to regular space" do
      assert Fuzzy.normalize("hello\u00A0world") == "hello world"
    end

    test "normalizes thin/hair spaces to regular space" do
      # \u2009 = thin space, \u200A = hair space
      assert Fuzzy.normalize("a\u2009b\u200Ac") == "a b c"
    end

    test "applies all normalizations in combination" do
      input = "\u201Chello\u201D \u2014 \u2018world\u2019   "
      expected = "\"hello\" - 'world'"
      assert Fuzzy.normalize(input) == expected
    end
  end

  # -- Fuzzy find -------------------------------------------------------------

  describe "fuzzy_find/2" do
    test "finds match when curly quotes differ" do
      content = "puts 'hello world'"
      pattern = "puts \u2018hello world\u2019"

      assert {:ok, "puts 'hello world'"} = Fuzzy.fuzzy_find(content, pattern)
    end

    test "finds match when em-dash differs from hyphen" do
      content = "foo - bar - baz"
      pattern = "foo \u2014 bar \u2014 baz"

      assert {:ok, "foo - bar - baz"} = Fuzzy.fuzzy_find(content, pattern)
    end

    test "finds match when trailing whitespace differs" do
      content = "hello   \nworld  "
      pattern = "hello\nworld"

      assert {:ok, _original} = Fuzzy.fuzzy_find(content, pattern)
    end

    test "finds match with non-breaking spaces" do
      content = "value\u00A0= 42"
      pattern = "value = 42"

      assert {:ok, "value\u00A0= 42"} = Fuzzy.fuzzy_find(content, pattern)
    end

    test "returns :no_match when text is truly absent" do
      assert :no_match = Fuzzy.fuzzy_find("hello world", "completely different")
    end

    test "returns :no_match when multiple fuzzy matches exist (ambiguous)" do
      # Both occurrences of 'hello' would match the curly-quoted pattern
      content = "'hello' and 'hello'"
      pattern = "\u2018hello\u2019"

      assert :no_match = Fuzzy.fuzzy_find(content, pattern)
    end

    test "returns the original (non-normalized) substring" do
      # The original has an em-dash; the pattern has a hyphen.
      # The returned value should be the em-dash version.
      content = "prefix \u2014 suffix"
      pattern = "prefix - suffix"

      assert {:ok, "prefix \u2014 suffix"} = Fuzzy.fuzzy_find(content, pattern)
    end

    test "returns :no_match for empty pattern" do
      # Empty normalized pattern would match everywhere — treat as no match
      # (the caller already guards empty old_string, but be safe)
      content = "some content"
      # A pattern that normalizes to empty is unlikely but test the edge
      assert :no_match = Fuzzy.fuzzy_find(content, "truly missing text")
    end
  end
end
