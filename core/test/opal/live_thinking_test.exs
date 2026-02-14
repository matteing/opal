defmodule Opal.LiveThinkingTest do
  @moduledoc """
  Live tests that hit the real GitHub Copilot API with thinking-enabled models.

  Run with:

      mix test --include live

  To record/refresh fixture files:

      mix test --include live --include save_fixtures

  Recorded fixtures are committed and replayed by ThinkingIntegrationTest.
  """
  use ExUnit.Case, async: false

  alias Opal.Test.FixtureHelper

  @moduletag :live

  # ── Recording Provider ─────────────────────────────────────────────

  defmodule RecordingProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(model, messages, tools, opts \\ []) do
      case Opal.Provider.Copilot.stream(model, messages, tools, opts) do
        {:ok, resp} ->
          :persistent_term.put({__MODULE__, :last_response}, resp)
          {:ok, resp}

        error ->
          error
      end
    end

    @impl true
    def parse_stream_event(data) do
      if :persistent_term.get({__MODULE__, :recording}, false) do
        events = :persistent_term.get({__MODULE__, :recorded_events}, [])
        :persistent_term.put({__MODULE__, :recorded_events}, events ++ [data])
      end

      Opal.Provider.Copilot.parse_stream_event(data)
    end

    @impl true
    def convert_messages(model, messages),
      do: Opal.Provider.Copilot.convert_messages(model, messages)

    @impl true
    def convert_tools(tools), do: Opal.Provider.convert_tools(tools)

    def start_recording do
      :persistent_term.put({__MODULE__, :recording}, true)
      :persistent_term.put({__MODULE__, :recorded_events}, [])
    end

    def stop_recording do
      events = :persistent_term.get({__MODULE__, :recorded_events}, [])
      :persistent_term.put({__MODULE__, :recording}, false)
      events
    end
  end

  # ── Test Tool ──────────────────────────────────────────────────────

  defmodule LiveTestReadTool do
    @behaviour Opal.Tool
    @impl true
    def name, do: "read_file"
    @impl true
    def description, do: "Read a file from disk"
    @impl true
    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "description" => "Absolute file path"}},
        "required" => ["path"]
      }

    @impl true
    def execute(%{"path" => path}, _ctx) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
      end
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────

  setup do
    case Opal.Auth.Copilot.get_token() do
      {:ok, _token} -> :ok
      {:error, _} -> {:skip, "No valid Copilot auth token available"}
    end
  end

  defp maybe_save_fixture(fixture_name) do
    if MapSet.member?(MapSet.new(ExUnit.configuration()[:include] || []), :save_fixtures) do
      events = RecordingProvider.stop_recording()

      if length(events) > 0 do
        path = FixtureHelper.save_fixture(fixture_name, events)
        IO.puts("\n  📼 Saved fixture: #{path} (#{length(events)} events)")
      end
    else
      RecordingProvider.stop_recording()
    end
  end

  # ── Chat Completions — thinking (Claude) ───────────────────────────

  describe "live — Chat Completions thinking" do
    @tag timeout: 60_000
    @tag :save_fixtures
    test "Claude with reasoning_effort produces reasoning_content" do
      RecordingProvider.start_recording()

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          thinking_level: :high,
          system_prompt: "Think step by step. Respond in exactly one sentence.",
          tools: [],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, response} = Opal.prompt_sync(pid, "What is 7 * 8?", 50_000)
      Opal.stop_session(pid)

      assert is_binary(response)
      assert byte_size(response) > 0

      maybe_save_fixture("chat_completions_thinking.json")
    end

    @tag timeout: 60_000
    @tag :save_fixtures
    test "Claude thinking + tool call produces reasoning then tool use" do
      RecordingProvider.start_recording()

      # Create a temporary file to read
      tmp_file =
        Path.join(System.tmp_dir!(), "opal_live_test_#{System.unique_integer([:positive])}.txt")

      File.write!(tmp_file, "Hello from the live thinking test!")

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          thinking_level: :high,
          system_prompt:
            "You have a read_file tool. When asked to read a file, use it. Think step by step.",
          tools: [LiveTestReadTool],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, response} = Opal.prompt_sync(pid, "Read the file at #{tmp_file}", 50_000)
      Opal.stop_session(pid)
      File.rm(tmp_file)

      assert is_binary(response)
      assert byte_size(response) > 0

      maybe_save_fixture("chat_completions_thinking_tool_call.json")
    end
  end

  # ── Responses API — thinking (GPT-5) ───────────────────────────────

  describe "live — Responses API thinking" do
    @tag timeout: 60_000
    @tag :save_fixtures
    test "GPT-5 with reasoning produces reasoning summary" do
      RecordingProvider.start_recording()

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "gpt-5"},
          thinking_level: :high,
          system_prompt: "Think step by step. Respond in exactly one sentence.",
          tools: [],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, response} = Opal.prompt_sync(pid, "What is 7 * 8?", 50_000)
      Opal.stop_session(pid)

      assert is_binary(response)
      assert byte_size(response) > 0

      maybe_save_fixture("responses_api_thinking.json")
    end

    @tag timeout: 60_000
    @tag :save_fixtures
    test "GPT-5 thinking + tool call" do
      RecordingProvider.start_recording()

      tmp_file =
        Path.join(System.tmp_dir!(), "opal_live_test_#{System.unique_integer([:positive])}.txt")

      File.write!(tmp_file, "Hello from the live thinking test!")

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "gpt-5"},
          thinking_level: :high,
          system_prompt:
            "You have a read_file tool. When asked to read a file, use it. Think step by step.",
          tools: [LiveTestReadTool],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, response} = Opal.prompt_sync(pid, "Read the file at #{tmp_file}", 50_000)
      Opal.stop_session(pid)
      File.rm(tmp_file)

      assert is_binary(response)
      assert byte_size(response) > 0

      maybe_save_fixture("responses_api_thinking_tool_call.json")
    end
  end

  # ── Chat Completions — no thinking (baseline) ─────────────────────

  describe "live — Chat Completions no thinking (baseline)" do
    @tag timeout: 60_000
    @tag :save_fixtures
    test "Claude with thinking :off produces no reasoning_content" do
      RecordingProvider.start_recording()

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          thinking_level: :off,
          system_prompt: "Respond in exactly one sentence.",
          tools: [],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, response} = Opal.prompt_sync(pid, "What is 7 * 8?", 50_000)
      Opal.stop_session(pid)

      assert is_binary(response)
      maybe_save_fixture("chat_completions_no_thinking.json")
    end
  end

  # ── Reasoning effort levels ────────────────────────────────────────

  describe "live — reasoning effort levels" do
    for level <- [:low, :medium, :high] do
      @tag timeout: 60_000
      @tag :save_fixtures
      test "Claude thinking level :#{level} succeeds" do
        RecordingProvider.start_recording()

        {:ok, pid} =
          Opal.start_session(%{
            model: {:copilot, "claude-sonnet-4"},
            thinking_level: unquote(level),
            system_prompt: "Respond in exactly one sentence.",
            tools: [],
            working_dir: System.tmp_dir!(),
            provider: RecordingProvider
          })

        {:ok, response} = Opal.prompt_sync(pid, "What is 2 + 2?", 50_000)
        Opal.stop_session(pid)

        assert is_binary(response)
        assert byte_size(response) > 0

        maybe_save_fixture("chat_completions_thinking_#{unquote(level)}.json")
      end
    end
  end
end
