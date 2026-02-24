defmodule Opal.SessionPersistenceTest do
  @moduledoc """
  Integration tests for session persistence, history navigation, and
  CLI state (model) persistence across sessions.
  """
  use ExUnit.Case, async: false

  alias Opal.Session
  alias Opal.Message

  setup do
    dir = Path.join(System.tmp_dir!(), "opal_persist_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ── Save & Load Round-Trip ─────────────────────────────────────────

  describe "save/load round-trip" do
    test "preserves messages, order, and parent chain", %{dir: dir} do
      sid = "roundtrip-#{System.unique_integer([:positive])}"
      {:ok, s1} = Session.start_link(session_id: sid)

      m1 = Message.user("hello")
      m2 = Message.assistant("hi there")
      m3 = Message.user("how are you?")
      :ok = Session.append(s1, m1)
      :ok = Session.append(s1, m2)
      :ok = Session.append(s1, m3)
      :ok = Session.save(s1, dir)

      GenServer.stop(s1)

      # Reload into a fresh process
      path = Path.join(dir, "#{sid}.dets")
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)

      path2 = Session.get_path(s2)
      assert length(path2) == 3
      assert Enum.map(path2, & &1.content) == ["hello", "hi there", "how are you?"]
      assert Enum.map(path2, & &1.role) == [:user, :assistant, :user]

      # Parent chain is intact
      [p1, p2, p3] = path2
      assert p1.parent_id == nil
      assert p2.parent_id == p1.id
      assert p3.parent_id == p2.id

      assert Session.current_id(s2) == m3.id
    end

    test "preserves metadata across save/load", %{dir: dir} do
      sid = "meta-#{System.unique_integer([:positive])}"
      {:ok, s1} = Session.start_link(session_id: sid)

      :ok = Session.set_metadata(s1, :title, "My Session")
      :ok = Session.set_metadata(s1, :custom_key, %{nested: true})
      :ok = Session.append(s1, Message.user("test"))
      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      path = Path.join(dir, "#{sid}.dets")
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)

      assert Session.get_metadata(s2, :title) == "My Session"
      assert Session.get_metadata(s2, :custom_key) == %{nested: true}
    end

    test "preserves branches across save/load", %{dir: dir} do
      sid = "branch-#{System.unique_integer([:positive])}"
      {:ok, s1} = Session.start_link(session_id: sid)

      m1 = Message.user("root")
      m2 = Message.assistant("branch A response")
      :ok = Session.append(s1, m1)
      :ok = Session.append(s1, m2)

      # Branch back to root, add alternate path
      :ok = Session.branch(s1, m1.id)
      m3 = Message.assistant("branch B response")
      :ok = Session.append(s1, m3)

      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      path = Path.join(dir, "#{sid}.dets")
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)

      # Current path should be the branch B path (m1 → m3)
      current_path = Session.get_path(s2)
      assert length(current_path) == 2
      assert Enum.map(current_path, & &1.id) == [m1.id, m3.id]

      # All messages should exist (including branch A)
      all = Session.all_messages(s2)
      assert length(all) == 3
      all_ids = Enum.map(all, & &1.id) |> MapSet.new()
      assert m1.id in all_ids
      assert m2.id in all_ids
      assert m3.id in all_ids

      # Can switch back to branch A
      :ok = Session.branch(s2, m2.id)
      branch_a = Session.get_path(s2)
      assert Enum.map(branch_a, & &1.id) == [m1.id, m2.id]
    end

    test "empty session saves and loads correctly", %{dir: dir} do
      sid = "empty-#{System.unique_integer([:positive])}"
      {:ok, s1} = Session.start_link(session_id: sid)
      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      path = Path.join(dir, "#{sid}.dets")
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)

      assert Session.get_path(s2) == []
      assert Session.current_id(s2) == nil
    end
  end

  # ── Session Listing ────────────────────────────────────────────────

  describe "list_sessions/1" do
    test "lists multiple sessions sorted newest-first", %{dir: dir} do
      for i <- 1..3 do
        sid = "list-#{i}-#{System.unique_integer([:positive])}"
        {:ok, s} = Session.start_link(session_id: sid)
        :ok = Session.append(s, Message.user("msg #{i}"))
        :ok = Session.save(s, dir)
        GenServer.stop(s)
        # Ensure different mtime (filesystem granularity can be 1s)
        if i < 3, do: Process.sleep(1100)
      end

      sessions = Session.list_sessions(dir)
      assert length(sessions) == 3

      # Newest first
      mtimes = Enum.map(sessions, & &1.modified)
      assert mtimes == Enum.sort(mtimes, {:desc, NaiveDateTime})
    end

    test "session listing includes correct IDs", %{dir: dir} do
      sid = "id-check-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)
      :ok = Session.append(s, Message.user("test"))
      :ok = Session.save(s, dir)
      GenServer.stop(s)

      [entry] = Session.list_sessions(dir)
      assert entry.id == sid
      assert String.ends_with?(entry.path, "#{sid}.dets")
    end

    test "session listing includes metadata title", %{dir: dir} do
      sid = "titled-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)
      :ok = Session.set_metadata(s, :title, "My Title")
      :ok = Session.append(s, Message.user("test"))
      :ok = Session.save(s, dir)
      GenServer.stop(s)

      [entry] = Session.list_sessions(dir)
      assert entry.title == "My Title"
    end
  end

  # ── History (recent_prompts) ───────────────────────────────────────

  describe "recent_prompts/2 (history navigation)" do
    test "extracts user prompts from saved sessions", %{dir: dir} do
      sid = "history-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)

      :ok = Session.append(s, Message.user("first prompt"))
      :ok = Session.append(s, Message.assistant("response 1"))
      :ok = Session.append(s, Message.user("second prompt"))
      :ok = Session.append(s, Message.assistant("response 2"))
      :ok = Session.save(s, dir)
      GenServer.stop(s)

      prompts = Session.recent_prompts(dir)
      texts = Enum.map(prompts, & &1["text"])

      # Should contain user messages only, newest-first
      assert "second prompt" in texts
      assert "first prompt" in texts
      refute "response 1" in texts
      refute "response 2" in texts

      # Newest first within a session
      idx_first = Enum.find_index(texts, &(&1 == "second prompt"))
      idx_second = Enum.find_index(texts, &(&1 == "first prompt"))
      assert idx_first < idx_second
    end

    test "collects prompts across multiple sessions", %{dir: dir} do
      for i <- 1..3 do
        sid = "multi-#{i}-#{System.unique_integer([:positive])}"
        {:ok, s} = Session.start_link(session_id: sid)
        :ok = Session.append(s, Message.user("prompt from session #{i}"))
        :ok = Session.append(s, Message.assistant("reply #{i}"))
        :ok = Session.save(s, dir)
        GenServer.stop(s)
        if i < 3, do: Process.sleep(1100)
      end

      prompts = Session.recent_prompts(dir)
      texts = Enum.map(prompts, & &1["text"])

      assert length(texts) == 3
      assert "prompt from session 1" in texts
      assert "prompt from session 2" in texts
      assert "prompt from session 3" in texts
    end

    test "respects limit option", %{dir: dir} do
      sid = "limit-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)

      for i <- 1..10 do
        :ok = Session.append(s, Message.user("prompt #{i}"))
        :ok = Session.append(s, Message.assistant("reply #{i}"))
      end

      :ok = Session.save(s, dir)
      GenServer.stop(s)

      prompts = Session.recent_prompts(dir, limit: 3)
      assert length(prompts) == 3
    end

    test "returns timestamps with prompts", %{dir: dir} do
      sid = "ts-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)
      :ok = Session.append(s, Message.user("timestamped"))
      :ok = Session.append(s, Message.assistant("reply"))
      :ok = Session.save(s, dir)
      GenServer.stop(s)

      [prompt | _] = Session.recent_prompts(dir)
      assert Map.has_key?(prompt, "text")
      assert Map.has_key?(prompt, "timestamp")
      assert is_binary(prompt["timestamp"])
    end

    test "follows active branch for history", %{dir: dir} do
      sid = "branch-hist-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)

      m1 = Message.user("root question")
      :ok = Session.append(s, m1)
      :ok = Session.append(s, Message.assistant("old reply"))
      :ok = Session.append(s, Message.user("old follow-up"))

      # Branch back to root and take a new path
      :ok = Session.branch(s, m1.id)
      :ok = Session.append(s, Message.assistant("new reply"))
      :ok = Session.append(s, Message.user("new follow-up"))

      :ok = Session.save(s, dir)
      GenServer.stop(s)

      prompts = Session.recent_prompts(dir)
      texts = Enum.map(prompts, & &1["text"])

      # Should follow the current branch (root → new reply → new follow-up)
      assert "root question" in texts
      assert "new follow-up" in texts
      # Old branch should NOT appear since we follow current_id path
      refute "old follow-up" in texts
    end

    test "returns empty for directory with no sessions", %{dir: dir} do
      assert Session.recent_prompts(dir) == []
    end

    test "skips sessions with no user messages", %{dir: dir} do
      sid = "no-user-#{System.unique_integer([:positive])}"
      {:ok, s} = Session.start_link(session_id: sid)
      # Only system/assistant messages
      :ok = Session.append(s, Message.assistant("just a response"))
      :ok = Session.save(s, dir)
      GenServer.stop(s)

      assert Session.recent_prompts(dir) == []
    end
  end

  # ── CLI State (Model Persistence) ──────────────────────────────────

  # ── End-to-End: Save → List → Load → History ──────────────────────

  describe "end-to-end session lifecycle" do
    test "create session, save, list, reload, verify history", %{dir: dir} do
      sid = "e2e-#{System.unique_integer([:positive])}"

      # 1. Create session and add a conversation
      {:ok, s1} = Session.start_link(session_id: sid)
      :ok = Session.set_metadata(s1, :title, "E2E Test")
      :ok = Session.append(s1, Message.user("What is Elixir?"))
      :ok = Session.append(s1, Message.assistant("Elixir is a functional language."))
      :ok = Session.append(s1, Message.user("Tell me more"))
      :ok = Session.append(s1, Message.assistant("It runs on the BEAM VM."))
      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      # 2. List sessions — should find our session
      sessions = Session.list_sessions(dir)
      assert length(sessions) == 1
      assert hd(sessions).id == sid
      assert hd(sessions).title == "E2E Test"

      # 3. Reload from disk
      path = hd(sessions).path
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)

      # 4. Verify full conversation is intact
      path2 = Session.get_path(s2)
      assert length(path2) == 4
      contents = Enum.map(path2, & &1.content)

      assert contents == [
               "What is Elixir?",
               "Elixir is a functional language.",
               "Tell me more",
               "It runs on the BEAM VM."
             ]

      # 5. History should contain only user prompts, newest-first
      prompts = Session.recent_prompts(dir)
      texts = Enum.map(prompts, & &1["text"])
      assert texts == ["Tell me more", "What is Elixir?"]

      # 6. Can continue the conversation after loading
      :ok = Session.append(s2, Message.user("What about OTP?"))
      path3 = Session.get_path(s2)
      assert length(path3) == 5
      assert List.last(path3).content == "What about OTP?"
    end

    test "multiple sessions contribute to combined history", %{dir: dir} do
      # Session 1
      {:ok, s1} = Session.start_link(session_id: "multi-a-#{System.unique_integer([:positive])}")
      :ok = Session.append(s1, Message.user("alpha"))
      :ok = Session.append(s1, Message.assistant("reply alpha"))
      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      # Ensure different mtime (filesystem granularity can be 1s)
      Process.sleep(1100)

      # Session 2
      {:ok, s2} = Session.start_link(session_id: "multi-b-#{System.unique_integer([:positive])}")
      :ok = Session.append(s2, Message.user("beta"))
      :ok = Session.append(s2, Message.assistant("reply beta"))
      :ok = Session.save(s2, dir)
      GenServer.stop(s2)

      # History should have prompts from both, newest session first
      prompts = Session.recent_prompts(dir)
      texts = Enum.map(prompts, & &1["text"])
      assert length(texts) == 2
      assert hd(texts) == "beta"
      assert List.last(texts) == "alpha"
    end

    test "overwriting a saved session preserves latest data", %{dir: dir} do
      sid = "overwrite-#{System.unique_integer([:positive])}"

      # First save
      {:ok, s1} = Session.start_link(session_id: sid)
      :ok = Session.append(s1, Message.user("version 1"))
      :ok = Session.save(s1, dir)

      # Add more messages and save again
      :ok = Session.append(s1, Message.assistant("reply"))
      :ok = Session.append(s1, Message.user("version 2"))
      :ok = Session.save(s1, dir)
      GenServer.stop(s1)

      # Load should have all 3 messages
      path = Path.join(dir, "#{sid}.dets")
      {:ok, s2} = Session.start_link(session_id: sid, load_from: path)
      assert length(Session.get_path(s2)) == 3
    end
  end
end
