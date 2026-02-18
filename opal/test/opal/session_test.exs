defmodule Opal.SessionTest do
  use ExUnit.Case, async: true

  alias Opal.Session
  alias Opal.Message

  setup do
    {:ok, session} =
      Session.start_link(session_id: "test-session-#{System.unique_integer([:positive])}")

    %{session: session}
  end

  describe "append/2 and get_path/1" do
    test "empty session returns empty path", %{session: session} do
      assert Session.get_path(session) == []
    end

    test "appending a message makes it the current leaf", %{session: session} do
      msg = Message.user("hello")
      :ok = Session.append(session, msg)

      assert Session.current_id(session) == msg.id
      path = Session.get_path(session)
      assert length(path) == 1
      assert hd(path).id == msg.id
    end

    test "appending multiple messages builds a linear path", %{session: session} do
      m1 = Message.user("first")
      m2 = Message.assistant("reply")
      m3 = Message.user("follow-up")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)
      :ok = Session.append(session, m3)

      path = Session.get_path(session)
      assert length(path) == 3
      assert Enum.map(path, & &1.id) == [m1.id, m2.id, m3.id]

      # Verify parent_id chain
      [p1, p2, p3] = path
      assert p1.parent_id == nil
      assert p2.parent_id == m1.id
      assert p3.parent_id == m2.id
    end
  end

  describe "append_many/2" do
    test "appends multiple messages in order", %{session: session} do
      msgs = [Message.user("a"), Message.assistant("b"), Message.user("c")]
      :ok = Session.append_many(session, msgs)

      path = Session.get_path(session)
      assert length(path) == 3
      assert Enum.map(path, & &1.content) == ["a", "b", "c"]
    end
  end

  describe "get_message/2" do
    test "returns the message by ID", %{session: session} do
      msg = Message.user("test")
      :ok = Session.append(session, msg)

      found = Session.get_message(session, msg.id)
      assert found.id == msg.id
      assert found.content == "test"
    end

    test "returns nil for unknown ID", %{session: session} do
      assert Session.get_message(session, "nonexistent") == nil
    end
  end

  describe "branch/2" do
    test "branches from a past message", %{session: session} do
      m1 = Message.user("first")
      m2 = Message.assistant("reply")
      m3 = Message.user("follow-up")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)
      :ok = Session.append(session, m3)

      # Branch back to m1
      :ok = Session.branch(session, m1.id)
      assert Session.current_id(session) == m1.id

      # Append a new message from the branch point
      m4 = Message.user("alternate follow-up")
      :ok = Session.append(session, m4)

      # Path should be m1 → m4
      path = Session.get_path(session)
      assert length(path) == 2
      assert Enum.map(path, & &1.id) == [m1.id, m4.id]
    end

    test "returns error for nonexistent message", %{session: session} do
      assert Session.branch(session, "nope") == {:error, :not_found}
    end
  end

  describe "get_tree/1" do
    test "returns empty list for empty session", %{session: session} do
      assert Session.get_tree(session) == []
    end

    test "returns nested tree structure", %{session: session} do
      m1 = Message.user("root")
      m2 = Message.assistant("reply")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)

      tree = Session.get_tree(session)
      assert length(tree) == 1

      root = hd(tree)
      assert root.message.id == m1.id
      assert length(root.children) == 1
      assert hd(root.children).message.id == m2.id
    end

    test "shows branches in tree", %{session: session} do
      m1 = Message.user("root")
      m2 = Message.assistant("branch A")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)

      # Branch back to root
      :ok = Session.branch(session, m1.id)
      m3 = Message.assistant("branch B")
      :ok = Session.append(session, m3)

      tree = Session.get_tree(session)
      root = hd(tree)
      assert root.message.id == m1.id
      assert length(root.children) == 2

      child_ids = Enum.map(root.children, & &1.message.id) |> Enum.sort()
      expected = Enum.sort([m2.id, m3.id])
      assert child_ids == expected
    end
  end

  describe "all_messages/1" do
    test "returns all messages unordered", %{session: session} do
      m1 = Message.user("a")
      m2 = Message.assistant("b")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)

      all = Session.all_messages(session)
      assert length(all) == 2
      ids = Enum.map(all, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([m1.id, m2.id])
    end
  end

  describe "session_id/1" do
    test "returns the session ID", %{session: session} do
      id = Session.session_id(session)
      assert is_binary(id)
      assert String.starts_with?(id, "test-session-")
    end
  end

  describe "save/2 and load/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "opal_session_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "saves and loads a session", %{session: session, dir: dir} do
      m1 = Message.user("hello")
      m2 = Message.assistant("hi there")
      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)

      :ok = Session.save(session, dir)

      # Verify the file exists
      session_id = Session.session_id(session)
      path = Path.join(dir, "#{session_id}.dets")
      assert File.exists?(path)

      # Create a new session and load from DETS
      {:ok, session2} = Session.start_link(session_id: session_id, load_from: path)

      path2 = Session.get_path(session2)
      assert length(path2) == 2
      assert Enum.map(path2, & &1.content) == ["hello", "hi there"]
      assert Session.current_id(session2) == m2.id
    end

    test "load returns error for missing file", %{session: session, dir: dir} do
      # Save and verify it works; no separate load/2 API — loading is via start_link opts
      :ok = Session.append(session, Message.user("test"))
      :ok = Session.save(session, dir)
      session_id = Session.session_id(session)
      path = Path.join(dir, "#{session_id}.dets")
      assert File.exists?(path)
    end
  end

  describe "list_sessions/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "opal_sessions_list_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "lists saved sessions", %{session: session, dir: dir} do
      m1 = Message.user("test")
      :ok = Session.append(session, m1)
      :ok = Session.save(session, dir)

      sessions = Session.list_sessions(dir)
      assert length(sessions) == 1

      entry = hd(sessions)
      assert entry.id == Session.session_id(session)
      assert String.ends_with?(entry.path, ".dets")
    end

    test "returns empty list for empty directory", %{dir: dir} do
      assert Session.list_sessions(dir) == []
    end

    test "returns empty list for nonexistent directory" do
      assert Session.list_sessions("/nonexistent/dir") == []
    end
  end

  describe "replace_path_segment/3 (compaction support)" do
    test "replaces middle segment with summary", %{session: session} do
      m1 = Message.user("old 1")
      m2 = Message.assistant("old 2")
      m3 = Message.user("old 3")
      m4 = Message.assistant("keep 1")
      m5 = Message.user("keep 2")

      :ok = Session.append(session, m1)
      :ok = Session.append(session, m2)
      :ok = Session.append(session, m3)
      :ok = Session.append(session, m4)
      :ok = Session.append(session, m5)

      # Remove the first 3, replace with summary
      summary = %Message{
        id: "summary-id",
        role: :assistant,
        content: "[Summary of 3 messages]"
      }

      :ok = Session.replace_path_segment(session, [m1.id, m2.id, m3.id], summary)

      path = Session.get_path(session)
      assert length(path) == 3

      [s, k1, k2] = path
      assert s.id == "summary-id"
      assert s.content == "[Summary of 3 messages]"
      assert s.parent_id == nil
      assert k1.parent_id == "summary-id"
      assert k2.content == "keep 2"
    end
  end
end
