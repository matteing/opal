defmodule Opal.Agent.CompactionFailureTest do
  @moduledoc """
  Tests compaction resilience: overflow without session, auto-compact
  threshold boundary.
  """
  use ExUnit.Case, async: true

  alias Opal.Agent.Overflow

  describe "context_overflow? pattern matching" do
    test "detects context_length_exceeded" do
      assert Overflow.context_overflow?("context_length_exceeded")
    end

    test "detects maximum context length" do
      assert Overflow.context_overflow?("maximum context length exceeded")
    end

    test "detects too many tokens" do
      assert Overflow.context_overflow?("too many tokens in the prompt")
    end

    test "detects prompt is too long" do
      assert Overflow.context_overflow?("prompt is too long for model")
    end

    test "detects request too large" do
      assert Overflow.context_overflow?("request too large for processing")
    end

    test "case insensitive matching" do
      assert Overflow.context_overflow?("CONTEXT_LENGTH_EXCEEDED")
      assert Overflow.context_overflow?("Maximum Context Length")
    end

    test "does not match transient errors" do
      refute Overflow.context_overflow?("429 Too Many Requests")
      refute Overflow.context_overflow?("503 Service Unavailable")
      refute Overflow.context_overflow?("econnreset")
    end

    test "handles atom input" do
      assert Overflow.context_overflow?(:context_length_exceeded)
    end

    test "handles non-matching atoms" do
      refute Overflow.context_overflow?(:econnreset)
    end
  end

  describe "usage_overflow?" do
    test "overflow when input_tokens exceeds context_window" do
      assert Overflow.usage_overflow?(130_000, 128_000)
    end

    test "no overflow when within limits" do
      refute Overflow.usage_overflow?(50_000, 128_000)
    end

    test "boundary: exactly at limit is not overflow" do
      refute Overflow.usage_overflow?(128_000, 128_000)
    end
  end
end
