defmodule Opal.SessionResilienceTest do
  @moduledoc """
  Tests session persistence and load resilience: save to invalid path,
  corrupted JSONL, empty file, nonexistent file, session process death.
  """
  use ExUnit.Case, async: true

  alias Opal.Session

  describe "save to invalid path" do
    test "save with nonexistent directory crashes session (caught by caller)" do
      session_id = "sess-save-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      Session.append(session, Opal.Message.user("test"))

      # Session.save calls File.mkdir_p! which raises on invalid paths.
      # The GenServer crashes — this is the expected behavior (caller gets EXIT).
      # In production, terminate/2 wraps this in try/rescue.
      Process.flag(:trap_exit, true)

      catch_exit do
        Session.save(session, "/nonexistent/deeply/nested/path")
      end

      # The session process is now dead (expected)
      refute Process.alive?(session)
    end
  end

  describe "load nonexistent file" do
    test "load from missing file returns error" do
      session_id = "sess-load-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      result = Session.load(session, "/nonexistent/session.jsonl")
      assert match?({:error, _}, result)
      assert Process.alive?(session)
    end
  end

  describe "load empty file" do
    test "empty file causes a match error (no header line)" do
      session_id = "sess-empty-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      path = Path.join(System.tmp_dir!(), "empty_session_#{session_id}.jsonl")
      File.write!(path, "")

      # Empty file has no header line — do_load will crash with MatchError.
      # This is a known gap: the session doesn't handle empty files gracefully.
      Process.flag(:trap_exit, true)

      catch_exit do
        Session.load(session, path)
      end

      File.rm(path)
    end
  end

  describe "load corrupted JSONL" do
    test "file with invalid JSON header crashes session" do
      session_id = "sess-corrupt-#{System.unique_integer([:positive])}"
      {:ok, session} = Session.start_link(session_id: session_id)

      path = Path.join(System.tmp_dir!(), "corrupt_session_#{session_id}.jsonl")
      File.write!(path, "this is not json\n{\"role\": \"user\", \"content\": \"hi\"}\n")

      # Jason.decode! on invalid header crashes the session
      Process.flag(:trap_exit, true)

      catch_exit do
        Session.load(session, path)
      end

      File.rm(path)
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

      # Trap exits so stop doesn't kill the test
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
