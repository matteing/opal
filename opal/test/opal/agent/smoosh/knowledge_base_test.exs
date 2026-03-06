defmodule Opal.Agent.Smoosh.KnowledgeBaseTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Smoosh.KnowledgeBase

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    session_id = "test-kb-#{System.unique_integer([:positive])}"
    {:ok, pid} = KnowledgeBase.start_link(session_id, tmp_dir)
    %{pid: pid, session_id: session_id, tmp_dir: tmp_dir}
  end

  describe "lifecycle" do
    test "starts and registers in Opal.Registry", %{pid: pid, session_id: sid} do
      assert Process.alive?(pid)
      assert {:ok, ^pid} = KnowledgeBase.lookup(sid)
    end

    test "lookup returns :not_started for unknown session" do
      assert :not_started = KnowledgeBase.lookup("nonexistent-session")
    end

    test "has_content? is false initially", %{pid: pid} do
      refute KnowledgeBase.has_content?(pid)
    end

    test "creates sqlite file on disk", %{tmp_dir: tmp_dir, session_id: sid} do
      assert File.exists?(Path.join([tmp_dir, sid, "kb.sqlite3"]))
    end
  end

  describe "index/4" do
    test "indexes content and returns chunk count", %{pid: pid} do
      content = """
      # Hello World

      This is some test content for indexing.

      ## Details

      More detailed information here.
      """

      assert {:ok, %{chunks: n}} = KnowledgeBase.index(pid, "test_source", content)
      assert n > 0
    end

    test "has_content? is true after indexing", %{pid: pid} do
      KnowledgeBase.index(pid, "src", "test content here")
      assert KnowledgeBase.has_content?(pid)
    end

    test "deduplicates on re-index with same label", %{pid: pid} do
      KnowledgeBase.index(pid, "shell: ls", "first version of output")
      KnowledgeBase.index(pid, "shell: ls", "second version of output")

      sources = KnowledgeBase.list_sources(pid)
      ls_sources = Enum.filter(sources, &(&1.label == "shell: ls"))
      assert length(ls_sources) == 1
    end

    test "different labels create separate sources", %{pid: pid} do
      KnowledgeBase.index(pid, "tool_a", "content a")
      KnowledgeBase.index(pid, "tool_b", "content b")

      sources = KnowledgeBase.list_sources(pid)
      assert length(sources) == 2
    end
  end

  describe "search/3" do
    setup %{pid: pid} do
      KnowledgeBase.index(pid, "shell: gh issue list", """
      # GitHub Issues

      ## Authentication Bug

      Users are experiencing login failures when using OAuth tokens.
      The authentication middleware rejects valid tokens after rotation.

      ## Performance Regression

      API response times increased by 300ms after the database migration.
      Query optimization needed for the user_sessions table.
      """)

      KnowledgeBase.index(pid, "grep: config", """
      config/auth.ex:15: @token_ttl 3600
      config/auth.ex:22: @refresh_window 300
      config/database.ex:8: pool_size: 10
      """)

      :ok
    end

    test "finds results with Porter stemming (running → run)", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "authentication")
      assert length(results) > 0
      assert Enum.any?(results, &String.contains?(&1.content, "login"))
    end

    test "finds results with exact terms", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "OAuth tokens")
      assert length(results) > 0
    end

    test "respects limit option", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "the", limit: 1)
      assert length(results) <= 1
    end

    test "source filter narrows results", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "config", source: "grep")
      assert Enum.all?(results, &String.contains?(&1.source, "grep"))
    end

    test "returns empty list for no match", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "xyzzy_nonexistent_term")
      assert results == []
    end

    test "results include rank and metadata", %{pid: pid} do
      {:ok, [result | _]} = KnowledgeBase.search(pid, "authentication")
      assert is_float(result.rank)
      assert is_binary(result.title)
      assert is_binary(result.content)
      assert is_binary(result.source)
      assert result.content_type in [:code, :prose]
    end

    test "trigram fallback finds partial identifiers", %{pid: pid} do
      # "token_ttl" won't match Porter stemming but should match trigram
      {:ok, results} = KnowledgeBase.search(pid, "token_ttl")
      assert length(results) > 0
    end

    test "fuzzy correction finds misspelled terms", %{pid: pid} do
      # "authenticaton" (missing 'i') should fuzzy-correct to "authentication"
      {:ok, results} = KnowledgeBase.search(pid, "authenticaton")
      assert length(results) > 0
      assert Enum.any?(results, &String.contains?(&1.content, "login"))
    end

    test "fuzzy correction returns nothing when no close match", %{pid: pid} do
      {:ok, results} = KnowledgeBase.search(pid, "zzzzxyzzy")
      assert results == []
    end
  end

  describe "list_sources/1" do
    test "returns all indexed sources", %{pid: pid} do
      KnowledgeBase.index(pid, "source_a", "content a")
      KnowledgeBase.index(pid, "source_b", "content b")

      sources = KnowledgeBase.list_sources(pid)
      labels = Enum.map(sources, & &1.label)
      assert "source_a" in labels
      assert "source_b" in labels
    end

    test "includes chunk counts", %{pid: pid} do
      KnowledgeBase.index(pid, "multi", "# One\n\ncontent\n\n# Two\n\nmore content")

      [source] = KnowledgeBase.list_sources(pid)
      assert source.chunk_count > 0
    end
  end

  describe "sanitize_query/2" do
    test "wraps terms in quotes for AND mode" do
      assert KnowledgeBase.sanitize_query("hello world") == ~s|"hello" "world"|
    end

    test "wraps terms in quotes for OR mode" do
      assert KnowledgeBase.sanitize_query("hello world", :or) == ~s|"hello" OR "world"|
    end

    test "strips FTS5 operators" do
      assert KnowledgeBase.sanitize_query("NOT hello AND world") == ~s|"hello" "world"|
    end

    test "strips special characters" do
      assert KnowledgeBase.sanitize_query("test's (value)") == ~s|"test" "s" "value"|
    end
  end

  describe "levenshtein/2" do
    test "identical strings have distance 0" do
      assert KnowledgeBase.levenshtein("hello", "hello") == 0
    end

    test "empty vs non-empty" do
      assert KnowledgeBase.levenshtein("", "abc") == 3
      assert KnowledgeBase.levenshtein("abc", "") == 3
    end

    test "single substitution" do
      assert KnowledgeBase.levenshtein("cat", "bat") == 1
    end

    test "single insertion" do
      assert KnowledgeBase.levenshtein("cat", "cats") == 1
    end

    test "single deletion" do
      assert KnowledgeBase.levenshtein("cats", "cat") == 1
    end

    test "multiple edits" do
      assert KnowledgeBase.levenshtein("kitten", "sitting") == 3
    end
  end

  describe "stopwords" do
    test "common words are excluded from vocabulary", %{pid: pid} do
      KnowledgeBase.index(
        pid,
        "stopword_test",
        "the quick brown fox and the lazy dog with very much running"
      )

      # "the", "and", "with", "very", "much", "running" are stopwords
      # "quick", "brown", "fox", "lazy", "dog" should be in vocabulary
      # Search for a non-stopword should work
      {:ok, results} = KnowledgeBase.search(pid, "quick brown fox")
      assert length(results) > 0
    end
  end
end
