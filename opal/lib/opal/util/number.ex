defmodule Opal.Util.Number do
  @moduledoc "Numeric utilities."

  @doc """
  Clamps `value` to the range `[lo, hi]`.

      iex> Opal.Util.Number.clamp(5, 1, 10)
      5

      iex> Opal.Util.Number.clamp(-3, 0, 100)
      0

      iex> Opal.Util.Number.clamp(999, 0, 100)
      100
  """
  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
