defmodule Opal.Util.Map do
  @moduledoc "Shared map-building helpers."

  @doc """
  Strips nil and empty string values from a map.

      iex> Opal.Util.Map.compact(%{a: 1, b: nil, c: ""})
      %{a: 1}
  """
  @spec compact(map()) :: map()
  def compact(map), do: Map.reject(map, fn {_, v} -> v == nil or v == "" end)

  @doc """
  Puts `value` into `map` under `key` unless `value` is nil.

      iex> Opal.Util.Map.put_non_nil(%{a: 1}, :b, nil)
      %{a: 1}

      iex> Opal.Util.Map.put_non_nil(%{a: 1}, :b, 2)
      %{a: 1, b: 2}
  """
  @spec put_non_nil(map(), term(), term()) :: map()
  def put_non_nil(map, _key, nil), do: map
  def put_non_nil(map, key, val), do: Map.put(map, key, val)
end
