defmodule Opal.Test.FixtureHelper do
  @moduledoc """
  Helpers for loading and saving API response fixtures.

  Fixtures are JSON files in test/support/fixtures/ containing SSE event
  sequences that can be replayed by test providers.
  """

  @fixtures_dir Path.join([__DIR__, "fixtures"])

  @doc "Loads a fixture file and returns the parsed map."
  def load_fixture(name) when is_binary(name) do
    path = Path.join(@fixtures_dir, name)

    path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "Returns the list of SSE data lines from a fixture, formatted as 'data: ...' strings."
  def fixture_events(name) do
    fixture = load_fixture(name)

    Enum.map(fixture["events"], fn event ->
      "data: #{event["data"]}\n"
    end)
  end

  @doc """
  Saves SSE event data to a fixture file. Used for recording live API responses.

  Call with `--include save_fixtures` to enable saving.
  """
  def save_fixture(name, events) when is_binary(name) and is_list(events) do
    fixture = %{
      "description" => "Recorded live fixture: #{name}",
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "events" => Enum.map(events, fn event_data -> %{"data" => event_data} end)
    }

    path = Path.join(@fixtures_dir, name)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(fixture, pretty: true))
    path
  end

  @doc "Returns the path to the fixtures directory."
  def fixtures_dir, do: @fixtures_dir

  @doc """
  Builds a mock Req.Response that replays fixture events via process messages.

  Returns `{:ok, resp}` where `resp` can be used with `Req.parse_message/2`.
  The events are sent asynchronously to the caller process.
  """
  def build_fixture_response(fixture_name) do
    events = fixture_events(fixture_name)
    caller = self()
    ref = make_ref()

    resp = %Req.Response{
      status: 200,
      headers: %{},
      body: %Req.Response.Async{
        ref: ref,
        stream_fun: fn
          inner_ref, {inner_ref, {:data, data}} -> {:ok, [data: data]}
          inner_ref, {inner_ref, :done} -> {:ok, [:done]}
          _, _ -> :unknown
        end,
        cancel_fun: fn _ref -> :ok end
      }
    }

    spawn(fn ->
      Process.sleep(5)

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end)

    {:ok, resp}
  end
end
