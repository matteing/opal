defmodule Opal.Session.BranchSummaryTest do
  use ExUnit.Case, async: true

  alias Opal.Session
  alias Opal.Session.BranchSummary
  alias Opal.Message

  # Helper to start a fresh session and populate it with messages.
  defp start_session(id) do
    {:ok, session} = Session.start_link(session_id: id)
    session
  end

  # Builds a linear chain of messages and appends them to the session.
  defp populate_chain(session, count) do
    messages =
      for i <- 1..count do
        if rem(i, 2) == 1 do
          Message.user("User message #{i}")
        else
          Message.assistant("Assistant response #{i}")
        end
      end

    Enum.each(messages, fn msg -> Session.append(session, msg) end)
    messages
  end

  describe "get_path_to/2" do
    test "returns path from root to a specific message" do
      session = start_session("path-to-test")
      msgs = populate_chain(session, 5)

      target_id = Enum.at(msgs, 2).id
      path = Session.get_path_to(session, target_id)

      assert length(path) == 3
      assert List.last(path).id == target_id
    end

    test "returns empty list for nonexistent message" do
      session = start_session("path-to-empty")
      assert [] = Session.get_path_to(session, "nonexistent")
    end
  end

  describe "summarize_abandoned/4" do
    test "returns nil for branches shorter than 3 messages" do
      session = start_session("short-branch")

      # Create a common prefix
      msg1 = Message.user("Start")
      Session.append(session, msg1)
      msg2 = Message.assistant("Reply")
      Session.append(session, msg2)

      # Branch A: only 1 message after the prefix
      msg3 = Message.user("Branch A")
      Session.append(session, msg3)

      old_leaf = msg3.id
      branch_point = msg2.id

      assert {:ok, nil} = BranchSummary.summarize_abandoned(session, old_leaf, branch_point)
    end

    test "returns nil when strategy is :skip" do
      session = start_session("skip-branch")
      populate_chain(session, 10)
      leaf_id = Session.current_id(session)

      # Branch to the first message
      path = Session.get_path(session)
      target_id = Enum.at(path, 0).id

      assert {:ok, nil} =
               BranchSummary.summarize_abandoned(session, leaf_id, target_id, strategy: :skip)
    end

    test "generates fallback summary without a provider" do
      session = start_session("fallback-branch")
      msgs = populate_chain(session, 8)
      leaf_id = Session.current_id(session)

      # Target = first message (so the "abandoned" branch is msgs 2..8)
      target_id = Enum.at(msgs, 0).id

      assert {:ok, summary_msg} =
               BranchSummary.summarize_abandoned(session, leaf_id, target_id)

      assert summary_msg.role == :user
      assert summary_msg.content =~ "Branch context"
      assert summary_msg.content =~ "branch-summary"
      assert summary_msg.metadata.type == :branch_summary
      assert summary_msg.metadata.from_leaf == leaf_id
    end

    test "fallback summary includes message count" do
      session = start_session("count-branch")
      msgs = populate_chain(session, 6)
      leaf_id = Session.current_id(session)
      target_id = Enum.at(msgs, 0).id

      {:ok, summary_msg} = BranchSummary.summarize_abandoned(session, leaf_id, target_id)

      # The summary text should mention the count of abandoned messages
      assert summary_msg.content =~ "5 messages"
    end
  end

  describe "branch_with_summary/3" do
    test "branches and appends summary when summarize: true" do
      session = start_session("bws-test")
      msgs = populate_chain(session, 8)
      _leaf_id = Session.current_id(session)
      target_id = Enum.at(msgs, 1).id

      # Branch with summary (no provider → fallback summary)
      assert :ok = Session.branch_with_summary(session, target_id, summarize: true)

      # The current path should now end with the summary message
      path = Session.get_path(session)
      last = List.last(path)
      assert last.content =~ "Branch context"
      assert last.metadata.type == :branch_summary
    end

    test "branches without summary when summarize: false (default)" do
      session = start_session("bws-no-summary")
      msgs = populate_chain(session, 6)
      _leaf = Session.current_id(session)
      target_id = Enum.at(msgs, 1).id

      assert :ok = Session.branch_with_summary(session, target_id)

      # Path should end at the target, no summary appended
      path = Session.get_path(session)
      assert List.last(path).id == target_id
    end

    test "returns error for nonexistent target" do
      session = start_session("bws-notfound")
      populate_chain(session, 3)

      assert {:error, :not_found} =
               Session.branch_with_summary(session, "nonexistent", summarize: true)
    end
  end
end
