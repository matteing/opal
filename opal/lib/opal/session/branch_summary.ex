defmodule Opal.Session.BranchSummary do
  @moduledoc """
  Summarizes abandoned branches when navigating the session tree.

  When the user navigates from branch A to branch B, this module collects
  the messages unique to the abandoned branch (from the common ancestor
  to the old leaf) and generates a compact summary. The summary is then
  injected at the branch point so the LLM knows what was tried and can
  avoid repeating failed approaches.

  ## How It Works

  1. Build the full path from root to the old leaf and the new target
  2. Find the deepest node common to both paths (the branch point)
  3. Extract messages unique to the abandoned branch
  4. Summarize via LLM (or fallback to a truncation summary)
  5. Wrap in a user message with `metadata.type: :branch_summary`

  ## Minimum Threshold

  Branches shorter than 3 messages are not summarized — there isn't
  enough signal to justify the overhead.
  """

  @min_messages 3

  @doc """
  Generates a summary of the branch being abandoned.

  Returns `{:ok, summary_message}` if a summary was generated,
  `{:ok, nil}` if the branch is too short, or `{:error, reason}`.

  ## Options

    * `:provider` — LLM provider module (e.g. `Opal.Provider.Copilot`)
    * `:model` — `%Opal.Provider.Model{}` for summarization calls
    * `:strategy` — set to `:skip` to disable summarization
  """
  @spec summarize_abandoned(
          session :: GenServer.server(),
          old_leaf_id :: String.t(),
          new_target_id :: String.t(),
          opts :: keyword()
        ) :: {:ok, Opal.Message.t() | nil} | {:error, term()}
  def summarize_abandoned(session, old_leaf_id, new_target_id, opts \\ []) do
    # Skip if explicitly disabled
    if Keyword.get(opts, :strategy) == :skip do
      {:ok, nil}
    else
      old_path = Opal.Session.get_path_to(session, old_leaf_id)
      new_path = Opal.Session.get_path_to(session, new_target_id)

      ancestor_id = deepest_common_ancestor(old_path, new_path)
      abandoned_msgs = messages_after(old_path, ancestor_id)

      if length(abandoned_msgs) < @min_messages do
        # Too short to warrant summarization
        {:ok, nil}
      else
        case generate_summary(abandoned_msgs, opts) do
          {:ok, text} ->
            msg = %Opal.Message{
              id: generate_id(),
              role: :user,
              content: """
              [Branch context] The following is a summary of a branch that was explored and returned from:

              <branch-summary>
              #{text}
              </branch-summary>

              This exploration was abandoned. Consider what was learned when proceeding.\
              """,
              metadata: %{type: :branch_summary, from_leaf: old_leaf_id}
            }

            {:ok, msg}

          {:error, _} = err ->
            err
        end
      end
    end
  end

  # -- Path analysis ----------------------------------------------------------

  # Finds the deepest node present in both paths. This is the "fork point"
  # where the two branches diverge.
  defp deepest_common_ancestor(path_a, path_b) do
    ids_b = MapSet.new(Enum.map(path_b, & &1.id))

    path_a
    |> Enum.filter(fn msg -> MapSet.member?(ids_b, msg.id) end)
    |> List.last()
    |> case do
      nil -> nil
      msg -> msg.id
    end
  end

  # Returns messages from the path that come after the given ancestor ID.
  # These are the messages unique to the abandoned branch.
  defp messages_after(path, nil), do: path

  defp messages_after(path, ancestor_id) do
    path
    |> Enum.drop_while(fn msg -> msg.id != ancestor_id end)
    |> Enum.drop(1)
  end

  # -- Summary generation -----------------------------------------------------

  defp generate_summary(messages, opts) do
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    if provider && model do
      # Use the LLM to produce a focused summary of the abandoned branch
      transcript = Opal.Session.Compaction.serialize_conversation(messages)

      prompt = """
      Summarize this abandoned exploration branch. Focus on:
      1. What was attempted
      2. What worked or didn't work
      3. Key findings or errors encountered
      4. Why this approach may have been abandoned

      Be very concise (3-8 bullet points).

      #{transcript}
      """

      Opal.Session.Compaction.summarize_with_provider(provider, model, prompt)
    else
      # Fallback: simple structural summary (no LLM available)
      count = length(messages)
      roles = messages |> Enum.map(& &1.role) |> Enum.frequencies()
      {:ok, "[Explored branch: #{count} messages — #{inspect(roles)}]"}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
