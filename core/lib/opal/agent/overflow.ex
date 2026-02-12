defmodule Opal.Agent.Overflow do
  @moduledoc """
  Detects context-window overflow errors from LLM providers.

  When the accumulated conversation (system prompt + messages + tool results)
  exceeds the model's context window, providers return an error with a
  recognisable message. This module pattern-matches those messages so the
  agent can distinguish overflow from ordinary errors and trigger an
  emergency compaction instead of giving up.

  ## Two Detection Paths

  1. **Error-based** — The provider rejects the request outright.
     Detected by `context_overflow?/1`.

  2. **Usage-based** — The request succeeds but the reported `input_tokens`
     exceed the known context window (the provider silently truncated).
     Detected by `usage_overflow?/2`.

  Both paths feed into the same recovery flow in `Opal.Agent`.
  """

  # ── Overflow Patterns ───────────────────────────────────────────────────
  #
  # These cover OpenAI, Anthropic, Google, and generic proxy error formats.
  # Patterns are matched case-insensitively against the stringified error.

  @overflow_patterns [
    "context_length_exceeded",
    "maximum context length",
    "max_tokens",
    "too many tokens",
    "prompt is too long",
    "request too large",
    "context window",
    "token limit",
    "input too long",
    "exceeds the model's maximum",
    "reduce the length",
    "maximum number of tokens",
    "content_too_large",
    "string_above_max_length"
  ]

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the error string indicates a context-window overflow.

  Accepts any term — it will be converted to a string and checked
  case-insensitively against known provider error patterns.

  ## Examples

      iex> Opal.Agent.Overflow.context_overflow?("context_length_exceeded")
      true

      iex> Opal.Agent.Overflow.context_overflow?("rate_limit")
      false
  """
  @spec context_overflow?(term()) :: boolean()
  def context_overflow?(reason) do
    text = reason |> to_string() |> String.downcase()
    Enum.any?(@overflow_patterns, &String.contains?(text, &1))
  end

  @doc """
  Returns `true` if the reported input token count exceeds the context window.

  This catches the case where the provider accepted the request but had to
  truncate or is about to hit limits on the *next* turn.

  ## Examples

      iex> Opal.Agent.Overflow.usage_overflow?(250_000, 200_000)
      true

      iex> Opal.Agent.Overflow.usage_overflow?(150_000, 200_000)
      false
  """
  @spec usage_overflow?(non_neg_integer(), pos_integer()) :: boolean()
  def usage_overflow?(input_tokens, context_window) do
    input_tokens > context_window
  end
end
