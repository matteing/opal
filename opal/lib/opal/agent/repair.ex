defmodule Opal.Agent.Repair do
  @moduledoc """
  Message-history repair for the agent loop.

  LLM providers require every assistant message that includes `tool_calls`
  to be immediately followed by a `tool_result` for **each** call_id.
  Several things can break that invariant:

    * **Abort** — the user cancels while tools are still running, leaving
      assistant messages whose tool_calls have no results.
    * **Compaction** — summarisation may drop tool_result messages that
      were paired with an earlier assistant turn.
    * **Stream errors** — a partial response may be flushed without all
      tool_results arriving.
    * **Session reload** — replaying from disk can re-introduce any of
      the above corruptions.

  This module provides two complementary repair layers that run at
  different points in the agent loop:

  ## Layer 1 — `find_orphaned_calls/1`

  Scans the **full** message history (newest-first, since messages are
  stored in reverse) and returns `call_id`s for any assistant messages
  whose tool_calls lack a corresponding `tool_result` anywhere after
  them. The agent appends synthetic `"[Aborted by user]"` results for
  each one, mutating state **before** the next LLM turn begins.

  Called from `run_turn_internal` (before every turn) and from
  `cancel_tool_execution` (on abort).

  ## Layer 2 — `ensure_tool_results/1`

  Operates on the **chronological** message list right before it is sent
  to the provider (inside `build_messages`). It:

    1. **Relocates** — moves any tool_result that drifted away from its
       parent assistant message back to the correct position.
    2. **Synthesises** — injects `"[Error: tool result missing]"` for
       any tool_call that still has no result.
    3. **Strips** — removes tool_results that have no matching
       tool_call (fully orphaned) or are duplicates.

  Because this runs on every provider call, it acts as a safety net
  regardless of what caused the corruption.
  """

  # MapSet is opaque — Dialyzer can't see through recursive calls that thread it
  @dialyzer {:no_opaque, find_orphaned_calls: 3}

  require Logger

  # ---------------------------------------------------------------------------
  # Layer 2 — ensure_tool_results (positional validation)
  # ---------------------------------------------------------------------------

  @doc """
  Walks a chronological message list and ensures every assistant message
  with `tool_calls` is immediately followed by matching `tool_result`
  messages. Strips orphaned or duplicate results, and synthesises
  placeholders for any that are missing.

  This is the last line of defence before messages reach the provider.

  ## Algorithm

    1. **Collect** all valid `call_id`s from assistant messages (so we
       know the universe of legitimate IDs).
    2. **Walk** the list sequentially:
       - Standalone `tool_result` → strip (it will be relocated or is
         genuinely orphaned).
       - Assistant with `tool_calls` → extract matching results from the
         **remainder** of the list via `take_tool_results_for_ids/2`,
         synthesise any that are missing, and place them immediately
         after the assistant message.
       - Anything else → pass through.
  """
  @spec ensure_tool_results([Opal.Message.t()]) :: [Opal.Message.t()]
  def ensure_tool_results(chronological_messages) do
    # First pass: collect all valid tool_call IDs from assistant messages.
    # We need this set so we can distinguish "known but out-of-place" results
    # from "completely unknown" results when stripping.
    valid_call_ids =
      Enum.reduce(chronological_messages, MapSet.new(), fn
        %{role: :assistant, tool_calls: tcs}, ids when is_list(tcs) and tcs != [] ->
          tcs
          |> Enum.map(&tool_call_id/1)
          |> Enum.filter(&is_binary/1)
          |> Enum.reduce(ids, &MapSet.put(&2, &1))

        _, ids ->
          ids
      end)

    # Second pass: walk sequentially, relocating results next to their
    # parent assistant message and synthesising any that are missing.
    do_ensure(chronological_messages, valid_call_ids, [])
  end

  # Base case: all messages processed, reverse the accumulator.
  defp do_ensure([], _valid_ids, acc), do: Enum.reverse(acc)

  # Strip standalone tool_results encountered outside the context of their
  # parent assistant message. There are two sub-cases:
  #   - The call_id IS in valid_call_ids → it was relocated by the assistant
  #     branch below, so this is a leftover duplicate.
  #   - The call_id is NOT in valid_call_ids → there's no matching tool_call
  #     at all; it's fully orphaned (e.g. survived compaction by accident).
  defp do_ensure([%{role: :tool_result, call_id: cid} | rest], valid_ids, acc) do
    if MapSet.member?(valid_ids, cid) do
      Logger.warning("Stripping out-of-place tool_result: #{cid}")
    else
      Logger.warning("Stripping orphaned tool_result with no matching tool_call: #{cid}")
    end

    do_ensure(rest, valid_ids, acc)
  end

  # When we encounter an assistant message with tool_calls:
  #   1. Extract the expected call_ids from the tool_calls list.
  #   2. Scan the remaining messages to pull out matching tool_results
  #      (first match wins per id; duplicates are discarded).
  #   3. For any expected id that wasn't found, create a synthetic
  #      error result so the provider sees a complete pairing.
  #   4. Place [assistant, result1, result2, ...] into the accumulator.
  defp do_ensure(
         [%{role: :assistant, tool_calls: tcs} = msg | rest],
         valid_ids,
         acc
       )
       when is_list(tcs) and tcs != [] do
    # Determine which call_ids this assistant message expects results for.
    expected_ids =
      tcs
      |> Enum.map(&tool_call_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    # Partition the remaining messages: pull out results that match our
    # expected ids, leaving everything else for subsequent processing.
    %{matched: matched, rest: rest} = take_tool_results_for_ids(rest, MapSet.new(expected_ids))

    missing = Enum.reject(expected_ids, &Map.has_key?(matched, &1))

    if missing != [] do
      Logger.warning(
        "Injecting #{length(missing)} synthetic tool_results for orphaned tool_calls"
      )
    end

    # Build the result list in expected_ids order, using the real result
    # when available and a synthetic placeholder when not.
    results =
      Enum.map(expected_ids, fn call_id ->
        Map.get(matched, call_id) ||
          Opal.Message.tool_result(call_id, "[Error: tool result missing]", true)
      end)

    # Prepend in reverse: results first (they'll be reversed at the end),
    # then the assistant message itself.
    new_acc = Enum.reverse([msg | results]) ++ acc
    do_ensure(rest, valid_ids, new_acc)
  end

  # Pass-through for user messages, plain assistant messages, etc.
  defp do_ensure([msg | rest], valid_ids, acc) do
    do_ensure(rest, valid_ids, [msg | acc])
  end

  # ---------------------------------------------------------------------------
  # take_tool_results_for_ids — helper for ensure_tool_results
  # ---------------------------------------------------------------------------

  # Partitions `messages` into two groups:
  #
  #   - `matched` — a map of `call_id => tool_result_msg` for IDs in
  #     `expected_ids`. Only the first occurrence is kept; duplicates are
  #     logged and discarded.
  #   - `rest` — all other messages, in their original order.
  #
  # This lets the caller "pull" matching results out of an arbitrary
  # position in the message list and relocate them next to their parent.
  @spec take_tool_results_for_ids([Opal.Message.t()], MapSet.t()) :: %{
          matched: %{String.t() => Opal.Message.t()},
          rest: [Opal.Message.t()]
        }
  defp take_tool_results_for_ids(messages, expected_ids) do
    {matched, kept_rev} =
      Enum.reduce(messages, {%{}, []}, fn
        %{role: :tool_result, call_id: cid} = msg, {found, kept} ->
          cond do
            # First match for this call_id — claim it.
            is_binary(cid) and MapSet.member?(expected_ids, cid) and not Map.has_key?(found, cid) ->
              {Map.put(found, cid, msg), kept}

            # Duplicate match — discard with a warning.
            is_binary(cid) and MapSet.member?(expected_ids, cid) ->
              Logger.warning("Dropping duplicate tool_result for call_id: #{cid}")
              {found, kept}

            # Not one of our expected IDs — keep for later processing.
            true ->
              {found, [msg | kept]}
          end

        # Non-tool_result messages are always kept.
        msg, {found, kept} ->
          {found, [msg | kept]}
      end)

    %{matched: matched, rest: Enum.reverse(kept_rev)}
  end

  # ---------------------------------------------------------------------------
  # Layer 1 — find_orphaned_calls (state-level repair)
  # ---------------------------------------------------------------------------

  @doc """
  Scans a newest-first message list and returns `call_id`s for every
  assistant tool_call that lacks a corresponding `tool_result`.

  The caller is responsible for appending synthetic results for the
  returned IDs (typically `"[Aborted by user]"`).

  ## How it works

  Because messages are stored newest-first, walking the list means we
  encounter `tool_result` messages **before** the assistant messages
  they belong to. We accumulate seen result IDs in a `MapSet`, then
  when we hit an assistant message with tool_calls, we check which
  call_ids are NOT in the set — those are orphaned.

  This catches "deep orphans" — orphaned tool_calls buried in history
  with valid turns stacked on top of them.
  """
  @spec find_orphaned_calls([Opal.Message.t()]) :: [String.t()]
  def find_orphaned_calls(messages) do
    find_orphaned_calls(messages, MapSet.new(), [])
  end

  # Base case: all messages inspected, return accumulated orphan IDs.
  defp find_orphaned_calls([], _result_ids, acc), do: acc

  # tool_result encountered — record its call_id so we know this result
  # exists when we later encounter its parent assistant message.
  defp find_orphaned_calls([%{role: :tool_result, call_id: cid} | rest], result_ids, acc) do
    find_orphaned_calls(rest, MapSet.put(result_ids, cid), acc)
  end

  # Assistant message with tool_calls — check each call_id against the
  # result IDs we've seen so far. Any that are missing are orphaned.
  defp find_orphaned_calls([%{role: :assistant, tool_calls: tcs} | rest], result_ids, acc)
       when is_list(tcs) and tcs != [] do
    orphans =
      tcs
      |> tool_call_ids()
      |> Enum.reject(&MapSet.member?(result_ids, &1))

    find_orphaned_calls(rest, result_ids, acc ++ orphans)
  end

  # All other message types — skip.
  defp find_orphaned_calls([_ | rest], result_ids, acc) do
    find_orphaned_calls(rest, result_ids, acc)
  end

  # ---------------------------------------------------------------------------
  # Helpers — call_id extraction
  # ---------------------------------------------------------------------------

  # Extracts a call_id from a tool_call map. Handles both atom-keyed
  # (`%{call_id: "..."}`) and string-keyed (`%{"call_id" => "..."}`)
  # maps, since different code paths produce both shapes.
  @spec tool_call_id(map()) :: String.t() | nil
  defp tool_call_id(%{call_id: call_id}) when is_binary(call_id), do: call_id
  defp tool_call_id(%{"call_id" => call_id}) when is_binary(call_id), do: call_id
  defp tool_call_id(_), do: nil

  # Extracts all call_ids from a list of tool_call maps, preserving order
  # and silently dropping entries with no valid call_id.
  @spec tool_call_ids([map()]) :: [String.t()]
  defp tool_call_ids(tool_calls) do
    Enum.reduce(tool_calls, [], fn tc, ids ->
      case tool_call_id(tc) do
        call_id when is_binary(call_id) -> [call_id | ids]
        _ -> ids
      end
    end)
    |> Enum.reverse()
  end
end
