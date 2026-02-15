defmodule Opal.Agent.RetryTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Retry

  # ── retryable?/1 ──────────────────────────────────────────────────────

  describe "retryable?/1" do
    # Transient errors — these should be retried

    test "rate limit errors are retryable" do
      assert Retry.retryable?("429 Too Many Requests")
      assert Retry.retryable?("rate_limit_exceeded")
      assert Retry.retryable?("Rate Limit Exceeded")
      assert Retry.retryable?("too many requests")
    end

    test "server errors are retryable" do
      assert Retry.retryable?("500 Internal Server Error")
      assert Retry.retryable?("502 Bad Gateway")
      assert Retry.retryable?("503 Service Unavailable")
      assert Retry.retryable?("504 Gateway Timeout")
      assert Retry.retryable?("server_error")
    end

    test "connection errors are retryable" do
      assert Retry.retryable?("ECONNRESET")
      assert Retry.retryable?("econnrefused")
      assert Retry.retryable?("ETIMEDOUT")
      assert Retry.retryable?("connection refused")
      assert Retry.retryable?("socket hang up")
      assert Retry.retryable?("fetch failed")
      assert Retry.retryable?("request timeout")
    end

    test "overloaded server is retryable" do
      assert Retry.retryable?("The server is overloaded, please try again later")
    end

    # Permanent errors — these should NOT be retried

    test "context overflow errors are not retryable" do
      refute Retry.retryable?("context_length_exceeded")
      refute Retry.retryable?("maximum context length exceeded")
      refute Retry.retryable?("too many tokens in the prompt")
      refute Retry.retryable?("prompt is too long")
    end

    test "auth errors are not retryable" do
      refute Retry.retryable?("unauthorized")
      refute Retry.retryable?("invalid_api_key")
      refute Retry.retryable?("authentication failed")
    end

    test "content errors are not retryable" do
      refute Retry.retryable?("content_too_large")
      refute Retry.retryable?("string_above_max_length")
    end

    # Edge cases

    test "unknown errors are not retryable" do
      refute Retry.retryable?("something completely unknown")
      refute Retry.retryable?("")
    end

    test "permanent pattern takes precedence over transient" do
      # An error that matches both — permanent wins
      refute Retry.retryable?("500: context_length_exceeded")
    end

    test "accepts non-string terms" do
      assert Retry.retryable?(:econnrefused)
      refute Retry.retryable?(:unauthorized)
    end
  end

  # ── delay/2 ───────────────────────────────────────────────────────────

  describe "delay/2" do
    test "first attempt returns base delay" do
      assert Retry.delay(1) == 2_000
    end

    test "delays double on each attempt" do
      assert Retry.delay(1) == 2_000
      assert Retry.delay(2) == 4_000
      assert Retry.delay(3) == 8_000
      assert Retry.delay(4) == 16_000
    end

    test "delay is capped at max" do
      # Default max is 60_000
      assert Retry.delay(10) == 60_000
      assert Retry.delay(20) == 60_000
    end

    test "custom base and max" do
      assert Retry.delay(1, base_ms: 1_000, max_ms: 10_000) == 1_000
      assert Retry.delay(2, base_ms: 1_000, max_ms: 10_000) == 2_000
      assert Retry.delay(3, base_ms: 1_000, max_ms: 10_000) == 4_000
      assert Retry.delay(4, base_ms: 1_000, max_ms: 10_000) == 8_000
      assert Retry.delay(5, base_ms: 1_000, max_ms: 10_000) == 10_000
      assert Retry.delay(6, base_ms: 1_000, max_ms: 10_000) == 10_000
    end
  end
end
