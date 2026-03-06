defmodule Opal.Agent.Smoosh.ChunkerTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Smoosh.Chunker

  describe "detect_type/1" do
    test "detects markdown by heading" do
      assert Chunker.detect_type("# Hello\nworld") == :markdown
    end

    test "detects markdown by code fence" do
      assert Chunker.detect_type("Some text\n```elixir\ncode\n```") == :markdown
    end

    test "detects markdown by bold text" do
      assert Chunker.detect_type("**Important** notice here") == :markdown
    end

    test "detects markdown by link" do
      assert Chunker.detect_type("[click](http://example.com)") == :markdown
    end

    test "detects JSON object" do
      assert Chunker.detect_type(~s|{"key": "value"}|) == :json
    end

    test "detects JSON array" do
      assert Chunker.detect_type(~s|[1, 2, 3]|) == :json
    end

    test "falls back to plaintext" do
      assert Chunker.detect_type("just some plain text\nwith lines") == :plaintext
    end

    test "invalid JSON starting with { falls back" do
      assert Chunker.detect_type("{not valid json at all}") == :plaintext
    end
  end

  describe "chunk/2 markdown" do
    test "splits by headings" do
      md = """
      # Section One

      First content.

      ## Section Two

      Second content.
      """

      chunks = Chunker.chunk(md)
      titles = Enum.map(chunks, & &1.title)

      assert "Section One" in titles
      assert "Section Two" in titles
    end

    test "preserves code block content" do
      md = """
      # Code Example

      ```elixir
      defmodule Foo do
        def bar, do: :ok
      end
      ```

      Some explanation.
      """

      chunks = Chunker.chunk(md)
      code_chunk = Enum.find(chunks, &(&1.title == "Code Example"))
      assert code_chunk
      assert String.contains?(code_chunk.content, "defmodule Foo")
    end

    test "splits oversized sections" do
      # 5000 bytes > 4096 default max
      large_body = String.duplicate("x", 5000)

      md = "# Big Section\n\n#{large_body}"
      chunks = Chunker.chunk(md, max_bytes: 4096)

      assert length(chunks) > 1
      assert Enum.all?(chunks, fn c -> byte_size(c.content) <= 4096 end)
    end

    test "uses label as fallback title for untitled content" do
      md = "# \n\nSome text without a heading title."
      chunks = Chunker.chunk(md, label: "test_source")
      # The empty heading extracts to "", so the label is used as fallback
      assert hd(chunks).title == "test_source"
    end
  end

  describe "chunk/2 JSON" do
    test "small JSON stays as single chunk" do
      json = Jason.encode!(%{name: "test", value: 42})
      chunks = Chunker.chunk(json)

      assert length(chunks) == 1
      assert hd(chunks).content_type == :prose
    end

    test "large JSON object is split by keys" do
      large = for i <- 1..50, into: %{}, do: {"key_#{i}", String.duplicate("x", 200)}
      json = Jason.encode!(large)

      chunks = Chunker.chunk(json, max_bytes: 1024)
      assert length(chunks) > 1
    end

    test "large JSON array is batched" do
      items = for i <- 1..100, do: %{id: i, data: String.duplicate("y", 100)}
      json = Jason.encode!(items)

      chunks = Chunker.chunk(json, max_bytes: 2048)
      assert length(chunks) > 1

      # Titles should have array range notation
      assert Enum.any?(chunks, fn c -> String.contains?(c.title, "[") end)
    end

    test "key paths used as titles for nested objects" do
      json =
        Jason.encode!(%{
          users: %{
            admin: %{name: "Alice", role: "admin"},
            guest: %{name: "Bob", role: "guest"}
          }
        })

      chunks = Chunker.chunk(json, max_bytes: 64)
      titles = Enum.map(chunks, & &1.title)
      assert Enum.any?(titles, &String.contains?(&1, "users"))
    end
  end

  describe "chunk/2 plaintext" do
    test "splits by blank lines when paragraphs exist" do
      text = """
      First paragraph with some content.

      Second paragraph with more content.

      Third paragraph here.
      """

      chunks = Chunker.chunk(text)
      assert length(chunks) == 3
    end

    test "uses fixed-line groups for unstructured text" do
      lines = for i <- 1..100, do: "Line #{i}: #{String.duplicate("x", 50)}"
      text = Enum.join(lines, "\n")

      chunks = Chunker.chunk(text, max_bytes: 2048)
      assert length(chunks) > 1
    end

    test "respects max_bytes" do
      text = String.duplicate("a line of text\n", 500)
      chunks = Chunker.chunk(text, max_bytes: 1024)

      assert Enum.all?(chunks, fn c -> byte_size(c.content) <= 1100 end)
    end
  end

  describe "chunk/2 edge cases" do
    test "empty content returns empty list" do
      assert Chunker.chunk("") == []
    end

    test "whitespace-only returns empty list" do
      assert Chunker.chunk("   \n  \n  ") == []
    end

    test "single small content returns single chunk" do
      chunks = Chunker.chunk("hello world")
      assert length(chunks) == 1
      assert hd(chunks).content == "hello world"
    end
  end
end
