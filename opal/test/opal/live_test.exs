defmodule Opal.LiveTest do
  @moduledoc """
  Live tests that hit the real GitHub Copilot API.

  These tests are excluded by default. Run with:

      mix test --include live

  Requires a valid GitHub Copilot authentication token.
  To save fixtures from live responses, also include:

      mix test --include live --include save_fixtures
  """
  use ExUnit.Case, async: false

  alias Opal.Test.FixtureHelper

  @moduletag :live

  # Provider that records SSE events for fixture saving
  defmodule RecordingProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(model, messages, tools, opts \\ []) do
      case Opal.Provider.Copilot.stream(model, messages, tools, opts) do
        {:ok, resp} ->
          # Store the response for potential fixture recording
          :persistent_term.put({__MODULE__, :last_response}, resp)
          {:ok, resp}

        error ->
          error
      end
    end

    @impl true
    def parse_stream_event(data) do
      # Record raw SSE data if save_fixtures is enabled
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

  setup do
    case Opal.Auth.Copilot.get_token() do
      {:ok, _token} -> :ok
      {:error, _} -> {:skip, "No valid Copilot auth token available"}
    end
  end

  describe "live API — simple prompt" do
    @tag timeout: 30_000
    test "sends a prompt and receives a text response" do
      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          system_prompt: "Respond with exactly the word 'pong' and nothing else.",
          tools: [],
          working_dir: System.tmp_dir!()
        })

      assert {:ok, response} = Opal.prompt_sync(pid, "ping", 25_000)
      assert is_binary(response)
      assert byte_size(response) > 0

      Opal.stop_session(pid)
    end
  end

  describe "live API — with tool" do
    @tag timeout: 30_000
    test "agent can use the Read tool" do
      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          system_prompt: "You have a read tool. Use it when asked to read files.",
          tools: [Opal.Tool.ReadFile],
          working_dir: System.tmp_dir!()
        })

      assert {:ok, response} =
               Opal.prompt_sync(pid, "What files are in the current directory?", 25_000)

      assert is_binary(response)
      assert byte_size(response) > 0

      Opal.stop_session(pid)
    end
  end

  describe "live API — fixture recording" do
    @tag :save_fixtures
    @tag timeout: 30_000
    test "records and saves a live response as a fixture" do
      RecordingProvider.start_recording()

      {:ok, pid} =
        Opal.start_session(%{
          model: {:copilot, "claude-sonnet-4"},
          system_prompt: "Respond with exactly: 'Hello from live test'",
          tools: [],
          working_dir: System.tmp_dir!(),
          provider: RecordingProvider
        })

      {:ok, _response} = Opal.prompt_sync(pid, "Say hello", 25_000)
      Opal.stop_session(pid)

      events = RecordingProvider.stop_recording()
      assert length(events) > 0

      path =
        FixtureHelper.save_fixture(
          "live_recorded_#{System.unique_integer([:positive])}.json",
          events
        )

      assert File.exists?(path)
      # Clean up the recorded fixture
      File.rm!(path)
    end
  end
end
