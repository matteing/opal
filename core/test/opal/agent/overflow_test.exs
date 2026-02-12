defmodule Opal.Agent.OverflowTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Overflow

  # ── context_overflow?/1 ───────────────────────────────────────────────

  describe "context_overflow?/1" do
    test "detects OpenAI-style overflow errors" do
      assert Overflow.context_overflow?("context_length_exceeded")
      assert Overflow.context_overflow?("This model's maximum context length is 128000 tokens")
      assert Overflow.context_overflow?("maximum context length exceeded")
    end

    test "detects generic token limit errors" do
      assert Overflow.context_overflow?("too many tokens")
      assert Overflow.context_overflow?("prompt is too long")
      assert Overflow.context_overflow?("request too large for model")
      assert Overflow.context_overflow?("token limit exceeded")
      assert Overflow.context_overflow?("input too long")
    end

    test "detects Anthropic-style overflow errors" do
      assert Overflow.context_overflow?("exceeds the model's maximum context length")
      assert Overflow.context_overflow?("reduce the length of the messages")
      assert Overflow.context_overflow?("maximum number of tokens exceeded")
    end

    test "detects content size errors" do
      assert Overflow.context_overflow?("content_too_large")
      assert Overflow.context_overflow?("string_above_max_length")
    end

    test "detects context window mentions" do
      assert Overflow.context_overflow?("context window exceeded")
      assert Overflow.context_overflow?("max_tokens limit reached")
    end

    test "does not match unrelated errors" do
      refute Overflow.context_overflow?("rate_limit_exceeded")
      refute Overflow.context_overflow?("500 Internal Server Error")
      refute Overflow.context_overflow?("unauthorized")
      refute Overflow.context_overflow?("connection refused")
      refute Overflow.context_overflow?("")
    end

    test "case insensitive matching" do
      assert Overflow.context_overflow?("CONTEXT_LENGTH_EXCEEDED")
      assert Overflow.context_overflow?("Maximum Context Length")
    end

    test "accepts non-string terms" do
      assert Overflow.context_overflow?(:context_length_exceeded)
      refute Overflow.context_overflow?(:econnrefused)
    end
  end

  # ── usage_overflow?/2 ─────────────────────────────────────────────────

  describe "usage_overflow?/2" do
    test "returns true when input exceeds context window" do
      assert Overflow.usage_overflow?(250_000, 200_000)
      assert Overflow.usage_overflow?(200_001, 200_000)
    end

    test "returns false when input fits within context window" do
      refute Overflow.usage_overflow?(150_000, 200_000)
      refute Overflow.usage_overflow?(200_000, 200_000)
    end

    test "boundary: exactly at limit is not overflow" do
      refute Overflow.usage_overflow?(128_000, 128_000)
    end

    test "boundary: one over limit is overflow" do
      assert Overflow.usage_overflow?(128_001, 128_000)
    end
  end
end
