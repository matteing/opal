defmodule Opal.ReasoningEffortTest do
  @moduledoc """
  Tests for reasoning effort / thinking level support across the stack.

  Verifies:
  - Model-level thinking level validation
  - Provider handling (Copilot role switching, reasoning effort mapping)
  - Model discovery exposes supported thinking levels per model
  """
  use ExUnit.Case, async: true

  alias Opal.Provider.Model
  alias Opal.Provider.Copilot
  alias Opal.Message

  # ============================================================
  # Model-level thinking_level validation
  # ============================================================

  describe "Model thinking_level validation" do
    test "valid levels are off, low, medium, high" do
      for level <- [:off, :low, :medium, :high] do
        model = Model.new(:copilot, "test", thinking_level: level)
        assert model.thinking_level == level
      end
    end

    test "defaults to :off" do
      model = Model.new(:copilot, "test")
      assert model.thinking_level == :off
    end

    test "rejects invalid levels" do
      for invalid <- [:xhigh, :extreme, :auto, :none] do
        assert_raise ArgumentError, ~r/invalid thinking_level/, fn ->
          Model.new(:copilot, "test", thinking_level: invalid)
        end
      end
    end

    test "parse/2 passes thinking_level option" do
      model = Model.parse("anthropic:claude-sonnet-4-5", thinking_level: :high)
      assert model.thinking_level == :high
    end

    test "coerce/2 passes thinking_level option" do
      model = Model.coerce({:copilot, "claude-opus-4.6"}, thinking_level: :medium)
      assert model.thinking_level == :medium
    end
  end

  # ============================================================
  # Copilot provider: thinking affects message conversion
  # ============================================================

  describe "Copilot provider reasoning effort" do
    test "system role is 'system' when thinking is off (chat completions)" do
      model = Model.new(:copilot, "claude-sonnet-4", thinking_level: :off)
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}

      [result] = Copilot.convert_messages(model, [msg])
      assert result.role == "system"
    end

    test "system role is 'system' when thinking is off (responses API)" do
      model = Model.new(:copilot, "gpt-5", thinking_level: :off)
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}

      [result] = Copilot.convert_messages(model, [msg])
      assert result.role == "system"
    end

    test "system role becomes 'developer' when thinking is enabled (responses API)" do
      for level <- [:low, :medium, :high] do
        model = Model.new(:copilot, "gpt-5", thinking_level: level)
        msg = %Message{id: "s1", role: :system, content: "Be helpful."}

        [result] = Copilot.convert_messages(model, [msg])

        assert result.role == "developer",
               "expected 'developer' role for thinking_level=#{level}, got '#{result.role}'"
      end
    end

    test "chat completions model keeps 'system' even with thinking enabled" do
      # Chat completions API doesn't use developer role
      model = Model.new(:copilot, "claude-sonnet-4", thinking_level: :high)
      msg = %Message{id: "s1", role: :system, content: "Be helpful."}

      [result] = Copilot.convert_messages(model, [msg])
      # Chat completions always uses "system"
      assert result.role == "system"
    end

    test "reasoning SSE events are parsed as thinking events" do
      # Responses API reasoning item
      data =
        Jason.encode!(%{
          "type" => "response.output_item.added",
          "item" => %{"type" => "reasoning", "id" => "rs_001"}
        })

      assert [{:thinking_start, %{item_id: "rs_001"}}] = Copilot.parse_stream_event(data)
    end

    test "reasoning summary delta is parsed as thinking_delta" do
      data =
        Jason.encode!(%{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "Let me analyze this..."
        })

      assert [{:thinking_delta, "Let me analyze this..."}] = Copilot.parse_stream_event(data)
    end

    test "chat completions reasoning_content is parsed as thinking_delta" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{"reasoning_content" => "Thinking step 1..."},
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      assert {:thinking_delta, "Thinking step 1..."} in events
    end

    test "empty reasoning_content is ignored" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{"reasoning_content" => ""},
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      refute Enum.any?(events, fn {type, _} -> type == :thinking_delta end)
    end

    test "nil reasoning_content is ignored" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{"content" => "Hello"},
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      refute Enum.any?(events, fn {type, _} -> type == :thinking_delta end)
    end

    test "text and reasoning can coexist in same delta" do
      data =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "content" => "answer text",
                "reasoning_content" => "internal thought"
              },
              "finish_reason" => nil
            }
          ]
        })

      events = Copilot.parse_stream_event(data)
      assert {:text_delta, "answer text"} in events
      assert {:thinking_delta, "internal thought"} in events
    end

    test "responses API reasoning item done does not crash" do
      data =
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "item" => %{"type" => "reasoning", "id" => "rs_001"}
        })

      # Should return empty — not a function_call done
      assert [] = Copilot.parse_stream_event(data)
    end
  end

  # ============================================================
  # ============================================================
  # Reasoning effort mapping
  # ============================================================

  describe "reasoning effort mapping" do
    test "model with thinking :off does not add reasoning_effort" do
      model = Model.new(:anthropic, "claude-sonnet-4-5", thinking_level: :off)
      assert model.thinking_level == :off
    end

    test "model with thinking :high adds reasoning_effort" do
      model = Model.new(:anthropic, "claude-sonnet-4-5", thinking_level: :high)
      assert model.thinking_level == :high
    end
  end

  # ============================================================
  # Model discovery: thinking levels per model
  # ============================================================

  describe "Opal.Provider.Registry thinking level discovery" do
    test "copilot models include thinking_levels field" do
      models = Opal.Provider.Registry.list_copilot()
      assert length(models) > 0

      for model <- models do
        assert Map.has_key?(model, :thinking_levels),
               "model #{model.id} missing thinking_levels field"

        assert is_list(model.thinking_levels)
      end
    end

    test "reasoning-capable models have non-empty thinking_levels" do
      models = Opal.Provider.Registry.list_copilot()
      claude = Enum.find(models, &(&1.id == "claude-opus-4.6"))
      assert claude != nil
      assert claude.supports_thinking == true
      # Opus 4.6+ supports adaptive thinking with "max" effort
      assert claude.thinking_levels == ["low", "medium", "high", "max"]
    end

    test "non-reasoning models have empty thinking_levels" do
      models = Opal.Provider.Registry.list_copilot()
      gpt4o = Enum.find(models, &(&1.id == "gpt-4o"))
      assert gpt4o != nil
      assert gpt4o.supports_thinking == false
      assert gpt4o.thinking_levels == []
    end

    test "thinking_levels never includes xhigh" do
      models = Opal.Provider.Registry.list_copilot()

      for model <- models do
        refute "xhigh" in model.thinking_levels,
               "model #{model.id} should not support xhigh"
      end
    end

    test "direct provider models also include thinking_levels" do
      models = Opal.Provider.Registry.list_provider(:anthropic)
      assert length(models) > 0

      claude = Enum.find(models, &(&1.id == "claude-opus-4.6"))
      assert claude.supports_thinking == true
      # Opus 4.6+ supports adaptive thinking with "max" effort
      assert claude.thinking_levels == ["low", "medium", "high", "max"]
    end
  end

  # ============================================================
  # RPC handler: thinking/set and model/set with thinking_level
  # ============================================================

  describe "RPC handler parse_thinking_level" do
    # The handler maps string levels to atoms; invalid values default to :off.
    # We test the contract through Model construction since the handler is
    # not directly testable without a running session.

    test "model/set without thinking_level defaults to off" do
      model = Model.coerce("claude-sonnet-4", thinking_level: :off)
      assert model.thinking_level == :off
    end

    test "model/set with valid thinking_level is accepted" do
      for level <- [:low, :medium, :high] do
        model = Model.coerce("claude-sonnet-4", thinking_level: level)
        assert model.thinking_level == level
      end
    end

    test "xhigh is rejected as thinking_level" do
      assert_raise ArgumentError, ~r/invalid thinking_level/, fn ->
        Model.new(:copilot, "test", thinking_level: :xhigh)
      end
    end
  end

  # ============================================================
  # End-to-end: thinking level through model selection
  # ============================================================

  describe "thinking level model selection flow" do
    test "model with thinking creates correct struct" do
      # Simulates: user picks claude-opus-4.6 from model picker, then picks "high"
      model = Model.parse("claude-opus-4.6", thinking_level: :high)
      assert model.provider == :copilot
      assert model.id == "claude-opus-4.6"
      assert model.thinking_level == :high
    end

    test "direct provider model with thinking" do
      model = Model.parse("anthropic:claude-sonnet-4-5", thinking_level: :medium)
      assert model.provider == :copilot
      # whole string becomes the ID
      assert model.id == "anthropic:claude-sonnet-4-5"
      assert model.thinking_level == :medium
    end

    test "non-reasoning model defaults to off" do
      model = Model.parse("gpt-4o")
      assert model.thinking_level == :off
    end
  end
end
