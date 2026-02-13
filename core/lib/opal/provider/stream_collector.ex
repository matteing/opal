defmodule Opal.Provider.StreamCollector do
  @moduledoc """
  Shared helper for collecting text from provider streams.

  Supports both stream shapes returned by `Opal.Provider.stream/4`:
  raw SSE via `%Req.Response{}` and native `%Opal.Provider.EventStream{}`.
  """

  alias Opal.Provider.EventStream

  @spec collect_text(Req.Response.t() | EventStream.t(), module(), non_neg_integer()) ::
          String.t()
  def collect_text(stream, provider, timeout_ms \\ 30_000)

  def collect_text(%Req.Response{} = resp, provider, timeout_ms) do
    collect_sse(resp, provider, "", timeout_ms)
  end

  def collect_text(%EventStream{ref: ref, cancel_fun: cancel_fun}, _provider, timeout_ms) do
    collect_events(ref, cancel_fun, "", timeout_ms)
  end

  defp collect_sse(
         %Req.Response{body: %Req.Response.Async{ref: ref}} = resp,
         provider,
         acc,
         timeout_ms
       ) do
    receive do
      {^ref, _} = message ->
        handle_sse_message(resp, provider, acc, timeout_ms, message)
    after
      timeout_ms -> acc
    end
  end

  defp collect_sse(resp, provider, acc, timeout_ms) do
    receive do
      message ->
        handle_sse_message(resp, provider, acc, timeout_ms, message)
    after
      timeout_ms -> acc
    end
  end

  defp collect_events(ref, cancel_fun, acc, timeout_ms) do
    receive do
      {^ref, {:events, events}} when is_list(events) ->
        collect_events(ref, cancel_fun, append_events(events, acc), timeout_ms)

      {^ref, :done} ->
        acc
    after
      timeout_ms ->
        safe_cancel(cancel_fun)
        acc
    end
  end

  defp handle_sse_message(resp, provider, acc, timeout_ms, message) do
    case Req.parse_message(resp, message) do
      {:ok, chunks} when is_list(chunks) ->
        {next_acc, done?} =
          Enum.reduce(chunks, {acc, false}, fn
            {:data, data}, {text_acc, done} ->
              {append_sse_data(data, provider, text_acc), done}

            :done, {text_acc, _done} ->
              {text_acc, true}

            _other, {text_acc, done} ->
              {text_acc, done}
          end)

        if done? do
          next_acc
        else
          collect_sse(resp, provider, next_acc, timeout_ms)
        end

      :unknown ->
        collect_sse(resp, provider, acc, timeout_ms)
    end
  end

  defp append_sse_data(data, provider, acc) do
    data
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.reduce(acc, fn
      "data: [DONE]", text_acc ->
        text_acc

      "data: " <> json, text_acc ->
        provider.parse_stream_event(json)
        |> append_events(text_acc)

      "{" <> _ = json, text_acc ->
        provider.parse_stream_event(json)
        |> append_events(text_acc)

      _other, text_acc ->
        text_acc
    end)
  end

  defp append_events(events, acc) do
    Enum.reduce(events, acc, fn
      {:text_delta, delta}, text_acc when is_binary(delta) ->
        text_acc <> delta

      {:text_done, text}, "" when is_binary(text) ->
        text

      _other, text_acc ->
        text_acc
    end)
  end

  defp safe_cancel(cancel_fun) when is_function(cancel_fun, 0) do
    cancel_fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_cancel(_), do: :ok
end
