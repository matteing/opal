defmodule Opal.Provider.EventStreamTest do
  use ExUnit.Case, async: true

  alias Opal.Provider.EventStream

  describe "struct" do
    test "enforces required keys" do
      ref = make_ref()
      cancel_fn = fn -> :ok end

      stream = %EventStream{ref: ref, cancel_fun: cancel_fn}
      assert stream.ref == ref
      assert is_function(stream.cancel_fun, 0)
    end

    test "raises without required keys" do
      assert_raise ArgumentError, fn ->
        struct!(EventStream, [])
      end
    end
  end

  describe "message protocol" do
    test "events are sent as {ref, {:events, list}}" do
      ref = make_ref()

      send(self(), {ref, {:events, [{:text_start, %{}}, {:text_delta, "hello"}]}})

      assert_received {^ref, {:events, events}}
      assert [{:text_start, %{}}, {:text_delta, "hello"}] = events
    end

    test "done is sent as {ref, :done}" do
      ref = make_ref()
      send(self(), {ref, :done})
      assert_received {^ref, :done}
    end
  end
end
