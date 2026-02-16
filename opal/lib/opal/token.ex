defmodule Opal.Token do
  @moduledoc """
  Token estimation utilities for proactive context management.

  Provides heuristic token counting and a hybrid estimator that combines
  actual provider usage data with estimates for recently added messages.
  This enables the agent to predict context overflow *before* it happens,
  rather than reacting to provider errors.

  ## Accuracy

  The heuristic uses ~4 characters per token, which is accurate within
  ~20% for mixed coding sessions. This is intentionally not a real
  tokenizer — accurate enough for threshold decisions without adding
  a heavy BPE dependency.
  """

  # -- Constants --------------------------------------------------------------

  # Average characters per token across common models.
  # Slightly overestimates for prose, underestimates for code with short
  # identifiers — but good enough for compaction threshold decisions.
  @chars_per_token 4

  # Per-message overhead: role, separator tokens, framing.
  @overhead_per_message 10

  # -- Public API -------------------------------------------------------------

  @doc """
  Estimates token count from a text string.

  Returns 0 for nil input. Uses a simple `byte_size / 4` heuristic.

  ## Examples

      iex> Opal.Token.estimate("hello world")
      2
      iex> Opal.Token.estimate(nil)
      0
  """
  @spec estimate(String.t() | nil) :: non_neg_integer()
  def estimate(nil), do: 0
  def estimate(text) when is_binary(text), do: div(byte_size(text), @chars_per_token)

  @doc """
  Estimates token count for a single message, including content,
  tool calls, and per-message framing overhead.
  """
  @spec estimate_message(Opal.Message.t()) :: non_neg_integer()
  def estimate_message(%Opal.Message{} = msg) do
    content_tokens = estimate(msg.content)

    # Tool calls carry structured data (name + JSON arguments) that
    # the model must process as part of the context.
    tool_call_tokens =
      case msg.tool_calls do
        nil ->
          0

        [] ->
          0

        calls ->
          Enum.reduce(calls, 0, fn tc, acc ->
            name_tokens = estimate(tc.name)

            args_tokens =
              case Jason.encode(tc.arguments) do
                {:ok, json} -> estimate(json)
                _ -> 0
              end

            # Each tool call has its own framing overhead
            acc + name_tokens + args_tokens + @overhead_per_message
          end)
      end

    content_tokens + tool_call_tokens + @overhead_per_message
  end

  @doc """
  Estimates total token count for a list of messages.
  """
  @spec estimate_context([Opal.Message.t()]) :: non_neg_integer()
  def estimate_context(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message(msg) end)
  end

  @doc """
  Hybrid estimate combining actual LLM usage data with heuristic trailing tokens.

  Uses `last_known_tokens` (from the most recent provider usage report) as
  the calibrated base, then adds heuristic estimates for any messages
  appended after that report was received.

  This solves the "lagging indicator" problem: between turns, tool results
  and user messages grow the context but `last_prompt_tokens` is stale.

  ## Example

      # After a turn: provider reported 50k tokens, then 3 tool results added
      hybrid_estimate(50_000, [tool_result_1, tool_result_2, tool_result_3])
      #=> ~55_000 (50k + estimated 5k from tool outputs)
  """
  @spec hybrid_estimate(non_neg_integer(), [Opal.Message.t()]) :: non_neg_integer()
  def hybrid_estimate(last_known_tokens, messages_since) do
    trailing = estimate_context(messages_since)
    last_known_tokens + trailing
  end
end
