defmodule Opal.Agent.Retry do
  @moduledoc """
  Classifies provider errors and computes retry delays.

  The agent loop encounters errors from LLM providers that fall into two
  categories: **transient** (rate limits, server overload, connection resets)
  and **permanent** (auth failures, invalid requests, context overflow).

  Transient errors are retried with exponential backoff. Permanent errors
  are surfaced immediately so the user (or an upstream handler like the
  overflow detector) can act on them.

  ## Backoff Strategy

  Delay doubles on each attempt, capped at a configurable maximum:

      attempt 1 → 2 000 ms
      attempt 2 → 4 000 ms
      attempt 3 → 8 000 ms
      ...
      attempt N → min(base × 2^(N-1), max)

  Jitter is intentionally omitted — a single agent doesn't generate enough
  concurrent requests to benefit from it, and deterministic delays make
  testing straightforward.
  """

  # ── Error Patterns ──────────────────────────────────────────────────────
  #
  # Transient: the request might succeed if we wait and try again.
  # Permanent: the request will never succeed without changing the payload.
  #
  # Permanent patterns are checked first so that an error like
  # "rate_limit on context_length_exceeded" is classified as permanent.

  @transient_patterns [
    "overloaded",
    "rate_limit",
    "rate limit",
    "too many requests",
    "429",
    "500",
    "502",
    "503",
    "504",
    "connection",
    "econnreset",
    "econnrefused",
    "etimedout",
    "fetch failed",
    "socket hang up",
    "request timeout",
    "server_error"
  ]

  @permanent_patterns Opal.Agent.Overflow.overflow_patterns() ++
                        [
                          "unauthorized",
                          "invalid_api_key",
                          "authentication"
                        ]

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the error is transient and safe to retry.

  Permanent errors are checked first — if *any* permanent pattern matches,
  the error is **not** retryable regardless of transient patterns.

  ## Examples

      iex> Opal.Agent.Retry.retryable?("429 Too Many Requests")
      true

      iex> Opal.Agent.Retry.retryable?("context_length_exceeded")
      false

      iex> Opal.Agent.Retry.retryable?("something completely unknown")
      false
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(reason) do
    text = reason |> to_string() |> String.downcase()

    # Permanent errors are never retried, even if they also match a
    # transient pattern (e.g. "500: context_length_exceeded").
    not matches_any?(text, @permanent_patterns) and
      matches_any?(text, @transient_patterns)
  end

  @doc """
  Computes the retry delay in milliseconds for the given attempt number.

  Attempt is 1-indexed. The delay doubles on each attempt, capped at `max_ms`.

  ## Options

    * `:base_ms` — initial delay (default `2_000`)
    * `:max_ms`  — ceiling (default `60_000`)

  ## Examples

      iex> Opal.Agent.Retry.delay(1)
      2_000

      iex> Opal.Agent.Retry.delay(3, base_ms: 1_000, max_ms: 10_000)
      4_000
  """
  @spec delay(pos_integer(), keyword()) :: pos_integer()
  def delay(attempt, opts \\ []) do
    base = Keyword.get(opts, :base_ms, 2_000)
    max = Keyword.get(opts, :max_ms, 60_000)

    # 2^(attempt - 1) gives: 1× for attempt 1, 2× for attempt 2, etc.
    min(base * Integer.pow(2, attempt - 1), max)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp matches_any?(text, patterns) do
    Enum.any?(patterns, &String.contains?(text, &1))
  end
end
