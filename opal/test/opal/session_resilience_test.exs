defmodule Opal.SessionResilienceTest do
  @moduledoc """
  Tests session persistence resilience: save to invalid path,
  load from nonexistent/corrupt DETS, session process death.
  """
  use ExUnit.Case, async: true

  alias Opal.Session

  describe "save to invalid path" do
    test "save with nonexistent directory crashes session (caught by caller)" do
      session_id = "sess-save-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      Session.append(session, Opal.Message.user("test"))

      Process.flag(:trap_exit, true)

      catch_exit do
        Session.save(session, "/nonexistent/deeply/nested/path")
      end

      refute Process.alive?(session)
    end
  end

  describe "load nonexistent file" do
    test "start_link with missing load_from ignores gracefully" do
      session_id = "sess-load-#{System.unique_integer([:positive])}"

      {:ok, session} =
        Session.start_link(session_id: session_id, load_from: "/nonexistent/session.dets")

      # Session starts empty when load_from fails
      assert Session.current_id(session) == nil
      assert Session.get_path(session) == []
      assert Process.alive?(session)
    end
  end

  describe "save and reload roundtrip" do
    test "saves DETS and reloads via start_link" do
      dir = Path.join(System.tmp_dir!(), "opal_resilience_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      session_id = "sess-roundtrip-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      Session.append(session, Opal.Message.user("hello"))
      Session.append(session, Opal.Message.assistant("hi"))
      :ok = Session.save(session, dir)

      path = Path.join(dir, "#{session_id}.dets")
      assert File.exists?(path)

      # Load into a new session
      {:ok, session2} = Session.start_link(session_id: session_id, load_from: path)
      assert length(Session.get_path(session2)) == 2
    end
  end

  describe "session process operations" do
    test "append to session adds message" do
      session_id = "sess-append-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      msg = Opal.Message.user("hello")
      Session.append(session, msg)

      messages = Session.get_path(session)
      assert length(messages) == 1
      assert hd(messages).content == "hello"
    end

    test "current_id returns nil for empty session" do
      session_id = "sess-cid-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      assert Session.current_id(session) == nil
    end

    test "current_id returns message id after append" do
      session_id = "sess-cid2-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      msg = Opal.Message.user("hello")
      Session.append(session, msg)

      assert Session.current_id(session) == msg.id
    end
  end

  describe "terminate best-effort save" do
    test "session terminate doesn't crash test process" do
      session_id = "sess-term-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      Session.append(session, Opal.Message.user("test"))

      Process.flag(:trap_exit, true)

      GenServer.stop(session, :shutdown)

      receive do
        {:EXIT, ^session, :shutdown} -> :ok
      after
        1000 -> :ok
      end

      refute Process.alive?(session)
    end
  end
end
