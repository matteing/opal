defmodule Opal.Session.Compaction do
  @moduledoc """
  Context window compaction following pi's approach.

  Summarizes older messages using the agent's LLM, producing a structured
  summary that preserves goals, progress, decisions, and file operations.
  Falls back to truncation if no agent is available.

  ## How it works

  1. Walk backwards from the newest message, estimating tokens, until
     `keep_recent_tokens` (default 20k) is reached — this is the cut point.
  2. Cut at a turn boundary (user message), never mid-turn.
  3. Serialize messages before the cut point into a text transcript.
  4. Ask the LLM to produce a structured summary.
  5. Replace old messages with a single summary message.

  ## Usage

      Opal.Session.Compaction.compact(session, agent: agent_pid)
      Opal.Session.Compaction.compact(session, strategy: :truncate)
  """

  require Logger

  @keep_recent_tokens 20_000
  @chars_per_token 4

  # ── Summary Prompts ─────────────────────────────────────────────────
  #
  # The transcript is wrapped in <conversation> tags (see serialize_conversation/1)
  # which signals to the LLM that this is data to analyze, not a conversation
  # to participate in. The explicit anti-continuation rules reinforce this.

  @summary_prompt """
  Summarize the following conversation transcript. Produce a structured summary using this exact format:

  ## Goal
  [What the user is trying to accomplish]

  ## Constraints & Preferences
  - [Requirements mentioned by user]

  ## Progress
  ### Done
  - [x] [Completed tasks]

  ### In Progress
  - [ ] [Current work]

  ## Key Decisions
  - **[Decision]**: [Rationale]

  ## Next Steps
  1. [What should happen next]

  ## Critical Context
  - [Any data or state needed to continue]

  <read-files>
  [list file paths that were read, one per line]
  </read-files>

  <modified-files>
  [list file paths that were created, written, or edited, one per line]
  </modified-files>

  CRITICAL RULES:
  - Do NOT continue the conversation.
  - Do NOT respond to any questions in the conversation.
  - Do NOT generate code, commands, or suggestions.
  - ONLY output the structured summary in the format above.

  Be concise. Focus on preserving information needed to continue the work.

  ---

  """

  # Used when a previous compaction summary already exists — the LLM updates
  # it incrementally rather than re-summarizing from scratch. This prevents
  # progressive information loss across multiple compaction cycles.
  @update_summary_prompt """
  You are updating an existing conversation summary with new information.

  <previous-summary>
  %PREVIOUS%
  </previous-summary>

  UPDATE the summary above based on the new transcript below.
  Rules:
  - Merge new progress into existing Done/In Progress sections.
  - Move completed In Progress items to Done.
  - Update Next Steps to reflect current state.
  - Preserve all file paths, function names, and error messages.
  - Do NOT drop information from the previous summary unless explicitly superseded.
  - Do NOT continue the conversation. ONLY output the updated summary.

  Use the same structured format (## Goal, ## Progress, etc.).

  ---

  """

  @doc """
  Compacts old messages in the session.

  ## Options

    * `:agent` — Agent pid for LLM summarization (calls get_state to get provider/model)
    * `:provider` — Provider module (alternative to `:agent`, avoids GenServer call)
    * `:model` — Model struct (required when `:provider` is given)
    * `:strategy` — `:summarize` (default if provider available) or `:truncate`
    * `:keep_recent_tokens` — tokens to keep uncompacted (default: #{@keep_recent_tokens})
    * `:instructions` — optional focus instructions for the summary
  """
  @spec compact(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def compact(session, opts \\ []) do
    {provider, model} = resolve_provider(opts)
    has_provider = provider != nil
    strategy = Keyword.get(opts, :strategy, if(has_provider, do: :summarize, else: :truncate))
    keep_tokens = Keyword.get(opts, :keep_recent_tokens, @keep_recent_tokens)
    instructions = Keyword.get(opts, :instructions)
    force = Keyword.get(opts, :force, false)

    path = Opal.Session.get_path(session)

    cut_idx =
      case find_cut_point(path, keep_tokens) do
        nil when force and length(path) > 2 ->
          # Force mode: compact all but the last 2 messages (keep recent context)
          max(length(path) - 2, 1)

        other ->
          other
      end

    case cut_idx do
      nil ->
        :ok

      idx ->
        to_compact = Enum.slice(path, 0, idx)
        ids_to_remove = Enum.map(to_compact, & &1.id)

        # Accumulate file-op history across compaction cycles — metadata
        # from a previous summary is merged with freshly extracted ops
        # so we never lose track of files the agent touched.
        merged_ops = cumulative_file_ops(to_compact)

        # Detect split turns (cut lands inside a multi-message turn) and
        # generate appropriate summaries for each segment.
        summary_content =
          case detect_split_turn(path, idx) do
            :clean ->
              build_summary(to_compact, strategy, {provider, model}, instructions)

            {:split, turn_start} ->
              build_split_summary(path, turn_start, idx, {provider, model}, instructions)
          end

        summary_msg = %Opal.Message{
          id: generate_id(),
          role: :user,
          content: "[Conversation summary — older messages were compacted]\n\n#{summary_content}",
          parent_id: nil,
          # Structured metadata survives serialization and enables downstream
          # code to recover file-op history without parsing free-form text.
          metadata: %{
            type: :compaction_summary,
            read_files: merged_ops.read,
            modified_files: merged_ops.modified
          }
        }

        Logger.debug("Compacting #{length(to_compact)} messages, keeping #{length(path) - idx}")
        Opal.Session.replace_path_segment(session, ids_to_remove, summary_msg)
    end
  end

  # Resolve provider/model from opts — either explicit or via agent pid
  defp resolve_provider(opts) do
    case {Keyword.get(opts, :provider), Keyword.get(opts, :model)} do
      {p, m} when p != nil and m != nil ->
        {p, m}

      _ ->
        case Keyword.get(opts, :agent) do
          nil ->
            {nil, nil}

          agent ->
            state = Opal.Agent.get_state(agent)
            {state.provider, state.model}
        end
    end
  end

  # Walk backwards from the end, accumulating estimated tokens.
  # Return the index of the first message to keep (cut point).
  # Always cut at a user message boundary to avoid splitting turns.
  defp find_cut_point(path, keep_tokens) do
    total = length(path)
    keep_chars = keep_tokens * @chars_per_token

    {_, _acc_chars, cut_idx} =
      path
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce({false, 0, nil}, fn {msg, rev_idx}, {found, chars, cut} ->
        msg_chars = estimate_chars(msg)
        new_chars = chars + msg_chars

        if found do
          {true, new_chars, cut}
        else
          if new_chars >= keep_chars do
            # Find the nearest user message boundary at or before this point
            real_idx = total - 1 - rev_idx
            boundary = find_turn_boundary(path, real_idx)
            {true, new_chars, boundary}
          else
            {false, new_chars, cut}
          end
        end
      end)

    # Only compact if we found a cut point with at least one message to remove
    if cut_idx && cut_idx >= 1, do: cut_idx, else: nil
  end

  # Find the nearest turn boundary (user message) at or after the given index.
  defp find_turn_boundary(path, idx) do
    path
    |> Enum.with_index()
    |> Enum.drop(idx)
    |> Enum.find_value(fn {msg, i} ->
      if msg.role == :user, do: i
    end) || idx
  end

  defp estimate_chars(%{content: nil}), do: 20
  defp estimate_chars(%{content: c}) when is_binary(c), do: byte_size(c) + 20
  defp estimate_chars(_), do: 20

  # ── Summary generation ──────────────────────────────────────────────

  # Truncation fallback: no LLM needed, just record message counts and file ops.
  defp build_summary(messages, :truncate, _provider_model, _instructions) do
    file_ops = extract_file_ops(messages)
    count = length(messages)
    roles = messages |> Enum.map(& &1.role) |> Enum.frequencies()
    role_str = roles |> Enum.map(fn {r, n} -> "#{n} #{r}" end) |> Enum.join(", ")

    read =
      if file_ops.read != [],
        do: "\n\n<read-files>\n#{Enum.join(file_ops.read, "\n")}\n</read-files>",
        else: ""

    modified =
      if file_ops.modified != [],
        do: "\n\n<modified-files>\n#{Enum.join(file_ops.modified, "\n")}\n</modified-files>",
        else: ""

    "[Compacted #{count} messages: #{role_str}]#{read}#{modified}"
  end

  # LLM-powered summarization with iterative update support.
  # If the first message is itself a previous compaction summary, we ask
  # the LLM to *update* it rather than starting fresh. This prevents
  # progressive information loss across multiple compaction cycles.
  defp build_summary(messages, :summarize, {provider, model}, instructions) do
    previous = extract_previous_summary(messages)
    transcript = serialize_conversation(messages)

    prompt =
      if previous do
        # Iterative update: feed the old summary + new transcript
        @update_summary_prompt
        |> String.replace("%PREVIOUS%", previous)
        |> Kernel.<>(transcript)
      else
        @summary_prompt <> transcript
      end

    prompt =
      if instructions do
        prompt <> "\n\nAdditional focus instructions: #{instructions}"
      else
        prompt
      end

    case summarize_with_provider(provider, model, prompt) do
      {:ok, summary} ->
        summary

      {:error, _reason} ->
        Logger.warning("LLM summarization failed, falling back to truncation")
        build_summary(messages, :truncate, nil, nil)
    end
  end

  # Checks whether the first message in the segment is a previous compaction
  # summary (identified by the header we prepend in compact/2).
  defp extract_previous_summary(messages) do
    case List.first(messages) do
      %{content: "[Conversation summary" <> _ = content} -> content
      _ -> nil
    end
  end

  @doc """
  Calls the LLM provider to generate a summary from a prompt.

  Used internally by compaction and externally by `BranchSummary`.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec summarize_with_provider(module(), Opal.Model.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def summarize_with_provider(provider, model, prompt) do
    # The system prompt explicitly forbids continuation — models are less
    # likely to slip into "assistant mode" when both system and user prompts
    # reinforce the constraint.
    summary_messages = [
      Opal.Message.system("""
      You are a conversation summarizer. Your ONLY job is to produce a structured summary.
      You will receive a conversation transcript wrapped in <conversation> tags.
      Analyze it and output ONLY the structured summary. Never continue the conversation.
      Never respond to questions. Never generate code unless quoting a key decision.
      """),
      Opal.Message.user(prompt)
    ]

    case provider.stream(model, summary_messages, []) do
      {:ok, resp} ->
        text = Opal.Provider.StreamCollector.collect_text(resp, provider, 30_000)
        if text != "", do: {:ok, String.trim(text)}, else: {:error, :empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Serializes messages into a text transcript for summarization.
  """
  @spec serialize_conversation([Opal.Message.t()]) :: String.t()
  def serialize_conversation(messages) do
    # Wrapping in <conversation> tags creates a clear data boundary.
    # Models treat XML-wrapped content as data to analyze rather than
    # dialogue to participate in — this is the primary anti-continuation
    # mechanism.
    body =
      messages
      |> Enum.map(fn msg ->
        case msg.role do
          :user ->
            "[User]: #{msg.content || ""}"

          :assistant ->
            lines = ["[Assistant]: #{msg.content || ""}"]

            tool_lines =
              case msg.tool_calls do
                calls when is_list(calls) and calls != [] ->
                  tools =
                    Enum.map_join(calls, "; ", fn tc ->
                      args = tc.arguments |> Jason.encode!() |> String.slice(0, 200)
                      "#{tc.name}(#{args})"
                    end)

                  ["[Assistant tool calls]: #{tools}"]

                _ ->
                  []
              end

            Enum.join(lines ++ tool_lines, "\n")

          :tool_result ->
            output = String.slice(msg.content || "", 0, 500)
            "[Tool result (#{msg.name || msg.call_id})]: #{output}"

          :system ->
            "[System]: #{msg.content || ""}"

          _ ->
            "[#{msg.role}]: #{msg.content || ""}"
        end
      end)
      |> Enum.join("\n")

    "<conversation>\n#{body}\n</conversation>"
  end

  @doc """
  Extracts file read/write operations from tool calls in messages.
  """
  @spec extract_file_ops([Opal.Message.t()]) :: %{read: [String.t()], modified: [String.t()]}
  def extract_file_ops(messages) do
    Enum.reduce(messages, %{read: [], modified: []}, fn msg, acc ->
      case msg do
        %{role: :assistant, tool_calls: calls} when is_list(calls) ->
          Enum.reduce(calls, acc, fn tc, inner ->
            case tc.name do
              "read_file" ->
                path = tc.arguments["path"]
                if path, do: %{inner | read: [path | inner.read]}, else: inner

              name when name in ["write_file", "edit_file", "edit_file_lines"] ->
                path = tc.arguments["path"]
                if path, do: %{inner | modified: [path | inner.modified]}, else: inner

              _ ->
                inner
            end
          end)

        _ ->
          acc
      end
    end)
    |> then(fn ops ->
      %{read: Enum.uniq(Enum.reverse(ops.read)), modified: Enum.uniq(Enum.reverse(ops.modified))}
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # ── Cumulative File-Op Tracking ──────────────────────────────────────
  #
  # Each compaction cycle extracts file ops from tool calls and merges
  # them with ops stored in the previous summary's metadata. This ensures
  # that files read/written 3 compaction cycles ago are still tracked.

  # Combines file ops from the previous summary's metadata with fresh
  # ops extracted from tool calls in the current batch.
  defp cumulative_file_ops(messages_to_compact) do
    previous_ops = extract_previous_file_ops(messages_to_compact)
    current_ops = extract_file_ops(messages_to_compact)
    merge_file_ops(previous_ops, current_ops)
  end

  # Recovers file-op history from a previous compaction summary's metadata.
  defp extract_previous_file_ops(messages) do
    case List.first(messages) do
      %{metadata: %{read_files: read, modified_files: modified}}
      when is_list(read) and is_list(modified) ->
        %{read: read, modified: modified}

      _ ->
        %{read: [], modified: []}
    end
  end

  # Merges two file-op maps, deduplicating and promoting files that were
  # initially only read but later modified (a common pattern: read → edit).
  defp merge_file_ops(prev, current) do
    all_modified = Enum.uniq(prev.modified ++ current.modified)
    # Files that were only read — exclude any that were also modified
    all_read = Enum.uniq(prev.read ++ current.read) -- all_modified

    %{read: all_read, modified: all_modified}
  end

  # ── Split-Turn Detection ─────────────────────────────────────────────
  #
  # When the cut point falls inside a multi-message turn (e.g. a user
  # message followed by 30 assistant+tool messages), naive compaction
  # produces an incoherent summary — part of the turn is summarized,
  # part is kept, and neither makes sense alone.
  #
  # We detect this and generate dual summaries: one for the history
  # before the turn, and one for the turn's prefix that's being compacted.

  # Checks whether the cut point lands at a clean turn boundary
  # (starts with a :user message in the kept portion) or inside a turn.
  defp detect_split_turn(path, cut_idx) do
    kept = Enum.drop(path, cut_idx)

    case kept do
      [%{role: :user} | _] ->
        # Clean cut: the kept portion starts at a turn boundary
        :clean

      _ ->
        # We're cutting inside a turn — find where it started
        turn_start =
          path
          |> Enum.take(cut_idx)
          |> Enum.reverse()
          |> Enum.find_index(fn msg -> msg.role == :user end)

        case turn_start do
          nil ->
            # No user message found in the compacted segment — treat as clean
            :clean

          offset ->
            actual_start = cut_idx - 1 - offset

            # Only split if the turn prefix is substantial (≥ 5 messages).
            # Tiny prefixes aren't worth a separate summary.
            turn_prefix_len = cut_idx - actual_start

            if turn_prefix_len >= 5 do
              {:split, actual_start}
            else
              :clean
            end
        end
    end
  end

  # Generates dual summaries when a cut lands mid-turn:
  #   1. History summary — everything before the split turn
  #   2. Turn-prefix summary — the part of the current turn being compacted
  defp build_split_summary(path, turn_start_idx, cut_idx, {provider, model}, instructions) do
    history = Enum.take(path, turn_start_idx)
    turn_prefix = Enum.slice(path, turn_start_idx, cut_idx - turn_start_idx)

    history_summary =
      if history != [] do
        build_summary(history, :summarize, {provider, model}, instructions)
      else
        nil
      end

    turn_summary =
      build_summary(
        turn_prefix,
        :summarize,
        {provider, model},
        "This is the BEGINNING of an in-progress turn. " <>
          "Focus on what was attempted and any intermediate results."
      )

    merge_split_summaries(history_summary, turn_summary)
  end

  # Combines history and turn-prefix summaries into a single coherent block.
  defp merge_split_summaries(nil, turn) do
    "## Turn Context (split turn)\n\n#{turn}"
  end

  defp merge_split_summaries(history, turn) do
    """
    ## History Summary

    #{history}

    ---

    ## Turn Context (split turn)

    #{turn}\
    """
  end
end
