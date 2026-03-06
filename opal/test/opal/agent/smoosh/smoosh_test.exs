defmodule Opal.Agent.SmooshTest do
  use ExUnit.Case, async: true

  alias Opal.Agent.Smoosh
  alias Opal.Agent.State
  alias Opal.Provider.Model

  # ── Test tools ──────────────────────────────────────────────────────

  defmodule SkipTool do
    @behaviour Opal.Tool
    def name, do: "skip_tool"
    def description, do: "Tool that skips smoosh"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: {:ok, "ok"}
    def smoosh, do: :skip
  end

  defmodule AlwaysTool do
    @behaviour Opal.Tool
    def name, do: "always_tool"
    def description, do: "Tool that always compresses"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: {:ok, "ok"}
    def smoosh, do: :always
  end

  defmodule AutoTool do
    @behaviour Opal.Tool
    def name, do: "auto_tool"
    def description, do: "Tool without smoosh callback"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args, _ctx), do: {:ok, "ok"}
    # No smoosh/0 callback — defaults to :auto
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp state(smoosh_opts \\ %{}) do
    smoosh_config =
      Map.merge(
        %{
          enabled: true,
          threshold_bytes: 4_096,
          hard_limit_bytes: 102_400,
          compressor_model: nil,
          index_enabled: true
        },
        smoosh_opts
      )

    config = Opal.Config.new(%{features: %{smoosh: smoosh_config}})

    %State{
      session_id: "smoosh-test-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: config,
      tools: [SkipTool, AlwaysTool, AutoTool]
    }
  end

  defp disabled_state do
    config = Opal.Config.new(%{features: %{smoosh: %{enabled: false}}})

    %State{
      session_id: "smoosh-disabled-#{System.unique_integer([:positive])}",
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      config: config,
      tools: [SkipTool, AlwaysTool, AutoTool]
    }
  end

  defp small_output, do: "small"
  defp medium_output, do: String.duplicate("x", 5_000)
  defp huge_output, do: String.duplicate("x", 200_000)

  # ── classify/3 ──────────────────────────────────────────────────────

  describe "classify/3" do
    test "returns :pass_through for tool with smoosh: :skip" do
      assert Smoosh.classify(SkipTool, medium_output(), state()) == :pass_through
    end

    test "returns :pass_through for tool with smoosh: :skip even for huge output" do
      assert Smoosh.classify(SkipTool, huge_output(), state()) == :pass_through
    end

    test "returns :compress for tool with smoosh: :always even for small output" do
      assert Smoosh.classify(AlwaysTool, small_output(), state()) == :compress
    end

    test "returns :pass_through for auto tool with small output" do
      assert Smoosh.classify(AutoTool, small_output(), state()) == :pass_through
    end

    test "returns :compress for auto tool with medium output" do
      assert Smoosh.classify(AutoTool, medium_output(), state()) == :compress
    end

    test "returns :index_only for auto tool with huge output" do
      assert Smoosh.classify(AutoTool, huge_output(), state()) == :index_only
    end

    test "respects custom threshold_bytes" do
      # Set threshold to 100 bytes — even small-ish output triggers compression
      s = state(%{threshold_bytes: 100})
      assert Smoosh.classify(AutoTool, "x" |> String.duplicate(101), s) == :compress
    end

    test "respects custom hard_limit_bytes" do
      s = state(%{threshold_bytes: 100, hard_limit_bytes: 1_000})
      assert Smoosh.classify(AutoTool, String.duplicate("x", 1_001), s) == :index_only
    end
  end

  # ── maybe_compress/3 ────────────────────────────────────────────────

  describe "maybe_compress/3" do
    test "no-op when smoosh is disabled" do
      result = {:ok, medium_output()}
      assert {^result, _state} = Smoosh.maybe_compress(AutoTool, result, disabled_state())
    end

    test "no-op when tool_mod is nil" do
      result = {:ok, medium_output()}
      assert {^result, _state} = Smoosh.maybe_compress(nil, result, state())
    end

    test "passes through error results unchanged" do
      result = {:error, "something failed"}
      assert {^result, _state} = Smoosh.maybe_compress(AutoTool, result, state())
    end

    test "passes through small outputs for auto tools" do
      result = {:ok, small_output()}
      assert {^result, _state} = Smoosh.maybe_compress(AutoTool, result, state())
    end

    test "passes through all outputs for skip tools" do
      result = {:ok, medium_output()}
      assert {^result, _state} = Smoosh.maybe_compress(SkipTool, result, state())
    end
  end

  # ── Features integration ────────────────────────────────────────────

  describe "Config.Features smoosh" do
    test "smoosh disabled by default" do
      f = Opal.Config.Features.new(%{})
      assert f.smoosh.enabled == false
    end

    test "smoosh can be enabled" do
      f = Opal.Config.Features.new(%{smoosh: %{enabled: true}})
      assert f.smoosh.enabled == true
    end

    test "smoosh options can be overridden" do
      f = Opal.Config.Features.new(%{smoosh: %{enabled: true, threshold_bytes: 8_192}})
      assert f.smoosh.threshold_bytes == 8_192
    end

    test "boolean shorthand works" do
      f = Opal.Config.Features.new(%{smoosh: true})
      assert f.smoosh.enabled == true
      assert f.smoosh.threshold_bytes == 4_096
    end
  end

  # ── Tool callback ───────────────────────────────────────────────────

  describe "tool smoosh/0 callback" do
    test "skip tool declares :skip" do
      assert SkipTool.smoosh() == :skip
    end

    test "always tool declares :always" do
      assert AlwaysTool.smoosh() == :always
    end

    test "auto tool does not export smoosh/0" do
      refute function_exported?(AutoTool, :smoosh, 0)
    end

    test "built-in read_file declares :skip" do
      assert Opal.Tool.ReadFile.smoosh() == :skip
    end

    test "built-in edit_file declares :skip" do
      assert Opal.Tool.EditFile.smoosh() == :skip
    end

    test "built-in shell does not declare smoosh (defaults to :auto)" do
      refute function_exported?(Opal.Tool.Shell, :smoosh, 0)
    end
  end
end
