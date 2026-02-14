defmodule Opal.Agent.RetryPolicyTest do
  @moduledoc """
  Tests retry classification edge cases: combined patterns, unknown errors,
  atom/tuple errors, delay cap, retry counter reset.
  """
  use ExUnit.Case, async: true

  alias Opal.Agent.Retry

  describe "combined permanent + transient" do
    test "permanent pattern takes priority over transient" do
      # Contains both "500" (transient) and "context_length_exceeded" (permanent)
      refute Retry.retryable?("500: context_length_exceeded")
    end

    test "rate_limit on auth error is permanent" do
      refute Retry.retryable?("rate_limit: unauthorized")
    end

    test "server error with prompt too long is permanent" do
      refute Retry.retryable?("500 server_error: prompt is too long")
    end
  end

  describe "unknown error" do
    test "completely unknown error string is not retried" do
      refute Retry.retryable?("something completely unexpected happened")
    end

    test "empty string is not retried" do
      refute Retry.retryable?("")
    end

    test "nil-like error is not retried" do
      refute Retry.retryable?("nil")
    end
  end

  describe "atom and tuple errors" do
    test "atom :econnreset is retryable" do
      assert Retry.retryable?(:econnreset)
    end

    test "atom :econnrefused is retryable" do
      assert Retry.retryable?(:econnrefused)
    end

    test "atom :etimedout is retryable" do
      assert Retry.retryable?(:etimedout)
    end

    test "atom :unauthorized is not retryable" do
      refute Retry.retryable?(:unauthorized)
    end

    test "integer error codes convert safely" do
      # to_string(429) = "429"
      assert Retry.retryable?(429)
      assert Retry.retryable?(503)
      refute Retry.retryable?(401)
    end
  end

  describe "delay cap" do
    test "delay never exceeds max_ms regardless of attempt" do
      max = 10_000

      for attempt <- [1, 5, 10, 20, 100] do
        d = Retry.delay(attempt, base_ms: 1_000, max_ms: max)
        assert d <= max, "Attempt #{attempt}: delay #{d} exceeded max #{max}"
      end
    end

    test "delay doubles each attempt" do
      d1 = Retry.delay(1, base_ms: 100, max_ms: 100_000)
      d2 = Retry.delay(2, base_ms: 100, max_ms: 100_000)
      d3 = Retry.delay(3, base_ms: 100, max_ms: 100_000)

      assert d1 == 100
      assert d2 == 200
      assert d3 == 400
    end

    test "delay at attempt 1 equals base_ms" do
      assert Retry.delay(1, base_ms: 2000) == 2000
    end
  end

  describe "retry counter reset" do
    test "successful response resets counter (integration)" do
      # This is tested at the agent level in provider_errors_test.exs
      # Here we verify the retry module itself is stateless
      assert Retry.retryable?("429")
      assert Retry.delay(1) == 2_000
    end
  end

  describe "all transient patterns" do
    test "each transient pattern is retryable" do
      patterns = [
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

      for pattern <- patterns do
        assert Retry.retryable?("error: #{pattern}"),
               "Expected '#{pattern}' to be retryable"
      end
    end
  end

  describe "all permanent patterns" do
    test "each permanent pattern is not retryable" do
      patterns = [
        "context_length_exceeded",
        "maximum context length",
        "too many tokens",
        "prompt is too long",
        "unauthorized",
        "invalid_api_key",
        "authentication",
        "content_too_large",
        "string_above_max_length"
      ]

      for pattern <- patterns do
        refute Retry.retryable?("error: #{pattern}"),
               "Expected '#{pattern}' to be permanent (not retryable)"
      end
    end
  end
end
