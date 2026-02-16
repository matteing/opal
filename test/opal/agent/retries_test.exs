defmodule Opal.Agent.RetriesTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Retries

  describe "retryable?/1" do
    test "rate limit string is retryable" do
      assert Retries.retryable?("429 Too Many Requests")
    end

    test "overloaded is retryable" do
      assert Retries.retryable?("overloaded")
    end

    test "server error 500 is retryable" do
      assert Retries.retryable?("500 Internal Server Error")
    end

    test "503 is retryable" do
      assert Retries.retryable?("503 Service Unavailable")
    end

    test "connection errors are retryable" do
      assert Retries.retryable?("econnreset")
      assert Retries.retryable?("econnrefused")
    end

    test "context_length_exceeded is NOT retryable (permanent)" do
      refute Retries.retryable?("context_length_exceeded")
    end

    test "unauthorized is NOT retryable (permanent)" do
      refute Retries.retryable?("unauthorized")
    end

    test "permanent takes precedence over transient" do
      refute Retries.retryable?("500: context_length_exceeded")
    end

    test "arbitrary unknown errors are not retryable" do
      refute Retries.retryable?("some weird error")
    end

    test "atoms are converted to string" do
      assert Retries.retryable?(:econnreset)
      refute Retries.retryable?(:invalid_api_key)
    end
  end

  describe "delay/2" do
    test "attempt 1 returns base delay (2000ms)" do
      assert Retries.delay(1) == 2_000
    end

    test "attempt 2 doubles" do
      assert Retries.delay(2) == 4_000
    end

    test "attempt 3 quadruples" do
      assert Retries.delay(3) == 8_000
    end

    test "caps at max_ms" do
      assert Retries.delay(100) == 60_000
    end

    test "respects custom base_ms" do
      assert Retries.delay(1, base_ms: 1_000) == 1_000
    end

    test "respects custom max_ms" do
      assert Retries.delay(10, max_ms: 10_000) == 10_000
    end
  end
end
