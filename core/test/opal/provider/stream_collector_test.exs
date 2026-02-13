defmodule Opal.Provider.StreamCollectorTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.EventStream
  alias Opal.Provider.StreamCollector

  defmodule MockProvider do
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => "delta", "text" => text}} -> [{:text_delta, text}]
        {:ok, %{"type" => "done", "text" => text}} -> [{:text_done, text}]
        _ -> []
      end
    end
  end

  test "collect_text/3 reads SSE stream deltas" do
    ref = make_ref()
    resp = build_mock_resp(ref)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {ref, {:data, "data: #{Jason.encode!(%{"type" => "delta", "text" => "Hello"})}\n"}}
      )

      send(
        parent,
        {ref, {:data, "data: #{Jason.encode!(%{"type" => "delta", "text" => " world"})}\n"}}
      )

      send(parent, {ref, :done})
    end)

    assert StreamCollector.collect_text(resp, MockProvider, 1_000) == "Hello world"
  end

  test "collect_text/3 reads native event stream deltas" do
    ref = make_ref()
    stream = %EventStream{ref: ref, cancel_fun: fn -> :ok end}
    parent = self()

    spawn(fn ->
      send(parent, {ref, {:events, [{:text_start, %{}}, {:text_delta, "Native"}]}})
      send(parent, {ref, {:events, [{:text_delta, " stream"}]}})
      send(parent, {ref, :done})
    end)

    assert StreamCollector.collect_text(stream, MockProvider, 1_000) == "Native stream"
  end

  defp build_mock_resp(ref) do
    %Req.Response{
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
  end
end
